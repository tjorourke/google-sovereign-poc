"""TrustUsBank: four finance agents in Berlin, from the console.

trustusbank/deploy.sh puts them there: AgentRegistry pushes each agent onto kagent,
each agent's tools are its own core-banking MCP server behind agentgateway, and
every agent thinks with Gemma 3 27B on the H100 in the cluster. This module only
talks to them: it lists what is running and holds one A2A conversation at a time,
through a port-forward to kagent-controller with the Berlin kubeconfig.

    TUB_PF_PORT   18093 (a free port is picked if it is taken)
    TUB_USER      bob   the person the console signs in as (88-identity.sh creates
                        bob and alice in Keycloak, password TUB_USER_PASSWORD)

Every turn carries an identity. The console signs the person in, and exchanges
that token (RFC 8693) at the agent's own Keycloak client, so the bearer kagent
sees names both: preferred_username=bob and agent_id=trustusbank-payments.
Without it kagent records the caller as an anonymous A2A_USER_<id>.
"""
from __future__ import annotations

import json
import os
import subprocess
import threading
import base64
import time
import urllib.parse
import urllib.request
import uuid
from pathlib import Path

import google_sov

AGENTS = json.loads((Path(__file__).parent / "trustusbank" / "agents.json").read_text())
AR_NS = "agentregistry-system"
MCP_NS = "mcp"
PF_PORT = int(os.environ.get("TUB_PF_PORT", "18093"))

KEYCLOAK = os.environ.get("TUB_KEYCLOAK", "http://keycloak.agentic.eu0.internal").rstrip("/")
REALM = "agentregistry"
USER = os.environ.get("TUB_USER", "bob")

_pf_lock = threading.Lock()
_pf: subprocess.Popen | None = None
_pf_port = PF_PORT


def _kubectl(*args, timeout=20):
    return google_sov._kubectl(*args, timeout=timeout)


def _up(url: str) -> bool:
    try:
        urllib.request.urlopen(url + "/health", timeout=2)
        return True
    except urllib.error.HTTPError:
        return True   # kagent-controller answered, whatever it thinks of /health
    except Exception:
        return False


