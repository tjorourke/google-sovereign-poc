#!/usr/bin/env python3
"""Render the per-agent MCP tool policies from yaml/mcp-mesh/grants.json.

One EnterpriseAgentgatewayPolicy per agent per MCP backend, <agent>--<backend> in
ns mcp, enforced at the shared mcp-waypoint. Its one clause names the agent by its
mesh identity (the namespace and ServiceAccount in its SPIFFE certificate, which
ztunnel proves) and the tools it may use on that server. No HTTP header is
trusted. agentgateway ORs every Allow policy attached to a backend, so a new agent
is a new policy and nobody else's changes; removing an agent deletes its policies.

Default deny comes from mcp-catalog--tools-list: one policy on every backend that
lets the mcp-catalog workload call tools/list (so the console can show an admin
what a server offers) and nothing else. With an Allow policy always attached,
any caller no policy names is refused.

    mcp_policies.py           print the YAML (grants.json and the catalog policy)
    mcp_policies.py --apply   apply it, and delete the grants.json policies no longer rendered

Every policy is labelled mcp-lockdown/source: "grants" for this file's, "console"
for the ones the demo console writes when an admin approves a builder agent. Each
side prunes only its own, so re-running this never removes an approval.

An agent is named, not its ServiceAccount: AgentRegistry names the Deployment and
its SA <agent>-latest-<deployment name, cut to 16>, kagent names them <agent>, and
the live Deployments decide which. An agent with no Deployment yet gets no policy
until it exists (re-run, or let the console re-sync on deploy).
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path

LAB = Path(__file__).resolve().parent.parent
GRANTS = LAB / "yaml" / "mcp-mesh" / "grants.json"
NS = "mcp"


def load(path: Path = GRANTS) -> dict:
    return json.loads(path.read_text())


def service_accounts(namespaces, env: dict | None = None) -> dict:
    """(namespace, deployment) -> ServiceAccount, for the namespaces agents run in."""
    out = {}
    for ns in sorted(set(namespaces)):
        context = (env or os.environ).get("KUBE_CONTEXT")
        ctx = ["--context", context] if context else []
        r = subprocess.run(["kubectl", *ctx, "-n", ns, "get", "deploy", "-o", "json"],
                           capture_output=True, text=True, timeout=30, env=env)
        if r.returncode != 0:
            raise RuntimeError(f"cannot list Deployments in {ns}: {r.stderr.strip()}")
        for d in json.loads(r.stdout).get("items", []):
            spec = d["spec"]["template"]["spec"]
            out[(ns, d["metadata"]["name"])] = spec.get("serviceAccountName") or "default"
    return out


def resolve(ns: str, agent: str, sas: dict) -> list[str]:
    """The ServiceAccounts an agent runs as: <agent> itself, or AgentRegistry's <agent>-latest-*."""
    hits = [sa for (n, dep), sa in sas.items()
            if n == ns and (dep == agent or dep.startswith(f"{agent}-latest-"))]
    return sorted(set(hits))


def clause(ns: str, sa: str, tools: list[str] | None) -> str:
    who = f'(source.identity.namespace == "{ns}"\n  && source.identity.serviceAccount == "{sa}"'
    if tools is None:
        return who + '\n  && mcp.methodName == "tools/list")'
    return who + f'\n  && mcp.tool.name in {json.dumps(sorted(set(tools)))})'


CATALOG_POLICY = "mcp-catalog--tools-list"
LABEL = "mcp-lockdown"


def _meta(name: str, source: str, **labels) -> dict:
    return {"name": name, "namespace": NS,
            "labels": {"app.kubernetes.io/managed-by": "mcp-lockdown", f"{LABEL}/source": source,
                       **{f"{LABEL}/{k}": v for k, v in labels.items()}}}


def _allow(targets: list[str], exprs: list[str]) -> dict:
    return {
        "targetRefs": [{"group": "agentgateway.dev", "kind": "AgentgatewayBackend", "name": b} for b in targets],
        "backend": {"mcp": {"authorization": {"action": "Allow", "policy": {"matchExpressions": exprs}}}},
    }


def _doc(meta: dict, spec: dict) -> dict:
    return {"apiVersion": "enterpriseagentgateway.solo.io/v1alpha1",
            "kind": "EnterpriseAgentgatewayPolicy", "metadata": meta, "spec": spec}


