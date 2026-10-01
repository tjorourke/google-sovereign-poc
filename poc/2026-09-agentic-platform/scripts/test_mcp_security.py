"""Offline regression checks for credential routing and reconciliation."""
import asyncio
import importlib.util
import os
from pathlib import Path
from tempfile import TemporaryDirectory
from types import ModuleType, SimpleNamespace
import unittest
from unittest.mock import patch

import mcp_security


class IdentityTests(unittest.TestCase):
    def test_reconcile_preserves_config_and_is_idempotent(self):
        original = {"env": [{"name": "MODEL_KEY", "valueFrom": {"secretKeyRef": {"name": "model", "key": "key"}}}],
                    "volumes": [{"name": "custom", "emptyDir": {}}],
                    "volumeMounts": [{"name": "custom", "mountPath": "/custom"}]}
        secured = mcp_security.identity_deployment(original)
        self.assertEqual(secured, mcp_security.identity_deployment(secured))
        self.assertEqual(original["env"][0], secured["env"][0])
        self.assertIn(original["volumes"][0], secured["volumes"])
        self.assertIn("/app", next(e["value"] for e in secured["env"] if e["name"] == "PYTHONPATH"))
        self.assertNotIn("mcp-workload-token", [v["name"] for v in original["volumes"]])

    def test_legacy_endpoints_only_migrate_known_mcp_hosts(self):
        self.assertEqual(mcp_security.migrate_url("http://mcp.agentic.eu0.internal/mcp/payments"),
                         "http://bank-payments.mcp.svc.cluster.local:3000/mcp")
        self.assertEqual(mcp_security.migrate_url("https://example.com/mcp/payments"),
                         "https://example.com/mcp/payments")
        with self.assertRaises(ValueError):
            mcp_security.migrate_url("http://mcp.agentic.eu0.internal/mcp/unknown")

    def test_token_rotation_and_origin_isolation(self):
        class Toolset:
            def __init__(self, **kwargs):
                self.params = kwargs["connection_params"]

        module = ModuleType("google.adk.tools.mcp_tool.mcp_toolset")
        module.McpToolset = Toolset
        with TemporaryDirectory() as temp:
            token = Path(temp) / "token"
            token.write_text("first-token")
            with patch.dict(os.environ, {"MCP_WORKLOAD_TOKEN_FILE": str(token),
                "MCP_WORKLOAD_ORIGINS": '["http://bank-payments.mcp.svc.cluster.local:3000/mcp"]'}), \
                 patch.dict("sys.modules", {module.__name__: module}):
                spec = importlib.util.spec_from_file_location("adapter_test", mcp_security.LAB / "yaml/mcp-mesh/sitecustomize.py")
                adapter = importlib.util.module_from_spec(spec)
                spec.loader.exec_module(adapter)
                factory = lambda **kw: SimpleNamespace(event_hooks={"request": []})
                params = SimpleNamespace(url="http://bank-payments.mcp.svc.cluster.local:3000/mcp", httpx_client_factory=factory)
                Toolset(connection_params=params)
                client = params.httpx_client_factory()
                request = SimpleNamespace(url=params.url, headers={})
                asyncio.run(client.event_hooks["request"][0](request))
                self.assertEqual(request.headers["Authorization"], "Bearer first-token")
                token.write_text("rotated-token")
                asyncio.run(client.event_hooks["request"][0](request))
                self.assertEqual(request.headers["Authorization"], "Bearer rotated-token")
                request.url = "https://attacker.example/mcp"
                with self.assertRaises(RuntimeError):
                    asyncio.run(client.event_hooks["request"][0](request))
                llm = SimpleNamespace(url="http://llm.agentic.eu0.internal/v1", httpx_client_factory=factory)
                Toolset(connection_params=llm)
                self.assertIs(llm.httpx_client_factory, factory)


if __name__ == "__main__":
    unittest.main()
