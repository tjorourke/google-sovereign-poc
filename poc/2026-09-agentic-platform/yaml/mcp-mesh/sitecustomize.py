"""ADK integration for rotating, audience-bound Kubernetes workload JWTs.

Mounted on PYTHONPATH by mcp_security.py for both BYO and declarative agents.
Use ADK's public HTTP-client factory extension rather than a static bearer header:
the kubelet rotates the projected token and every HTTP request reads it again.
Only explicitly configured MCP origins receive the token. No LLM traffic does.
"""
import json
import os
import sys
from pathlib import Path
from urllib.parse import urlsplit


def origin(url):
    u = urlsplit(url)
    return (u.scheme, u.hostname, u.port or (443 if u.scheme == "https" else 80))


def install():
    token_file = os.environ.get("MCP_WORKLOAD_TOKEN_FILE")
    if not token_file:
        return
    allowed = {origin(u) for u in json.loads(os.environ["MCP_WORKLOAD_ORIGINS"])}
    from google.adk.tools.mcp_tool.mcp_toolset import McpToolset
    original = McpToolset.__init__
    if getattr(original, "_workload_identity", False):
        return

    def authenticated(self, *args, **kwargs):
        params = kwargs.get("connection_params")
        url = getattr(params, "url", "")
        if url and origin(url) in allowed:
            factory = params.httpx_client_factory
            target = origin(url)

            async def add_identity(request):
                if origin(str(request.url)) != target:
                    raise RuntimeError("Refusing MCP credential redirect to another origin")
                token = Path(token_file).read_text().strip()
                if not token:
                    raise RuntimeError("MCP workload token is empty")
                request.headers["Authorization"] = "Bearer " + token

            def client_factory(*a, **kw):
                client = factory(*a, **kw)
                client.event_hooks.setdefault("request", []).append(add_identity)
                return client

            params.httpx_client_factory = client_factory
        original(self, *args, **kwargs)

    authenticated._workload_identity = True
    McpToolset.__init__ = authenticated


try:
    install()
except Exception as error:
    # Python normally logs and ignores sitecustomize failures. Identity setup
    # must fail closed instead of starting an apparently healthy broken agent.
    print(f"MCP workload identity bootstrap failed: {error}", file=sys.stderr)
    os._exit(1)
