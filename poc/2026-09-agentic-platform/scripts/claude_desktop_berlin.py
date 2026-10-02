#!/usr/bin/env python3
"""Claude Desktop's Berlin gateway profile and refreshing Keycloak credential helper.

Uses the same managed settings as the EKS lab. `on` backs up the Desktop profile
and saved deployment mode; `off` restores them. Does not change Claude Code.
Run as the laptop user, not with sudo; only installing the system plist uses sudo.
"""
import argparse
import base64
import json
import os
from pathlib import Path
import plistlib
import shlex
import ssl
import subprocess
import sys
import urllib.request
import urllib.parse

LAB = Path(__file__).resolve().parents[1]
STATE = Path.home() / ".config/trustusbank-desktop"
MANAGED = Path("/Library/Managed Preferences/com.anthropic.claudefordesktop.plist")
DESKTOP = Path.home() / "Library/Application Support/Claude/claude_desktop_config.json"
BASE = os.environ.get("TUB_DESKTOP_URL", "https://agw.agentic.eu0.internal/trustusbank")


def get_token():
    # Matches the local demonstration account configured by 88-identity.sh.
    form = urllib.parse.urlencode({"grant_type": "password", "client_id": "trustusbank-console",
        "username": os.environ.get("TUB_USER", "bob"), "password": os.environ.get("TUB_USER_PASSWORD", "password"),
        "scope": "openid"}).encode()
    url = os.environ.get("TUB_KEYCLOAK", "https://keycloak.agentic.eu0.internal").rstrip("/")
    with urllib.request.urlopen(url + "/realms/agentregistry/protocol/openid-connect/token", form, timeout=20,
                                context=tls_context() if url.startswith("https:") else None) as response:
        return json.load(response)["access_token"]


def ca_pem():
    if os.environ.get("TUB_CA_FILE"):
        return Path(os.environ["TUB_CA_FILE"]).read_text()
    # Read only the public CA certificate, never the gateway's private key.
    config = os.environ.get("GCD_KUBECONFIG", str(LAB / "deploy/console.kubeconfig"))
    result = subprocess.run(["kubectl", "--kubeconfig", config, "-n", "agentgateway-system", "get", "secret",
                             "agentic-edge-tls", "-o", r"jsonpath={.data.ca\.crt}"], capture_output=True, text=True, check=True)
    return base64.b64decode(result.stdout).decode()


def tls_context():
    context = ssl.create_default_context()
    context.load_verify_locations(cadata=ca_pem())
    return context


def request(path, body, token=None):
    req = urllib.request.Request(BASE.rstrip("/") + path, data=json.dumps(body).encode(), headers={
        "Content-Type": "application/json", "Authorization": "Bearer " + (token or get_token()),
        "anthropic-version": "2023-06-01"})
    return urllib.request.urlopen(req, timeout=300, context=tls_context() if BASE.startswith("https:") else None)


def profile():
    return {"inferenceProvider": "gateway", "inferenceGatewayBaseUrl": BASE,
            "inferenceGatewayAuthScheme": "bearer", "inferenceCredentialKind": "helper-script",
            "inferenceCredentialHelper": str(STATE / "credential.sh"), "inferenceCredentialHelperTtlSec": 60,
            "inferenceModels": json.dumps(["gemma-3-27b-it"]), "modelDiscoveryEnabled": "false",
            "disableDeploymentModeChooser": True, "disabledBuiltinTools": json.dumps(["WebSearch", "WebFetch"])}


def put(path, data, mode=0o600):
    # These paths are owned by this explicit setup command, not cluster resources.
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_name(path.name + ".tmp")
    temp.write_bytes(data)
    temp.chmod(mode)
    temp.replace(path)


