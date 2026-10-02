"""Stage the stdlib-only banking site in Berlin without a laptop Docker daemon.

Artifacts are immutable, commit-pinned source archives in ConfigMaps. Existing
Python images supply the runtime; a runtime/Dockerfile change is rejected rather
than pretending to build a new image. Promotion copies the reviewed artifact.
"""
import base64
import copy
import gzip
import hashlib
import io
import json
import subprocess
import tarfile

import google_sov

SHA = "demo.solo.io/source-sha"
TAG = "demo.solo.io/artifact-tag"
BUNDLE = "demo.solo.io/source-bundle"
VOLUMES = {"site-snapshot", "site-source-bundle"}
DOCKERFILE = """FROM python:3.12-alpine
ARG GIT_SHA=dev
ENV GIT_SHA=${GIT_SHA} PYTHONUNBUFFERED=1
WORKDIR /app
COPY server.py config.json /app/
COPY static /app/static
COPY site /app/site
EXPOSE 8080
USER 65534
CMD ["python3", "/app/server.py"]"""


def kube(*args, data=None):
    result = subprocess.run(["kubectl", *args], env=google_sov._env(), input=data,
                            capture_output=True, text=True, timeout=210)
    if result.returncode:
        raise RuntimeError(result.stderr.strip()[:600])
    return result.stdout


def deployment(ns):
    return json.loads(kube("-n", ns, "get", "deploy", "payments", "-o", "json"))


def artifact_tag(ns):
    return deployment(ns)["metadata"].get("annotations", {}).get(TAG)


def pack(archive):
    files = {}
    with tarfile.open(fileobj=io.BytesIO(archive), mode="r:gz") as src:
        for member in src.getmembers():
            parts = member.name.split("/")[1:]
            if not parts or member.isdir():
                continue
            if member.issym() or member.islnk() or not member.isfile() or ".." in parts:
                raise ValueError("Unsupported archive entry")
            name = "/".join(parts)
            if name in {"server.py", "config.json", "Dockerfile"} or name.startswith(("site/", "static/")):
                if member.size > 2_000_000:
                    raise ValueError("A site file exceeds the snapshot limit")
                files[name] = src.extractfile(member).read()
    if files.pop("Dockerfile", b"").decode().strip() != DOCKERFILE:
        raise ValueError("Runtime/Dockerfile changes require a new image build; this hosted workflow stages the existing Python website runtime")
    if not {"server.py", "config.json", "site/index.html"} <= files.keys():
        raise ValueError("Missing required website files")
    if sum(map(len, files.values())) > 8_000_000:
        raise ValueError("Site exceeds the snapshot limit")
    output = io.BytesIO()
    with tarfile.open(fileobj=output, mode="w") as dest:
        for name, content in sorted(files.items()):
            item = tarfile.TarInfo(name)
            item.size, item.mode = len(content), 0o644
            dest.addfile(item, io.BytesIO(content))
    compressed = gzip.compress(output.getvalue(), mtime=0)
    if len(compressed) > 700_000:
        raise ValueError("Compressed website exceeds the ConfigMap artifact limit")
    return compressed


def ensure_bundle(ns, name, data, sha):
    digest = hashlib.sha256(data).hexdigest()
    existing = kube("-n", ns, "get", "configmap", name, "--ignore-not-found", "-o", "json")
    if existing:
        cm = json.loads(existing)
        if cm["metadata"].get("annotations", {}).get("sha256") != digest:
            raise ValueError("Immutable artifact name collision")
        return
    cm = {"apiVersion": "v1", "kind": "ConfigMap", "immutable": True,
          "metadata": {"name": name, "namespace": ns, "labels": {"company": "trustusbank"},
                       "annotations": {SHA: sha, "sha256": digest}},
          "binaryData": {"site.tgz": base64.b64encode(data).decode()}}
    kube("create", "-f", "-", data=json.dumps(cm))


def apply_template(ns, template, annotations):
    dep = deployment(ns)
    kube("-n", ns, "patch", "deploy", "payments", "--type=json", "-p", json.dumps([
        {"op": "test", "path": "/metadata/resourceVersion", "value": dep["metadata"]["resourceVersion"]},
        {"op": "add", "path": "/metadata/annotations", "value": {**dep["metadata"].get("annotations", {}), **annotations}},
        {"op": "replace", "path": "/spec/template", "value": template}]))
    kube("-n", ns, "rollout", "status", "deploy/payments", "--timeout=180s")


