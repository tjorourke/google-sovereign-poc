#!/usr/bin/env python3
"""Send one A2A message to an agent and report which tools it actually called.

Asking a model to LIST its tools is not a test: a 3B model will happily recite a
tool name it saw in its own configuration, which reads as a policy failure when
the tool was never reachable. What cannot be faked is the tool-call trace, so
this asks the agent to DO the thing and reports what it actually invoked.
"""
import json, sys, urllib.request

prompt = sys.argv[1]
body = json.dumps({"jsonrpc": "2.0", "id": "1", "method": "message/send",
                   "params": {"message": {"role": "user", "messageId": "p1",
                              "parts": [{"kind": "text", "text": prompt}]}}}).encode()
req = urllib.request.Request("http://localhost:8080", body,
                             {"Content-Type": "application/json"})
res = json.load(urllib.request.urlopen(req, timeout=360))
res = res.get("result", res)

calls = [d.get("name") for m in (res.get("history") or [])
         for p in m.get("parts", []) if p.get("kind") == "data"
         for d in [p.get("data", {})] if "args" in d]

texts: list[str] = []
def walk(o):
    if isinstance(o, dict):
        if o.get("role") == "user":
            return
        if o.get("kind") == "text" and isinstance(o.get("text"), str):
            t = o["text"].strip()
            if t and t not in texts:
                texts.append(t)
        for v in o.values():
            walk(v)
    elif isinstance(o, list):
        for v in o:
            walk(v)
walk(res.get("artifacts") or res)

print("TOOLS=" + ",".join(c for c in calls if c))
print("ANSWER=" + (texts[-1].replace("\n", " ")[:400] if texts else ""))
