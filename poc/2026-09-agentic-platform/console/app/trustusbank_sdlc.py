#!/usr/bin/env python3
"""TrustUsBank agent SDLC on Google Cloud Dedicated, with a person at both gates:

  1. the PM agent turns a request into a GitHub issue labelled `spec-review`;
  2. a person approves the spec (`agent-ready`) or turns it down (`spec-rejected`, closed);
  3. the engineer agent commits to `agent/issue-<n>` and opens a pull request (`in-review`);
  4. the platform builds that pull request and stages it in trustusbank-staging;
  5. a person approves (merge, the staged image goes to trustusbank-prod, `live`) or
     denies (a comment, the issue back to `agent-ready`, staging back to what prod runs).

Both agents are Gemma 3 27B on kagent, put there by AgentRegistry (trustusbank-sdlc/
deploy.sh), and each is called as bob through its own Keycloak client (trustusbank-pm-agent,
trustusbank-dev-agent), the trustusbank_lab token-exchange pattern. Their GitHub tools are a small
MCP server behind agentgateway. This module only does the deterministic work around them:
label, build, push, roll out, merge, comment. The console's own GitHub access is the local
`gh` login; it never goes into the cluster.
"""
from __future__ import annotations

import json
import os
import subprocess
import tempfile
import threading
import time
import urllib.error
import urllib.request
import uuid
from pathlib import Path

import google_sov
import trustusbank_lab as tl

ROOT = Path(__file__).parent
AGENTS = json.loads((ROOT / "trustusbank-sdlc" / "agents.json").read_text())
REPO = os.environ.get("TUB_REPO", "tjorourke/trustusbank-payments")
REPO_URL = f"https://github.com/{REPO}.git"
AR_HOST = os.environ.get("TUB_AR_HOST", "docker.pkg-berlin-build0.goog")
IMAGE = os.environ.get("TUB_APP_IMAGE", f"{AR_HOST}/eu0/soloio-eval/solo/trustusbank-payments")
AR_NS = "agentregistry-system"
ENVS = {"staging": "trustusbank-staging", "prod": "trustusbank-prod"}
HOSTS = {"staging": "staging.payments.agentic.eu0.internal", "prod": "payments.agentic.eu0.internal"}
STATE_FILE = Path(os.environ.get("CONSOLE_STATE_DIR", str(ROOT / "data"))) / "tubsdlc-state.json"
SITE_PREFIX = "/tubsdlc/site"   # serve.py proxies the app here, so previews work without /etc/hosts


def staging_url() -> str:
    return f"http://{HOSTS['staging']}"


def prod_url() -> str:
    return f"http://{HOSTS['prod']}"


def _load_state() -> dict:
    if STATE_FILE.exists():
        try:
            return json.loads(STATE_FILE.read_text())
        except json.JSONDecodeError:
            pass
    return {"stage": "idle"}


def _save_state(state: dict) -> None:
    STATE_FILE.parent.mkdir(exist_ok=True)
    STATE_FILE.write_text(json.dumps(state, indent=2))


def _set_stage(stage: str, **extra) -> None:
    state = _load_state()
    state.update(stage=stage, stage_at=int(time.time()), **extra)
    _save_state(state)


# ── identity: bob, through each agent's own Keycloak client ──────────────────
_id_errors: dict = {}


def _token(role: str) -> str | None:
    """bob's token exchanged at trustusbank-<role>-agent: the person and the agent in one JWT."""
    tok_url = f"{tl.KEYCLOAK}/realms/{tl.REALM}/protocol/openid-connect/token"
    client = f"trustusbank-{role}-agent"
    for attempt in (1, 2):
        try:
            with tl._id_lock:
                user = tl._cached("user", lambda: tl._form(tok_url, {
                    "grant_type": "password", "client_id": "trustusbank-console", "username": tl.USER,
                    "password": os.environ.get("TUB_USER_PASSWORD", "password"), "scope": "openid"})["access_token"])
                tok = tl._cached(client, lambda: tl._form(tok_url, {
                    "grant_type": "urn:ietf:params:oauth:grant-type:token-exchange", "subject_token": user,
                    "subject_token_type": "urn:ietf:params:oauth:token-type:access_token",
                    "requested_token_type": "urn:ietf:params:oauth:token-type:access_token"},
                    basic=(client, tl._secret(client)))["access_token"])
            _id_errors.pop(role, None)
            return tok
        except Exception as e:  # noqa: BLE001
            if attempt == 2:
                _id_errors[role] = f"Keycloak at {tl.KEYCLOAK}: {e}. Run scripts/88-identity.sh."
                return None
            # A hosted console is long-lived: a cached token or client secret that
            # predates a Keycloak rebuild fails every call until restart (Keycloak
            # here is ephemeral). Drop the identity caches once and refetch — the
            # same retry trustusbank_lab._token() has always had.
            with tl._id_lock:
                tl._tokens.clear()
                tl._secrets.pop(client, None)


