#!/usr/bin/env python3
"""Reconcile MCP JWTs, agent waypoint enrollment and legacy endpoint migration.

Explicit kubeconfig/context required. No credentials are written to the repo.
The issuer and PUBLIC JWKS come from this cluster. Re-run after signing-key
rotation, agent creation, or a cluster rebuild. Console deploy/approval calls
reconcile_agents so newly created agents get the same workload identity.
"""
from __future__ import annotations

import argparse
import copy
import hashlib
import json
import os
import subprocess
from pathlib import Path
from urllib.parse import urlsplit

import mcp_policies

LAB = Path(__file__).resolve().parent.parent
AUDIENCE = "trustusbank-mcp"
TOKEN_PATH = "/var/run/secrets/mcp/token"
ADAPTER_PATH = "/opt/mcp-identity"


def kubectl(*args, env=None, data=None):
    env = env or os.environ
    if not env.get("KUBECONFIG"):
        raise RuntimeError("Set KUBECONFIG to the isolated Berlin kubeconfig")
    ctx = ["--context", env["KUBE_CONTEXT"]] if env.get("KUBE_CONTEXT") else []
    r = subprocess.run(["kubectl", *ctx, *args], env=env, input=data,
                       text=True, capture_output=True, timeout=120)
    if r.returncode:
        raise RuntimeError(r.stderr.strip())
    return r.stdout


def get(kind, namespace=None, env=None):
    return json.loads(kubectl(*(["-n", namespace] if namespace else []), "get", kind,
                              *([] if namespace else ["-A"]), "-o", "json", env=env))["items"]


def apply(doc, env=None):
    return kubectl("apply", "-f", "-", env=env, data=json.dumps(doc)).strip()


def patch(kind, ns, name, body, env=None):
    return kubectl("-n", ns, "patch", kind, name, "--type=merge", "-p", json.dumps(body), env=env)


def document(kind, name, ns, spec, api="enterpriseagentgateway.solo.io/v1alpha1"):
    return {"apiVersion": api, "kind": kind,
            "metadata": {"name": name, "namespace": ns, "labels": {"company": "trustusbank"}}, "spec": spec}


def servers():
    primary = [{"name": n, "namespace": "mcp", "port": 3000, "path": s["path"],
                "backend": s["backend"], "route": n + "-mesh", "waypoint": "mcp-waypoint",
                "selector": {"app": n}} for n, s in mcp_policies.load()["services"].items()]
    return primary + [
        {"name": "everything-server", "namespace": "agents", "port": 3000, "path": "/mcp",
         "backend": "everything-server", "route": "mcpserver-everything-server-waypoint",
         "waypoint": "mcpserver-everything-server-waypoint",
         "selector": {"app.kubernetes.io/name": "everything-server"}},
        {"name": "kagent-tools", "namespace": "kagent", "port": 8084, "path": "/mcp",
         "backend": "kagent-tools-mcp", "route": "kagent-tools-mesh", "waypoint": "mcp-waypoint",
         "selector": {"app.kubernetes.io/name": "kagent-tools"}},
    ]


def url(s):
    return f'http://{s["name"]}.{s["namespace"]}.svc.cluster.local:{s["port"]}{s["path"]}'


def migrate_url(value):
    parsed = urlsplit(value)
    if parsed.hostname == "mcp.agentic.eu0.internal":
        tail = parsed.path.rstrip("/").split("/")[-1]
        name = "everything-server" if tail == "mcp" else (
            "bank-" + tail if tail in {"payments", "compliance", "credit", "gdpr"} else tail)
        for s in servers():
            if s["namespace"] == "mcp" and s["name"] == name:
                return url(s)
        raise ValueError(f"Unknown legacy MCP endpoint: {value}")
    return value


def projected_volume():
    return {"name": "mcp-workload-token", "projected": {"sources": [{"serviceAccountToken": {
        "audience": AUDIENCE, "expirationSeconds": 3600, "path": "token"}}]}}


