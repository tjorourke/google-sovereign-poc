#!/usr/bin/env python3
"""Extract every heredoc'd Kubernetes manifest from the deploy scripts and parse
it as YAML, with shell variables replaced by plausible dummies.

Rationale: the scripts apply these with `kubectl apply -f -`, so an indentation
or quoting mistake only shows up mid-deploy. One such bug (a quoted heredoc that
should have been unquoted) already cost a debugging cycle. This catches the rest
before they cost a run against a real cluster.
"""
import glob, os, re, sys

import yaml

DUMMIES = {
    "NS": "probe-ns", "MCP_NS": "mcp", "AGW_NS": "agentgateway-system",
    "GW": "agentgateway-proxy", "GW_SVC": "agentgateway-proxy-svc",
    "SERVER": "everything-server", "MCP_IMAGE": "reg.example/p/r/img:1",
    "ALLOW_TOOL": "sum", "BASE_DOMAIN": "agentic.eu0.internal",
    "DEFAULT_SC": "standard-rwo", "UNIVERSE_API_DOMAIN": "apis-berlin-build0.goog",
    "KEYCLOAK_IMAGE": "quay.io/keycloak/keycloak:26.3",
    "KEYCLOAK_ADMIN_PASSWORD": "admin", "ISSUER_URL": "http://keycloak.example",
    "MODEL_ID": "google/gemma-3-1b-it", "VLLM_IMAGE": "vllm/vllm-openai:v0.8.5",
    "MODEL_NS": "model", "COMPUTE_CLASS_ANN": 'cloud.google.com/compute-class: "Accelerator"',
    "GPU_ANN": 'cloud.google.com/gke-accelerator: "nvidia-h100-80gb"',
    "GPU_COUNT_ANN": 'cloud.google.com/gke-accelerator-count: "8"',
    "RESOURCES": 'requests: { cpu: "8", memory: 16Gi }',
    "EXTRA_ARGS": "--device=cpu",
}

# Heredocs that feed kubectl/arctl. Capture the delimiter so we know whether the
# shell would have expanded variables inside.
HEREDOC = re.compile(
    r"<<(?P<q>'?)(?P<delim>[A-Z]+)\1\s*\n(?P<body>.*?)\n(?P=delim)\s*$",
    re.S | re.M,
)

def subst(text):
    def repl(m):
        name = m.group(1)
        if name not in DUMMIES:
            raise KeyError(name)
        return DUMMIES[name]
    # ${VAR} and ${VAR:-default}
    text = re.sub(r"\$\{([A-Z_][A-Z0-9_]*):-[^}]*\}",
                  lambda m: DUMMIES.get(m.group(1), "dummy"), text)
    return re.sub(r"\$\{([A-Z_][A-Z0-9_]*)\}", repl, text)

errors, checked = [], 0
HERE = os.path.dirname(os.path.abspath(__file__))
for path in sorted(glob.glob(os.path.join(HERE, "*.sh"))):
    src = open(path).read()
    for m in HEREDOC.finditer(src):
        delim, body, quoted = m.group("delim"), m.group("body"), bool(m.group("q"))
        if delim not in ("YAML", "PYEOF"):
            continue
        if delim == "PYEOF":
            continue
        line_no = src[: m.start()].count("\n") + 1
        label = f"{path}:{line_no}"

        # A quoted heredoc containing ${VAR} is a bug: the shell will NOT expand
        # it and the literal reaches the cluster.
        if quoted:
            leaked = re.findall(r"\$\{[A-Z_][A-Z0-9_]*\}", body)
            if leaked:
                errors.append(f"{label}: quoted heredoc leaks unexpanded {sorted(set(leaked))}")
                continue
            text = body
        else:
            try:
                text = subst(body)
            except KeyError as e:
                errors.append(f"{label}: no dummy for variable {e}")
                continue

        # Container-side shell vars are escaped as \$ in the script; unescape so
        # the YAML parses the way kubectl would see it.
        text = text.replace("\\$", "$")

        try:
            docs = [d for d in yaml.safe_load_all(text) if d]
        except yaml.YAMLError as e:
            errors.append(f"{label}: YAML parse error: {str(e).splitlines()[0]}")
            continue

        if not docs:
            errors.append(f"{label}: heredoc produced no documents")
            continue

        for d in docs:
            checked += 1
            if not isinstance(d, dict):
                errors.append(f"{label}: document is {type(d).__name__}, not a mapping")
                continue
            for req in ("apiVersion", "kind"):
                if req not in d:
                    errors.append(f"{label}: {d.get('kind','?')} missing {req}")
            print(f"  ok  {label:52s} {d.get('kind','?'):22s} {d.get('apiVersion','?')}")