def identity(role: str) -> dict:
    tok = _token(role)
    if not tok:
        return {"signed_in": False, "user": tl.USER, "client": f"trustusbank-{role}-agent", "error": _id_errors.get(role)}
    c = tl._claims(tok)
    return {"signed_in": True, "user": c.get("preferred_username"), "name": c.get("name"),
            "client": c.get("azp") or f"trustusbank-{role}-agent", "issuer": c.get("iss")}


def _headers(role: str, accept: str | None = None) -> dict:
    h = {"content-type": "application/json"}
    if accept:
        h["accept"] = accept
    tok = _token(role)
    if tok:
        h["authorization"] = "Bearer " + tok
    return h


# ── GitHub, through the console's local gh login ─────────────────────────────
def _gh(*args, timeout=30):
    return subprocess.run(["gh", *args], capture_output=True, text=True, timeout=timeout)


def _issues(label: str) -> list[dict]:
    p = _gh("issue", "list", "--repo", REPO, "--label", label, "--state", "open",
            "--json", "number,title,url,createdAt,body", "--limit", "20")
    if p.returncode != 0:
        return []
    out = sorted(json.loads(p.stdout or "[]"), key=lambda i: i["createdAt"])
    for i in out:
        i["summary"] = (i.pop("body", "") or "").split("\n\n---\n")[0].strip()[:600]
    return out


def latest_spec_review_issue() -> dict | None:
    """The newest spec the PM filed: the one waiting for a person."""
    issues = _issues("spec-review")
    return issues[-1] if issues else None


def latest_agent_ready_issue() -> dict | None:
    """The oldest approved spec: the one get_next_issue hands the engineer."""
    issues = _issues("agent-ready")
    return issues[0] if issues else None


def latest_in_review_issue() -> dict | None:
    issues = _issues("in-review")
    return issues[-1] if issues else None


def _pull_request(issue: dict | None) -> dict | None:
    """The open pull request the engineer opened from agent/issue-<n>."""
    if not issue:
        return None
    p = _gh("pr", "list", "--repo", REPO, "--state", "open", "--head", f"agent/issue-{issue['number']}",
            "--json", "number,title,url,headRefName,headRefOid,additions,deletions,changedFiles")
    if p.returncode != 0:
        return None
    prs = json.loads(p.stdout or "[]")
    return prs[0] if prs else None


def recent_issues() -> list[dict]:
    p = _gh("issue", "list", "--repo", REPO, "--state", "all", "--json",
            "number,title,url,state,labels,updatedAt", "--limit", "8")
    if p.returncode != 0:
        return []
    return [{"number": i["number"], "title": i["title"], "url": i["url"], "state": i["state"].lower(),
             "labels": [l["name"] for l in i["labels"]]} for i in json.loads(p.stdout or "[]")]


def _comment(number: int, body: str) -> None:
    _gh("issue", "comment", str(number), "--repo", REPO, "--body", body)


def _relabel(number: int, add: str, *remove: str) -> None:
    args = ["issue", "edit", str(number), "--repo", REPO, "--add-label", add]
    for r in remove:
        args += ["--remove-label", r]
    _gh(*args)


# ── what each environment runs ───────────────────────────────────────────────
def _image(env: str) -> str | None:
    r = google_sov._kubectl("-n", ENVS[env], "get", "deploy/payments",
                            "-o", "jsonpath={.spec.template.spec.containers[0].image}")
    return r.stdout.strip() if r.returncode == 0 and r.stdout.strip() else None