def stage(repo, sha, tag, ns):
    if len(sha) != 40 or any(c not in "0123456789abcdef" for c in sha):
        raise ValueError("A full immutable Git commit SHA is required")
    proc = subprocess.run(["gh", "api", f"repos/{repo}/tarball/{sha}"], capture_output=True, timeout=90)
    if proc.returncode:
        raise RuntimeError("Cannot fetch the approved repository commit")
    data = pack(proc.stdout)
    name = "payments-src-" + sha[:20]
    ensure_bundle(ns, name, data, sha)
    template = copy.deepcopy(deployment(ns)["spec"]["template"])
    spec = template["spec"]
    server = spec["containers"][0]
    spec.setdefault("securityContext", {})["fsGroup"] = 65534
    spec["volumes"] = [v for v in spec.get("volumes", []) if v["name"] not in VOLUMES] + [
        {"name": "site-snapshot", "emptyDir": {}},
        {"name": "site-source-bundle", "configMap": {"name": name}}]
    spec["initContainers"] = [c for c in spec.get("initContainers", []) if c["name"] != "unpack-site"] + [{
        "name": "unpack-site", "image": server["image"],
        "command": ["python3", "-c", "import tarfile; tarfile.open('/bundle/site.tgz').extractall('/source',filter='data')"],
        "volumeMounts": [{"name": "site-snapshot", "mountPath": "/source"}, {"name": "site-source-bundle", "mountPath": "/bundle", "readOnly": True}],
        "resources": {"requests": {"cpu": "50m", "memory": "64Mi", "ephemeral-storage": "64Mi"}},
        "securityContext": {"runAsUser": 65534, "allowPrivilegeEscalation": False}}]
    server["command"] = ["python3", "/srv-snapshot/server.py"]
    server["volumeMounts"] = [v for v in server.get("volumeMounts", []) if v["name"] != "site-snapshot"] + [
        {"name": "site-snapshot", "mountPath": "/srv-snapshot", "readOnly": True}]
    server["env"] = [v for v in server.get("env", []) if v["name"] != "GIT_SHA"] + [{"name": "GIT_SHA", "value": sha}]
    template.setdefault("metadata", {}).setdefault("annotations", {}).update({SHA: sha, TAG: tag, BUNDLE: name})
    apply_template(ns, template, {SHA: sha, TAG: tag, BUNDLE: name})


def copy_environment(source, target, app_env):
    dep = deployment(source)
    annotations = dep["metadata"].get("annotations", {})
    name = annotations.get(BUNDLE)
    if name:
        cm = json.loads(kube("-n", source, "get", "configmap", name, "-o", "json"))
        ensure_bundle(target, name, base64.b64decode(cm["binaryData"]["site.tgz"]), annotations[SHA])
    template = copy.deepcopy(dep["spec"]["template"])
    server = template["spec"]["containers"][0]
    server["env"] = [v for v in server.get("env", []) if v["name"] != "APP_ENV"] + [{"name": "APP_ENV", "value": app_env}]
    apply_template(target, template, {k: annotations.get(k, "") for k in (SHA, TAG, BUNDLE)})


def roll_image(ns, image):
    template = copy.deepcopy(deployment(ns)["spec"]["template"])
    spec = template["spec"]
    server = spec["containers"][0]
    server["image"] = image
    server.pop("command", None)
    server["env"] = [v for v in server.get("env", []) if v["name"] != "GIT_SHA"]
    server["volumeMounts"] = [v for v in server.get("volumeMounts", []) if v["name"] not in VOLUMES]
    spec["volumes"] = [v for v in spec.get("volumes", []) if v["name"] not in VOLUMES]
    spec["initContainers"] = [v for v in spec.get("initContainers", []) if v["name"] != "unpack-site"]
    for key in (SHA, TAG, BUNDLE):
        template.get("metadata", {}).get("annotations", {}).pop(key, None)
    apply_template(ns, template, {k: "" for k in (SHA, TAG, BUNDLE)})