print()
print(f"{checked} manifest document(s) parsed")

# ── part 2: Autopilot admission ───────────────────────────────────────────────
# Fields Autopilot refuses. GCD additionally does not support the
# WorkloadAllowlist mechanism, so there is no way to grant any of these.
BANNED_POD = ["hostNetwork", "hostPID", "hostIPC", "hostPath"]
BANNED_CTR_SEC = ["privileged", "allowPrivilegeEscalation"]
BANNED_CAPS = {"SYS_ADMIN", "NET_ADMIN", "NET_RAW", "SYS_PTRACE"}

problems, pods = [], 0

def check_podspec(label, kind, spec):
    global pods
    pods += 1
    for f in BANNED_POD:
        if f in spec and spec[f]:
            problems.append(f"{label} [{kind}]: pod sets {f} — Autopilot rejects this")
    for v in spec.get("volumes", []) or []:
        if "hostPath" in v:
            problems.append(f"{label} [{kind}]: hostPath volume {v.get('name')} — Autopilot rejects this")
    containers = (spec.get("containers") or []) + (spec.get("initContainers") or [])
    if not containers:
        problems.append(f"{label} [{kind}]: no containers")
    for c in containers:
        name = c.get("name", "?")
        res = (c.get("resources") or {}).get("requests") or {}
        if not res.get("cpu") or not res.get("memory"):
            problems.append(
                f"{label} [{kind}] container '{name}': missing resources.requests"
                f" cpu/memory — Autopilot will rewrite or reject"
            )
        sec = c.get("securityContext") or {}
        for f in BANNED_CTR_SEC:
            if sec.get(f):
                problems.append(f"{label} [{kind}] container '{name}': securityContext.{f}=true — Autopilot rejects")
        caps = ((sec.get("capabilities") or {}).get("add") or [])
        bad = BANNED_CAPS.intersection({c.upper() for c in caps})
        if bad:
            problems.append(f"{label} [{kind}] container '{name}': capabilities {sorted(bad)} — Autopilot rejects, and GCD has no allowlist mechanism")
        if sec.get("runAsUser") == 0:
            problems.append(f"{label} [{kind}] container '{name}': runAsUser 0 — Autopilot rejects")

for path in sorted(glob.glob(os.path.join(HERE, "*.sh"))) + [os.path.join(HERE, "..", "yaml", "keycloak", "keycloak.yaml")]:
    src = open(path).read()
    blocks = []
    if path.endswith(".yaml"):
        blocks = [(1, src, False)]
    else:
        for m in HEREDOC.finditer(src):
            if m.group("delim") != "YAML":
                continue
            blocks.append((src[: m.start()].count("\n") + 1, m.group("body"), bool(m.group("q"))))
    for line_no, body, quoted in blocks:
        label = f"{path}:{line_no}"
        text = body if quoted else subst(body)
        text = text.replace("\\$", "$")
        try:
            docs = [d for d in yaml.safe_load_all(text) if isinstance(d, dict)]
        except yaml.YAMLError:
            continue
        for d in docs:
            kind = d.get("kind", "?")
            spec = d.get("spec") or {}
            if kind == "Pod":
                check_podspec(label, kind, spec)
            elif kind in ("Deployment", "StatefulSet", "DaemonSet", "Job"):
                tmpl = ((spec.get("template") or {}).get("spec")) or {}
                if tmpl:
                    check_podspec(label, kind, tmpl)

print(f"{pods} pod spec(s) checked for Autopilot admission")

all_errors = errors + problems
if all_errors:
    print(f"\n{len(all_errors)} PROBLEM(S):")
    for e in all_errors:
        print(f"  x {e}")
    sys.exit(1)
print("no banned fields; every container has cpu+memory requests")
print("\nall clean")