def _image_tag(env: str) -> str | None:
    r = google_sov._kubectl("-n", ENVS[env], "get", "deploy/payments", "-o", "jsonpath={.metadata.annotations.demo\\.solo\\.io/artifact-tag}")
    if r.returncode == 0 and r.stdout.strip():
        return r.stdout.strip()
    img = _image(env)
    return img.split(":")[-1] if img else None


def _gateway(env: str, path: str, method="GET", body: bytes | None = None, headers: dict | None = None,
             timeout=8):
    """A request to the app through the agentgateway LB with the route's Host header, so
    the console works before /etc/hosts has the entries."""
    base = os.environ.get("GCD_AGW_URL")
    ip = None if base else google_sov._external_ip()
    if not base and not ip:
        raise RuntimeError("agentgateway has no external IP yet")
    req = urllib.request.Request((base or f"http://{ip}").rstrip("/") + path, data=body, method=method,
                                 headers={**(headers or {}), "Host": HOSTS[env]})
    return urllib.request.urlopen(req, timeout=timeout)


def _live(env: str) -> dict | None:
    try:
        with _gateway(env, "/api/config", timeout=4) as r:
            c = json.loads(r.read())
        return {"sha": c.get("sha"), "limit": c.get("daily_transfer_limit_eur"),
                "announcement": c.get("announcement"), "features": c.get("features")}
    except Exception:  # noqa: BLE001
        return None


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **kw):
        return None


def site_proxy(env: str, path: str, method="GET", body: bytes | None = None,
               content_type: str | None = None) -> tuple[int, dict, bytes]:
    """Serve the app at /tubsdlc/site/<env>/... from the console. Every link and fetch in
    the app is relative, so the pages work under the prefix unchanged."""
    if env not in ENVS:
        return 404, {"Content-Type": "text/plain"}, b"unknown environment"
    base = os.environ.get("GCD_AGW_URL")
    ip = None if base else google_sov._external_ip()
    if not base and not ip:
        return 503, {"Content-Type": "text/plain"}, b"agentgateway has no external IP yet"
    hdrs = {"Host": HOSTS[env]}
    if content_type:
        hdrs["Content-Type"] = content_type
    req = urllib.request.Request((base or f"http://{ip}").rstrip("/") + "/" + path.lstrip("/"), data=body, method=method, headers=hdrs)
    opener = urllib.request.build_opener(_NoRedirect)
    try:
        r = opener.open(req, timeout=15)
        code, h, data = r.status, r.headers, r.read()
    except urllib.error.HTTPError as e:
        code, h, data = e.code, e.headers, e.read()
    except Exception as e:  # noqa: BLE001
        return 502, {"Content-Type": "text/plain"}, f"cannot reach {HOSTS[env]}: {e}".encode()
    out = {"Content-Type": h.get("Content-Type", "application/octet-stream"), "Cache-Control": "no-store"}
    loc = h.get("Location")
    if loc:
        out["Location"] = f"{SITE_PREFIX}/{env}{loc}" if loc.startswith("/") else loc
    return code, out, data


# ── staging follows the open pull request ────────────────────────────────────
_STAGE_INFLIGHT = set()
_STAGE_LOCK = threading.Lock()


def _autostage_if_needed(issue: dict | None, pr: dict | None, staging_tag: str | None) -> None:
    """However the pull request got there or moved on (the console's fetch, someone chatting
    to the engineer directly, a fix after a denial), staging follows its head: every status()
    poll compares the two and builds in the background when they drift."""
    if not issue or not pr or _load_state().get("stage") in ("building", "implementing"):
        return
    head = pr["headRefOid"][:12]
    if (staging_tag or "").startswith(head):
        return
    if _load_state().get("failed_sha") == head:
        return   # one failed build per commit; the next push retries
    if _load_state().get("stage") == "denied" and _load_state().get("denied_sha") == head:
        return   # a denied commit stays off staging; only the next push restages
    with _STAGE_LOCK:
        if head in _STAGE_INFLIGHT:
            return
        _STAGE_INFLIGHT.add(head)

    def run():
        try:
            build_and_stage()
        finally:
            with _STAGE_LOCK:
                _STAGE_INFLIGHT.discard(head)

    threading.Thread(target=run, daemon=True).start()


