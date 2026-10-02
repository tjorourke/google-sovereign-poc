import base64
import importlib.util
import io
import json
import os
from pathlib import Path
import tarfile
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from unittest.mock import patch

import google_snapshot


class HostedRoutesTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        auth = Path(cls.temp.name) / "auth.json"
        auth.write_text(json.dumps({"username": "demo", "password": "test-only", "session_key": "test-key"}))
        with patch.dict(os.environ, GOOGLE_ONLY="1", CONSOLE_AUTH_FILE=str(auth)):
            spec = importlib.util.spec_from_file_location("hosted_serve", Path(__file__).parent / "serve.py")
            cls.module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(cls.module)
        cls.server = cls.module.ThreadingHTTPServer(("127.0.0.1", 0), cls.module.Handler)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()
        cls.url = f"http://127.0.0.1:{cls.server.server_port}"

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.temp.cleanup()

    def call(self, path, auth=False, data=None, headers=None):
        hdrs = dict(headers or {})
        if auth:
            hdrs["Authorization"] = "Basic " + base64.b64encode(b"demo:test-only").decode()
        req = urllib.request.Request(self.url + path, data=data, headers=hdrs)
        try:
            with urllib.request.urlopen(req, timeout=5) as r:
                return r.status, r.read()
        except urllib.error.HTTPError as e:
            return e.code, e.read()

    def call_raw(self, path, data=None, headers=None):
        """No redirect following: redirects are the auth behaviour under test."""
        class NoRedirect(urllib.request.HTTPRedirectHandler):
            def redirect_request(self, *a, **k):
                return None
        req = urllib.request.Request(self.url + path, data=data, headers=headers or {})
        try:
            with urllib.request.build_opener(NoRedirect).open(req, timeout=5) as r:
                return r.status, r.read(), r.headers
        except urllib.error.HTTPError as e:
            return e.code, e.read(), e.headers

    def test_health_is_public_but_demo_requires_login(self):
        self.assertEqual(self.call("/healthz")[0], 200)
        status, _, hdrs = self.call_raw("/google")
        self.assertEqual(status, 302)
        self.assertEqual(hdrs.get("Location"), "/login")
        status, body = self.call("/google", auth=True)
        self.assertEqual(status, 200)
        # The hosted nav stays inside the Google story; no other lab leaks in.
        nav = body.split(b'<div class="nav-links">')[1].split(b"</div>")[0]
        self.assertNotIn(b"/kernwerk", nav)
        self.assertIn(b"/google/dlp", nav)

    def test_other_labs_and_notebook_execution_are_absent(self):
        for path in ("/kernwerk", "/admin", "/api/notebook/run", "/api/labs/reset", "/google/all"):
            self.assertEqual(self.call(path, auth=True, data=b"{}")[0], 404)
        self.assertEqual(self.call("/kernwerk", auth=True)[0], 404)

    def test_cross_origin_write_is_rejected(self):
        self.assertEqual(self.call("/api/google/dlp/clear", auth=True, data=b"{}",
                                   headers={"Origin": "https://unrelated.example"})[0], 403)

    def test_login_page_and_session_cookie(self):
        status, body = self.call("/login")
        self.assertEqual(status, 200)
        self.assertIn(b"Sign in", body)
        # Wrong credentials: 401, no session.
        status, _ = self.call("/login", data=b"username=demo&password=wrong")
        self.assertEqual(status, 401)
        # Right credentials: 303 with an HMAC session cookie the demo accepts.
        status, _, hdrs = self.call_raw("/login", data=b"username=demo&password=test-only")
        self.assertEqual(status, 303)
        cookie = hdrs.get("Set-Cookie", "").split(";", 1)[0]
        self.assertTrue(cookie.startswith("tub_session="))
        self.assertEqual(self.call("/google", headers={"Cookie": cookie})[0], 200)
        # Sign-out clears the session cookie and returns to the login page.
        status, _, hdrs = self.call_raw("/logout", headers={"Cookie": cookie})
        self.assertEqual(status, 303)
        self.assertIn("Max-Age=0", hdrs.get("Set-Cookie", ""))
        self.assertEqual(hdrs.get("Location"), "/login")


class SnapshotTests(unittest.TestCase):
    def archive(self, dockerfile=None, symlink=False):
        output = io.BytesIO()
        with tarfile.open(fileobj=output, mode="w:gz") as tar:
            for name, content in {"Dockerfile": dockerfile or google_snapshot.DOCKERFILE,
                                  "server.py": "print('demo')", "config.json": "{}",
                                  "site/index.html": "<h1>TrustUsBank</h1>", ".env.local": "must not ship"}.items():
                data = content.encode()
                item = tarfile.TarInfo("repo-commit/" + name)
                item.size = len(data)
                tar.addfile(item, io.BytesIO(data))
            if symlink:
                item = tarfile.TarInfo("repo-commit/site/link")
                item.type, item.linkname = tarfile.SYMTYPE, "/etc/passwd"
                tar.addfile(item)
        return output.getvalue()

    def test_snapshot_is_deterministic_and_excludes_unrelated_files(self):
        first = google_snapshot.pack(self.archive())
        self.assertEqual(first, google_snapshot.pack(self.archive()))
        with tarfile.open(fileobj=io.BytesIO(first), mode="r:gz") as tar:
            self.assertEqual(set(tar.getnames()), {"server.py", "config.json", "site/index.html"})

    def test_runtime_changes_and_links_are_rejected(self):
        with self.assertRaises(ValueError):
            google_snapshot.pack(self.archive(dockerfile="FROM arbitrary-runtime"))
        with self.assertRaises(ValueError):
            google_snapshot.pack(self.archive(symlink=True))


if __name__ == "__main__":
    unittest.main()
