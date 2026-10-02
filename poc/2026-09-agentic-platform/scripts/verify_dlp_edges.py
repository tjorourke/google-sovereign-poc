#!/usr/bin/env python3
"""Live negative controls for the deployed reader and the residency guardrail."""
import base64
import json
import os
import urllib.error
import urllib.request


def post(path, body, headers=None):
    host = "agw." + os.environ.get("BASE_DOMAIN", "agentic.eu0.internal")
    url = os.environ.get("GCD_AGW_URL", "http://" + host).rstrip("/")
    request = urllib.request.Request(url + path, data=json.dumps(body).encode(),
                                     headers={"Host": host, "Content-Type": "application/json", **(headers or {})})
    try:
        with urllib.request.urlopen(request, timeout=45) as response:
            return response.status, response.read().decode()
    except urllib.error.HTTPError as error:
        return error.code, error.read().decode()


def main():
    passed = 0
    for name, data in (("empty.txt", ""), ("bad.txt", "not-valid-base64!"),
                       ("bad.pdf", base64.b64encode(b"not a PDF").decode()),
                       ("bad.exe", base64.b64encode(b"not text").decode())):
        status, _ = post("/tub/summarize", {"name": name, "data": data})
        assert status == 400, (name, status)
        print(f"PASS: {name} rejected before inference")
        passed += 1
    # A name with no banking marker exercises broader NER detection after CEL.
    # Forging target/class headers must not disable the webhook's residency gate.
    body = {"model": "gemini-3.8-flash", "max_tokens": 32,
            "messages": [{"role": "user", "content": "Write a note to John Smith about his upcoming appointment."}]}
    status, text = post("/v1/chat/completions", body, {"x-selected-model": "gemini-3.8-flash",
                        "x-tub-data": "general", "x-tub-target": "gemma"})
    assert status == 409 and "TrustUsBank residency:" in text, (status, text)
    print("PASS: Presidio-only detection cannot be sent to Gemini using a forged target header")
    passed += 1
    body["model"] = "gemma-3-27b-it"
    body["messages"] = [{"role": "user", "content": "Continue"},
                        {"role": "assistant", "tool_calls": [{"id": "call_demo", "type": "function",
                         "function": {"name": "get_record", "arguments": "{}"}}]},
                        {"role": "tool", "tool_call_id": "call_demo", "content": "Customer CUS-20194"}]
    status, text = post("/v1/chat/completions", body, {"x-selected-model": "gemma-3-27b-it"})
    assert status == 422 and "Tool conversations" in text, (status, text)
    print("PASS: tool conversations are rejected rather than exempted from DLP")
    print(f"{passed + 1} negative controls passed")


if __name__ == "__main__":
    main()