def _kagent_agents() -> dict:
    """role -> {name, ready} for the SDLC agents AgentRegistry created on kagent."""
    r = google_sov._kubectl("-n", AR_NS, "get", "agents.kagent.dev", "-o", "json")
    if r.returncode != 0:
        raise RuntimeError(google_sov._auth_hint(r.stderr) or "cannot list kagent agents")
    out = {}
    for a in json.loads(r.stdout).get("items", []):
        name = a["metadata"]["name"]
        for role in (x["role"] for x in AGENTS):
            if name == f"trustusbank-{role}-agent":
                conds = {c.get("type"): c.get("status") for c in a.get("status", {}).get("conditions", [])}
                out[role] = {"name": name, "ready": conds.get("Ready") == "True"}
    return out


def status() -> dict:
    state = _load_state()
    state["repo"] = REPO
    state["repo_url"] = f"https://github.com/{REPO}"
    try:
        live = _kagent_agents()
        state["reachable"] = True
    except Exception as e:  # noqa: BLE001
        live, state["reachable"], state["error"] = {}, False, str(e)
    state["agents"] = [{**{k: a[k] for k in ("role", "name", "title", "description", "prompts")},
                        "deployment": (live.get(a["role"]) or {}).get("name"),
                        "ready": (live.get(a["role"]) or {}).get("ready", False),
                        "identity": identity(a["role"]),
                         "mcp_route": f"sdlc-{a['role']}.mcp.svc.cluster.local:3000/mcp"} for a in AGENTS]
    state["spec_review_issue"] = latest_spec_review_issue()
    state["agent_ready_issue"] = latest_agent_ready_issue()
    issue = latest_in_review_issue()
    pr = _pull_request(issue)
    state["in_review_issue"] = issue
    state["pull_request"] = pr
    state["issues"] = recent_issues()
    for env in ENVS:
        state[f"{env}_image"] = _image_tag(env) if state["reachable"] else None
        state[f"{env}_live"] = _live(env)
        state[f"{env}_url"] = f"http://{HOSTS[env]}"
        state[f"{env}_preview"] = f"{SITE_PREFIX}/{env}/"
    state["gateway_ip"] = google_sov._external_ip()
    if state["reachable"]:
        _autostage_if_needed(issue, pr, state.get("staging_image"))
    return state


# ── gate 1: the spec ─────────────────────────────────────────────────────────
def spec_decision(approve: bool, reason: str = "", number: int | None = None) -> dict:
    """Approve: the spec becomes `agent-ready` for the engineer. Turn down: the reason goes
    on the issue, which is labelled `spec-rejected` and closed. Nothing is built either way."""
    issue = ({"number": int(number)} if number else latest_spec_review_issue())
    if not issue:
        return {"ok": False, "error": "no spec is waiting for review"}
    n = issue["number"]
    who = identity("pm").get("user") or tl.USER
    if approve:
        _comment(n, f"**Spec approved** by {who} in the demo console. Labelled `agent-ready`: "
                    "the AI dev agent picks it up next.")
        _relabel(n, "agent-ready", "spec-review")
        _set_stage("spec_approved", spec_issue=n)
        return {"ok": True, "approved": True, "issue": issue}
    reason = (reason or "").strip()
    if not reason:
        return {"ok": False, "error": "a reason is required to turn a spec down"}
    _comment(n, f"**Spec turned down** by {who}: {reason}\n\nClosed. Ask the PM agent for a new spec.")
    _relabel(n, "spec-rejected", "spec-review")
    _gh("issue", "close", str(n), "--repo", REPO, "--reason", "not planned")
    _set_stage("spec_rejected", spec_issue=n, spec_reason=reason)
    return {"ok": True, "approved": False, "issue": issue}


