#!/usr/bin/env python3
"""Package the in-repo console app, build/push in-universe, and deploy in Berlin.

The hosted source of truth is poc/2026-09-agentic-platform/console/app in THIS
repository; the laptop demo-console is untouched. Run through
97-google-console.sh so registry and isolated kubeconfig settings are loaded.
Only explicitly listed lab helper files are staged next to the app: no local
env files, kubeconfigs, credentials, notebook runners or generated state.
"""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import secrets
import shutil
import subprocess
import tempfile

LAB = Path(__file__).resolve().parents[1]
CONSOLE = LAB / "console"
NS = "trustusbank-console"
LAB_FILES = ["scripts/mcp_policies.py", "scripts/mcp_security.py", "yaml/mcp-mesh/grants.json",
             "yaml/mcp-mesh/sitecustomize.py", "yaml/mcp-mesh/discovery_tokens.py"]


def run(command, **kwargs):
    return subprocess.run(command, check=True, **kwargs)


def kube(*args, data=None):
    return run(["kubectl", *args], input=data, text=True, capture_output=True).stdout


def apply(doc):
    if doc.get("kind") != "List":
        doc.setdefault("metadata", {}).setdefault("labels", {})["company"] = "trustusbank"
    kube("apply", "-f", "-", data=json.dumps(doc))


def resource(kind, name, spec, namespace=None, api="rbac.authorization.k8s.io/v1"):
    return {"apiVersion": api, "kind": kind, "metadata": {"name": name, **({"namespace": namespace} if namespace else {})}, **spec}


def rbac():
    subject = [{"kind": "ServiceAccount", "name": "google-console", "namespace": NS}]
    def binding(name, role, namespace=None, cluster=False):
        return resource("ClusterRoleBinding" if cluster else "RoleBinding", name,
                        {"roleRef": {"apiGroup": "rbac.authorization.k8s.io", "kind": "ClusterRole", "name": role}, "subjects": subject}, namespace)
    def rules(group, resources, verbs):
        return {"apiGroups": [group], "resources": resources, "verbs": verbs}
    read = ["get", "list", "watch"]
    write = ["get", "list", "watch", "create", "update", "patch", "delete"]
    docs = [resource("ClusterRole", "google-console-discovery", {"rules": [
        rules("kagent.dev", ["agents", "remotemcpservers"], read),
        rules("", ["namespaces"], read),
        {**rules("", ["namespaces"], ["patch", "update"]), "resourceNames": ["agents", "kagent", "agentregistry-system"]}]}),
        binding("google-console-discovery", "google-console-discovery", cluster=True),
        resource("ClusterRole", "google-console-read", {"rules": [
            rules("", ["pods", "pods/log", "services", "serviceaccounts", "configmaps"], read),
            rules("apps", ["deployments", "replicasets"], read),
            rules("kagent.dev", ["agents", "remotemcpservers", "modelconfigs"], read),
            rules("agentgateway.dev", ["agentgatewaybackends", "agentgatewaypolicies"], read),
            rules("enterpriseagentgateway.solo.io", ["enterpriseagentgatewaypolicies"], read),
            rules("gateway.networking.k8s.io", ["gateways", "httproutes", "listenersets"], read)]}),
        resource("ClusterRole", "google-console-agent-management", {"rules": [
            rules("", ["configmaps"], write), rules("kagent.dev", ["agents", "remotemcpservers"], write),
            rules("security.istio.io", ["authorizationpolicies"], write)]}),
        resource("ClusterRole", "google-console-mcp-management", {"rules": [
            rules("enterpriseagentgateway.solo.io", ["enterpriseagentgatewaypolicies"], write),
            rules("", ["pods/exec"], ["create"])]}),
        resource("ClusterRole", "google-console-site-management", {"rules": [
            rules("apps", ["deployments"], ["get", "list", "watch", "patch", "update"]),
            rules("", ["configmaps"], ["get", "create", "list"])]})]
    # No "agents" namespace: the everything-server toy agents were removed from the
    # cluster and repo (DEMO-READINESS), and a binding to a missing namespace fails.
    for ns in ("agentgateway-system", "model", "mcp", "agentregistry-system", "kagent", "trustusbank-staging", "trustusbank-prod"):
        docs.append(binding("google-console-read", "google-console-read", ns))
    for ns in ("agentregistry-system", "kagent"):
        docs.append(binding("google-console-manage-agents", "google-console-agent-management", ns))
    docs.append(binding("google-console-manage-mcp", "google-console-mcp-management", "mcp"))
    for ns in ("trustusbank-staging", "trustusbank-prod"):
        docs.append(binding("google-console-manage-site", "google-console-site-management", ns))
    return docs


