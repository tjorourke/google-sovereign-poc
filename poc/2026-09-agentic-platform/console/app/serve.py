#!/usr/bin/env python3
"""Demo console on http://localhost:8900

    python3 serve.py
    KUBE_CONTEXT=arn:aws:eks:... python3 serve.py   # override the pin below

Homepage with two cards. /decisions is the live Gateway decisions view from
the task-routing cluster. /economy is Token economics with MCP.

Each lab reaches its own cluster and pins its own context, so kubectl's current
context is never consulted: this file pins model-routing for Gateway decisions,
live_run pins kind-mesh1, substrate pins kind-substrate, and dlp and agents_lab
find model-routing themselves.
"""
from __future__ import annotations

import errno
import base64
import hashlib
import hmac
import html
import re
import importlib.util
import json
import mimetypes
import os
import queue
import signal
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT))

GOOGLE_ONLY = os.environ.get("GOOGLE_ONLY") == "1"
if not GOOGLE_ONLY:
    import notebooks  # noqa: E402  (local multi-lab console only)
import google_sov  # noqa: E402
PAGES = ROOT / "pages"
STATIC = ROOT / "static"
DATA = ROOT / "data"
# /app has no parents[1] in the container; the dashboard module is laptop-only.
LAB_DASH = None if GOOGLE_ONLY else ROOT.parents[1] / "agentgateway-inference-task-routing-eks" / "scripts" / "30-dashboard.py"

PORT = int(os.environ.get("DASHBOARD_PORT", "8900"))
NS = os.environ.get("DASHBOARD_NAMESPACE", "agentgateway-system")


# opa and decision-gateway only exist on model-routing. The console serves labs
# from several clusters at once (live_run pins kind-mesh1, substrate pins
# kind-substrate), so kubectl's current context says nothing about where this
# page's logs are: pin it by name the way dlp and agents_lab already do.
def current_context() -> str:
    if os.environ.get("KUBE_CONTEXT") or os.environ.get("MODEL_ROUTING_CONTEXT"):
        return os.environ.get("KUBE_CONTEXT") or os.environ["MODEL_ROUTING_CONTEXT"]
    try:
        names = subprocess.check_output(
            ["kubectl", "config", "get-contexts", "-o", "name"],
            text=True, stderr=subprocess.DEVNULL,
        ).split()
    except Exception:
        return ""
    return next((n for n in names if n.endswith("cluster/model-routing") or n == "model-routing"),
                next((n for n in names if n == "kind-model-routing"), ""))


CTX = "" if GOOGLE_ONLY else current_context()
HOSTED_AUTH = None
if GOOGLE_ONLY:
    # Hosting exposes agent creation and approvals. Fail startup without a
    # mounted access credential rather than publishing an anonymous admin UI.
    HOSTED_AUTH = json.loads(Path(os.environ["CONSOLE_AUTH_FILE"]).read_text())
    if not HOSTED_AUTH.get("username") or not HOSTED_AUTH.get("password") or not HOSTED_AUTH.get("session_key"):
        raise RuntimeError("CONSOLE_AUTH_FILE must contain username, password and session_key")

LOGIN_PAGE = """<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Sign in · TrustUsBank</title><style>
  body { margin: 0; min-height: 100vh; display: grid; place-items: center; background: #f4f1ec;
         font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Helvetica, Arial, sans-serif; }
  .card { background: #fff; border: 1px solid #e8e2d8; border-radius: 20px; padding: 36px 34px;
          width: min(380px, 92vw); box-shadow: 0 24px 60px -40px rgba(18,13,31,.35); }
  h1 { margin: 18px 0 4px; font-size: 22px; color: #120d1f; }
  .sub { color: #6b6478; font-size: 13.5px; margin: 0 0 22px; }
  label { display: block; font-size: 12px; font-weight: 700; color: #5d5669; margin: 14px 0 6px; }
  input { width: 100%; box-sizing: border-box; border: 1px solid #e0d9ce; border-radius: 10px;
          padding: 11px 13px; font: 15px/1.4 inherit; background: #fbfaf7; }
  input:focus { outline: 2px solid #c4b5fd; border-color: #c4b5fd; }
  button { margin-top: 22px; width: 100%; border: 0; border-radius: 999px; padding: 12px;
           background: #120d1f; color: #fff; font: 800 15px/1 inherit; cursor: pointer; }
  .err { margin-top: 14px; color: #b91c1c; font-size: 13px; font-weight: 650; }
  .err[hidden] { display: none; }
</style></head><body>
<form class="card" method="post" action="/login">
  <svg width="26" height="26" viewBox="0 0 48 48" aria-hidden="true">
    <g stroke="#a78bfa" stroke-width="2.4" opacity="0.6" stroke-linecap="round">
      <line x1="24" y1="7" x2="7" y2="24"/><line x1="24" y1="7" x2="41" y2="24"/>
      <line x1="7" y1="24" x2="41" y2="24"/><line x1="24" y1="24" x2="24" y2="41"/>
    </g>
    <circle cx="24" cy="7" r="5" fill="#a78bfa"/><circle cx="7" cy="24" r="5" fill="#7c3aed"/>
    <circle cx="41" cy="24" r="5" fill="#7c3aed"/><circle cx="24" cy="41" r="5" fill="#5b21b6"/>
  </svg>
  <h1>TrustUsBank</h1>
  <p class="sub">Google Sovereign Cloud demo · Berlin</p>
  <label for="u">Username</label>
  <input id="u" name="username" autocomplete="username" autofocus required>
  <label for="p">Password</label>
  <input id="p" name="password" type="password" autocomplete="current-password" required>
  <p class="err" hidden>Wrong username or password.</p>
  <button type="submit">Sign in</button>
</form>
</body></html>
"""

dashboard = None
decisions_ok = False
decisions_error = ""


def load_dashboard():
    global dashboard
    spec = importlib.util.spec_from_file_location("task_dashboard", LAB_DASH)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    dashboard = mod
    return mod


NAV = """<nav class="console-nav">
  <a class="brand" href="/">
    <svg width="22" height="22" viewBox="0 0 48 48" aria-hidden="true">
      <g stroke="#a78bfa" stroke-width="2.4" opacity="0.6" stroke-linecap="round">
        <line x1="24" y1="7" x2="7" y2="24"/><line x1="24" y1="7" x2="41" y2="24"/>
        <line x1="7" y1="24" x2="41" y2="24"/><line x1="7" y1="24" x2="24" y2="41"/>
        <line x1="41" y1="24" x2="24" y2="41"/>
      </g>
      <circle cx="24" cy="7" r="5" fill="#a78bfa"/>
      <circle cx="7" cy="24" r="5" fill="#7c3aed"/>
      <circle cx="41" cy="24" r="5" fill="#7c3aed"/>
      <circle cx="24" cy="41" r="5" fill="#5b21b6"/>
    </svg>
    Solo.io
  </a>
  <div class="nav-links">
    <a href="/user-story-1" class="up">← Agentics Overview</a>
    <a href="/desktop">Agentdesktop</a>
    <a href="/decisions" class="active">Gateway decisions</a>
    <a href="/economy">Token economics</a>
    <a href="/cost">Cost</a>
    <a href="/agents">My agents</a>
    <a href="/approvals">Platform approval</a>
    <a href="/petstore">Agent SDLC</a>
    <a href="/substrate">Substrate</a>
  </div>
  <span class="nav-status"><i class="dot live"></i><span>live from the cluster</span></span>
</nav>
"""


