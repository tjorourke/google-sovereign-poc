#!/usr/bin/env python3
"""Make a real, authenticated model call and print its AGW trace deep-link.

No seeded spans. The gateway verifies the Keycloak JWT and records audit.user,
audit.agent and audit.team. Tokens stay in memory. Defaults match 88-identity.sh.
"""
import argparse
import json
import os
import secrets
import urllib.error
import urllib.parse
import urllib.request


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prompt", default="Summarise: customer CUS-20194 has IBAN DE89370400440532013000 and reports a missing payment of EUR 450.")
    parser.add_argument("--route", choices=("gemma", "gemini"), default="gemini")
    args = parser.parse_args()
    domain = os.environ.get("BASE_DOMAIN", "agentic.eu0.internal")
    keycloak = os.environ.get("TUB_KEYCLOAK", f"http://keycloak.{domain}").rstrip("/")
    form = urllib.parse.urlencode({
        "grant_type": "password", "client_id": "trustusbank-console",
        "username": os.environ.get("TUB_USER", "bob"),
        "password": os.environ.get("TUB_USER_PASSWORD", "password"), "scope": "openid",
    }).encode()
    with urllib.request.urlopen(keycloak + "/realms/agentregistry/protocol/openid-connect/token", form, timeout=20) as response:
        token = json.load(response)["access_token"]
    trace = secrets.token_hex(16)
    model = "gemma-3-27b-it" if args.route == "gemma" else "gemini-3.8-flash"
    request = urllib.request.Request(
        os.environ.get("GCD_AGW_URL", f"http://agw.{domain}").rstrip("/") + "/v1/chat/completions",
        data=json.dumps({"model": model, "max_tokens": 256, "messages": [{"role": "user", "content": args.prompt}]}).encode(),
        headers={"Host": f"agw.{domain}", "Content-Type": "application/json",
                 "Authorization": "Bearer " + token, "x-selected-model": model,
                 "traceparent": f"00-{trace}-{secrets.token_hex(8)}-01"})
    try:
        with urllib.request.urlopen(request, timeout=180) as response:
            status, raw = response.status, response.read()
    except urllib.error.HTTPError as error:
        status, raw = error.code, error.read()
    try:
        body = json.loads(raw)
    except ValueError:
        body = {"error": raw.decode(errors="replace")}
    print(json.dumps({"status": status, "requested": model, "answered_by": body.get("model"),
                      "trace_id": trace, "trace_url": f"http://kagent.{domain}/age/tracing/{trace}",
                      "usage": body.get("usage"), "error": body.get("error")}, indent=2))
    return 0 if status in (200, 403) else 1


if __name__ == "__main__":
    raise SystemExit(main())
