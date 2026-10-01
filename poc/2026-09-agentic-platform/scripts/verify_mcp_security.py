#!/usr/bin/env python3
"""Read-only live security checks. Exit nonzero on any failed assertion.

No tokens or tool data are emitted. tools/call probes use sum/echo only.
Run with the isolated KUBECONFIG and optionally KUBE_CONTEXT.
"""
import argparse
import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

import mcp_security as security
import mcp_policies

PROBE = r'''
import json,sys,urllib.request,urllib.error
from pathlib import Path
cfg=json.load(sys.stdin)
token=cfg.get("token") or Path("/var/run/secrets/mcp/token").read_text().strip()
def rpc(url,method,params=None,sid=None,auth="valid"):
    h={"Content-Type":"application/json","Accept":"application/json, text/event-stream"}
    if auth != "missing": h["Authorization"]="Bearer "+(token if auth=="valid" else "invalid.jwt.signature")
    if sid: h["mcp-session-id"]=sid
    body={"jsonrpc":"2.0","id":1,"method":method}
    if params is not None: body["params"]=params
    try:
        with urllib.request.urlopen(urllib.request.Request(url,json.dumps(body).encode(),h),timeout=8) as r:
            raw=r.read().decode(); payload=next((l[5:] for l in raw.splitlines() if l.startswith("data:")),raw)
            return r.status, (json.loads(payload) if payload.strip() else {}),r.headers.get("mcp-session-id") or sid
    except urllib.error.HTTPError as e:
        return e.code,{"error":e.read().decode()},sid
    except (urllib.error.URLError,ConnectionError,TimeoutError) as e:
        return 0,{"error":type(e).__name__},sid
out=[]
for test in cfg["tests"]:
    url=test["url"]; auth=test.get("auth","valid")
    code,data,sid=rpc(url,"initialize",{"protocolVersion":"2025-03-26","capabilities":{},
        "clientInfo":{"name":"security-audit","version":"1"}},auth=auth)
    row={"name":test["name"],"status":code}
    if code==200 and test.get("list"):
        code,data,_=rpc(url,"tools/list",{},sid,auth)
        row.update(status=code,tools=sorted(t["name"] for t in data.get("result",{}).get("tools",[])))
    if code==200 and test.get("call"):
        code,data,_=rpc(url,"tools/call",test["call"],sid,auth)
        row.update(status=code,denied=bool(data.get("error") or data.get("result",{}).get("isError")))
    out.append(row)
print(json.dumps(out))
'''


