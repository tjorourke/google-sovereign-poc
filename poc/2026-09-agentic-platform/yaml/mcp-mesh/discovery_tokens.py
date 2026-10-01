"""Keep controller discovery headers current from its projected workload JWT.

Runs as kagent-controller, with permission to patch only the named discovery
Secret in the three MCP client namespaces. Tokens stay inside Kubernetes.
"""
import json
import ssl
import time
import urllib.request
from pathlib import Path

ROOT = Path("/var/run/secrets/kubernetes.io/serviceaccount")
TLS = ssl.create_default_context(cafile=str(ROOT / "ca.crt"))


def sync():
    token = Path("/var/run/secrets/mcp/token").read_text().strip()
    for ns in ("kagent", "agents", "agentregistry-system"):
        request = urllib.request.Request(
            f"https://kubernetes.default.svc/api/v1/namespaces/{ns}/secrets/mcp-discovery-identity",
            json.dumps({"stringData": {"Authorization": "Bearer " + token}}).encode(),
            {"Authorization": "Bearer " + (ROOT / "token").read_text().strip(),
             "Content-Type": "application/merge-patch+json"}, method="PATCH")
        with urllib.request.urlopen(request, context=TLS, timeout=15):
            pass
    Path("/tmp/identity-ready").touch()


while True:
    try:
        sync()
    except Exception as error:
        print(f"Discovery identity refresh failed: {type(error).__name__}", flush=True)
        Path("/tmp/identity-ready").unlink(missing_ok=True)
    time.sleep(60)