# ── agents ───────────────────────────────────────────────────────────────────
def chat_stream(role: str, text: str):
    """One streamed A2A turn to trustusbank-<role>-agent through kagent-controller, signed in as
    bob through the agent's own Keycloak client. The same events trustusbank_lab.chat_stream
    yields."""
    text = (text or "").strip()
    if not text:
        yield {"t": "error", "error": "Type a message first."}
        return
    try:
        dep = (_kagent_agents().get(role) or {}).get("name")
        if not dep:
            yield {"t": "error", "error": f"No trustusbank-{role}-agent agent on kagent: run ./trustusbank-sdlc/deploy.sh"}
            return
        base = tl._a2a_base()
    except Exception as e:  # noqa: BLE001
        yield {"t": "error", "error": str(e)}
        return
    msg = {"role": "user", "messageId": uuid.uuid4().hex, "kind": "message",
           "parts": [{"kind": "text", "text": text[:4000]}]}
    body = json.dumps({"jsonrpc": "2.0", "id": uuid.uuid4().hex, "method": "message/stream",
                       "params": {"message": msg}}).encode()
    req = urllib.request.Request(f"{base}/api/a2a/{AR_NS}/{dep}/", data=body, method="POST",
                                 headers=_headers(role, "text/event-stream"))
    who = identity(role)
    yield {"t": "agent", "deployment": dep, "agent_id": f"trustusbank-{role}-agent",
           "user": who.get("user"), "signed_in": who.get("signed_in")}
    seen_calls, seen_results, said = set(), set(), set()
    task_id, state, t0 = None, None, time.time()

    def parts_events(parts, partial=False):
        for part in parts or []:
            if part.get("kind") == "text" and part.get("text"):
                if partial:
                    yield {"t": "delta", "text": part["text"]}
                elif part["text"] not in said:
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
                           "result": tl._tool_result(data["response"]), "at": round(time.time() - t0, 1)}

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
                task_id = ev.get("taskId") or (ev.get("id") if ev.get("kind") == "task" else None) or task_id
                if ev.get("kind") == "artifact-update":
                    yield from parts_events((ev.get("artifact") or {}).get("parts"))
                    continue
                if ev.get("kind") != "status-update":
                    continue
                st = ev.get("status") or {}
                state = st.get("state") or state
                if state == "submitted":
                    continue
                yield from parts_events((st.get("message") or {}).get("parts"),
                                        (ev.get("metadata") or {}).get("kagent_adk_partial"))
    except Exception as e:  # noqa: BLE001
        if not task_id:
            yield {"t": "error", "error": f"Could not reach {dep} through kagent: {e}"}
            return
    if state not in tl.TERMINAL and task_id:
        # A connection that drops mid-turn: ask for the task until it finishes.
        yield {"t": "recovering", "state": state, "at": round(time.time() - t0, 1)}
        give_up = time.time() + 90
        while time.time() < give_up:
            try:
                rb = json.dumps({"jsonrpc": "2.0", "id": uuid.uuid4().hex, "method": "tasks/get",
                                 "params": {"id": task_id}}).encode()
                rq = urllib.request.Request(f"{base}/api/a2a/{AR_NS}/{dep}/", data=rb, method="POST",
                                            headers=_headers(role))
                with urllib.request.urlopen(rq, timeout=20) as r:
                    task = json.loads(r.read()).get("result") or {}
            except Exception:  # noqa: BLE001
                time.sleep(2)
                continue
            state = (task.get("status") or {}).get("state") or state
            if state in tl.TERMINAL:
                for m in task.get("history") or []:
                    if m.get("role") == "agent":
                        yield from (e for e in parts_events(m.get("parts")) if e["t"] != "message")
                yield from parts_events(((task.get("status") or {}).get("message") or {}).get("parts"))
                for art in task.get("artifacts") or []:
                    yield from parts_events(art.get("parts"))
                break
            time.sleep(1)
    if state == "failed" and not said:
        yield {"t": "error", "error": f"{dep} failed the task: see its pod log in ns {AR_NS}"}
    elif state not in tl.TERMINAL and not said:
        yield {"t": "error", "error": f"The stream from {dep} closed and the task never finished ({state}). Ask again."}
    yield {"t": "done", "state": state, "elapsed": round(time.time() - t0, 1)}


def pm_chat(text: str):
    """The PM agent turns a product request into a spec, filed as `spec-review`."""
    yield from chat_stream("pm", text)
    spec = latest_spec_review_issue()
    if spec:
        _set_stage("spec_review", spec_issue=spec["number"])
        yield {"t": "spec", "issue": spec}


DEFAULT_FETCH_PROMPT = ("Pick up the next agent-ready issue in trustusbank-payments and implement it: "
                        "make the change on the issue's branch, then call open_pull_request.")


