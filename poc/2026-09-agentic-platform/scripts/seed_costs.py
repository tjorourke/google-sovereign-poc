#!/usr/bin/env python3
"""Seed labelled Gemma/Gemini cost history, preserving real traffic.

Five-minute batches are deterministic and checked before insertion. Re-running
fills new completed batches instead of duplicating the history. Do not run two
seeders concurrently. Synthetic rows feed the existing ClickHouse materialized
views; they do not populate the gateway's live budget-enforcement counters.
"""
import argparse
import hashlib
import json
import math
import os
import random
from datetime import datetime, timedelta, timezone

from mcp_security import kubectl

PREFIX = "seed-cost-v2-"
PEOPLE = {
    "bob": ("payments-ops", 800, .90, {"trustusbank-payments": .65, "trustusbank-credit": .35}),
    "carol": ("payments-ops", 1200, .96, {"trustusbank-payments": .45, "trustusbank-credit": .55}),
    "david": ("development", 900, .35, {"trustusbank-dev-agent": .85, "trustusbank-pm-agent": .15}),
    "emma": ("development", 600, .45, {"trustusbank-pm-agent": .55, "trustusbank-dev-agent": .45}),
    "alice": ("compliance", 700, .99, {"trustusbank-compliance": .60, "trustusbank-gdpr": .40}),
    "frank": ("platform", 400, .60, {"trustusbank-sovereign": .80, "fx-helper": .20}),
}
MODELS = {
    "gemma-3-27b-it": ("model/llm", .60, 1.80),
    "gemini-3.8-flash": ("agentgateway-system/models", .50, 3.00),
}


def clickhouse(query, data=None):
    return kubectl("-n", os.getenv("CH_NS", "solo-enterprise"), "exec", "-i",
                   os.getenv("CH_POD", "solo-mgmt-clickhouse-shard0-0"), "-c", "clickhouse", "--",
                   "clickhouse-client", "-q", query, data=data)


def rows_for_batch(start):
    batch = start.strftime("%Y%m%d%H%M")
    rng = random.Random(batch)
    local_hour = (start.hour + 2) % 24
    day_factor = 1.0 if start.weekday() < 5 else .22
    office = .90 + .25 * math.sin((local_hour - 8) / 10 * math.pi) if 8 <= local_hour < 18 else .12
    for user, (team, daily, gemma_share, agents) in PEOPLE.items():
        expected = daily / 120 * day_factor * office * rng.uniform(.7, 1.3)
        count = int(expected) + (rng.random() < expected % 1)
        # Keep all chart dimensions represented even during quieter demo hours.
        count = max(1, count)
        for index in range(count):
            agent = rng.choices(list(agents), weights=list(agents.values()))[0]
            model = "gemma-3-27b-it" if rng.random() < gemma_share else "gemini-3.8-flash"
            route, pin, pout = MODELS[model]
            tin = max(300, int(rng.gauss(4600 if team == "development" else 3400, 900)))
            tout = max(40, int(rng.lognormvariate(6.2 if team == "development" else 5.7, .45)))
            identity = hashlib.sha256(f"{batch}/{user}/{index}".encode()).hexdigest()
            yield {
                "Timestamp": (start + timedelta(seconds=rng.randrange(300))).strftime("%Y-%m-%d %H:%M:%S.%f"),
                "TraceId": PREFIX + batch + "-" + identity[:16], "SpanId": identity[16:32], "ParentSpanId": "",
                "ServiceName": "agentgateway-proxy", "SpanName": "POST /v1/chat/completions",
                "Duration": int((.2 + tout / (55 if model.startswith("gemma") else 160)) * 1e9),
                "RequestModel": model, "ResponseModel": model, "Provider": "openai",
                "InputTokens": tin, "OutputTokens": tout, "Route": route,
                "HttpPath": "/v1/chat/completions", "HttpStatus": 200,
                "MCPTarget": "", "MCPResourceName": "", "MCPResourceType": "", "ToolName": "",
                "ErrorMsg": "", "IsRoot": 1, "HasAttrs": 1,
                "CostUsd": round((tin * pin + tout * pout) / 1e6, 9),
                "CacheReadCostUsd": 0, "CacheWriteCostUsd": 0,
                "CustomDimensions": {"user": user, "group": team, "agent": agent, "model": model,
                                     "provider": "openai", "data_origin": "demo-seed"},
                "Cluster": "agentic", "Namespace": "agentgateway-system",
            }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--days", type=int, default=14)
    args = parser.parse_args()
    if not 1 <= args.days <= 90:
        parser.error("days must be between 1 and 90")
    now = datetime.now(timezone.utc)
    end = now.replace(minute=now.minute // 5 * 5, second=0, microsecond=0)
    existing = set(clickhouse(
        f"SELECT DISTINCT substring(TraceId,{len(PREFIX)+1},12) FROM platformdb.agw_spans_typed "
        f"WHERE startsWith(TraceId,'{PREFIX}') FORMAT TSVRaw").splitlines())
    batch = end - timedelta(days=args.days)
    pending, added, batches = [], 0, 0

    def flush():
        if pending:
            clickhouse("INSERT INTO platformdb.agw_spans_typed FORMAT JSONEachRow", "\n".join(pending))
            pending.clear()

    while batch < end:
        if batch.strftime("%Y%m%d%H%M") not in existing:
            rows = list(rows_for_batch(batch))
            pending.extend(json.dumps(row, separators=(",", ":")) for row in rows)
            added += len(rows)
            batches += 1
            # Flush only at batch boundaries, so a completed batch is never
            # partially skipped by the next run's existence check.
            if len(pending) >= 5000:
                flush()
        batch += timedelta(minutes=5)
    flush()
    print(f"Added {added:,} synthetic requests in {batches:,} new five-minute batches ({args.days} days).")
    print(clickhouse(
        "SELECT RequestModel AS model, count() AS requests, sum(InputTokens+OutputTokens) AS tokens, "
        "round(sum(CostUsd),2) AS usd FROM platformdb.agw_spans_typed "
        f"WHERE startsWith(TraceId,'{PREFIX}') GROUP BY model ORDER BY model FORMAT PrettyCompact"))


if __name__ == "__main__":
    main()