def agent_policies(cfg: dict, grants: list[dict], sas: dict, source: str) -> list[dict]:
    """One policy per (agent, backend): every ServiceAccount the agent runs as, with
    the tools granted on that server. Repeated grants for the same pair are merged."""
    tools: dict = {}
    for g in grants:
        svc = cfg["services"].get(g["service"])
        if svc:
            tools.setdefault((g["namespace"], g["agent"], svc["backend"]), set()).update(g["tools"])
    out = []
    for (ns, agent, backend), ts in sorted(tools.items()):
        accounts = resolve(ns, agent, sas)
        if not accounts or not ts:
            continue
        out.append(_doc(_meta(f"{agent}--{backend}", source, agent=agent, **{"agent-namespace": ns}, backend=backend),
                        _allow([backend], [clause(ns, sa, sorted(ts)) for sa in accounts])))
    return out


def catalog_policy(cfg: dict) -> dict:
    """tools/list for mcp-catalog on every backend: the one Allow always attached."""
    cat = cfg["catalog"]
    return _doc(_meta(CATALOG_POLICY, "grants", agent=cat["serviceAccount"], **{"agent-namespace": cat["namespace"]}),
                _allow(sorted(s["backend"] for s in cfg["services"].values()),
                       [clause(cat["namespace"], cat["serviceAccount"], None)]))


def to_yaml(doc, indent=0) -> str:
    """Just enough YAML for these policies, with multi-line CEL as literal blocks."""
    pad = "  " * indent
    lines = []
    if isinstance(doc, dict):
        for k, v in doc.items():
            if isinstance(v, (dict, list)) and v:
                lines.append(f"{pad}{k}:")
                lines.append(to_yaml(v, indent + 1))
            else:
                lines.append(f"{pad}{k}: {scalar(v, indent)}")
    else:
        for v in doc:
            if isinstance(v, dict):
                body = to_yaml(v, indent + 1).lstrip()
                lines.append(f"{pad}- {body}")
            else:
                lines.append(f"{pad}- {scalar(v, indent)}")
    return "\n".join(lines)


def scalar(v, indent) -> str:
    if isinstance(v, str) and "\n" in v:
        pad = "  " * (indent + 1)
        return "|\n" + "\n".join(pad + line for line in v.splitlines())
    return json.dumps(v)


def render(grants: list[dict] | None = None, cfg: dict | None = None, env: dict | None = None,
           sas: dict | None = None, source: str = "grants") -> list[dict]:
    """source="grants" renders grants.json and the catalog policy. Anything else
    renders only the grants passed in, labelled with that source (the console).
    sas= adds (namespace, deployment) -> ServiceAccount entries not live yet."""
    cfg = cfg or load()
    if grants is None:
        grants = cfg["grants"]
    sas = {**service_accounts((g["namespace"] for g in grants), env), **(sas or {})}
    docs = agent_policies(cfg, grants, sas, source)
    return [catalog_policy(cfg)] + docs if source == "grants" else docs


def _kubectl(args: list[str], env: dict | None, stdin: str | None = None) -> str:
    context = (env or os.environ).get("KUBE_CONTEXT")
    ctx = ["--context", context] if context else []
    r = subprocess.run(["kubectl", *ctx, *args], input=stdin, capture_output=True, text=True, timeout=60, env=env)
    if r.returncode != 0:
        raise RuntimeError(r.stderr.strip())
    return r.stdout


def apply(docs: list[dict], source: str = "grants", env: dict | None = None) -> list[str]:
    """Apply docs, then delete this source's policies that are no longer rendered.
    The grants side also clears unlabelled mcp-lockdown policies (the old
    <backend>-per-agent ones). Returns the names deleted."""
    if docs:
        _kubectl(["apply", "-f", "-"], env, "\n---\n".join(to_yaml(d) for d in docs))
    keep = {d["metadata"]["name"] for d in docs}
    live = json.loads(_kubectl(["-n", NS, "get", "enterpriseagentgatewaypolicies",
                                "-l", "app.kubernetes.io/managed-by=mcp-lockdown", "-o", "json"], env))
    stale = []
    for p in live.get("items", []):
        mine = (p["metadata"].get("labels") or {}).get(f"{LABEL}/source")
        if p["metadata"]["name"] not in keep and (mine == source or (source == "grants" and mine is None)):
            stale.append(p["metadata"]["name"])
    if stale:
        _kubectl(["-n", NS, "delete", "enterpriseagentgatewaypolicies", *stale, "--ignore-not-found"], env)
    return stale


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--apply", action="store_true", help="apply, and prune the grants.json policies no longer rendered")
    a = ap.parse_args()
    docs = render()
    if not a.apply:
        print("\n---\n".join(to_yaml(p) for p in docs))
        return 0
    gone = apply(docs)
    print(f"applied {len(docs)} policies" + (f", deleted {', '.join(gone)}" if gone else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