def fetch_and_implement(text: str | None = None):
    """The engineer agent finds its own work, commits to the issue's branch and opens a
    pull request; then the platform builds and stages that pull request."""
    _set_stage("implementing")
    yield from chat_stream("dev", (text or "").strip() or DEFAULT_FETCH_PROMPT)
    issue = latest_in_review_issue()
    pr = _pull_request(issue)
    if not issue or not pr or (_image_tag("staging") or "").startswith(pr["headRefOid"][:12]):
        _set_stage("implemented")
        yield {"t": "stage", "stage": "implemented",
               "note": "Nothing new to stage: no pull request is open, or staging already runs it."}
        return
    yield {"t": "stage", "stage": "building", "sha": pr["headRefOid"][:12], "issue": issue, "pull_request": pr}
    res = build_and_stage()
    yield {"t": "stage", "stage": "staged" if res.get("ok") else "build_failed", **res}


# ── platform ─────────────────────────────────────────────────────────────────
def _run(cmd, timeout, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout,
                          env=google_sov._env(), **kw)


def _docker_login() -> str | None:
    tok = _run(["gcloud", "auth", "print-access-token"], 30)
    if tok.returncode != 0 or not tok.stdout.strip():
        return google_sov._auth_hint(tok.stderr) or "gcloud has no access token: run ./scripts/gcd-auth.sh"
    p = subprocess.run(["docker", "login", "-u", "oauth2accesstoken", "--password-stdin", AR_HOST],
                       input=tok.stdout.strip(), capture_output=True, text=True, timeout=30)
    return None if p.returncode == 0 else f"docker login to {AR_HOST} failed"


def _roll(env: str, image: str) -> str | None:
    ns = ENVS[env]
    import google_snapshot
    if google_snapshot.artifact_tag(ns):
        google_snapshot.roll_image(ns, image)
        return None
    p = google_sov._kubectl("-n", ns, "set", "image", "deploy/payments", f"payments={image}")
    if p.returncode != 0:
        return (p.stderr or "kubectl set image failed")[:300]
    google_sov._kubectl("-n", ns, "rollout", "status", "deploy/payments", "--timeout=180s", timeout=200)
    return None


_build_lock = threading.Lock()


def build_and_stage() -> dict:
    """Build the open pull request's head for linux/amd64, push it to the Berlin registry
    and roll it out to trustusbank-staging. The commit comes from GitHub, never from the
    agent's reply."""
    if not _build_lock.acquire(blocking=False):
        return {"ok": False, "error": "a build is already running"}
    try:
        issue = latest_in_review_issue()
        pr = _pull_request(issue)
        if not pr:
            return {"ok": False, "error": "no pull request is open for review"}
        sha = pr["headRefOid"][:12]
        tag = f"{sha}-{int(time.time())}"
        _set_stage("building", building_sha=sha, failed_sha=None)
        if os.environ.get("CONSOLE_BUILD_MODE") == "snapshot":
            import google_snapshot
            try:
                google_snapshot.stage(REPO, pr["headRefOid"], tag, ENVS["staging"])
            except Exception as e:
                _set_stage("build_failed", error=str(e), failed_sha=sha)
                return {"ok": False, "error": str(e)}
            _set_stage("staged", staged_tag=tag, staged_sha=sha, staged_pr=pr["number"], error=None)
            note = f"**Staged for review**: immutable source snapshot `{pr['headRefOid']}` on the existing Berlin Python runtime. Review at {staging_url()}."
            _comment(pr["number"], note)
            _comment(issue["number"], note)
            return {"ok": True, "tag": tag, "sha": sha, "artifact": "source-snapshot", "issue": issue,
                    "pull_request": pr, "staging_url": staging_url()}
        err = _docker_login()
        if err:
            _set_stage("build_failed", error=err, failed_sha=sha)
            return {"ok": False, "error": err}
        with tempfile.TemporaryDirectory() as td:
            steps = [(["gh", "repo", "clone", REPO, td, "--", "--depth", "1", "-q",
                       "--branch", pr["headRefName"]], 90, "clone failed"),
                     (["docker", "build", "-q", "--platform", "linux/amd64", "--build-arg", f"GIT_SHA={sha}",
                       "-t", f"{IMAGE}:{tag}", td], 300, "docker build failed"),
                     (["docker", "push", "-q", f"{IMAGE}:{tag}"], 300, "docker push failed")]
            for cmd, timeout, what in steps:
                p = _run(cmd, timeout)
                if p.returncode != 0:
                    err = ((p.stderr or "").strip()[-400:] or what)
                    _set_stage("build_failed", error=err, failed_sha=sha)
                    return {"ok": False, "error": err}
        err = _roll("staging", f"{IMAGE}:{tag}")
        if err:
            _set_stage("build_failed", error=err, failed_sha=sha)
            return {"ok": False, "error": err}
        _set_stage("staged", staged_tag=tag, staged_sha=sha, staged_pr=pr["number"], error=None)
        note = (f"**Staged for review** at commit `{sha[:7]}`: {staging_url()}\n\n"
                f"Image `trustusbank-payments:{tag}` in `{ENVS['staging']}` on Google Cloud Dedicated "
                "(Berlin). Approve or deny from the demo console.")
        _comment(pr["number"], note)
        _comment(issue["number"], note)
        return {"ok": True, "tag": tag, "sha": sha, "issue": issue, "pull_request": pr,
                "staging_url": staging_url()}
    finally:
        _build_lock.release()