def nav_html() -> str:
    if decisions_ok:
        state = '<i class="dot live"></i><span>live from the cluster</span>'
    else:
        why = html.escape(decisions_error or "not attached")
        state = f'<i class="dot off"></i><span>not attached · {why}</span>'
    return NAV.replace(
        '<i class="dot live"></i><span>live from the cluster</span>',
        state,
        1,
    )


# The data classification story reuses Agentdesktop and Gateway decisions, under its
# own paths, so its nav keeps the presenter inside that story.
KERNWERK_LINKS = [
    ("/kernwerk", "Data classification"),
    ("/kernwerk/desktop", "Agentdesktop"),
    ("/kernwerk/gateway-decisions", "Gateway decisions"),
    ("/kernwerk/prompts", "Demo prompts"),
    ("/kernwerk/dlp", "Data protection"),
    ("/kernwerk/manifests", "Manifests"),
]


def kernwerk_nav(page: str, active: str) -> str:
    links = ['    <a href="/" class="up">← All demos</a>'] + [
        '    <a href="%s"%s>%s</a>' % (href, ' class="active"' if href == active else "", label)
        for href, label in KERNWERK_LINKS]
    page = re.sub(r'<div class="nav-links">.*?</div>',
                  '<div class="nav-links">\n' + "\n".join(links) + '\n  </div>', page, count=1, flags=re.S)
    page = re.sub(r'<a href="/user-story-1">← [^<]*</a>', '<a href="/kernwerk">← Data classification</a>', page)
    return page.replace('href="/dlp-routing"', 'href="/kernwerk"')


GOOGLE_COST_UI = "http://kagent.agentic.eu0.internal/age/cost-management"
GOOGLE_LINKS = [
    ("/google", "Google Sovereign Cloud"),
    ("/google/routing", "Routing"),
    ("/google/dlp", "Data protection"),
    ("/google/agents", "Agents"),
    ("/google/sdlc", "Website"),
    ("/google/approvals", "Approvals"),
    (GOOGLE_COST_UI, "Cost"),
]


def google_nav(page: str, active: str) -> str:
    """A console page reused under /google: the Google steps in the nav, the crumb back to /google."""
    links = ['    <a href="/google" class="up">TrustUsBank</a>' if GOOGLE_ONLY else '    <a href="/" class="up">← All demos</a>'] + [
        '    <a href="%s"%s%s>%s</a>' % (href, ' class="active"' if href == active else "",
                                      ' target="_blank" rel="noopener"' if href.startswith("http") else "", label)
        for href, label in GOOGLE_LINKS]
    if GOOGLE_ONLY:
        links.append('    <a href="/logout">Sign out</a>')
    page = re.sub(r'<div class="nav-links">.*?</div>',
                  '<div class="nav-links">\n' + "\n".join(links) + '\n  </div>', page, count=1, flags=re.S)
    page = re.sub(r'<a class="st-crumb" href="[^"]*">← [^<]*</a>',
                  '<a class="st-crumb" href="/google">← Google Sovereign Cloud</a>', page)
    return re.sub(r'<div class="crumb"><a href="[^"]*">← [^<]*</a>',
                  '<div class="crumb"><a href="/google">← Google Sovereign Cloud</a>', page)


def decisions_html(kernwerk: bool = False) -> bytes:
    page = dashboard.PAGE
    page = page.replace("<title>Gateway decisions</title>", "<title>Gateway decisions · Solo.io</title>", 1)
    page = page.replace(
        "</head>",
        '<link rel="icon" type="image/svg+xml" href="/static/favicon.svg">\n'
        '<link rel="stylesheet" href="/static/css/app.css"></head>',
        1,
    )
    nav = kernwerk_nav(nav_html(), "/kernwerk/gateway-decisions") if kernwerk else nav_html()
    # page-kernwerk turns on the data-class pill and its filter. The same cards feed both
    # paths, so /decisions keeps showing the task and the pool and nothing about data class.
    body = "page-decisions page-kernwerk" if kernwerk else "page-decisions"
    page = page.replace("<body>", "<body class='%s'>" % body + nav, 1)
    return page.encode()