def identity_deployment(dep):
    """Preserve caller fields, add the adapter and a rotating workload token."""
    dep = copy.deepcopy(dep)
    env = {e["name"]: e for e in dep.get("env", [])}
    # BYO images set PYTHONPATH=/app in the image, invisible in the Agent CR.
    # Preserve that default when adding an explicit Kubernetes env override.
    old_path = env.get("PYTHONPATH", {}).get("value", "/app")
    paths = [p for p in old_path.split(":") if p and p != ADAPTER_PATH]
    if "/app" not in paths:
        paths.append("/app")
    for key, value in {
        "PYTHONPATH": ":".join([ADAPTER_PATH, *paths]),
        "MCP_WORKLOAD_TOKEN_FILE": TOKEN_PATH,
        "MCP_WORKLOAD_ORIGINS": json.dumps([url(s) for s in servers()] + [
            "http://everything-server.agents:3000/mcp", "http://kagent-tools.kagent:8084/mcp"]),
    }.items():
        env[key] = {"name": key, "value": value}
    if "MCP_SERVERS_CONFIG" in env:
        config = json.loads(env["MCP_SERVERS_CONFIG"].get("value") or "[]")
        for server in config:
            if server.get("url"):
                server["url"] = migrate_url(server["url"])
        env["MCP_SERVERS_CONFIG"]["value"] = json.dumps(config)
    dep["env"] = list(env.values())
    volumes = {v["name"]: v for v in dep.get("volumes", [])}
    volumes["mcp-workload-token"] = projected_volume()
    volumes["mcp-identity-adapter"] = {"name": "mcp-identity-adapter", "configMap": {"name": "mcp-identity-adapter"}}
    dep["volumes"] = list(volumes.values())
    mounts = {v["name"]: v for v in dep.get("volumeMounts", [])}
    for name, path in [("mcp-workload-token", "/var/run/secrets/mcp"), ("mcp-identity-adapter", ADAPTER_PATH)]:
        mounts[name] = {"name": name, "mountPath": path, "readOnly": True}
    dep["volumeMounts"] = list(mounts.values())
    dep.setdefault("labels", {})["company"] = "trustusbank"
    dep.setdefault("annotations", {})["mcp-lockdown/adapter-sha256"] = hashlib.sha256(
        (LAB / "yaml/mcp-mesh/sitecustomize.py").read_bytes()).hexdigest()
    return dep