def probe(ns, dep, tests, token=None):
    config = {"tests": tests}
    if token:
        config["token"] = token
    result = security.kubectl("-n", ns, "exec", "-i", "deploy/" + dep, "--", "python3", "-c", PROBE,
                              data=json.dumps(config))
    return json.loads(result)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, help="Write credential-free JSON evidence")
    options = parser.parse_args()
    checks = []

    def check(name, passed, detail=""):
        checks.append({"check": name, "passed": bool(passed), "detail": detail})
        print(("PASS " if passed else "FAIL ") + name + (": " + detail if detail else ""))

    servers = security.servers()
    policies = security.get("enterpriseagentgatewaypolicy")
    routes = security.get("httproute")
    gateways = {(g["metadata"]["namespace"], g["metadata"]["name"]): g for g in security.get("gateway")}
    for s in servers:
        name = s["namespace"] + "/" + s["name"]
        p = next((p for p in policies if p["metadata"]["namespace"] == s["namespace"] and
                  p["metadata"]["name"] == s["name"] + "-strict-jwt"), {})
        jwt = p.get("spec", {}).get("traffic", {}).get("jwtAuthentication", {})
        check(name + " strict JWT", jwt.get("mode") == "Strict" and
              all(security.AUDIENCE in provider.get("audiences", []) for provider in jwt.get("providers", [])))
        statuses = [c for a in p.get("status", {}).get("ancestors", []) for c in a.get("conditions", [])]
        check(name + " policy attached", bool(statuses) and all(c["status"] == "True" and
              c.get("observedGeneration") == p["metadata"]["generation"] for c in statuses))
    check("No edge MCP routes", not any(r["metadata"]["namespace"] == "mcp" and any(
        p.get("kind", "Gateway") == "Gateway" for p in r["spec"].get("parentRefs", [])) for r in routes))

    tests = [{"name": s["namespace"] + "/" + s["name"] + " " + auth, "url": security.url(s), "auth": auth}
             for s in servers for auth in ("missing", "invalid")]
    for r in probe("mcp", "mcp-catalog", tests):
        check(r["name"], r["status"] == 401, "HTTP " + str(r["status"]))
    for r in probe("mcp", "mcp-catalog", [{"name": s["name"] + " catalog", "url": security.url(s), "list": True}
                                          for s in servers if s["namespace"] == "mcp"]):
        check(r["name"], r["status"] == 200 and bool(r.get("tools")), str(len(r.get("tools", []))) + " tools")

    agents = security.get("agents.kagent.dev")
    pods = security.get("pod")
    svcs = {(s["metadata"]["namespace"], s["metadata"]["name"]): s for s in security.get("service")}
    for a in agents:
        ns, name = a["metadata"]["namespace"], a["metadata"]["name"]
        svc = svcs.get((ns, name), {})
        wp = svc.get("metadata", {}).get("labels", {}).get("istio.io/use-waypoint")
        gateway = gateways.get((ns, wp), {})
        check(ns + "/" + name + " waypoint", bool(wp) and any(c["type"] == "Programmed" and
              c["status"] == "True" for c in gateway.get("status", {}).get("conditions", [])), wp or "missing")
        field = "byo" if a["spec"]["type"] == "BYO" else "declarative"
        env = {e["name"]: e.get("value") for e in a["spec"][field].get("deployment", {}).get("env", [])}
        check(name + " rotating JWT", env.get("MCP_WORKLOAD_TOKEN_FILE") == security.TOKEN_PATH)
        pod = next(p for p in pods if p["metadata"]["namespace"] == ns and
                   p["metadata"].get("labels", {}).get("kagent") == name and p["status"]["phase"] == "Running")
        bypass = probe("kagent", "mcp-discovery-refresh", [{"name": "agent bypass",
            "url": f'http://{pod["status"]["podIP"]}:8080/'}])[0]
        check(name + " controller pod-IP bypass denied", bypass["status"] == 0)
        if field == "byo":
            endpoints = [v["url"] for v in json.loads(env.get("MCP_SERVERS_CONFIG") or "[]")]
        else:
            endpoints = ["http://everything-server." + ("agents" if ns == "agents" else "mcp") + ".svc.cluster.local:3000/mcp"]
        for endpoint in endpoints:
            srv = next((s for s in servers if security.url(s) == endpoint), None)
            check(name + " mesh endpoint", srv is not None, endpoint)
            if not srv:
                continue
            clauses = [e for p in policies if p["metadata"]["namespace"] == srv["namespace"] and any(
                t["name"] == srv["backend"] for t in p["spec"].get("targetRefs", []))
                for e in p["spec"].get("backend", {}).get("mcp", {}).get("authorization", {}).get("policy", {}).get("matchExpressions", [])
                if f'== "{ns}"' in e and f'== "{name}"' in e]
            allowed = set()
            for expr in clauses:
                match = re.search(r'mcp.tool.name in (\[[^\]]*\])', expr)
                if match:
                    allowed.update(json.loads(match[1]))
                allowed.update(re.findall(r'mcp.tool.name == "([^"]+)"', expr))
            r = probe(ns, name, [{"name": name, "url": endpoint, "list": True}])[0]
            check(name + " exact tool grant", r["status"] == 200 and set(r.get("tools", [])) == allowed,
                  ", ".join(r.get("tools", [])) or "no tools (default deny)")

    # Valid signature but wrong audience, and valid token replayed from another
    # mesh identity. Neither bearer value is printed or passed on a command line.
    wrong = security.kubectl("-n", "mcp", "create", "token", "mcp-catalog", "--audience=wrong-audience", "--duration=10m").strip()
    r = probe("mcp", "mcp-catalog", [{"name": "wrong audience", "url": security.url(servers[0])}], wrong)[0]
    check("Wrong audience denied", r["status"] == 401, "HTTP " + str(r["status"]))
    replay = security.kubectl("-n", "mcp", "create", "token", "mcp-catalog", "--audience=" + security.AUDIENCE,
                             "--duration=10m").strip()
    r = probe("agentregistry-system", "trustusbank-payments-latest-trustusbank-paym", [
        {"name": "identity replay", "url": security.url(servers[0])}], replay)[0]
    check("JWT/mesh identity mismatch denied", r["status"] == 403, "HTTP " + str(r["status"]))
    for s in servers:
        pod = next(p for p in security.get("pod", s["namespace"]) if all(
            p["metadata"].get("labels", {}).get(k) == v for k, v in s["selector"].items()) and p["status"]["phase"] == "Running")
        r = probe("mcp", "mcp-catalog", [{"name": "pod bypass", "url":
            f'http://{pod["status"]["podIP"]}:{s["port"]}{s["path"]}'}])[0]
        check(s["namespace"] + "/" + s["name"] + " pod-IP bypass denied", r["status"] == 0)
    endpoint = "http://everything-server.mcp.svc.cluster.local:3000/mcp"
    for tool, args, denied in [("sum", {"a": 17, "b": 25}, False), ("echo", {"message": "security-audit"}, True)]:
        r = probe("kagent", "sovereign-calc", [{"name": tool, "url": endpoint,
            "call": {"name": tool, "arguments": args}}])[0]
        check("sovereign-calc " + tool, (r["status"] in (200, 400) if denied else r["status"] == 200) and r.get("denied") == denied,
              "denied" if r.get("denied") else "allowed")
    failed = sum(not c["passed"] for c in checks)
    print(f"\n{len(checks)-failed}/{len(checks)} checks passed")
    if options.output:
        options.output.write_text(json.dumps({"verifiedAt": datetime.now(timezone.utc).isoformat(),
            "passed": len(checks) - failed, "failed": failed, "checks": checks}, indent=2) + "\n")
    return bool(failed)


if __name__ == "__main__":
    sys.exit(main())
