#!/usr/bin/env bash
# 57-ar-ask.sh "<prompt>" — ask the AgentRegistry-deployed agent, and print the
# tools it actually called alongside its answer.
#
# The A2A call is made from inside the cluster (kubectl exec into a pod that has
# python3) rather than from the laptop, because the agent's Service is only
# reachable on the cluster network and GCD publishes no name for it. The tool
# calls come back as `data` parts on result.history, so we can show the tool
# hops without depending on the trace backend.
set -uo pipefail
SD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SD/lib.sh"
load_env
kube_context >/dev/null 2>&1 || true
assert_kube_reachable

PROMPT="${*:-Add 17 and 25 using your sum tool.}"

SVC="$(kubectl -n agentregistry-system get svc -o name 2>/dev/null \
       | grep -m1 sovereignagent | cut -d/ -f2)"
[[ -n "$SVC" ]] || die "no AgentRegistry-deployed agent Service found — run 56-ar-push-agent.sh"

# Any in-cluster pod with python3; see python_pod() in lib.sh for why this is
# not a fixed selector.
CALLER="$(python_pod)" || die "no in-cluster pod with python3 to call from"
POD_NS="${CALLER%%/*}"; POD="${CALLER##*/}"

log "asking ${SVC} — \"${PROMPT}\"  (from ${POD_NS}/${POD})"
kubectl -n "$POD_NS" exec -i "$POD" -- python3 - "$SVC" "$PROMPT" <<'PY'
import json, sys, urllib.request
svc, prompt = sys.argv[1], sys.argv[2]
url = "http://%s.agentregistry-system.svc.cluster.local:8080" % svc
body = json.dumps({"jsonrpc":"2.0","id":"1","method":"message/send","params":{"message":{
    "role":"user","messageId":"ask-1","parts":[{"kind":"text","text":prompt}]}}}).encode()
r = json.load(urllib.request.urlopen(
    urllib.request.Request(url, body, {"Content-Type":"application/json"}), timeout=280))
res = r.get("result", r)

calls, resps = [], {}
for m in (res.get("history") or []):
    for p in m.get("parts", []):
        if p.get("kind") == "data":
            d = p.get("data", {})
            if "args" in d:     calls.append(d)
            if "response" in d: resps[d.get("id")] = d["response"]
if calls:
    print("\nTools the agent called:")
    for i, c in enumerate(calls, 1):
        out = resps.get(c.get("id"), {})
        sc  = out.get("structuredContent") if isinstance(out, dict) else None
        val = sc.get("result") if isinstance(sc, dict) else out
        print("  %d. %s(%s) -> %s" % (i, c.get("name"), c.get("args"), val))

seen = []
def walk(o):
    if isinstance(o, dict):
        if o.get("role") == "user": return
        if o.get("kind") == "text" and isinstance(o.get("text"), str):
            t = o["text"].strip()
            if t and t not in seen: seen.append(t)
        for v in o.values(): walk(v)
    elif isinstance(o, list):
        for v in o: walk(v)
walk(res.get("artifacts") or res)
print("\nAnswer: " + (seen[-1] if seen else json.dumps(r)[:400]))
PY