def install_managed(data):
    payload = STATE / "profile.plist"
    put(payload, data)
    subprocess.run(["sudo", "/bin/mkdir", "-p", str(MANAGED.parent)], check=True)
    subprocess.run(["sudo", "/usr/bin/install", "-m", "644", "-o", "root", "-g", "wheel", str(payload), str(MANAGED)], check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("token", "profile", "preflight", "status", "on", "off"))
    args = parser.parse_args()
    if args.action == "token":
        print(get_token())  # The Desktop helper contract requires only the bearer token on stdout.
        return
    if args.action == "profile":
        print(json.dumps(profile(), indent=2))
        return
    current = plistlib.loads(MANAGED.read_bytes()) if MANAGED.exists() else {}
    if args.action == "status":
        print(json.dumps({"gateway": current.get("inferenceGatewayBaseUrl"),
                          "credential_kind": current.get("inferenceCredentialKind"),
                          "berlin": current.get("inferenceGatewayBaseUrl") == BASE}, indent=2))
        return
    if args.action in ("preflight", "on"):
        with request("/v1/messages", {"model": "gemma-3-27b-it", "max_tokens": 32,
                                      "messages": [{"role": "user", "content": "Say hello in one sentence."}]}) as response:
            result = json.load(response)
        if result.get("type") != "message" or not result.get("content"):
            raise SystemExit("Desktop Messages preflight returned no message; settings unchanged")
        print("Berlin Messages endpoint answered:", result.get("model"))
    if args.action == "preflight":
        return
    if os.geteuid() == 0:
        raise SystemExit("Run as the laptop user, not sudo; the installer requests sudo only for the managed plist")
    STATE.mkdir(parents=True, exist_ok=True, mode=0o700)
    STATE.chmod(0o700)
    backup = STATE / "backup.json"
    if args.action == "on":
        # An agentdesktop-managed profile would be rewritten by its daemon.
        if MANAGED.with_name("." + MANAGED.name + ".owner").exists():
            raise SystemExit("This profile is owned by Agentdesktop. Switch its policy instead of overwriting it.")
        per_user = MANAGED.parent / Path.home().name / MANAGED.name
        if per_user.exists():
            raise SystemExit(f"A per-user managed profile exists at {per_user}; reconcile its owner first")
        if backup.exists() and current.get("inferenceGatewayBaseUrl") not in (None, BASE):
            raise SystemExit("A different profile is active since the saved backup; restore it before switching again")
        if not backup.exists():
            put(backup, json.dumps({"profile": base64.b64encode(MANAGED.read_bytes()).decode() if MANAGED.exists() else None,
                                   "desktop": base64.b64encode(DESKTOP.read_bytes()).decode() if DESKTOP.exists() else None}).encode())
        helper = "#!/bin/sh\nexec " + shlex.join([sys.executable, str(Path(__file__).resolve()), "token"]) + "\n"
        # Keep custom demo identity settings available to a GUI-launched helper.
        exports = {key: os.environ[key] for key in ("TUB_USER", "TUB_USER_PASSWORD", "TUB_KEYCLOAK", "TUB_CA_FILE", "GCD_KUBECONFIG") if key in os.environ}
        if exports:
            helper = "#!/bin/sh\n" + "\n".join("export " + key + "=" + shlex.quote(value) for key, value in exports.items()) + "\n" + helper.split("\n", 1)[1]
        put(STATE / "credential.sh", helper.encode(), 0o700)
        new = {k: v for k, v in current.items() if not k.startswith("inference")}
        new.update(profile())
        denied = current.get("disabledBuiltinTools", "[]")
        denied = json.loads(denied) if isinstance(denied, str) else denied
        new["disabledBuiltinTools"] = json.dumps(list(dict.fromkeys([*denied, "WebSearch", "WebFetch"])))
        put(STATE / "berlin-ca.crt", ca_pem().encode())
        subprocess.run(["sudo", "/usr/bin/security", "add-trusted-cert", "-d", "-r", "trustRoot",
                        "-k", "/Library/Keychains/System.keychain", str(STATE / "berlin-ca.crt")], check=True)
        install_managed(plistlib.dumps(new))
        config = json.loads(DESKTOP.read_text()) if DESKTOP.exists() else {}
        config["deploymentMode"] = "3p"
        put(DESKTOP, json.dumps(config, indent=2).encode())
        print("Desktop is configured for Berlin. Fully quit and reopen Claude, then start a new chat.")
    else:
        if current.get("inferenceGatewayBaseUrl") != BASE:
            raise SystemExit("Desktop is not on this Berlin endpoint; no settings changed")
        original = json.loads(backup.read_text())
        if original["profile"] is not None:
            install_managed(base64.b64decode(original["profile"]))
        else:
            subprocess.run(["sudo", "/bin/rm", "-f", str(MANAGED)], check=True)
        # Restore only the deployment mode; preserve chats/MCP settings edited
        # while the user was running the Berlin demo.
        old = json.loads(base64.b64decode(original["desktop"])) if original["desktop"] is not None else {}
        config = json.loads(DESKTOP.read_text()) if DESKTOP.exists() else {}
        if "deploymentMode" in old:
            config["deploymentMode"] = old["deploymentMode"]
        else:
            config.pop("deploymentMode", None)
        put(DESKTOP, json.dumps(config, indent=2).encode())
        backup.unlink()
        print("Previous Desktop settings restored. Fully quit and reopen Claude.")


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"Berlin Desktop setup: {type(error).__name__}: {error}", file=sys.stderr)
        raise SystemExit(1)