# ── gate 2: the pull request, as staged ──────────────────────────────────────
def promote(approve: bool, reason: str = "") -> dict:
    """Approve: the exact image reviewed in staging goes to prod, no rebuild; the pull
    request merges, which closes the issue, labelled `live`. Deny: prod is untouched,
    the reason goes on the pull request and the issue, the issue goes back to
    `agent-ready` so the engineer's next get_next_issue reads the denial, and staging
    goes back to what prod runs."""
    state = _load_state()
    tag = state.get("staged_tag")
    issue = latest_in_review_issue()
    pr = _pull_request(issue)
    who = identity("dev").get("user") or tl.USER
    if approve:
        if not tag or not (_image_tag("staging") or "").startswith(tag[:12]):
            return {"ok": False, "error": "nothing staged to promote"}
        if pr and not tag.startswith(pr["headRefOid"][:12]):
            return {"ok": False, "error": "the pull request moved on since it was staged: wait for staging to catch up"}
        import google_snapshot
        if google_snapshot.artifact_tag(ENVS["staging"]):
            google_snapshot.copy_environment(ENVS["staging"], ENVS["prod"], "production")
            err = None
        else:
            err = _roll("prod", f"{IMAGE}:{tag}")
        if err:
            return {"ok": False, "error": err}
        # Relabel before merging: the merge closes the issue ("Closes #n"), and a closed
        # issue still labelled in-review is what anyone looking at GitHub would see.
        if issue:
            _relabel(issue["number"], "live", "in-review")
        merged = None
        if pr:
            _comment(pr["number"], f"**Approved** by {who} after review in staging. Merging; production now "
                                   f"runs image `trustusbank-payments:{tag}`: {prod_url()}")
            m = _gh("pr", "merge", str(pr["number"]), "--repo", REPO, "--merge", "--delete-branch", timeout=60)
            merged = m.returncode == 0
        if issue:
            _comment(issue["number"], f"**Live** at {prod_url()} (image `trustusbank-payments:{tag}`), "
                                      f"approved by {who}.")
            _gh("issue", "close", str(issue["number"]), "--repo", REPO)
        _set_stage("promoted", promoted_tag=tag, merged=merged)
        return {"ok": True, "tag": tag, "issue": issue, "pull_request": pr, "merged": merged, "prod_url": prod_url()}
    reason = (reason or "").strip()
    if not reason:
        return {"ok": False, "error": "a reason is required to deny"}
    if not issue:
        return {"ok": False, "error": "no issue is in review"}
    if pr:
        _comment(pr["number"], f"**Changes requested** by {who} in staging review: {reason}")
    _comment(issue["number"], f"Denied in staging review by {who}: {reason}\n\nProduction is unchanged. "
                              "Back to `agent-ready`: the engineer agent reads this comment on its next pass "
                              "and updates the same pull request.")
    _relabel(issue["number"], "agent-ready", "in-review")
    prod_image = _image("prod")
    if prod_image:
        import google_snapshot
        if google_snapshot.artifact_tag(ENVS["prod"]) or google_snapshot.artifact_tag(ENVS["staging"]):
            google_snapshot.copy_environment(ENVS["prod"], ENVS["staging"], "staging")
        else:
            _roll("staging", prod_image)
    _set_stage("denied", denied_reason=reason, staged_tag=None,
               denied_sha=pr["headRefOid"][:12] if pr else None)
    return {"ok": True, "denied": True, "issue": issue, "pull_request": pr}