def reconcile_agents(env=None, names=None):
    agents = get("agents.kagent.dev", env=env)
    if names is not None:
        agents = [a for a in agents if a["metadata"]["name"] in names or
                  a["metadata"]["name"].split("-latest-")[0] in names]
    for ns in sorted({a["metadata"]["namespace"] for a in agents}):
        kubectl("label", "ns", ns, "istio.io/dataplane-mode=ambient", "--overwrite", env=env)
        apply({"apiVersion": "v1", "kind": "ConfigMap", "metadata": {
            "name": "mcp-identity-adapter", "namespace": ns},
            "data": {"sitecustomize.py": (LAB / "yaml/mcp-mesh/sitecustomize.py").read_text()}}, env)
    for a in agents:
        ns, name = a["metadata"]["namespace"], a["metadata"]["name"]
        field = "byo" if a["spec"]["type"] == "BYO" else "declarative"
        original = a["spec"][field].get("deployment", {})
        desired = identity_deployment(original)
        body = {"metadata": {"labels": {"kagent.solo.io/waypoint": "true", "company": "trustusbank"}},
                "spec": {field: {"deployment": desired}}}
        if original != desired or a["metadata"].get("labels", {}).get("kagent.solo.io/waypoint") != "true":
            patch("agent", ns, name, body, env)
            print(f"secured agent {ns}/{name}")
        # The generated ALLOW policy includes a controller bypass exception.
        # Require even that caller to use the Agent Service and its waypoint.
        policy = document("AuthorizationPolicy", name + "-waypoint-only", ns, {
            "selector": {"matchLabels": {"app": "kagent", "kagent": name}}, "action": "DENY",
            "rules": [{"from": [{"source": {"notPrincipals": [
                f"cluster.local/ns/{ns}/sa/agent-{name}-waypoint"]}}]}]}, "security.istio.io/v1")
        policy["metadata"]["ownerReferences"] = [{"apiVersion": a["apiVersion"], "kind": "Agent",
            "name": name, "uid": a["metadata"]["uid"]}]
        apply(policy, env)
    for r in get("remotemcpservers.kagent.dev", env=env):
        old = r["spec"]["url"]
        new = migrate_url(old)
        spec_patch = {"url": new} if old != new else {}
        known_hosts = {urlsplit(url(s)).hostname for s in servers()} | {f'{s["name"]}.{s["namespace"]}' for s in servers()}
        if urlsplit(new).hostname in known_hosts:
            headers = [h for h in r["spec"].get("headersFrom", []) if h["name"].lower() != "authorization"]
            headers.append({"name": "Authorization", "valueFrom": {
                "type": "Secret", "name": "mcp-discovery-identity", "key": "Authorization"}})
            if headers != r["spec"].get("headersFrom"):
                spec_patch["headersFrom"] = headers
        if spec_patch:
            patch("remotemcpserver", r["metadata"]["namespace"], r["metadata"]["name"], {"spec": spec_patch}, env)


def jwt_policy(s, issuer, jwks):
    # Require is conjunctive with other Allow policies. A token stolen from a
    # different ServiceAccount cannot be used under the caller's mesh identity.
    return document("EnterpriseAgentgatewayPolicy", s["name"] + "-strict-jwt", s["namespace"], {
        "targetRefs": [{"group": "gateway.networking.k8s.io", "kind": "HTTPRoute", "name": s["route"]}],
        "traffic": {
            "jwtAuthentication": {"mode": "Strict", "providers": [{"issuer": issuer,
                "audiences": [AUDIENCE], "jwks": {"inline": json.dumps(jwks)},
                "validation": {"requiredClaims": ["sub", "exp"]}}]},
            "authorization": {"action": "Require", "policy": {"matchExpressions": [
                'jwt.sub == "system:serviceaccount:" + source.identity.namespace + ":" + source.identity.serviceAccount']}}
        }})


