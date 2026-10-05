"""Agent builder and MCP approvals for the Google page, without kubectl.

The builder is the console's /agents page, made for Berlin: pick Gemma, write a
system prompt, tick skills and MCP tools, and AgentRegistry pushes a declarative
agent onto kagent, exactly as trustusbank/deploy.sh does. Then talk to it as bob.

The approvals are the console's /approvals page, kept in AgentRegistry itself. An
agent may ask for any MCP tool (the picker reads each server's tools/list live, from
mcp/mcp-catalog inside the mesh); a platform admin then approves or denies those tools for that
agent. The decision lives on the agent's own AgentRegistry record as annotations:

    demo.solo.io/approved-tools   JSON list of "server/tool"
    demo.solo.io/denied-tools     JSON list of "server/tool"
    demo.solo.io/reviewed-by      the admin's preferred_username
    demo.solo.io/reviewed-at      ISO timestamp

Enforcement is at the shared mcp-waypoint, not in the agent: every approval re-renders
the <agent>--<backend> EnterpriseAgentgatewayPolicies in ns mcp (scripts/mcp_policies.py
in the lab repo), which allows a caller only by its mesh identity, namespace and
ServiceAccount, and only the approved tools. Agents dial the MCP Services in-cluster,
with no identifying header. The Deployment's ALLOWED_TOOLS also hides unapproved tools.

The four TrustUsBank agents trustusbank/deploy.sh made are listed alongside, and
chat through their own Keycloak clients (bob's token exchanged, as Demo 2 does).

AgentRegistry and Keycloak go over hostnames; kubectl uses deploy/console.kubeconfig
(91-console-kubeconfig.sh), which does not expire with the gcloud login.
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse
import urllib.request
import uuid
from datetime import datetime, timezone
from pathlib import Path

import trustusbank_lab as tl

AR_URL = os.environ.get("GB_AR_URL", "http://agentregistry.agentic.eu0.internal").rstrip("/")
# Browser-facing registry UI. GB_AR_URL may point in-cluster on the hosted console
# (*.svc.cluster.local), which a presenter's browser can never resolve.
AR_UI_URL = os.environ.get("GB_AR_UI_URL", "https://agentregistry.agentic.eu0.internal").rstrip("/")
ARCTL = os.environ.get("ARCTL", str(Path.home() / ".arctl/bin/arctl"))
AR_NS = "agentregistry-system"
KEYCLOAK = tl.KEYCLOAK
REALM = tl.REALM
MODEL = {"name": "gemma-3-27b-it", "provider": "openai", "base_url": "http://llm.agentic.eu0.internal/v1",
         "title": "Gemma 3 27B", "where": "vLLM on an H100 in Berlin, through agentgateway's llm route"}
DEFAULT_IMAGE = "docker.pkg-berlin-build0.goog/eu0/soloio-eval/solo/trustusbank-agent:0.1.8"

BUILDER_LABEL = "demo.solo.io/builder"
TOOLS_ANN = "demo.solo.io/tools"
SKILLS_ANN = "demo.solo.io/skills"
PROMPT_ANN = "demo.solo.io/system"
# The admin's decisions, per agent, on the agent's own record.
OK_ANN, NO_ANN = "demo.solo.io/approved-tools", "demo.solo.io/denied-tools"
BY_ANN, AT_ANN = "demo.solo.io/reviewed-by", "demo.solo.io/reviewed-at"
# Builder agents are named exactly as typed: no forced prefix, so names stay short.
# At most 24 characters: AgentRegistry names the kagent Agent <name>-latest- plus 16
# characters of the Deployment's name, and kagent labels its Service with that
# Agent's waypoint, agent-<kagent name>-waypoint, which may not pass 63.
NAME_RE = re.compile(r"^[a-z][a-z0-9-]{1,22}[a-z0-9]$")


def _template_name(domain: str) -> str:
    name = f"my-{domain}"
    return name if NAME_RE.match(name) else f"{domain}-2"


def agent_name(raw: str) -> str:
    return (raw or "").strip().lower()

# Skills are prompt fragments: Berlin's AgentRegistry has no Skill packages, and
# these are what a bank would actually want an agent to always do.
SKILLS = [
    {"id": "bank-customers", "title": "Know our customers",
     "description": "The demo customers, their customer numbers and IBANs.",
     "body": "Our customers: Anna Schmidt is customer C-1001, account DE89500105170000100101. "
             "Mehmet Yilmaz is customer C-1002, business account DE89500105170000200201. "
             "Claire Dubois is customer C-1003, account DE89500105170000300301. "
             "When someone names a customer, use their account or customer number with your tools."},
    {"id": "cite-tools", "title": "Cite the tool",
     "description": "Say which tool each figure came from.",
     "body": "After every figure you give, name the tool that returned it in brackets, e.g. [get_account_balance]."},
    {"id": "german", "title": "Answer in the customer's language",
     "description": "Reply in the language of the question; formal Sie in German.",
     "body": "Answer in the language the question was asked in. In German, always use the formal 'Sie'."},
    {"id": "brief", "title": "Short answers",
     "description": "Three sentences at most, figures first.",
     "body": "Keep answers to three sentences at most and lead with the figures."},
    {"id": "mask-iban", "title": "Mask IBANs (DSGVO)",
     "description": "Show only the last four digits of an IBAN.",
     "body": "Never repeat a full IBAN: write it as DE** **** **** **** **01 01, showing only the last four digits."},
    {"id": "escalate", "title": "Escalate to a human",
     "description": "Hand over when a tool cannot answer or a limit is breached.",
     "body": "If your tools cannot answer, or a payment would breach a limit or an AML rule, say so plainly and "
             "recommend the customer is handed to a human colleague. Never guess."},
]

_lock = threading.Lock()
_ar_tok: tuple = (None, 0)
_cache: dict = {}   # key -> (expiry, value)


# ── AgentRegistry ────────────────────────────────────────────────────────────
def _ar_token() -> str:
    global _ar_tok
    tok, exp = _ar_tok
    if not tok or exp - time.time() < 60:
        tok = tl._form(f"{KEYCLOAK}/realms/{REALM}/protocol/openid-connect/token", {
            "grant_type": "password", "client_id": "ar-cli-password", "username": "admin-user",
            "password": os.environ.get("GB_AR_PASSWORD", "password")})["access_token"]
        _ar_tok = (tok, tl._claims(tok).get("exp", time.time() + 300))
    return tok


def _admin() -> str:
    try:
        return tl._claims(_ar_token()).get("preferred_username") or "admin-user"
    except Exception:  # noqa: BLE001
        return "admin-user"


def _arctl(*args, timeout=40) -> str:
    env = {**os.environ, "ARCTL_API_BASE_URL": AR_URL, "ARCTL_API_TOKEN": _ar_token()}
    r = subprocess.run([ARCTL, *args], capture_output=True, text=True, env=env, timeout=timeout)
    if r.returncode != 0:
        raise RuntimeError(f"arctl {args[0]} {args[1] if len(args) > 1 else ''}: "
                           f"{(r.stderr or r.stdout).strip()[:400]}")
    return r.stdout


def _get(kind: str) -> list:
    out = _arctl("get", kind, "-o", "json").strip()
    if not out or out == "null":
        return []
    data = json.loads(out)
    return data if isinstance(data, list) else [data]


def _apply(*docs: dict):
    # One record per call: arctl reads only the first document of a JSON multi-doc file.
    out = []
    for d in docs:
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
            json.dump(d, f)
            path = f.name
        try:
            out.append(_arctl("apply", "-f", path))
        finally:
            os.unlink(path)
    return "".join(out)


def _record(doc: dict) -> dict:
    """A fetched record, stripped to what apply accepts."""
    md = doc.get("metadata") or {}
    out = {"apiVersion": doc.get("apiVersion", "ar.dev/v1alpha1"), "kind": doc["kind"],
           "metadata": {"name": md["name"]}, "spec": doc.get("spec") or {}}
    for k in ("labels", "annotations"):
        if md.get(k):
            out["metadata"][k] = dict(md[k])
    return out


def _memo(key: str, ttl: float, fetch):
    hit = _cache.get(key)
    if hit and hit[0] > time.time():
        return hit[1]
    val = fetch()
    _cache[key] = (time.time() + ttl, val)
    return val


# ── MCP: tools/list from inside the mesh ─────────────────────────────────────
# Every MCP server sits behind the shared mcp-waypoint, which only lets mesh identities
# through: there is no route to them from the laptop. The mcp-catalog workload in ns mcp
# is allowed tools/list on every server and nothing else, so the console lists tools by
# running this small client there (kubectl exec).
LAB = Path(os.environ.get("GCD_LAB_ROOT", "~/code/google-sov/poc/2026-09-agentic-platform")).expanduser()
sys.path.insert(0, str(LAB / "scripts"))
import mcp_policies  # noqa: E402  (the same renderer scripts/92-mcp-lockdown.sh uses)
import mcp_security  # noqa: E402

MCP_NS = "mcp"
_LIST_TOOLS = r"""
import json, sys, urllib.request
from pathlib import Path
def post(url, body, sid=None):
    h = {"content-type": "application/json", "accept": "application/json, text/event-stream"}
    h["Authorization"] = "Bearer " + Path("/var/run/secrets/mcp/token").read_text().strip()
    if sid:
        h["mcp-session-id"] = sid
    with urllib.request.urlopen(urllib.request.Request(url, json.dumps(body).encode(), h), timeout=15) as r:
        sid = r.headers.get("mcp-session-id") or sid
        raw = r.read().decode("utf-8", "replace")
    msg = None
    for line in raw.splitlines():
        if line.startswith("data:"):
            try:
                msg = json.loads(line[5:])
            except ValueError:
                pass
    if msg is None and raw.strip().startswith("{"):
        msg = json.loads(raw)
    return msg, sid
