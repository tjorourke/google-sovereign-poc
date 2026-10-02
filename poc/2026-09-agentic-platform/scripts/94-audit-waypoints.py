#!/usr/bin/env python3
"""Export AGW waypoint spans to the Enterprise UI. Print manifests, or --apply.

MCP identity is a verified workload JWT plus mesh identity, not Bob's delegated
identity. Record that distinction explicitly instead of attributing tools to a
human whose token did not reach the waypoint. Re-run after creating new agents.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apply", action="store_true")
    args = parser.parse_args()
    env = dict(os.environ)
    deploy = Path(__file__).resolve().parents[1] / "deploy"
    fallback = next((p for p in (deploy / "console.kubeconfig", deploy / ".kubeconfig") if p.exists()), deploy / ".kubeconfig")
    env["KUBECONFIG"] = os.environ.get("GCD_KUBECONFIG", str(fallback))
    proc = subprocess.run(["kubectl", "get", "gateways", "-A", "-o", "json"], env=env,
                          text=True, capture_output=True, check=True)
    items = []
    for gw in json.loads(proc.stdout)["items"]:
        ns, name = gw["metadata"]["namespace"], gw["metadata"]["name"]
        if ns not in {"mcp", "agents", "kagent", "agentregistry-system", "trustusbank"}:
            continue
        if gw["spec"].get("gatewayClassName") != "enterprise-agentgateway-waypoint":
            continue
        items.append({"apiVersion": "enterpriseagentgateway.solo.io/v1alpha1",
                      "kind": "EnterpriseAgentgatewayPolicy",
                      "metadata": {"name": "audit-" + name.removesuffix("-waypoint"), "namespace": ns,
                                   "labels": {"company": "trustusbank", "audit-source": "google-sov"}},
                      "spec": {"targetRefs": [{"group": "gateway.networking.k8s.io", "kind": "Gateway", "name": name}],
                               "frontend": {"tracing": {
                                   "backendRef": {"name": "solo-enterprise-telemetry-collector", "namespace": "solo-enterprise", "port": 4317},
                                   "protocol": "GRPC", "randomSampling": "true",
                                   "attributes": {"add": [
                                       {"name": "audit.user", "expression": 'coalesce(jwt.preferred_username, "not delegated")'},
                                       {"name": "audit.workload", "expression": 'coalesce(jwt.sub, source.identity.namespace + "/" + source.identity.serviceAccount, "unattributed")'},
                                       {"name": "audit.agent", "expression": 'coalesce(jwt.agent_id, source.identity.namespace + "/" + source.identity.serviceAccount, "unattributed")'},
                                   ]}}}}})
    manifest = json.dumps({"apiVersion": "v1", "kind": "List", "items": items})
    if not args.apply:
        print(manifest)
    elif not items:
        raise SystemExit("No enterprise waypoints found")
    else:
        subprocess.run(["kubectl", "apply", "-f", "-"], input=manifest, text=True, env=env, check=True)
        for _ in range(30):
            result = subprocess.run(["kubectl", "get", "enterpriseagentgatewaypolicies", "-A",
                                     "-l", "audit-source=google-sov", "-o", "json"], env=env,
                                    text=True, capture_output=True, check=True)
            ready = {(p["metadata"]["namespace"], p["metadata"]["name"])
                     for p in json.loads(result.stdout)["items"]
                     if any({"Accepted", "Attached"} <= {
                         c["type"] for c in a.get("conditions", [])
                         if c.get("status") == "True" and c.get("observedGeneration") == p["metadata"]["generation"]}
                            for a in p.get("status", {}).get("ancestors", []))}
            if all((p["metadata"]["namespace"], p["metadata"]["name"]) in ready for p in items):
                break
            time.sleep(1)
        else:
            raise SystemExit("Waypoint tracing policies did not become Accepted and Attached")
        print(f"Tracing configured for {len(items)} waypoints")


if __name__ == "__main__":
    main()