def _a2a_base() -> str:
    if os.environ.get("TUB_KAGENT_URL"):
        return os.environ["TUB_KAGENT_URL"].rstrip("/")
    global _pf, _pf_port
    with _pf_lock:
        url = f"http://127.0.0.1:{_pf_port}"
        if _pf is not None and _pf.poll() is None and _up(url):
            return url
        if _pf is not None:
            _pf.kill()
            _pf = None
        # A forward left behind by an earlier console run still works.
        if not google_sov._port_free(PF_PORT) and _up(f"http://127.0.0.1:{PF_PORT}"):
            _pf_port = PF_PORT
            return f"http://127.0.0.1:{PF_PORT}"
        _pf_port = PF_PORT if google_sov._port_free(PF_PORT) else google_sov._free_port()
        url = f"http://127.0.0.1:{_pf_port}"
        _pf = subprocess.Popen(["kubectl", "-n", "kagent", "port-forward", "svc/kagent-controller",
                                f"{_pf_port}:8083"], env=google_sov._env(),
                               stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
        for _ in range(40):
            if _pf.poll() is not None:
                err = _pf.stderr.read() if _pf.stderr else ""
                _pf = None
                raise RuntimeError(google_sov._auth_hint(err) or "port-forward to kagent-controller exited")
            if _up(url):
                return url
            time.sleep(0.25)
        raise RuntimeError("port-forward to kagent-controller did not come up")


_id_lock = threading.Lock()
_tokens: dict = {}    # client id -> (access token, expiry)
_secrets: dict = {}   # agent client id -> client secret, never logged
_id_error: str | None = None


def _form(url: str, data: dict, basic: tuple | None = None, bearer: str | None = None, method="POST"):
    headers = {}
    if basic:
        headers["authorization"] = "Basic " + base64.b64encode(":".join(basic).encode()).decode()
    if bearer:
        headers["authorization"] = "Bearer " + bearer
    body = urllib.parse.urlencode(data).encode() if data is not None else None
    req = urllib.request.Request(url, data=body, method=method, headers=headers)
    with urllib.request.urlopen(req, timeout=10) as r:
        return json.loads(r.read())


def _claims(tok: str) -> dict:
    p = tok.split(".")[1]
    return json.loads(base64.urlsafe_b64decode(p + "=" * (-len(p) % 4)))


def _cached(key: str, fetch) -> str:
    tok, exp = _tokens.get(key, (None, 0))
    if not tok or exp - time.time() < 30:
        tok = fetch()
        _tokens[key] = (tok, _claims(tok).get("exp", time.time() + 60))
    return tok


def _secret(client: str) -> str:
    """The agent client's secret, read once through the Keycloak admin API."""
    if client not in _secrets:
        adm = _form(f"{KEYCLOAK}/realms/master/protocol/openid-connect/token",
                    {"grant_type": "password", "client_id": "admin-cli", "username": "admin",
                     "password": os.environ.get("TUB_KEYCLOAK_ADMIN_PASSWORD", "admin")})["access_token"]
        admin = f"{KEYCLOAK}/admin/realms/{REALM}/clients"
        req = urllib.request.Request(f"{admin}?clientId={client}", headers={"authorization": "Bearer " + adm})
        uid = json.loads(urllib.request.urlopen(req, timeout=10).read())[0]["id"]
        req = urllib.request.Request(f"{admin}/{uid}/client-secret", headers={"authorization": "Bearer " + adm})
        _secrets[client] = json.loads(urllib.request.urlopen(req, timeout=10).read())["value"]
    return _secrets[client]


def console_token() -> str:
    """The demo user's signed console JWT; never manufacture caller headers."""
    with _id_lock:
        return _cached("user", lambda: _form(
            f"{KEYCLOAK}/realms/{REALM}/protocol/openid-connect/token", {
                "grant_type": "password", "client_id": "trustusbank-console",
                "username": USER, "password": os.environ.get("TUB_USER_PASSWORD", "password"),
                "scope": "openid"})["access_token"])


def _token(domain: str) -> str | None:
    """USER's token, exchanged at trustusbank-<domain>: the person and the agent in one JWT."""
    global _id_error
    tok_url = f"{KEYCLOAK}/realms/{REALM}/protocol/openid-connect/token"
    client = f"trustusbank-{domain}"
    for attempt in (1, 2):
        try:
            with _id_lock:
                user = _cached("user", lambda: _form(tok_url, {
                    "grant_type": "password", "client_id": "trustusbank-console", "username": USER,
                    "password": os.environ.get("TUB_USER_PASSWORD", "password"), "scope": "openid"})["access_token"])
                tok = _cached(client, lambda: _form(tok_url, {
                    "grant_type": "urn:ietf:params:oauth:grant-type:token-exchange", "subject_token": user,
                    "subject_token_type": "urn:ietf:params:oauth:token-type:access_token",
                    "requested_token_type": "urn:ietf:params:oauth:token-type:access_token"},
                    basic=(client, _secret(client)))["access_token"])
            _id_error = None
            return tok
        except Exception as e:  # noqa: BLE001
            if attempt == 2:
                _id_error = f"Keycloak at {KEYCLOAK}: {e}. Run scripts/88-identity.sh."
                return None
            # A hosted console is long-lived: a cached token or client secret that
            # predates a Keycloak rebuild fails every call until restart. Drop the
            # identity caches once and refetch before declaring failure.
            with _id_lock:
                _tokens.clear()
                _secrets.pop(client, None)


def identity() -> dict:
    """Who the console is signed in as, from the token itself."""
    tok = _token("payments")
    if not tok:
        return {"signed_in": False, "user": USER, "error": _id_error}
    c = _claims(tok)
    return {"signed_in": True, "user": c.get("preferred_username"), "name": c.get("name"),
            "team": c.get("team"), "groups": c.get("Groups"), "sub": c.get("sub"),
            "issuer": c.get("iss")}


def _headers(domain: str, accept: str | None = None) -> dict:
    h = {"content-type": "application/json"}
    if accept:
        h["accept"] = accept
    tok = _token(domain)
    if tok:
        h["authorization"] = "Bearer " + tok
    return h


def _kagent_agents() -> dict:
    """domain -> {name, ready} for the agents AgentRegistry created on kagent."""
    r = _kubectl("-n", AR_NS, "get", "agents.kagent.dev", "-o", "json")
    if r.returncode != 0:
        raise RuntimeError(google_sov._auth_hint(r.stderr) or "cannot list kagent agents")
    out = {}
    for a in json.loads(r.stdout).get("items", []):
        name = a["metadata"]["name"]
        for d in (x["domain"] for x in AGENTS):
            if name.startswith(f"trustusbank-{d}"):
                conds = {c.get("type"): c.get("status") for c in a.get("status", {}).get("conditions", [])}
                out[d] = {"name": name, "ready": conds.get("Ready") == "True",
                          "accepted": conds.get("Accepted") == "True"}
    return out


def status() -> dict:
    try:
        live = _kagent_agents()
    except Exception as e:
        return {"reachable": False, "error": str(e), "agents": AGENTS}
    r = _kubectl("-n", MCP_NS, "get", "pods", "-l", "company=trustusbank", "-o", "json")
    mcp = {}
    if r.returncode == 0:
        for p in json.loads(r.stdout).get("items", []):
            cs = p.get("status", {}).get("containerStatuses", [])
            mcp[p["metadata"]["labels"].get("app", "").removeprefix("bank-")] = bool(cs) and all(
                c.get("ready") for c in cs)
    agents = []
    for a in AGENTS:
        d = a["domain"]
        agents.append({**{k: a[k] for k in ("domain", "name", "title", "description", "prompts")},
                       "deployment": (live.get(d) or {}).get("name"),
                       "ready": (live.get(d) or {}).get("ready", False),
                       "mcp_ready": mcp.get(d, False),
                       "mcp_route": f"mcp.agentic.eu0.internal/mcp/{d}"})
    return {"reachable": True, "agents": agents, "model": "gemma-3-27b-it", "identity": identity(),
            "model_route": "llm.agentic.eu0.internal → vLLM · H100 · ns model"}


def _tool_result(resp):
    if not isinstance(resp, dict):
        return resp
    texts = [c.get("text", "") for c in resp.get("content") or [] if isinstance(c, dict)]
    if not texts:
        return resp.get("result", resp)
    try:
        return json.loads(texts[0])
    except (json.JSONDecodeError, TypeError):
        return " ".join(texts)


def chat_stream(domain: str, text: str, context_id: str | None = None):
    """One streamed A2A turn. Yields delta, message, tool_call, tool_result, recovering, done, error."""
    text = (text or "").strip()
    if not text:
        yield {"t": "error", "error": "Type a message first."}
        return
    try:
        dep = (_kagent_agents().get(domain) or {}).get("name")
        if not dep:
            yield {"t": "error", "error": f"No {domain} agent on kagent: run ./trustusbank/deploy.sh"}
            return
        base = _a2a_base()
    except Exception as e:  # noqa: BLE001
        yield {"t": "error", "error": str(e)}
        return
    msg = {"role": "user", "messageId": uuid.uuid4().hex, "kind": "message",
           "parts": [{"kind": "text", "text": text[:4000]}]}
    if context_id:
        msg["contextId"] = context_id
    body = json.dumps({"jsonrpc": "2.0", "id": uuid.uuid4().hex, "method": "message/stream",
                       "params": {"message": msg}}).encode()
    req = urllib.request.Request(f"{base}/api/a2a/{AR_NS}/{dep}/", data=body, method="POST",
                                 headers=_headers(domain, "text/event-stream"))
    who = identity()
    yield {"t": "agent", "deployment": dep, "user": who.get("user") if who.get("signed_in") else None,
           "agent_id": f"trustusbank-{domain}"}
    seen_calls, seen_results, said = set(), set(), set()
    ctx, task_id, state, final, t0 = context_id, None, None, False, time.time()

    def parts_events(parts, partial=False):
        """Events for one message's parts: text, tool calls and tool results, each once."""
        for part in parts or []:
            if part.get("kind") == "text" and part.get("text"):
                if partial:
                    yield {"t": "delta", "text": part["text"]}
                elif part["text"] not in said:   # the final status and the artifact repeat it
                    said.add(part["text"])
                    yield {"t": "message", "text": part["text"]}
            data = part.get("data") if part.get("kind") == "data" else None
            if isinstance(data, dict) and "name" in data:
                cid = data.get("id") or data["name"]
                if "args" in data and cid not in seen_calls:
                    seen_calls.add(cid)
                    yield {"t": "tool_call", "id": cid, "name": data["name"], "args": data["args"],
                           "at": round(time.time() - t0, 1)}
                if "response" in data and cid not in seen_results:
                    seen_results.add(cid)
                    yield {"t": "tool_result", "id": cid, "name": data["name"],
                           "result": _tool_result(data["response"]), "at": round(time.time() - t0, 1)}

    try:
        with urllib.request.urlopen(req, timeout=300) as r:
            for raw in r:
                line = raw.decode("utf-8", "replace").strip()
                if not line.startswith("data:"):
                    continue
                try:
                    frame = json.loads(line[5:]) or {}
                except json.JSONDecodeError:
                    continue
                if frame.get("error"):
                    yield {"t": "error", "error": f"{dep}: {(frame['error'] or {}).get('message', frame['error'])}"}
                    return
                ev = frame.get("result") or {}
                ctx = ev.get("contextId") or ctx
                task_id = ev.get("taskId") or (ev.get("id") if ev.get("kind") == "task" else None) or task_id
                if ev.get("kind") == "artifact-update":
                    yield from parts_events((ev.get("artifact") or {}).get("parts"))
                    continue
                if ev.get("kind") != "status-update":
                    continue
                st = ev.get("status") or {}
                state = st.get("state") or state
                final = final or bool(ev.get("final"))
                if state == "submitted":
                    continue
                yield from parts_events((st.get("message") or {}).get("parts"),
                                        (ev.get("metadata") or {}).get("kagent_adk_partial"))
    except Exception as e:  # noqa: BLE001
        if not task_id:
            yield {"t": "error", "error": f"Could not reach {dep} through kagent: {e}"}
            return
    # kagent ends a turn's stream, marked final while still working, when a newer
    # message arrives on the same conversation: that newer turn has the answer.
    if final and state not in TERMINAL:
        yield {"t": "error", "error": "A newer message on this conversation took over before the agent answered. "
                                      "Send one message at a time, or start a new conversation."}
        yield {"t": "done", "contextId": ctx, "state": "superseded", "elapsed": round(time.time() - t0, 1)}
        return
    # A connection that drops mid-turn: ask for the task until it finishes.
    if state not in TERMINAL and task_id:
        yield {"t": "recovering", "state": state, "at": round(time.time() - t0, 1)}
        give_up = time.time() + 90
        while time.time() < give_up:
            try:
                task = _rpc(base, dep, "tasks/get", {"id": task_id}, domain).get("result") or {}
            except Exception:  # noqa: BLE001
                time.sleep(2)
                continue
            state = (task.get("status") or {}).get("state") or state
            if state in TERMINAL:
                for m in task.get("history") or []:
                    if m.get("role") == "agent":
                        for ev in parts_events(m.get("parts")):
                            if ev["t"] != "message":
                                yield ev
                yield from parts_events(((task.get("status") or {}).get("message") or {}).get("parts"))
                for art in task.get("artifacts") or []:
                    yield from parts_events(art.get("parts"))
                break
            time.sleep(1)
    if state == "failed" and not said:
        yield {"t": "error", "error": f"{dep} failed the task: see its pod log in ns {AR_NS}"}
    elif state not in TERMINAL and not said:
        yield {"t": "error", "error": f"The stream from {dep} closed and the task never finished ({state}). Ask again."}
    yield {"t": "done", "contextId": ctx, "state": state, "elapsed": round(time.time() - t0, 1)}


TERMINAL = {"completed", "failed", "canceled", "rejected", "input-required"}


def _rpc(base: str, dep: str, method: str, params: dict, domain: str) -> dict:
    body = json.dumps({"jsonrpc": "2.0", "id": uuid.uuid4().hex, "method": method, "params": params}).encode()
    req = urllib.request.Request(f"{base}/api/a2a/{AR_NS}/{dep}/", data=body, method="POST",
                                 headers=_headers(domain))
    with urllib.request.urlopen(req, timeout=20) as r:
        return json.loads(r.read())


def stop():
    global _pf
    with _pf_lock:
        if _pf is not None:
            _pf.kill()
            _pf = None