def reconcile_servers(env=None):
    issuer = json.loads(kubectl("get", "--raw", "/.well-known/openid-configuration", env=env))["issuer"]
    jwks = json.loads(kubectl("get", "--raw", "/openid/v1/jwks", env=env))
    deployed = {(s["metadata"]["namespace"], s["metadata"]["name"]): s for s in get("service", env=env)}
    for s in servers():
        ns, name = s["namespace"], s["name"]
        if (ns, name) not in deployed:
            print(f"MCP service {ns}/{name} not deployed; no route to secure yet")
            continue
        kubectl("label", "ns", ns, "istio.io/dataplane-mode=ambient", "--overwrite", env=env)
        # Static DNS targets are plain HTTP and lose workload mTLS on the
        # waypoint -> MCP hop. Service selectors resolve ambient endpoints and
        # preserve the waypoint's SPIFFE identity through HBONE.
        svc = deployed[(ns, name)]
        ports = copy.deepcopy(svc["spec"]["ports"])
        for port in ports:
            if port["port"] == s["port"]:
                port["appProtocol"] = "kgateway.dev/mcp"
        patch("service", ns, name, {"metadata": {"labels": {"mcp-lockdown/service": name}},
                                    "spec": {"ports": ports}}, env)
        if name == "kagent-tools":
            apply(document("Gateway", s["waypoint"], ns, {"gatewayClassName": "enterprise-agentgateway-waypoint",
                "listeners": [{"name": "mesh", "port": 15008, "protocol": "HBONE"}]}, "gateway.networking.k8s.io/v1"), env)
            apply(document("AgentgatewayBackend", s["backend"], ns, {"mcp": {"targets": [{"name": name,
                "static": {"host": f"{name}.{ns}.svc.cluster.local", "port": s["port"], "path": s["path"]}}]}},
                "agentgateway.dev/v1alpha1"), env)
            apply(document("HTTPRoute", s["route"], ns, {"parentRefs": [{"group": "", "kind": "Service", "name": name}],
                "rules": [{"backendRefs": [{"group": "agentgateway.dev", "kind": "AgentgatewayBackend", "name": s["backend"]}]}]},
                "gateway.networking.k8s.io/v1"), env)
            apply(document("EnterpriseAgentgatewayPolicy", "kagent-tools-default-deny", ns,
                           mcp_policies._allow([s["backend"]], ["false"])), env)
        if ns != "agents":  # The kmcp controller owns this backend already.
            patch("agentgatewaybackend", ns, s["backend"], {"spec": {"mcp": {"targets": [{
                "name": name, "selector": {"services": {"matchLabels": {"mcp-lockdown/service": name}}}}]}}}, env)
        apply(document("EnterpriseAgentgatewayPolicy", name + "-discovery-only", ns,
              mcp_policies._allow([s["backend"]], [mcp_policies.clause("kagent", "kagent-controller", None)])), env)
        if ns == "agents":
            grant = mcp_policies._doc(mcp_policies._meta("waypoint-calc--everything-server", "grants",
                agent="waypoint-calc", **{"agent-namespace": ns}, backend=s["backend"]),
                mcp_policies._allow([s["backend"]], [mcp_policies.clause(ns, "waypoint-calc", ["sum"])]))
            grant["metadata"]["namespace"] = ns
            apply(grant, env)
            # The old AccessPolicy translator adds an unrestricted controller
            # exception. A conjunctive Require keeps discovery list-only.
            restriction = mcp_policies._allow([s["backend"]], [
                '!(source.identity.namespace == "kagent" && source.identity.serviceAccount == "kagent-controller") || mcp.methodName == "tools/list"'])
            restriction["backend"]["mcp"]["authorization"]["action"] = "Require"
            apply(document("EnterpriseAgentgatewayPolicy", "controller-discovery-only", ns, restriction), env)
        kubectl("-n", ns, "label", "service", name, f'istio.io/use-waypoint={s["waypoint"]}', "--overwrite", env=env)
        print(apply(jwt_policy(s, issuer, jwks), env))
        # DENY wins over any old additive ALLOW policy, including generated
        # AccessPolicy exceptions. Pod-IP access must not bypass the waypoint.
        print(apply(document("AuthorizationPolicy", name + "-waypoint-only", ns, {
            "selector": {"matchLabels": s["selector"]}, "action": "DENY", "rules": [{"from": [{"source": {
                "notPrincipals": [f'cluster.local/ns/{ns}/sa/{s["waypoint"]}']}}]}]}, "security.istio.io/v1"), env))


