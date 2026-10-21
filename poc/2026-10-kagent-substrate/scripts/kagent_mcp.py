#!/usr/bin/env python3
"""kagent_mcp.py: call kagent's own MCP server (kagent-controller, /mcp).

kagent 1.0 serves its API as MCP tools as well as gRPC: sessions, checkpoints,
forks and sandboxes. The kagent CLI has no checkpoint or fork commands, so the
lab calls them here. Standard library only (MCP streamable HTTP, JSON-RPC).

  kagent_mcp.py URL tools                    tool names, one per line
  kagent_mcp.py URL call TOOL '{"k": "v"}'   the tool's result as JSON

URL is the controller's base URL, e.g. http://127.0.0.1:8083. kagent's default
authenticator takes the caller from X-User-Id, the same header the CLI sends
(--user-id, default admin@kagent.dev); sessions are partitioned by it.
"""
import json
import os
import sys
import urllib.error
import urllib.request

USER = os.environ.get("KAGENT_USER_ID", "admin@kagent.dev")
PROTOCOL = "2025-06-18"


class MCP:
    def __init__(self, base):
        self.url = base.rstrip("/") + "/mcp"
        self.session = None
        self.next_id = 0

    def _post(self, body):
        headers = {
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
            "X-User-Id": USER,
            "MCP-Protocol-Version": PROTOCOL,
        }
        if self.session:
            headers["Mcp-Session-Id"] = self.session
        req = urllib.request.Request(self.url, data=json.dumps(body).encode(), headers=headers, method="POST")
        try:
            with urllib.request.urlopen(req, timeout=300) as resp:
                self.session = resp.headers.get("Mcp-Session-Id") or self.session
                raw = resp.read().decode()
                ctype = resp.headers.get("Content-Type", "")
        except urllib.error.HTTPError as e:
            sys.exit(f"MCP HTTP {e.code}: {e.read().decode()[:500]}")
        if not raw.strip():
            return None
        if "text/event-stream" in ctype:
            # The JSON-RPC response is the data of the last SSE "message" event.
            data = [line[5:].strip() for line in raw.splitlines() if line.startswith("data:")]
            raw = data[-1] if data else "null"
        return json.loads(raw)

    def request(self, method, params=None):
        self.next_id += 1
        msg = self._post({"jsonrpc": "2.0", "id": self.next_id, "method": method, "params": params or {}})
        if msg is None:
            sys.exit(f"MCP {method}: empty response")
        if "error" in msg:
            sys.exit(f"MCP {method} error: {json.dumps(msg['error'])}")
        return msg["result"]

    def open(self):
        self.request("initialize", {
            "protocolVersion": PROTOCOL,
            "capabilities": {},
            "clientInfo": {"name": "kagent-substrate-lab", "version": "1"},
        })
        self._post({"jsonrpc": "2.0", "method": "notifications/initialized"})
        return self


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    mcp = MCP(sys.argv[1]).open()
    if sys.argv[2] == "tools":
        for tool in mcp.request("tools/list").get("tools", []):
            print(tool["name"])
        return
    if sys.argv[2] == "call" and len(sys.argv) >= 4:
        args = json.loads(sys.argv[4]) if len(sys.argv) > 4 else {}
        result = mcp.request("tools/call", {"name": sys.argv[3], "arguments": args})
        if result.get("isError"):
            text = " ".join(c.get("text", "") for c in result.get("content", []))
            sys.exit(f"tool {sys.argv[3]} failed: {text}")
        out = result.get("structuredContent")
        if out is None:
            text = "".join(c.get("text", "") for c in result.get("content", []))
            try:
                out = json.loads(text)
            except ValueError:
                out = {"text": text}
        print(json.dumps(out, indent=2))
        return
    sys.exit(__doc__)


if __name__ == "__main__":
    main()