def start_followers() -> None:
    global decisions_ok, decisions_error
    if not CTX:
        decisions_error = "no model-routing context in kubeconfig"
        return
    dashboard.CTX = CTX
    dashboard.NS = NS
    try:
        subprocess.run(
            ["kubectl", "--context", CTX, "-n", NS, "get", "deployment",
             "routing-policy", "decision-gateway", "-o", "name"],
            check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
        )
    except subprocess.CalledProcessError as e:
        decisions_error = e.stderr.decode("utf-8", "replace").strip().split("\n")[-1][:160] or "kubectl failed"
        return
    watch = [("routing-policy", dashboard.on_opa), ("decision-gateway", dashboard.on_gateway)]
    # Only present when the Kernwerk overlay is installed, and only it produces the
    # redactions the Kernwerk page marks up. Without it the page is the task router's
    # own and simply has nothing to show. Kept in step with the dashboard's own main().
    if subprocess.run(["kubectl", "--context", CTX, "-n", NS, "get", "deploy", "kernwerk-pii"],
                      stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0:
        watch.append(("kernwerk-pii", dashboard.on_pii))
    for target, handler in watch:
        threading.Thread(target=dashboard.follow, args=(target, handler), daemon=True).start()
    decisions_ok = True
    decisions_error = ""


# A failed attach at start (an expired AWS SSO login, a cluster still coming up) used
# to stick until the console restarted, so the nav kept showing an error that had long
# since been fixed. Keep trying in the background until it attaches.
def retry_followers(every: int = 20) -> None:
    def loop():
        while not decisions_ok:
            time.sleep(every)
            try:
                start_followers()
            except Exception as e:
                globals()["decisions_error"] = str(e)[:160]
        print(f"Gateway decisions attached to {CTX}", flush=True)
    threading.Thread(target=loop, daemon=True).start()


class Handler(BaseHTTPRequestHandler):
    # HTTP/1.0 (the BaseHTTPRequestHandler default) closes the socket after every
    # response. agentgateway pools upstream connections, and a pooled write onto a
    # socket the app just closed surfaces as a 503 "connection closed before
    # message completed" — browsers saw that as missing stylesheets.
    protocol_version = "HTTP/1.1"

    def _stream_start(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        # Under HTTP/1.1 keep-alive a response without Content-Length is only
        # delimited by closing the connection. Streamed answers must say so, or
        # the gateway waits for a body end that never comes.
        self.close_connection = True
        self.end_headers()

    def _session_cookie(self, user: str) -> str:
        exp = int(time.time()) + 12 * 3600
        sig = hmac.new(HOSTED_AUTH["session_key"].encode(), f"{user}|{exp}".encode(), "sha256").hexdigest()
        return f"tub_session={user}|{exp}|{sig}; Path=/; HttpOnly; Secure; SameSite=Lax"

    def _session_ok(self) -> bool:
        try:
            raw = next(c.split("=", 1)[1] for c in (self.headers.get("Cookie") or "").split(";")
                       if c.strip().startswith("tub_session="))
            user, exp, sig = raw.split("|")
            expect = hmac.new(HOSTED_AUTH["session_key"].encode(), f"{user}|{exp}".encode(), "sha256").hexdigest()
            return hmac.compare_digest(sig, expect) and int(exp) > time.time() \
                and hmac.compare_digest(user.encode(), HOSTED_AUTH["username"].encode())
        except (StopIteration, ValueError):
            return False

    def _google_access(self):
        if not GOOGLE_ONLY:
            return True
        path = urlparse(self.path).path
        if path in ("/login", "/healthz"):
            return True
        allowed = (path in ("/", "/index.html", "/api/trustusbank/status")
                   or path.startswith(("/google", "/static/", "/api/google/", "/api/tubsdlc/", "/api/trustusbank/", "/tubsdlc/site/")))
        if not allowed or path == "/google/all":
            self._send(404, "Not found", "text/plain")
            return False
        valid = self._session_ok()
        if not valid:
            try:
                scheme, value = self.headers.get("Authorization", "").split(" ", 1)
                decoded = base64.b64decode(value, validate=True).decode()
                expected = HOSTED_AUTH["username"] + ":" + HOSTED_AUTH["password"]
                valid = scheme.lower() == "basic" and hmac.compare_digest(decoded.encode(), expected.encode())
            except (ValueError, UnicodeError):
                valid = False
        if not valid:
            if path.startswith(("/api/", "/tubsdlc/")):
                # API clients (curl, tests) get a 401; browsers get the login page.
                self.send_response(401)
                self.send_header("WWW-Authenticate", 'Basic realm="TrustUsBank Berlin demo", charset="UTF-8"')
                self.send_header("Cache-Control", "no-store")
                self.end_headers()
            else:
                self._redirect("/login")
            return False
        if self.command in ("POST", "DELETE") and path != "/login":
            origin = self.headers.get("Origin")
            if (self.headers.get("Sec-Fetch-Site") == "cross-site"
                    or (origin and urlparse(origin).netloc != self.headers.get("Host"))):
                self._send(403, "Cross-origin write rejected", "text/plain")
                return False
        return True
    def log_message(self, *a):
        pass

    def _redirect(self, to):
        self.send_response(302)
        self.send_header("Location", to)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def _send(self, code, body, content_type, cache="no-store"):
        if isinstance(body, str):
            body = body.encode()
        if not GOOGLE_ONLY and content_type.startswith("text/html") and b"console-nav" in body:
            body = body.replace(b"</body>", b'<script src="/static/js/admin-link.js"></script></body>', 1)
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Cache-Control", cache)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        if GOOGLE_ONLY and self.path == "/login":
            length = int(self.headers.get("Content-Length") or 0)
            if length > 4096:
                return self._send(413, "too large", "text/plain")
            form = {k: v[0] for k, v in parse_qs(self.rfile.read(length).decode(), keep_blank_values=True).items()}
            ok = hmac.compare_digest(form.get("username", "").encode(), HOSTED_AUTH["username"].encode()) \
                and hmac.compare_digest(form.get("password", "").encode(), HOSTED_AUTH["password"].encode())
            if not ok:
                page = LOGIN_PAGE.replace('class="err" hidden', 'class="err"')
                return self._send(401, page, "text/html; charset=utf-8")
            self.send_response(303)
            self.send_header("Location", "/google")
            self.send_header("Set-Cookie", self._session_cookie(form["username"]))
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if not self._google_access():
            return
        if self.path == "/clear" and dashboard is not None:
            with dashboard.lock:
                dashboard.cards.clear()
            self.send_response(204)
            self.end_headers()
            return
        if self.path == "/api/run":
            return self._run()
        if self.path == "/api/google/chat/stream":
            b = self._body()
            self._stream_start()
            try:
                for ev in google_sov.chat_stream(b.get("prompt", ""), b.get("route", "auto")):
                    self.wfile.write(f"data: {json.dumps(ev)}\n\n".encode())
                    self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                pass
            except Exception as e:  # noqa: BLE001
                # A raised (not yielded) failure still owes the page a terminal
                # event, or it reads as a dead stream with no explanation.
                try:
                    self.wfile.write(f"data: {json.dumps({'t': 'done', 'status': 0, 'error': str(e)})}\n\n".encode())
                    self.wfile.flush()
                except (BrokenPipeError, ConnectionResetError):
                    pass
            return
        if self.path == "/api/google/chat":
            b = self._body()
            try:
                return self._json(google_sov.chat(b.get("prompt", ""), b.get("route", "auto")))
            except Exception as e:
                return self._json({"status": 0, "error": str(e)})
        if self.path == "/api/google/dlp/clear":
            import google_dlp
            try:
                return self._json(google_dlp.clear_history())
            except OSError as e:
                return self._json({"ok": False, "error": f"Could not save history reset: {e}"})
        if self.path == "/api/google/dlp/ask":
            # Whole answers, not a stream: the response guardrail can only check
            # an answer it can hold.
            b = self._body()
            import google_dlp
            try:
                return self._json(google_dlp.ask(b.get("prompt", ""), b.get("route", "auto")))
            except Exception as e:
                return self._json({"status": 0, "error": str(e)})
        if self.path == "/api/google/dlp/upload":
            b = self._body()
            import google_dlp
            try:
                return self._json(google_dlp.upload(b.get("name", "document"),
                                                    b.get("data", ""), b.get("prompt", "")))
            except Exception as e:
                return self._json({"status": 0, "error": str(e)})
        if self.path.startswith(("/api/google/agents", "/api/google/approvals")):
            return self._google_agents_post()
        if self.path.startswith("/api/google/builder/") or self.path.startswith("/api/google/mcp/"):
            return self._google_builder_post()
        if self.path.startswith("/api/trustusbank/") and self.path.endswith("/chat/stream"):
            import trustusbank_lab
            domain = self.path.split("/")[-3]
            body = self._body()
            self._stream_start()
            # Drain fully even if the browser leaves, so the agent's A2A task is not cancelled.
            client_gone = False
            for ev in trustusbank_lab.chat_stream(domain, body.get("text", ""), body.get("contextId")):
                if client_gone:
                    continue
                try:
                    self.wfile.write(f"data: {json.dumps(ev)}\n\n".encode())
                    self.wfile.flush()
                except (BrokenPipeError, ConnectionResetError):
                    client_gone = True
            return None
        if self.path == "/api/quadratic/run":
            return self._quadratic()
        if self.path.startswith("/api/term/"):
            return self._term_post()
        if self.path == "/api/agents":
            import agents_lab
            return self._json(agents_lab.create_agent(self._body()))
        if self.path == "/api/agents/preview":
            import agents_lab
            spec = self._body()
            if not (spec.get("name") or "").strip():
                return self._json({"yaml": ""})
            return self._json({"yaml": agents_lab.render_yaml(spec)})
        if self.path == "/api/agents/skills":
            import agents_lab
            return self._json(agents_lab.create_skill(self._body()))
        if self.path.startswith("/api/agents/") and self.path.endswith("/chat/stream"):
            import agents_lab
            name = self.path.split("/")[-3]
            body = self._body()
            self._stream_start()
            # Draining the generator fully, even once the browser is gone, matters: the
            # old code let a write failure propagate out of the for loop, which GC'd the
            # generator mid-iteration and closed chat_stream()'s open connection to
            # kagent-controller right under it -- so closing the tab or navigating away
            # mid-turn silently cancelled the agent's actual A2A task, not just the
            # browser's view of it. Caught live: a dev-bot run that stopped the instant
            # its final completion started streaming, GitHub never updated, no error
            # anywhere because nothing had actually failed -- the client just vanished
            # and took the agent's own request with it.
            client_gone = False
            for ev in agents_lab.chat_stream(name, body.get("text", ""), body.get("contextId")):
                if client_gone:
                    continue
                try:
                    self.wfile.write(f"data: {json.dumps(ev)}\n\n".encode())
                    self.wfile.flush()
                except (BrokenPipeError, ConnectionResetError):
                    client_gone = True
            return None
        if self.path.startswith("/api/agents/") and self.path.endswith("/chat"):
            import agents_lab
            name = self.path.split("/")[-2]
            body = self._body()
            return self._json(agents_lab.chat(name, body.get("text", ""), body.get("contextId")))
        if self.path.startswith("/api/agents/") and self.path.endswith("/approve-github"):
            import agents_lab
            name = self.path.split("/")[-2]
            return self._json(agents_lab.approve_github(name))
        if self.path.startswith("/api/agents/") and self.path.endswith("/revoke-github"):
            import agents_lab
            name = self.path.split("/")[-2]
            return self._json(agents_lab.revoke_github(name))
        if self.path == "/api/petstore/fetch":
            import petstore_lab
            body = self._body()
            self._stream_start()
            # See the identical fix on /chat/stream above: drain the generator fully
            # even once the browser is gone, so closing the tab mid-turn never cancels
            # dev-bot's actual work (or the build-and-stage that follows it).
            client_gone = False

            def emit(ev):
                nonlocal client_gone
                if client_gone:
                    return
                try:
                    self.wfile.write(f"data: {json.dumps(ev)}\n\n".encode())
                    self.wfile.flush()
                except (BrokenPipeError, ConnectionResetError):
                    client_gone = True

            for ev in petstore_lab.fetch_and_implement(body.get("text")):
                emit(ev)
                if ev.get("t") == "done":
                    emit({"t": "building"})
                    result = petstore_lab.build_and_stage()
                    emit({"t": "staged", **result})
            return None
        if self.path.startswith("/tubsdlc/site/"):
            return self._tubsdlc_site("POST")
        if self.path in ("/api/tubsdlc/pm", "/api/tubsdlc/fetch",
                         "/api/trustusbank/sdlc/pm", "/api/trustusbank/sdlc/fetch"):
            import trustusbank_sdlc
            body = self._body()
            self._stream_start()
            # Drain fully even if the browser leaves: the agent's turn, and the
            # build-and-stage after the engineer's, must not die with the tab.
            gen = (trustusbank_sdlc.pm_chat(body.get("text", "")) if self.path.endswith("/pm")
                   else trustusbank_sdlc.fetch_and_implement(body.get("text")))
            client_gone = False
            for ev in gen:
                if client_gone:
                    continue
                try:
                    self.wfile.write(f"data: {json.dumps(ev)}\n\n".encode())
                    self.wfile.flush()
                except (BrokenPipeError, ConnectionResetError):
                    client_gone = True
            return None
        if self.path in ("/api/tubsdlc/spec", "/api/trustusbank/sdlc/spec"):
            import trustusbank_sdlc
            body = self._body()
            return self._json(trustusbank_sdlc.spec_decision(bool(body.get("approve")), body.get("reason", ""),
                                                             body.get("number")))
        if self.path in ("/api/tubsdlc/promote", "/api/trustusbank/sdlc/promote"):
            import trustusbank_sdlc
            body = self._body()
            return self._json(trustusbank_sdlc.promote(bool(body.get("approve")), body.get("reason", "")))
        if self.path in ("/api/tubsdlc/stage", "/api/trustusbank/sdlc/stage"):
            import trustusbank_sdlc
            return self._json(trustusbank_sdlc.build_and_stage())
        if self.path == "/api/petstore/promote":
            import petstore_lab
            body = self._body()
            return self._json(petstore_lab.promote(bool(body.get("approve")), body.get("reason", "")))
        if self.path.startswith("/api/desktop/"):
            return self._desktop_post()
        if self.path == "/api/notebook/run":
            return self._notebook_run()
        if self.path == "/api/labs/reset":
            return self._lab_reset()
        if self.path == "/api/notebook/console":
            b = self._body()
            return self._json(notebooks.open_console(b.get("demo", ""), b.get("console", "")))
        if self.path == "/api/notebook/stop":
            b = self._body()
            return self._json(notebooks.stop(b.get("demo", ""), b.get("step", ""), int(b.get("index", 0))))
        if self.path == "/api/substrate/start":
            return self._substrate_start()
        if self.path == "/api/substrate/pause":
            import substrate
            return self._json(substrate.pause())
        if self.path == "/api/substrate/stop":
            import substrate
            return self._json(substrate.stop())
        self.send_response(404)
        self.end_headers()

    def _tubsdlc_site(self, method):
        """The TrustUsBank app, staging or prod, proxied through the gateway so the
        SDLC page can preview it without /etc/hosts entries."""
        import trustusbank_sdlc
        env, _, rest = self.path[len("/tubsdlc/site/"):].partition("/")
        if not rest and "?" not in env and not self.path.endswith("/"):
            return self._redirect(f"/tubsdlc/site/{env}/")
        body = None
        if method == "POST":
            body = self.rfile.read(int(self.headers.get("Content-Length") or 0))
        code, headers, data = trustusbank_sdlc.site_proxy(env, rest, method, body,
                                                          self.headers.get("Content-Type"))
        self.send_response(code)
        for k, v in headers.items():
            self.send_header(k, v)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _body(self):
        length = int(self.headers.get("Content-Length") or 0)
        try:
            return json.loads(self.rfile.read(length) or b"{}")
        except json.JSONDecodeError:
            return {}

    def _desktop_post(self):
        import desktop
        body = self._body()
        path = urlparse(self.path).path
        if path.endswith("/agw-off"):
            return self._json(desktop.agw_off())
        if path.endswith("/agw-on"):
            return self._json(desktop.agw_on())
        if path.endswith("/daemon-install"):
            return self._json(desktop.daemon_install())
        if path.endswith("/daemon-remove"):
            return self._json(desktop.daemon_remove())
        if path.endswith("/signin"):
            return self._json(desktop.signin(body.get("user") or "bob"))
        if path.endswith("/enrol-system"):
            return self._json(desktop.enrol_up_system(body.get("user") or "bob"))
        if path.endswith("/unenrol-system"):
            return self._json(desktop.enrol_down_system())
        if path.endswith("/enrol"):
            return self._json(desktop.enrol_up())
        if path.endswith("/unenrol"):
            return self._json(desktop.enrol_down())
        if path.endswith("/policy"):
            return self._json(desktop.apply_policy(body.get("name") or "lab"))
        self.send_response(404)
        self.end_headers()

    def _run(self):
        length = int(self.headers.get("Content-Length") or 0)
        try:
            body = json.loads(self.rfile.read(length) or b"{}")
        except json.JSONDecodeError:
            body = {}
        mode = body.get("mode") or "standard"
        prompt = body.get("prompt") or (
            "Give me the release report for tjorourke/network-slice-manager, all open pull requests."
        )
        self.send_response(200)
        self.send_header("Content-Type", "application/x-ndjson")
        self.send_header("Cache-Control", "no-store")
        self.end_headers()

        def emit(ev):
            self.wfile.write((json.dumps(ev) + "\n").encode())
            self.wfile.flush()

        try:
            from live_run import run as live
            live(mode, prompt, emit)
        except Exception as e:
            emit({"type": "error", "text": str(e)[:400]})

    def _term_post(self):
        import terminal
        if not terminal.allowed(self.headers, PORT):
            return self._send(403, "forbidden\n", "text/plain")
        body = self._body()
        lab = body.get("lab", "")
        try:
            if self.path == "/api/term/open":
                s = terminal.session(lab, fresh=bool(body.get("fresh")))
                return self._json({"ok": True, "id": s.id, "contexts": terminal.contexts(lab), "alive": s.alive})
            s = terminal.get(lab)
            if s is None:
                return self._send(404, "no shell\n", "text/plain")
            if self.path == "/api/term/input":
                s.write(str(body.get("data", "")).encode())
            elif self.path == "/api/term/resize":
                s.resize(max(20, int(body.get("cols", 120))), max(5, int(body.get("rows", 30))))
            return self._json({"ok": True})
        except ValueError as e:
            return self._send(400, str(e) + "\n", "text/plain")

    def _term_stream(self):
        """Terminal output from an offset, as ndjson, until the shell exits or the tab goes."""
        import base64
        import terminal
        from urllib.parse import parse_qs
        if not terminal.allowed(self.headers, PORT):
            return self._send(403, "forbidden\n", "text/plain")
        q = parse_qs(urlparse(self.path).query)
        s = terminal.get(q.get("lab", [""])[0])
        if s is None:
            return self._send(404, "no shell\n", "text/plain")
        offset = int(q.get("from", ["0"])[0])
        # A different shell from the one the page was following (the console
        # restarted, or New shell): start it from the top and tell the page.
        reset = q.get("id", [""])[0] != s.id
        if reset:
            offset = 0
        self.send_response(200)
        self.send_header("Content-Type", "application/x-ndjson")
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        try:
            while True:
                offset, data, alive = s.read_from(offset)
                ev = {"o": offset, "id": s.id}
                if reset:
                    ev["reset"], reset = True, False
                if data:
                    ev["d"] = base64.b64encode(data).decode()
                if not alive:
                    ev["exit"] = True
                self.wfile.write((json.dumps(ev) + "\n").encode())
                self.wfile.flush()
                if not alive:
                    return
        except (BrokenPipeError, ConnectionResetError):
            return

    def _quadratic(self):
        """The quadratic on the calculator MCP server, Standard or Code, streamed."""
        mode = "code" if self._body().get("mode") == "code" else "standard"
        self.send_response(200)
        self.send_header("Content-Type", "application/x-ndjson")
        self.send_header("Cache-Control", "no-store")
        self.end_headers()

        def emit(ev):
            self.wfile.write((json.dumps(ev) + "\n").encode())
            self.wfile.flush()

        try:
            import quadratic_run
            quadratic_run.run(mode, emit)
        except (BrokenPipeError, ConnectionResetError):
            return
        except Exception as e:
            emit({"type": "error", "text": str(e)[:400]})

    def _lab_reset(self):
        import lab_reset
        body = self._body()
        lab = body.get("lab", "")
        if lab not in lab_reset.SCOPES:
            return self._send(400, json.dumps({"error": "Unknown lab"}), "application/json")
        self.send_response(200)
        self.send_header("Content-Type", "application/x-ndjson")
        self.send_header("Cache-Control", "no-store")
        self.end_headers()

        def emit(ev):
            self.wfile.write((json.dumps(ev) + "\n").encode())
            self.wfile.flush()
        try:
            lab_reset.run(lab, emit)
        except (BrokenPipeError, ConnectionResetError):
            return
        except Exception as e:
            emit({"type": "error", "text": str(e)[:400]})

    def _notebook_run(self):
        body = self._body()
        self.send_response(200)
        self.send_header("Content-Type", "application/x-ndjson")
        self.send_header("Cache-Control", "no-store")
        self.end_headers()

        def emit(ev):
            self.wfile.write((json.dumps(ev) + "\n").encode())
            self.wfile.flush()

        try:
            notebooks.run(body.get("demo", ""), body.get("step", ""), int(body.get("index", 0)), emit,
                          part=int(body["part"]) if "part" in body else None,
                          revision=body.get("revision", ""),
                          params=body.get("params") if isinstance(body.get("params"), dict) else None)
        except Exception as e:
            emit({"type": "error", "text": str(e)[:400]})

    def _substrate_start(self):
        body = self._body()
        self.send_response(200)
        self.send_header("Content-Type", "application/x-ndjson")
        self.send_header("Cache-Control", "no-store")
        self.end_headers()

        def emit(ev):
            self.wfile.write((json.dumps(ev) + "\n").encode())
            self.wfile.flush()

        try:
            import substrate
            substrate.start(body, emit)
        except Exception as e:
            emit({"type": "error", "text": str(e)[:400]})

    def _google_agents_post(self):
        """/google/agents and /google/approvals: agents.html and approvals.html on Berlin,
        the same contract /api/agents serves for kind (google_builder.py)."""
        import google_builder as gb
        path = urlparse(self.path).path
        rest = path.split("/", 4)[4] if path.count("/") >= 4 else ""
        body = self._body()
        if rest == "":
            return self._json(gb.create_contract(body))
        if rest == "preview":
            return self._json(gb.preview(body))
        if rest == "skills":
            return self._json({"ok": False, "error": "Skills on Berlin are fixed prompt fragments; pick one."})
        name, _, action = rest.partition("/")
        if action == "approve-github":
            return self._json(gb.approve_contract(name, "approve"))
        if action == "revoke-github":
            return self._json(gb.approve_contract(name, "deny"))
        if action == "chat/stream":
            self._stream_start()
            client_gone = False
            for ev in gb.chat_stream(name, body.get("text", ""), body.get("contextId")):
                if client_gone:
                    continue
                try:
                    self.wfile.write(f"data: {json.dumps(ev)}\n\n".encode())
                    self.wfile.flush()
                except (BrokenPipeError, ConnectionResetError):
                    client_gone = True
            return None
        return self._json({"ok": False, "error": "unknown route"})

    def _google_page(self, page: str, active: str, approvals: bool) -> bytes:
        """agents.html or approvals.html, with the Google nav and window.AGENTS_API set."""
        import google_builder as gb
        html = google_nav((PAGES / page).read_text(), active)
        html = html.replace('href="/approvals"', 'href="/google/approvals"').replace('href="/agents"', 'href="/google/agents"')
        if approvals:
            html = html.replace("Allowed automatically", "Platform-managed grants")
            html = html.replace(
                "Some MCP servers are safe enough that nobody should have to sign off: this is decided once, by labelling the server's AgentRegistry record. An agent that picks one gets its grant at deploy. It is still enforced at the gateway: the agent must present its own signed MCP token, matching its mesh identity, and only the tools it picked are allowed. Every other agent gets a 403 before a session opens. Deleting the agent takes the grant straight back out.",
                "The bank and website agents have explicit grants maintained in the infrastructure repository. Every MCP request requires a short-lived signed workload JWT matching the caller’s mesh identity. Each grant allows only the named tools; missing or invalid tokens get 401, mismatched identities get 403, and ungranted tools stay hidden and cannot be called.")
            html = html.replace("No agent uses an auto-approved server yet. Try the Tower climb planner on", "No platform-managed grants found. See")
        icons = {"payments": "💶", "compliance": "🛡️", "credit": "🏦", "gdpr": "🔒"}
        templates = [{"id": a["domain"], "icon": icons.get(a["domain"], "🤖"), "title": a["title"], "name": "my-" + a["domain"],
                      "blurb": a["description"], "description": a["description"],
                      "prompt": gb.TEMPLATE_PROMPTS.get(a["domain"], a["description"]),
                      "skill": "bank-customers", "tools": {f"trustusbank-{a['domain']}-tools": gb.TUB_TOOLS[a["domain"]]}}
                     for a in gb.tl.AGENTS]
        cfg = {"AGENTS_API": "/api/google/approvals" if approvals else "/api/google/agents",
               "APPROVALS_PAGE": "/google/approvals", "CONFETTI_ON_DEPLOY": True, "SKILL_AUTHORING": False,
               "AGENT_MODEL": gb.MODEL["name"], "AGENT_TEMPLATES": templates,
               "CHAT_ROUTE_MODEL": f"{gb.MODEL['title']} · H100 Berlin",
               "AGENT_GLYPHS": {f"trustusbank-{d}-tools": g for d, g in icons.items()}}
        inject = "<script>" + "".join(f"window.{k}={json.dumps(v)};" for k, v in cfg.items()) + "</script>\n"
        marker = '<script src="/static/js/'
        i = html.find(marker)
        return (html[:i] + inject + html[i:]).encode() if i >= 0 else html.encode()

    def _google_builder_post(self):
        """The Google page's agent builder and MCP approvals (google_builder.py)."""
        import google_builder
        parts = self.path.split("/")
        body = self._body()
        if self.path == "/api/google/builder/deploy":
            return self._json(google_builder.deploy(body))
        if self.path.startswith("/api/google/builder/") and self.path.endswith("/review"):
            tools = body.get("tools")
            return self._json(google_builder.approve(parts[-2], tools if isinstance(tools, list) else None,
                                                     body.get("decision", "")))
        if self.path.endswith("/chat/stream"):
            self._stream_start()
            client_gone = False
            for ev in google_builder.chat_stream(parts[-3], body.get("text", ""), body.get("contextId")):
                if client_gone:
                    continue
                try:
                    self.wfile.write(f"data: {json.dumps(ev)}\n\n".encode())
                    self.wfile.flush()
                except (BrokenPipeError, ConnectionResetError):
                    client_gone = True
            return None
        return self._json({"ok": False, "error": "unknown builder route"})

    def do_DELETE(self):
        if not self._google_access():
            return
        path = urlparse(self.path).path
        if path.startswith("/api/agents/"):
            import agents_lab
            name = path.split("/")[-1]
            return self._json(agents_lab.delete_agent(name))
        if path.startswith("/api/google/agents/"):
            import google_builder
            return self._json(google_builder.delete_contract(path.split("/")[-1]))
        if path.startswith("/api/google/builder/"):
            import google_builder
            return self._json(google_builder.delete(path.split("/")[-1]))
        self.send_response(404)
        self.end_headers()

    def do_GET(self):
        path = urlparse(self.path).path
        if GOOGLE_ONLY and path == "/healthz":
            return self._json({"ok": True, "scope": "google-only"})
        if GOOGLE_ONLY and path == "/login":
            if self._session_ok():
                return self._redirect("/google")
            return self._send(200, LOGIN_PAGE, "text/html; charset=utf-8")
        if GOOGLE_ONLY and path == "/logout":
            self.send_response(303)
            self.send_header("Location", "/login")
            self.send_header("Set-Cookie", "tub_session=; Path=/; HttpOnly; Secure; SameSite=Lax; Max-Age=0")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if not self._google_access():
            return
        if GOOGLE_ONLY and path in ("/", "/index.html"):
            return self._redirect("/google")
        if path == "/admin":
            import lab_reset
            return self._send(200, lab_reset.admin_page(), "text/html; charset=utf-8")
        if path == "/api/labs/state":
            import lab_reset
            return self._json(lab_reset.GENERATIONS)
        if path.startswith("/api/labs/status/"):
            lab = path.rsplit("/", 1)[-1]
            if lab not in notebooks.DEMOS:
                return self._send(404, "Unknown lab", "text/plain")
            return self._json(notebooks.cluster_status(lab))
        if path == "/events":
            return self._events()
        if path in ("/", "/index.html"):
            return self._send(200, notebooks.home_page(), "text/html; charset=utf-8")
        if path == "/user-story-1":
            return self._send(200, (PAGES / "user-story-1.html").read_bytes(), "text/html; charset=utf-8")
        # Kernwerk, the sample EU customer. Google Sovereign Cloud has its own story on
        # the home page, so /kernwerk no longer needs a chooser in front of it.
        if path in ("/kernwerk", "/kernwerk/"):
            return self._send(200, kernwerk_nav((PAGES / "dlp-routing.html").read_text(), "/kernwerk").encode(),
                              "text/html; charset=utf-8")
        if path in ("/kernwerk/eu", "/kernwerk/eu/"):
            return self._redirect("/kernwerk")
        if path in ("/google", "/google/"):
            return self._send(200, google_nav((PAGES / "google-hub.html").read_text(), "/google").encode(),
                              "text/html; charset=utf-8")
        if path == "/google/routing":
            return self._send(200, google_nav((PAGES / "google-routing.html").read_text(), "/google/routing").encode(),
                              "text/html; charset=utf-8")
        if path in ("/google/dlp", "/google/dlp/"):
            return self._send(200, google_nav((PAGES / "google-dlp.html").read_text(), "/google/dlp").encode(),
                              "text/html; charset=utf-8")
        if path == "/api/google/dlp/status":
            import google_dlp
            return self._json(google_dlp.status())
        if path == "/api/google/dlp/samples":
            import google_dlp
            return self._json(google_dlp.samples())
        if path == "/api/google/dlp/events":
            import google_dlp
            return self._json(google_dlp.events())
        if path == "/google/sdlc":
            return self._send(200, google_nav((PAGES / "google-sdlc.html").read_text(), "/google/sdlc").encode(),
                              "text/html; charset=utf-8")
        if path.startswith("/tubsdlc/site/"):
            return self._tubsdlc_site("GET")
        if path in ("/google/agents", "/google/agents/"):
            return self._send(200, self._google_page("agents.html", "/google/agents", False), "text/html; charset=utf-8")
        if path in ("/google/approvals", "/google/approvals/"):
            return self._send(200, self._google_page("approvals.html", "/google/approvals", True),
                              "text/html; charset=utf-8")
        if path.startswith(("/api/google/agents", "/api/google/approvals")):
            import google_builder as gb
            approvals = path.startswith("/api/google/approvals")
            rest = path.split("/", 4)[4] if path.count("/") >= 4 else ""
            if rest == "":
                # Platform-managed grants are read-only but still visible, so
                # the admin can inspect every bank and SDLC agent's policy.
                return self._json(gb.list_contract(include_bank=True))
            if rest == "catalog":
                return self._json(gb.catalog_contract())
            if rest == "prompts":
                return self._json(gb.prompts())
            if rest.endswith("/status"):
                return self._json(gb.status_contract(rest.split("/")[0]))
        if path == "/google/all":   # the old one-page version, kept while the steps move out of it
            return self._send(200, (PAGES / "google-sovereign.html").read_bytes(), "text/html; charset=utf-8")
        if path == "/api/google/mcp":
            import google_builder
            return self._json(google_builder.mcp_catalog())
        if path == "/api/google/builder/catalog":
            import google_builder
            return self._json(google_builder.catalog())
        if path == "/api/google/builder/agents":
            import google_builder
            return self._json(google_builder.agents())
        if path.startswith("/api/google/builder/") and path.endswith("/status"):
            import google_builder
            return self._json(google_builder.status(path.split("/")[-2]))
        if path == "/api/google/status":
            return self._json(google_sov.status())
        if path in ("/api/tubsdlc/status", "/api/trustusbank/sdlc/status"):
            import trustusbank_sdlc
            return self._json(trustusbank_sdlc.status())
        if path == "/api/trustusbank/status":
            import trustusbank_lab
            return self._json(trustusbank_lab.status())
        # It was /nashville until the page became about data protection and routing
        # rather than the city it was written for. Bookmarks and any slide already
        # printed still work, which matters more than a tidy route table mid-demo.
        if path in ("/dlp-routing", "/nashville"):
            return self._redirect("/kernwerk")
        if path == "/kernwerk/manifests":
            return self._send(200, kernwerk_nav((PAGES / "kernwerk-manifests.html").read_text(),
                                                path).encode(),
                              "text/html; charset=utf-8")
        if path == "/kernwerk/prompts":
            return self._send(200, kernwerk_nav((PAGES / "kernwerk-prompts.html").read_text(),
                                                "/kernwerk/prompts").encode(),
                              "text/html; charset=utf-8")
        if path == "/api/kernwerk/prompts":
            import kernwerk_prompts
            return self._json(kernwerk_prompts.prompts())
        if path == "/api/kernwerk/manifests":
            import kernwerk_prompts
            return self._json(kernwerk_prompts.manifests())
        if path == "/kernwerk/dlp":
            # Through kernwerk_nav so the nav comes from KERNWERK_LINKS. These two used to
            # carry their own copy, and it went stale the moment a page was added.
            return self._send(200, kernwerk_nav((PAGES / "dlp.html").read_text(), path).encode(),
                              "text/html; charset=utf-8")
        # The one page in the Kernwerk story that was not under /kernwerk. Moved for the
        # sake of the nav; the old path still answers, like /nashville does.
        if path == "/dlp":
            return self._redirect("/kernwerk/dlp")
        if path == "/kernwerk/decisions":
            # Through kernwerk_nav so the nav comes from KERNWERK_LINKS. These two used to
            # carry their own copy, and it went stale the moment a page was added.
            return self._send(200, kernwerk_nav((PAGES / "kernwerk-decisions.html").read_text(), path).encode(),
                              "text/html; charset=utf-8")
        if path == "/economy":
            return self._send(200, (PAGES / "economy.html").read_bytes(), "text/html; charset=utf-8")
        if path == "/cost":
            # The gateway and UI hostnames come from console.env (AGW_HOST, SOLO_UI_HOST).
            page = (PAGES / "cost.html").read_text()
            page = (page.replace("__AGW_HOST__", os.environ.get("AGW_HOST", "agw.example.com"))
                        .replace("__SOLO_UI_HOST__", os.environ.get("SOLO_UI_HOST", "soloui.example.com")))
            return self._send(200, page.encode(), "text/html; charset=utf-8")
        if path == "/desktop":
            return self._send(200, (PAGES / "desktop.html").read_bytes(), "text/html; charset=utf-8")
        if path == "/agents":
            return self._send(200, (PAGES / "agents.html").read_bytes(), "text/html; charset=utf-8")
        if path == "/approvals":
            return self._send(200, (PAGES / "approvals.html").read_bytes(), "text/html; charset=utf-8")
        if path == "/substrate":
            return self._send(200, (PAGES / "substrate.html").read_bytes(), "text/html; charset=utf-8")
        if path == "/petstore":
            return self._send(200, (PAGES / "petstore-sdlc.html").read_bytes(), "text/html; charset=utf-8")
        if path == "/api/petstore/status":
            import petstore_lab
            return self._json(petstore_lab.status())
        # Hosted mode never imports the notebook module; any hosted path still
        # falling through here is unknown and gets the plain 404 at the end.
        parts = path.strip("/").split("/", 1)
        if not GOOGLE_ONLY and parts[0] in notebooks.DEMOS:
            demo = notebooks.load(parts[0])
            if len(parts) == 1:
                return self._send(200, notebooks.demo_page(demo), "text/html; charset=utf-8")
            step = demo.step(parts[1])
            if step is None:
                self.send_response(404)
                self.end_headers()
                return
            # A demo with present/<demo>.json gets the presenter view; ?classic is the full page.
            if "classic" not in urlparse(self.path).query:
                import present
                view = present.view(demo, step)
                if view:
                    return self._send(200, view, "text/html; charset=utf-8")
            return self._send(200, notebooks.step_page(demo, step), "text/html; charset=utf-8")
        if path == "/api/substrate/status":
            import substrate
            return self._json(substrate.status())
        if path == "/api/agents/catalog":
            import agents_lab
            return self._json(agents_lab.catalog())
        if path == "/api/agents/prompts":
            import agents_lab
            return self._json({"prompts": agents_lab.registry_prompts()})
        if path == "/api/agents":
            import agents_lab
            return self._json({"agents": agents_lab.list_agents(), "platform": agents_lab.platform()})
        if path.startswith("/api/agents/") and path.endswith("/status"):
            import agents_lab
            name = path.split("/")[-2]
            return self._json(agents_lab.agent_status(name))
        if path == "/api/dlp/status":
            import dlp
            return self._json(dlp.status())
        if path == "/api/dlp/config":
            import dlp
            return self._json(dlp.config())
        if path == "/api/dlp/samples":
            import dlp
            return self._json(dlp.samples())
        if path == "/api/dlp/events":
            import dlp
            return self._json(dlp.events())
        if path == "/api/desktop/status":
            import desktop
            return self._json(desktop.status())
        if path in ("/decisions", "/kernwerk/gateway-decisions"):
            if dashboard is None:
                return self._send(503, "Gateway decisions is not loaded.\n", "text/plain; charset=utf-8")
            return self._send(200, decisions_html(path.startswith("/kernwerk")), "text/html; charset=utf-8")
        if path == "/kernwerk/desktop":
            # Kernwerk's story is told as martink, whose IdP groups carry the
            # data-classification role. desktop.js reads the name off the body.
            page = kernwerk_nav((PAGES / "desktop.html").read_text(), path)
            page = page.replace("<body>", '<body data-signin="martink">', 1)
            page = page.replace("<code>bob</code>", "<code>martink</code>")
            return self._send(200, page.encode(), "text/html; charset=utf-8")
        if path == "/api/status":
            live = {"mcp": False, "ip": ""}
            try:
                from live_run import CTX as MESH, kubectl
                ip = kubectl(
                    "-n", "agentgateway-system", "get", "gateway", "mcp-demo",
                    "-o", "jsonpath={.status.addresses[0].value}",
                    check=False,
                ).stdout.strip()
                live = {"mcp": bool(ip), "ip": ip, "mesh": MESH}
            except Exception:
                pass
            return self._json({
                "decisions": decisions_ok,
                "context": CTX,
                "error": decisions_error,
                "live": live,
            })
        if path == "/api/mcp":
            return self._file(DATA / "mcp-demo.json", "application/json")
        if path == "/api/mcp/tools":
            try:
                import live_run
                q = urlparse(self.path).query
                mode = "code" if "mode=code" in q else "standard"
                names = live_run.list_mode_tools(mode)
                return self._json({"mode": mode, "count": len(names), "names": names})
            except Exception as e:
                return self._json({"error": str(e)[:200], "names": []})
        if path == "/api/term/stream":
            return self._term_stream()
        if path == "/substrate/live":
            return self._send(200, (PAGES / "substrate-live.html").read_bytes(), "text/html; charset=utf-8")
        if path == "/defence/live":
            return self._send(200, (PAGES / "defence-live.html").read_bytes(), "text/html; charset=utf-8")
        if path == "/api/defence/live":
            import defence_live
            return self._json(defence_live.state())
        if path == "/api/substrate/live":
            try:
                import substrate_live
                return self._json(substrate_live.state())
            except Exception as e:
                return self._json({"ok": False, "error": str(e)[:200]})
        if path == "/inference/live":
            return self._send(200, (PAGES / "inference-live.html").read_bytes(), "text/html; charset=utf-8")
        if path == "/api/inference/state":
            try:
                import inference_live
                return self._json(inference_live.state())
            except Exception as e:
                return self._json({"ok": False, "replicas": [], "counts": {}, "error": str(e)[:200]})
        if path == "/api/term/token":
            import terminal
            tok = terminal.token_for(self.headers, PORT)
            if not tok:
                return self._send(403, "forbidden\n", "text/plain")
            return self._json({"token": tok})
        if path == "/api/quadratic/tools":
            try:
                import quadratic_run
                mode = "code" if "mode=code" in urlparse(self.path).query else "standard"
                names = quadratic_run.list_mode_tools(mode)
                return self._json({"mode": mode, "count": len(names), "names": names})
            except Exception as e:
                return self._json({"error": str(e)[:200], "names": []})
        if path.startswith("/static/"):
            return self._static(path[len("/static/"):])
        self.send_response(404)
        self.end_headers()

    def _json(self, obj):
        self._send(200, json.dumps(obj), "application/json")

    def _file(self, path: Path, content_type):
        if not path.is_file():
            self.send_response(404)
            self.end_headers()
            return
        self._send(200, path.read_bytes(), content_type, cache="no-store")

    def _static(self, rel: str):
        target = (STATIC / rel).resolve()
        if STATIC not in target.parents and target != STATIC:
            self.send_response(403)
            self.end_headers()
            return
        if not target.is_file():
            self.send_response(404)
            self.end_headers()
            return
        ctype = mimetypes.guess_type(str(target))[0] or "application/octet-stream"
        if target.suffix == ".svg":
            ctype = "image/svg+xml"
        self._send(200, target.read_bytes(), ctype, cache="no-store")

    def _events(self):
        if dashboard is None:
            self.send_response(503)
            self.end_headers()
            return
        self._stream_start()
        q = queue.Queue()
        with dashboard.lock:
            dashboard.subscribers.append(q)
            backlog = list(dashboard.cards[-40:])
        try:
            for card in backlog:
                self.wfile.write(f"data: {json.dumps(card)}\n\n".encode())
            self.wfile.flush()
            while True:
                try:
                    payload = q.get(timeout=15)
                    self.wfile.write(f"data: {payload}\n\n".encode())
                except queue.Empty:
                    self.wfile.write(b": keepalive\n\n")
                self.wfile.flush()
        except Exception:
            pass
        finally:
            with dashboard.lock:
                if q in dashboard.subscribers:
                    dashboard.subscribers.remove(q)


def main():
    if GOOGLE_ONLY:
        import google_dlp
        google_dlp.start_followers()
        signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
        print(f"Google-only console on :{PORT}", flush=True)
        ThreadingHTTPServer((os.environ.get("CONSOLE_BIND", "0.0.0.0"), PORT), Handler).serve_forever()
        return
    try:
        load_dashboard()
        start_followers()
    except FileNotFoundError:
        print("task-routing dashboard module not found; Token economics still works", flush=True)
    except Exception as e:
        print(f"Gateway decisions not attached: {e}", flush=True)
    if decisions_ok:
        print(f"Gateway decisions attached to {CTX}", flush=True)
    else:
        print(f"Gateway decisions idle ({decisions_error or 'not attached'}), retrying", flush=True)
        if dashboard is not None and CTX:
            retry_followers()
    try:
        import dlp
        dlp.start_followers()
        print(f"Kernwerk decisions following {dlp.CTX.split('/')[-1] or 'nothing'}", flush=True)
    except Exception as e:
        print(f"Kernwerk decisions idle ({e})", flush=True)
    try:
        import desktop
        if desktop.ensure_port_forward():
            print("Agentdesktop console on http://127.0.0.1:18099/", flush=True)
        else:
            print("Agentdesktop port-forward not ready", flush=True)
    except Exception as e:
        print(f"Agentdesktop idle ({e})", flush=True)
    print(f"demo console on http://localhost:{PORT}  (ctrl-c to stop)", flush=True)
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    try:
        ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
    except OSError as e:
        if e.errno == errno.EADDRINUSE:
            raise SystemExit(
                f"port {PORT} is already taken. Stop the old dashboard "
                f"(python3 scripts/30-dashboard.py) and run this instead."
            ) from e
        raise
    finally:
        if dashboard is not None:
            with dashboard.lock:
                children = list(dashboard.followers)
            for child in children:
                if child.poll() is None:
                    child.terminate()


if __name__ == "__main__":
    main()