def reconcile_discovery(env=None):
    image = next(d for d in get("deployment", "mcp", env) if d["metadata"]["name"] == "mcp-catalog")[
        "spec"]["template"]["spec"]["containers"][0]["image"]
    for ns in ("kagent", "agents", "agentregistry-system"):
        if not any(s["metadata"]["name"] == "mcp-discovery-identity" for s in get("secret", ns, env)):
            apply({"apiVersion": "v1", "kind": "Secret", "metadata": {
                "name": "mcp-discovery-identity", "namespace": ns}, "type": "Opaque"}, env)
        apply({"apiVersion": "rbac.authorization.k8s.io/v1", "kind": "Role", "metadata": {
            "name": "mcp-discovery-refresh", "namespace": ns}, "rules": [{"apiGroups": [""],
            "resources": ["secrets"], "resourceNames": ["mcp-discovery-identity"], "verbs": ["patch"]}]}, env)
        apply({"apiVersion": "rbac.authorization.k8s.io/v1", "kind": "RoleBinding", "metadata": {
            "name": "mcp-discovery-refresh", "namespace": ns}, "roleRef": {"apiGroup": "rbac.authorization.k8s.io",
            "kind": "Role", "name": "mcp-discovery-refresh"}, "subjects": [{"kind": "ServiceAccount",
            "name": "kagent-controller", "namespace": "kagent"}]}, env)
    apply({"apiVersion": "v1", "kind": "ConfigMap", "metadata": {"name": "mcp-discovery-refresh", "namespace": "kagent"},
           "data": {"refresh.py": (LAB / "yaml/mcp-mesh/discovery_tokens.py").read_text()}}, env)
    apply(document("Deployment", "mcp-discovery-refresh", "kagent", {"replicas": 1,
        "selector": {"matchLabels": {"app": "mcp-discovery-refresh"}}, "template": {
            "metadata": {"labels": {"app": "mcp-discovery-refresh", "company": "trustusbank"}}, "spec": {
                "serviceAccountName": "kagent-controller",
                "volumes": [projected_volume(), {"name": "script", "configMap": {"name": "mcp-discovery-refresh"}}],
                "containers": [{"name": "refresh", "image": image, "command": ["python3", "/script/refresh.py"],
                    "resources": {"requests": {"cpu": "50m", "memory": "64Mi"}, "limits": {"memory": "128Mi"}},
                    "volumeMounts": [{"name": "script", "mountPath": "/script", "readOnly": True},
                                     {"name": "mcp-workload-token", "mountPath": "/var/run/secrets/mcp", "readOnly": True}],
                    "readinessProbe": {"exec": {"command": ["python3", "-c",
                        "import os,time; assert time.time()-os.stat('/tmp/identity-ready').st_mtime < 150"]},
                        "periodSeconds": 10}}]}}}, "apps/v1"), env)
    kubectl("-n", "kagent", "rollout", "status", "deploy/mcp-discovery-refresh", "--timeout=90s", env=env)
    # The native MCPServer still owns its server and waypoint; use a Remote ref
    # for its client so kagent's discovery request can carry the controller JWT.
    apply(document("RemoteMCPServer", "waypoint-tools", "agents", {
        "description": "Authenticated discovery of the waypoint calculator tools", "protocol": "STREAMABLE_HTTP",
        "url": "http://everything-server.agents.svc.cluster.local:3000/mcp"}, "kagent.dev/v1alpha2"), env)
    for r in get("remotemcpserver", env=env):
        if any(urlsplit(r["spec"]["url"]).hostname in {urlsplit(url(s)).hostname,
                f'{s["name"]}.{s["namespace"]}'} for s in servers()):
            headers = [h for h in r["spec"].get("headersFrom", []) if h["name"].lower() != "authorization"]
            headers.append({"name": "Authorization", "valueFrom": {
                "type": "Secret", "name": "mcp-discovery-identity", "key": "Authorization"}})
            patch("remotemcpserver", r["metadata"]["namespace"], r["metadata"]["name"], {"spec": {"headersFrom": headers}}, env)
    patch("agent", "agents", "waypoint-calc", {"spec": {"declarative": {"tools": [{"type": "McpServer",
        "mcpServer": {"apiGroup": "kagent.dev", "kind": "RemoteMCPServer", "name": "waypoint-tools",
                      "namespace": "agents", "toolNames": ["sum"]}}]}}}, env)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("phase", choices=["agents", "servers", "discovery"])
    args = ap.parse_args()
    {"agents": reconcile_agents, "servers": reconcile_servers, "discovery": reconcile_discovery}[args.phase]()


if __name__ == "__main__":
    main()