def package(context):
    """Stage the checked-in console app and the lab helpers it imports."""
    shutil.copytree(CONSOLE / "app", context / "app",
                    ignore=shutil.ignore_patterns("__pycache__", ".gstack", "*.pyc"))
    for relative in LAB_FILES:
        target = context / "google-sov/poc/2026-09-agentic-platform" / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(LAB / relative, target)
    shutil.copyfile(CONSOLE / "Dockerfile", context / "Dockerfile")
    digest = hashlib.sha256()
    for path in sorted(context.rglob("*")):
        if path.is_file():
            digest.update(str(path.relative_to(context)).encode())
            digest.update(path.read_bytes())
    return digest.hexdigest()[:16]


def secrets_for_console():
    existing = kube("-n", NS, "get", "secret", "console-access", "--ignore-not-found", "-o", "json")
    if existing:
        access = json.loads(base64.b64decode(json.loads(existing)["data"]["access.json"]))
    else:
        access = {}
    # The demo's shared sign-in. Override with CONSOLE_USER/CONSOLE_PASSWORD;
    # a session key is generated once and then preserved across redeploys.
    access["username"] = os.environ.get("CONSOLE_USER", "solo")
    access["password"] = os.environ.get("CONSOLE_PASSWORD", "S010g00g13!")
    access.setdefault("session_key", secrets.token_hex(32))
    apply({"apiVersion": "v1", "kind": "Secret", "metadata": {"name": "console-access", "namespace": NS},
           "stringData": {"access.json": json.dumps(access)}})
    local = LAB / "deploy/console-access.json"
    fd = os.open(local, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as output:
        json.dump({k: v for k, v in access.items() if k != "password"}, output)
    github = json.loads(kube("-n", "mcp", "get", "secret", "tub-sdlc-github", "-o", "json"))["data"]["GITHUB_TOKEN"]
    apply({"apiVersion": "v1", "kind": "Secret", "metadata": {"name": "console-integrations", "namespace": NS},
           "data": {"GITHUB_TOKEN": github}, "stringData": {
               "TUB_USER_PASSWORD": os.environ.get("TRUSTUSBANK_USER_PASSWORD", "password"),
               "TUB_KEYCLOAK_ADMIN_PASSWORD": os.environ.get("KEYCLOAK_ADMIN_PASSWORD", "admin"),
               "GB_AR_PASSWORD": os.environ.get("AR_ADMIN_PASSWORD", "password")}})
    print(f"Console login saved locally (0600): {local}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--image", help="Deploy an already built image instead of building")
    args = parser.parse_args()
    if args.image:
        image = args.image
    else:
        prefix = os.environ["AR_PREFIX"]
        with tempfile.TemporaryDirectory(prefix="google-console-", dir=LAB / "deploy") as tmp:
            parent = Path(tmp)
            context = parent / "context"
            context.mkdir()
            digest = package(context)
            image = f"{prefix}/trustusbank-console:{digest}"
            auth = parent / "auth"
            auth.mkdir()
            env = {**os.environ, "DOCKER_CONFIG": str(auth)}
            token = run(["gcloud", "auth", "print-access-token"], text=True, capture_output=True).stdout.strip()
            run(["docker", "login", "-u", "oauth2accesstoken", "--password-stdin", prefix.split("/")[0]],
                input=token, text=True, capture_output=True, env=env)
            # buildx with the DEFAULT docker config: an empty isolated one has no
            # builder instance and its driver negotiation fails. Only the registry
            # login/push use the isolated config, so ~/.docker is never mutated.
            run(["docker", "buildx", "build", "--platform", "linux/amd64", "--load", "-t", image, str(context)])
            run(["docker", "push", image], env=env)
            print(f"Built and pushed {image}")
    apply(resource("Namespace", NS, {}, api="v1"))
    secrets_for_console()
    for doc in rbac():
        apply(doc)
    # Rendering is limited to non-secret image/hostname values.
    deploy = (LAB / "console/deployment.yaml").read_text().replace("__CONSOLE_IMAGE__", image)
    kube("apply", "-f", "-", data=deploy)
    kube("-n", NS, "rollout", "status", "deployment/google-console", "--timeout=600s")
    ingress = (LAB / "console/ingress.yaml").read_text().replace("__BASE_DOMAIN__", os.environ.get("BASE_DOMAIN", "agentic.eu0.internal"))
    kube("apply", "-f", "-", data=ingress)
    print(f"Google console: https://agw.{os.environ.get('BASE_DOMAIN', 'agentic.eu0.internal')}/google")
    print(f"Image: {image}")


if __name__ == "__main__":
    main()