out = {}
for url in sys.argv[1:]:
    try:
        _, sid = post(url, {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
            "protocolVersion": "2025-03-26", "capabilities": {},
            "clientInfo": {"name": "google-builder", "version": "1"}}})
        try:
            post(url, {"jsonrpc": "2.0", "method": "notifications/initialized"}, sid)
        except Exception:
            pass
        msg, _ = post(url, {"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}}, sid)
        out[url] = {"tools": ((msg or {}).get("result") or {}).get("tools") or []}
    except Exception as e:
        out[url] = {"error": str(e)}
print(json.dumps(out))
"""


def _tools_lists(urls: tuple) -> dict:
    """url -> {tools} or {error}, for every in-cluster MCP URL, in one exec."""
    if not urls:
        return {}
    r = subprocess.run(["kubectl", "-n", MCP_NS, "exec", "-i", "deploy/mcp-catalog", "--", "python3", "-", *urls],
                       input=_LIST_TOOLS, env=tl.google_sov._env(), capture_output=True, text=True, timeout=90)
    if r.returncode != 0:
        raise RuntimeError(r.stderr.strip() or "kubectl exec into mcp/mcp-catalog failed")
    return json.loads(r.stdout)


def _service_of(url: str | None, services: dict) -> str | None:
    """The Service an MCPServer record points at: bank-payments, sdlc-pm, everything-server."""
    u = urllib.parse.urlparse(url or "")
    host = u.hostname or ""
    if host.endswith(f".{MCP_NS}.svc.cluster.local") or host.endswith(f".{MCP_NS}.svc"):
        svc = host.split(".")[0]
    else:   # an old edge route, mcp.<domain>/mcp/<name>
        tail = u.path.rstrip("/").split("/")[-1]
        svc = "everything-server" if tail == "mcp" else (f"bank-{tail}" if f"bank-{tail}" in services else tail)
    return svc if svc in services else None


def _incluster(svc: str, services: dict) -> str:
    return f"http://{svc}.{MCP_NS}.svc.cluster.local:3000{services[svc].get('path', '/mcp')}"


def _jlist(v) -> list:
    try:
        x = json.loads(v or "[]")
        return [str(i) for i in x] if isinstance(x, list) else []
    except (json.JSONDecodeError, TypeError):
        return []


def _servers(fresh=False) -> list:
    return _get("mcps") if fresh else _memo("servers", 5, lambda: _get("mcps"))


def _services(fresh=False) -> dict:
    """MCPServer name -> the Service behind it, for the servers grants.json knows."""
    known = mcp_policies.load()["services"]
    out = {}
    for m in _servers(fresh):
        svc = _service_of(((m.get("spec") or {}).get("remote") or {}).get("url"), known)
        if svc:
            out[(m.get("metadata") or {}).get("name")] = svc
    return out


def mcp_catalog(fresh=False) -> dict:
    """Every MCPServer in AgentRegistry and its live tools, with descriptions and input schemas."""
    try:
        servers = _servers(fresh)
        known = mcp_policies.load()["services"]
    except Exception as e:  # noqa: BLE001
        return {"reachable": False, "error": str(e), "servers": []}
    svc = {}
    for s in servers:
        name = (s.get("metadata") or {}).get("name")
        sv = _service_of(((s.get("spec") or {}).get("remote") or {}).get("url"), known)
        if sv:
            svc[name] = _incluster(sv, known)
    urls = tuple(sorted(set(svc.values())))
    try:
        lists, lerr = _memo("tools:" + ",".join(urls), 30, lambda: _tools_lists(urls)), None
    except Exception as e:  # noqa: BLE001
        lists, lerr = {}, f"tools/list from mcp/mcp-catalog: {e}"
    out = []
    for s in servers:
        md, spec = s.get("metadata") or {}, s.get("spec") or {}
        url = svc.get(md.get("name"))
        got = lists.get(url) or {}
        err = (None if url else "not an MCP service in yaml/mcp-mesh/grants.json") or lerr or (
            f"tools/list at {url}: {got['error']}" if got.get("error") else None)
        rows = [{"name": t.get("name"), "description": (t.get("description") or "").strip(),
                 "inputSchema": t.get("inputSchema") or {}} for t in got.get("tools") or []]
        out.append({"name": md.get("name"), "title": spec.get("title") or md.get("name"),
                    "description": spec.get("description") or "", "url": url, "error": err,
                    "tools": rows})
    out.sort(key=lambda s: (not s["name"].startswith("trustusbank-"), s["name"]))
    return {"reachable": True, "servers": out, "admin": _admin()}


# ── builder ──────────────────────────────────────────────────────────────────
def _skills() -> list:
    skills = list(SKILLS)
    try:
        for s in _memo("ar-skills", 60, lambda: _get("skills")):
            md, spec = s.get("metadata") or {}, s.get("spec") or {}
            skills.append({"id": "ar:" + md.get("name", ""), "title": spec.get("title") or md.get("name"),
                           "description": spec.get("description") or "From AgentRegistry",
                           "body": spec.get("description") or "", "source": "agentregistry"})
    except Exception:  # noqa: BLE001
        pass
    return skills


def catalog() -> dict:
    """Everything the wizard offers: the model, the skills and every MCP tool there is.
    Any tool can be picked; it only runs once a platform admin approves it for the agent."""
    cat = mcp_catalog()
    servers = [{"name": s["name"], "title": s["title"], "description": s["description"], "error": s["error"],
                "tools": [{"name": t["name"], "description": t["description"]} for t in s["tools"]]}
               for s in cat.get("servers", [])]
    templates = [{"id": a["domain"], "title": a["title"], "name": _template_name(a["domain"]), "system": a["system"],
                  "server": f"trustusbank-{a['domain']}-tools", "prompts": a["prompts"]} for a in tl.AGENTS]
    return {"reachable": cat.get("reachable"), "error": cat.get("error"), "model": MODEL, "skills": _skills(),
            "servers": servers, "templates": templates, "admin": cat.get("admin")}


def _image() -> str:
    try:
        for a in _get("agents"):
            if a["metadata"]["name"] == "trustusbank-payments":
                return a["spec"]["source"]["image"]
    except Exception:  # noqa: BLE001
        pass
    return DEFAULT_IMAGE


def _builder_records() -> list:
    return [a for a in _get("agents")
            if ((a.get("metadata") or {}).get("labels") or {}).get(BUILDER_LABEL) == "google"]


# ── the gateway policy an approval writes ────────────────────────────────────
# One EnterpriseAgentgatewayPolicy per agent per MCP backend, <agent>--<backend> in
# ns mcp, enforced at the shared mcp-waypoint every call to an MCP Service goes
# through. Its clause names the agent by its mesh identity (namespace and
# ServiceAccount, proven by ztunnel's mTLS) and the tools approved on that server; no
# HTTP header is trusted. agentgateway ORs the Allow policies on a backend, so an
# approval adds this agent's policy and touches no one else's. Default deny is the
# lab's mcp-catalog-tools-list policy, attached to every backend.
#
# The console owns only the builder agents' policies (label mcp-lockdown/source:
# console); the fixed agents' come from yaml/mcp-mesh/grants.json through the lab's
# 92-mcp-lockdown.sh. scripts/mcp_policies.py renders both.
SOURCE = "console"
_policy_error: str | None = None


def _sa_of(name: str) -> str:
    """What AgentRegistry names a builder agent's Deployment and ServiceAccount."""
    return f"{name}-latest-{(name + '-kagent')[:16]}"


def _as_grants(agent: str, tools: list, svc: dict) -> list:
    by: dict = {}
    for t in tools:
        server, _, tool = t.partition("/")
        if server in svc:
            by.setdefault(svc[server], []).append(tool)
    return [{"service": s, "namespace": AR_NS, "agent": agent, "tools": sorted(ts)} for s, ts in sorted(by.items())]


def _render(override: tuple | None = None) -> list:
    """The builder agents' policies, from the admin's approvals in AgentRegistry.
    override=(agent, ["server/tool", ...]) renders just that agent with those tools,
    for a preview."""
    svc = _services(fresh=True)
    if override:
        recs = [(override[0], override[1])]
    else:
        recs = [(r["metadata"]["name"], _review_of(r)["approved"]) for r in _builder_records()]
    grants, sas = [], {}
    for name, tools in recs:
        grants += _as_grants(name, tools, svc)
        # Known before AgentRegistry has created the Deployment, so a grant never
        # waits on the pod.
        sas[(AR_NS, _sa_of(name))] = _sa_of(name)
    return mcp_policies.render(grants, env=tl.google_sov._env(), sas=sas, source=SOURCE)


def _sync_policies() -> str | None:
    """Apply one policy per approved (builder agent, server) and delete the ones revoked."""
    global _policy_error
    try:
        mcp_security.reconcile_agents(env=tl.google_sov._env())
        mcp_policies.apply(_render(), source=SOURCE, env=tl.google_sov._env())
        _cache.pop("live-policies", None)
        _policy_error = None
    except Exception as e:  # noqa: BLE001
        _policy_error = f"gateway policy not applied: {e}"
    return _policy_error


def _live_policies() -> list:
    """Every mcp-lockdown policy as it is in the cluster now."""
    def fetch():
        r = tl._kubectl("-n", MCP_NS, "get", "enterpriseagentgatewaypolicies",
                        "-l", "app.kubernetes.io/managed-by=mcp-lockdown", "-o", "json")
        if r.returncode != 0:
            raise RuntimeError(r.stderr.strip() or "cannot list policies in ns mcp")
        return [{"apiVersion": p["apiVersion"], "kind": p["kind"],
                 "metadata": {"name": p["metadata"]["name"], "namespace": p["metadata"]["namespace"],
                              "labels": p["metadata"].get("labels") or {}},
                 "spec": p["spec"]} for p in json.loads(r.stdout).get("items", [])]
    return _memo("live-policies", 10, fetch)


def _identity(agent: str, ns: str = AR_NS) -> str:
    """namespace/ServiceAccount the waypoint knows this agent by."""
    try:
        sas = _memo("sas:" + ns, 15, lambda: mcp_policies.service_accounts([ns], tl.google_sov._env()))
        hit = mcp_policies.resolve(ns, agent, sas)
    except Exception:  # noqa: BLE001
        hit = []
    return f"{ns}/{hit[0] if hit else _sa_of(agent)}"


def _policies_for(agent: str, ns: str | None = AR_NS, override: tuple | None = None) -> str:
    """This agent's own policies: live from the cluster, or as an approval would write them."""
    try:
        if override:
            docs = _render(override)
        else:
            docs = [d for d in _live_policies()
                    if d["metadata"]["labels"].get("mcp-lockdown/agent") == agent
                    and ns in (None, d["metadata"]["labels"].get("mcp-lockdown/agent-namespace"))]
    except Exception as e:  # noqa: BLE001
        return f"# cannot read the policies: {e}\n"
    return "---\n".join(mcp_policies.to_yaml(d) + "\n" for d in docs)


def _deploy_records(name: str, system: str, skills: list, tools: list, description: str, review: dict):
    """Write the Agent and its Deployment. review holds the admin's per-agent decisions:
    {approved, denied, by, at}. The agent may ask for any tool; only approved ones run."""
    allowed = [t for t in tools if t in set(review.get("approved") or [])]
    svc, known = _services(fresh=True), mcp_policies.load()["services"]
    servers = sorted({t.split("/", 1)[0] for t in tools})
    live = sorted({t.split("/", 1)[0] for t in allowed})
    by_id = {s["id"]: s for s in _skills()}
    prompt = "\n\n".join([system.strip()] + [by_id[s]["body"] for s in skills if s in by_id and by_id[s]["body"]])
    # The Service itself, never an edge hostname: the call goes through the mcp-waypoint,
    # which knows this agent by its ServiceAccount. No header names it.
    mcp_cfg = [{"name": s, "type": "remote", "url": _incluster(svc[s], known)} for s in live if s in svc]
    names = [t.split("/", 1)[1] for t in allowed]
    ann = {TOOLS_ANN: json.dumps(tools), SKILLS_ANN: json.dumps(skills), PROMPT_ANN: system.strip()[:4000],
           OK_ANN: json.dumps(sorted(set(review.get("approved") or []) & set(tools))),
           NO_ANN: json.dumps(sorted(set(review.get("denied") or []) & set(tools)))}
    if review.get("by"):
        ann[BY_ANN], ann[AT_ANN] = review["by"], review.get("at") or ""
    agent = {"apiVersion": "ar.dev/v1alpha1", "kind": "Agent",
             "metadata": {"name": name, "labels": {BUILDER_LABEL: "google"}, "annotations": ann},
             "spec": {"description": description, "modelName": MODEL["name"], "modelProvider": MODEL["provider"],
                      "source": {"image": _image()},
                      "mcpServers": [{"kind": "MCPServer", "name": s} for s in servers]}}
    dep = {"apiVersion": "ar.dev/v1alpha1", "kind": "Deployment", "metadata": {"name": f"{name}-kagent"},
           "spec": {"targetRef": {"kind": "Agent", "name": name},
                    "runtimeRef": {"kind": "Runtime", "name": "kubernetes-default"},
                    "env": {"MODEL_NAME": MODEL["name"], "MODEL_BASE_URL": MODEL["base_url"],
                            "MODEL_API_KEY": "sovereign-local-noauth",
                            "MCP_SERVERS_CONFIG": json.dumps(mcp_cfg), "MCP_TERMINATE_ON_CLOSE": "false",
                            # Empty would mean every tool: an agent with none approved gets a name no tool has.
                            "ALLOWED_TOOLS": json.dumps(names or ["__none__"]),
                            "SYSTEM_MESSAGE": prompt, "AGENT_DESCRIPTION": description,
                            "ADK_AGENT_NAME": name.replace("-", "_"), "OTEL_SERVICE_NAME": name}}}
    identity = mcp_security.identity_deployment({"env": [
        {"name": k, "value": v} for k, v in dep["spec"]["env"].items()]})
    dep["spec"]["env"] = {e["name"]: e["value"] for e in identity["env"]}
    _apply(agent, dep)


def _review_of(rec: dict | None) -> dict:
    ann = ((rec or {}).get("metadata") or {}).get("annotations") or {}
    return {"approved": _jlist(ann.get(OK_ANN)), "denied": _jlist(ann.get(NO_ANN)),
            "by": ann.get(BY_ANN), "at": ann.get(AT_ANN)}


def deploy(body: dict) -> dict:
    """Create an agent, or redeploy one under the same name (Edit). Approvals already
    given for tools it still asks for are kept; new tools wait for the admin."""
    name = agent_name(body.get("name"))
    system = (body.get("system") or "").strip()
    skills = [s for s in body.get("skills") or [] if isinstance(s, str)]
    tools = sorted({t for t in body.get("tools") or [] if isinstance(t, str) and "/" in t})
    if not NAME_RE.match(name):
        if len(name) > 24:
            return {"ok": False, "error": f"Name '{name}' is {len(name)} characters; the limit is 24 (kagent's waypoint label must fit 63 bytes). Shorten it, e.g. '{name[:21]}-2'."}
        return {"ok": False, "error": f"Name '{name}': use 3-24 lowercase letters, digits or dashes, starting with a letter and ending with a letter or digit."}
    if not system:
        return {"ok": False, "error": "Say what the agent should do."}
    try:
        with _lock:
            existing = next((a for a in _get("agents") if a["metadata"]["name"] == name), None)
            if existing and ((existing["metadata"].get("labels") or {}).get(BUILDER_LABEL) != "google"):
                return {"ok": False, "error": f"{name} already exists in AgentRegistry and was not made here."}
            if existing and not body.get("edit"):
                return {"ok": False, "error": f"You already have an agent called {name}. Pick another name, or edit it."}
            review = _review_of(existing)
            desc = (body.get("description") or "").strip() or f"Built on the Google page with Gemma 3 27B."
            _deploy_records(name, system, skills, tools, desc[:300], review)
            _sync_policies()
    except Exception as e:  # noqa: BLE001
        return {"ok": False, "error": str(e)}
    waiting = [t for t in tools if t not in review["approved"]]
    return {"ok": True, "name": name, "deployment": f"{name}-kagent", "tools": tools, "skills": skills,
            "waiting": waiting}


def approve(name: str, tools: list | None, decision: str) -> dict:
    """The platform admin's call on tools one agent asked for: approve lets the tool run
    for that agent, deny blocks it. Either way the agent is redeployed to match."""
    if decision not in ("approve", "deny"):
        return {"ok": False, "error": "decision is approve or deny"}
    try:
        with _lock:
            rec = next((a for a in _builder_records() if a["metadata"]["name"] == name), None)
            if not rec:
                return {"ok": False, "error": f"No agent called {name}"}
            ann = rec["metadata"].get("annotations") or {}
            asked = _jlist(ann.get(TOOLS_ANN))
            tools = asked if tools is None else [t for t in tools if t in asked]
            review = _review_of(rec)
            ok, no = set(review["approved"]), set(review["denied"])
            for t in tools:
                ok.discard(t)
                no.discard(t)
                (ok if decision == "approve" else no).add(t)
            review = {"approved": sorted(ok), "denied": sorted(no), "by": _admin(),
                      "at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")}
            _deploy_records(name, ann.get(PROMPT_ANN, ""), _jlist(ann.get(SKILLS_ANN)), asked,
                            rec["spec"].get("description", ""), review)
            err = _sync_policies()
    except Exception as e:  # noqa: BLE001
        return {"ok": False, "error": str(e)}
    if err:
        return {"ok": False, "error": err}
    return {"ok": True, "name": name, "decision": decision, "tools": tools, "reviewed_by": review["by"],
            "running": [t for t in asked if t in ok]}


def _kagent_list() -> list:
    def fetch():
        req = urllib.request.Request(f"{tl._a2a_base()}/api/agents", headers={"authorization": "Bearer " + _bob()})
        with urllib.request.urlopen(req, timeout=10) as r:
            return json.loads(r.read()).get("data") or []
    return _memo("kagent", 2, fetch)


def _kagent(name: str) -> dict | None:
    for a in _kagent_list():
        md = (a.get("agent") or {}).get("metadata") or {}
        if md.get("namespace") == AR_NS and (md.get("name") == name or md.get("name", "").startswith(name + "-latest-")):
            return {"name": md["name"], "ready": bool(a.get("deploymentReady")), "accepted": bool(a.get("accepted"))}
    return None


def status(name: str) -> dict:
    try:
        dep = next((d for d in _get("deployments") if d.get("name") == f"{name}-kagent"), None)
    except Exception as e:  # noqa: BLE001
        return {"name": name, "error": str(e)}
    k, kerr = None, None
    try:
        k = _kagent(name)
    except Exception as e:  # noqa: BLE001
        kerr = f"kagent-controller: {e}"
    conds = (dep or {}).get("conditions") or []
    steps = [{"id": "registry", "label": "AgentRegistry has the agent", "ok": dep is not None},
             {"id": "pushed", "label": "Pushed to kagent", "ok": bool(k)},
             {"id": "accepted", "label": "kagent accepted it", "ok": bool(k and k["accepted"])},
             {"id": "ready", "label": "Pod ready on GKE in Berlin", "ok": bool(k and k["ready"])}]
    return {"name": name, "found": dep is not None, "ar_status": (dep or {}).get("status"),
            "conditions": [{"type": c.get("type"), "status": c.get("status"), "message": c.get("message")}
                           for c in conds],
            "kagent": k, "ready": bool(k and k["ready"]), "steps": steps, "error": kerr}


def agents() -> dict:
    try:
        recs = _builder_records()
    except Exception as e:  # noqa: BLE001
        return {"reachable": False, "error": str(e), "agents": []}
    out = []
    for a in recs:
        md = a["metadata"]
        ann = md.get("annotations") or {}
        try:
            k = _kagent(md["name"])
        except Exception:  # noqa: BLE001
            k = None
        rv = _review_of(a)
        asked = _jlist(ann.get(TOOLS_ANN))
        out.append({"name": md["name"], "description": a["spec"].get("description"),
                    "tools": asked, "skills": _jlist(ann.get(SKILLS_ANN)),
                    "approved": [t for t in asked if t in rv["approved"]],
                    "denied": [t for t in asked if t in rv["denied"]],
                    "waiting": [t for t in asked if t not in rv["approved"] and t not in rv["denied"]],
                    "reviewed_by": rv["by"], "reviewed_at": rv["at"],
                    "system": ann.get(PROMPT_ANN, ""), "created": md.get("createdAt"),
                    "kagent": k, "ready": bool(k and k["ready"])})
    out.sort(key=lambda a: a.get("created") or "", reverse=True)
    return {"reachable": True, "agents": out}


def delete(name: str) -> dict:
    if not NAME_RE.match(name or ""):
        return {"ok": False, "error": "bad name"}
    try:
        rec = next((a for a in _builder_records() if a["metadata"]["name"] == name), None)
        if not rec:
            return {"ok": False, "error": f"{name} is not a builder agent"}
        try:
            _arctl("delete", "deployment", f"{name}-kagent")
        except RuntimeError:
            pass
        _arctl("delete", "agent", name)
        with _lock:
            _sync_policies()
    except Exception as e:  # noqa: BLE001
        return {"ok": False, "error": str(e)}
    return {"ok": True, "name": name}


# ── chat as bob ──────────────────────────────────────────────────────────────
def _bob() -> str:
    tok_url = f"{KEYCLOAK}/realms/{REALM}/protocol/openid-connect/token"
    with tl._id_lock:
        return tl._cached("user", lambda: tl._form(tok_url, {
            "grant_type": "password", "client_id": "trustusbank-console", "username": tl.USER,
            "password": os.environ.get("TUB_USER_PASSWORD", "password"), "scope": "openid"})["access_token"])


def chat_stream(name: str, text: str, context_id: str | None = None):
    """One streamed A2A turn with a builder agent, signed in as bob. The same events
    trustusbank_lab.chat_stream yields; builder agents have no Keycloak client of
    their own, so bob's console token goes to kagent as it is."""
    text = (text or "").strip()
    if not text:
        yield {"t": "error", "error": "Type a message first."}
        return
    try:
        k = _kagent(name)
        if not k:
            yield {"t": "error", "error": f"{name} is not on kagent yet: deploy it, or wait for it to start."}
            return
        dep, base = k["name"], tl._a2a_base()
        # The bank's own agents have a Keycloak client each: bob's token is exchanged
        # at it, so kagent sees bob and agent_id. Builder agents get bob's token as is.
        fixed = FIXED.get(name)
        tok = fixed["token"]() if fixed else _bob()
        if not tok:
            raise RuntimeError((fixed["id_error"]() if fixed else tl._id_error) or "could not sign in as bob")
    except Exception as e:  # noqa: BLE001
        yield {"t": "error", "error": str(e)}
        return
    hdr = {"content-type": "application/json", "authorization": "Bearer " + tok}
    url = f"{base}/api/a2a/{AR_NS}/{dep}/"
    msg = {"role": "user", "messageId": uuid.uuid4().hex, "kind": "message",
           "parts": [{"kind": "text", "text": text[:4000]}]}
    if context_id:
        msg["contextId"] = context_id
    body = json.dumps({"jsonrpc": "2.0", "id": uuid.uuid4().hex, "method": "message/stream",
                       "params": {"message": msg}}).encode()
    req = urllib.request.Request(url, data=body, method="POST", headers={**hdr, "accept": "text/event-stream"})
    yield {"t": "agent", "deployment": dep, "user": tl._claims(tok).get("preferred_username"),
           "agent_id": tl._claims(tok).get("agent_id") or name, "own_identity": True,
           "identity_detail": "workload JWT + mesh identity"}
    seen_calls, seen_results, said = set(), set(), set()
    ctx, task_id, state, final, t0 = context_id, None, None, False, time.time()

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
    if final and state not in tl.TERMINAL:
        yield {"t": "error", "error": "A newer message on this conversation took over before the agent answered."}
        yield {"t": "done", "contextId": ctx, "state": "superseded", "elapsed": round(time.time() - t0, 1)}
        return
    if state not in tl.TERMINAL and task_id:
        yield {"t": "recovering", "state": state, "at": round(time.time() - t0, 1)}
        give_up = time.time() + 90
        while time.time() < give_up:
            try:
                rb = json.dumps({"jsonrpc": "2.0", "id": uuid.uuid4().hex, "method": "tasks/get",
                                 "params": {"id": task_id}}).encode()
                with urllib.request.urlopen(urllib.request.Request(url, data=rb, method="POST", headers=hdr),
                                            timeout=20) as r:
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
    yield {"t": "done", "contextId": ctx, "state": state, "elapsed": round(time.time() - t0, 1)}


# ── the /agents page's contract ──────────────────────────────────────────────
# /google/agents and /google/approvals are the console's own agents.html and
# approvals.html, pointed here with window.AGENTS_API. These functions answer in the
# exact JSON agents_lab.py gives them for kind; the work underneath is the code above.

SDLC_TOOLS = {
    "pm": ["list_issues", "get_app_settings", "create_issue"],
    "dev": ["get_next_issue", "update_setting", "read_file", "edit_file", "open_pull_request"],
}
# What a person would actually type in the wizard: the tools step does the rest.
TEMPLATE_PROMPTS = {
    "payments": "You help TrustUsBank customers with their accounts and payments. "
                "Use your tools for any numbers and keep answers short.",
    "compliance": "You check payments and companies for fraud and sanctions risk. "
                  "Give a clear yes or no and the next step.",
    "credit": "You help customers work out whether they can afford a loan. "
              "Use your tools for the figures and explain the decision simply.",
    "gdpr": "You tell customers what personal data the bank holds about them, and why. "
            "Answer in plain language.",
}

TUB_TOOLS = {
    "payments": ["get_account_balance", "list_transactions", "check_payment_limit", "get_ecb_fx_rate"],
    "compliance": ["screen_sanctions", "check_aml_threshold", "get_transaction_alerts"],
    "credit": ["get_customer_exposure", "assess_affordability"],
    "gdpr": ["find_personal_data", "list_processing_purposes", "draft_art15_response"],
}


def _domain_of(server: str) -> str | None:
    m = re.match(r"^trustusbank-([a-z]+)-tools$", server or "")
    return m.group(1) if m else None


def _fixed() -> dict:
    """The agents deployed by their own scripts, not by this page: the four bank agents
    and the Demo 3 PM and AI dev agents. Each has its own Keycloak client, and chat
    reuses its module's token exchange, so kagent sees bob and the agent_id."""
    import trustusbank_sdlc as ts
    out = {}
    for a in tl.AGENTS:
        d = a["domain"]
        out[a["name"]] = {"title": a["title"], "description": a["description"], "system": a["system"],
                          "server": f"trustusbank-{d}-tools", "tools": TUB_TOOLS.get(d, []),
                          "deploy": "trustusbank/deploy.sh", "token": lambda d=d: tl._token(d),
                          "id_error": lambda: tl._id_error}
    for a in ts.AGENTS:
        r = a["role"]
        out[a["name"]] = {"title": a["title"], "description": a["description"], "system": a["system"],
                           "server": f"trustusbank-{r}-agent-tools", "tools": SDLC_TOOLS.get(r, []),
                          "deploy": "trustusbank-sdlc/deploy.sh", "token": lambda r=r: ts._token(r),
                          "id_error": lambda r=r: ts._id_errors.get(r)}
    return out


FIXED = _fixed()


def catalog_contract() -> dict:
    cat = mcp_catalog()
    mcp = [{"id": s["name"], "name": s["title"] or s["name"], "description": s["description"] or "",
            "domain": _domain_of(s["name"]) or "", "registryName": s["name"], "autoApprove": False,
            "tools": [{"id": t["name"], "description": t["description"] or ""} for t in s["tools"]]
                     or [{"id": t, "description": ""} for t in TUB_TOOLS.get(_domain_of(s["name"]), [])]}
           for s in cat.get("servers", [])]
    mcp = [m for m in mcp if m["tools"]]   # a server whose tools/list failed and we know nothing of
    skills = [{"id": s["id"], "title": s["title"], "description": s["description"], "ready": True,
               "domain": "agentregistry" if s.get("source") == "agentregistry" else "prompt"} for s in _skills()]
    return {"skills": skills, "mcp": mcp, "autoApproveLabel": "",
             "platform": {"kagent": True, "registry": True, "ui": "http://kagent.agentic.eu0.internal", "registry_ui": AR_UI_URL,
                         "label": "kagent in Berlin (GCD)",
                         "note": None if cat.get("reachable") else cat.get("error")}}


def prompts() -> dict:
    return {"prompts": [{"id": a["domain"], "tag": a["title"], "description": a["description"],
                         "content": a["system"]} for a in tl.AGENTS]}


def _group(tools: list) -> list:
    out: dict = {}
    for t in tools:
        s, _, n = t.partition("/")
        out.setdefault(s, []).append(n)
    return [{"id": s, "tools": ts} for s, ts in out.items()]


def _yaml(name: str, description: str, servers: list, skills: list, prompt: str = "", tools: list = ()) -> str:
    """The whole agent, as small as it really is: a name, a model, a sentence and the tools."""
    first = " ".join((prompt or "").split())
    lines = ["# This is the whole agent.", "apiVersion: ar.dev/v1alpha1", "kind: Agent", "metadata:", f"  name: {name}"]
    ann = []
    if first:
        ann.append(f"    {PROMPT_ANN}: {json.dumps(first[:240] + ('…' if len(first) > 240 else ''), ensure_ascii=False)}")
    if skills:
        ann.append(f"    {SKILLS_ANN}: {', '.join(skills)}")
    if ann:
        lines += ["  annotations:"] + ann
    lines += ["spec:", f"  description: {json.dumps(description or '', ensure_ascii=False)}", f"  modelName: {MODEL['name']}"]
    if servers:
        lines += ["  mcpServers:"]
        for sv in servers:
            mine = [t.split("/", 1)[1] for t in tools if t.split("/", 1)[0] == sv]
            lines += [f"  - name: {sv}"] + ([f"    tools: [{', '.join(mine)}]"] if mine else [])
    return "\n".join(lines) + "\n"


def _contract_entry(rec: dict, k: dict | None) -> dict:
    md, spec = rec["metadata"], rec.get("spec") or {}
    ann = md.get("annotations") or {}
    asked = _jlist(ann.get(TOOLS_ANN))
    rv = _review_of(rec)
    servers = sorted({t.split("/", 1)[0] for t in asked})
    ok = [t for t in asked if t in rv["approved"]]
    return {"name": md["name"], "description": spec.get("description") or "", "prompt": ann.get(PROMPT_ANN, ""),
            "skills": _jlist(ann.get(SKILLS_ANN)), "mcp": _group(asked),
            "version": md.get("tag") or "latest", "updated": md.get("updatedAt") or md.get("createdAt"),
            "yaml": _yaml(md["name"], spec.get("description"), servers, _jlist(ann.get(SKILLS_ANN)),
                          ann.get(PROMPT_ANN, ""), asked),
            "applied": bool(k), "mcp_auto": [], "mcp_restricted": servers,
            "admin_approved": bool(asked) and len(ok) == len(asked),
            "denied": [t for t in asked if t in rv["denied"]],
            "apply_error": _policy_error,
            "identity": _identity(md["name"]),
            "policy_yaml": _policies_for(md["name"]) if ok else "",
            "policy_preview": _policies_for(md["name"], override=(md["name"], asked)),
            "auto_policy_yaml": "", "ready": bool(k and k["ready"]), "builder": True}


def _fixed_entry(name: str, f: dict, rec: dict | None, k: dict | None) -> dict:
    server, md = f["server"], (rec or {}).get("metadata") or {}
    return {"name": name, "description": f["description"], "prompt": f["system"], "skills": [],
            "mcp": [{"id": server, "tools": f["tools"]}],
            "version": md.get("tag") or "latest", "updated": md.get("updatedAt"),
            "yaml": _yaml(name, f["description"], [server], [], f["system"], [f"{server}/{t}" for t in f["tools"]]),
            "applied": bool(k), "apply_error": None if k else f"Not on kagent: run ./{f['deploy']}",
            # Deployed by its own script, granted in yaml/mcp-mesh/grants.json: nothing to approve here.
            "mcp_auto": [server], "mcp_restricted": [], "admin_approved": True,
            "identity": _identity(name), "granted_by": "yaml/mcp-mesh/grants.json (scripts/92-mcp-lockdown.sh)",
             "policy_yaml": "", "policy_preview": "", "auto_policy_yaml": _policies_for(name, ns=None),
            "ready": bool(k and k["ready"]), "builder": False, "title": f["title"], "deploy": f["deploy"]}


def list_contract(include_bank=True) -> dict:
    try:
        recs = _get("agents")
    except Exception as e:  # noqa: BLE001
        return {"agents": [], "error": str(e)}
    try:
        ks = {}
        for a in _kagent_list():
            md = (a.get("agent") or {}).get("metadata") or {}
            # AR Deployments name the kagent Agent <agent>-latest-...; agents applied directly
            # (the SDLC pair) carry the agent's own name. The own name wins.
            if md.get("namespace") == AR_NS:
                key = md.get("name", "").split("-latest-")[0]
                if key not in ks or "-latest-" not in md["name"]:
                    ks[key] = {"name": md["name"], "ready": bool(a.get("deploymentReady")),
                               "accepted": bool(a.get("accepted"))}
    except Exception:  # noqa: BLE001
        ks = {}
    by_name = {r["metadata"]["name"]: r for r in recs}
    built = [_contract_entry(r, ks.get(r["metadata"]["name"])) for r in recs
             if ((r["metadata"].get("labels") or {}).get(BUILDER_LABEL) == "google")]
    built.sort(key=lambda a: a.get("updated") or "", reverse=True)
    bank = [_fixed_entry(n, f, by_name.get(n), ks.get(n)) for n, f in FIXED.items()] if include_bank else []
    return {"agents": bank + built}


def create_contract(spec: dict) -> dict:
    name = (spec.get("name") or "").strip().lower()
    if name in FIXED:
        return {"ok": False, "error": f"{name} is one of the bank's own agents. Build a new one instead."}
    tools = [f"{m.get('id')}/{t}" for m in spec.get("mcp") or [] for t in m.get("tools") or []]
    try:
        exists = any(a["metadata"]["name"] == name for a in _builder_records())
    except Exception as e:  # noqa: BLE001
        return {"ok": False, "error": str(e)}
    r = deploy({"name": name, "system": spec.get("prompt"), "skills": spec.get("skills") or [], "tools": tools,
                "description": spec.get("description"), "edit": exists})
    if not r.get("ok"):
        return r
    return {"ok": True, "agent": {"name": name}, "waiting": r.get("waiting")}


def preview(spec: dict) -> dict:
    servers = sorted({m.get("id") for m in spec.get("mcp") or [] if m.get("tools")})
    tools = [f"{m.get('id')}/{t}" for m in spec.get("mcp") or [] for t in m.get("tools") or []]
    return {"yaml": _yaml(spec.get("name") or "my-agent", spec.get("description"), servers, spec.get("skills") or [],
                          spec.get("prompt") or "", tools)}


def status_contract(name: str) -> dict:
    # AgentRegistry creates the Agent asynchronously after deploy returns.
    # Reconcile here too before declaring a newly created agent ready.
    mcp_security.reconcile_agents(env=tl.google_sov._env(), names=[name])
    lst = list_contract().get("agents", [])
    a = next((x for x in lst if x["name"] == name), None)
    if not a:
        return {"steps": [], "ready": False, "urls": {"prompt": ""}, "error": f"No agent called {name}"}
    if not a.get("builder"):
        steps = [{"id": "registry", "label": "Published in AgentRegistry", "state": "done", "detail": a.get("deploy") or ""},
                 {"id": "ready", "label": "Running on kagent in Berlin", "state": "done" if a["ready"] else "wait",
                  "detail": "" if a["ready"] else "starting"}]
        return {"steps": steps, "ready": a["ready"], "agent": a, "urls": {"prompt": ""}, "logs": ""}
    st = status(name)
    s = {x["id"]: x["ok"] for x in st.get("steps", [])}
    approved = a["admin_approved"] or not a["mcp_restricted"]
    steps = [{"id": "saved", "label": "Saved in AgentRegistry", "state": "done" if s.get("registry") else "wait",
              "detail": a.get("updated") or ""},
             {"id": "pushed", "label": "Pushed to kagent", "state": "done" if s.get("pushed") else "wait", "detail": ""},
             {"id": "ready", "label": "Pod ready on GKE in Berlin", "state": "done" if s.get("ready") else "wait",
              "detail": "" if s.get("ready") else (st.get("ar_status") or "")},
             {"id": "approved", "label": "MCP tools allowed by a platform admin",
              "state": "done" if approved else "wait",
              "detail": "no tools asked for" if not a["mcp_restricted"] else
                        ("" if approved else "waiting on a platform admin at /google/approvals")}]
    logs = "\n".join(f"{c['type']}={c['status']}: {c.get('message') or ''}" for c in st.get("conditions") or [])
    return {"steps": steps, "ready": bool(st.get("ready")), "agent": a, "urls": {"prompt": ""},
            "logs": logs or (st.get("error") or "")}


def approve_contract(name: str, decision: str) -> dict:
    if name in FIXED:
        return {"ok": False, "error": f"{name} is deployed by ./{FIXED[name]['deploy']}: nothing to approve here."}
    r = approve(name, None, decision)
    return {"ok": bool(r.get("ok")), "error": r.get("error")}


def delete_contract(name: str) -> dict:
    if name in FIXED:
        return {"ok": False, "error": f"{name} is one of the bank's own agents and stays."}
    return delete(name)
