#!/usr/bin/env python3
"""Regression: native Desktop's ~19k-token preamble plus PDF must fit Gemma.

The earlier protocol smoke test omitted Desktop's large system instructions.
This deliberately uses synthetic padding, not captured private instructions.
"""
import base64
import json
from pathlib import Path
import urllib.error

import claude_desktop_berlin as client


def main():
    pdf = Path.home() / "Downloads/TrustUsBank-Confidential-Mortgage-Review.pdf"
    if not pdf.exists():
        pdf = Path(__file__).resolve().parents[1] / "deploy/trustusbank-case.pdf"
    body = {"model": "gemma-3-27b-it", "max_tokens": 2048, "stream": True,
            "system": "You summarise bank documents. Neutral reference padding follows:\n" + "context " * 19000 +
                      "\nNow summarise only the attached document in five short bullet points.",
            "messages": [{"role": "user", "content": [
                {"type": "text", "text": "Summarise this mortgage-support case for a branch manager in five short plain-English bullets. Include the shortfall, proposed support, deferred amount and checks before approval."},
                {"type": "document", "title": pdf.name, "source": {"type": "base64", "media_type": "application/pdf",
                 "data": base64.b64encode(pdf.read_bytes()).decode()}}]}]}
    token = client.get_token()
    with client.request("/v1/messages", body, token=token) as response:
        events = [json.loads(line[6:]) for line in response.read().decode().splitlines() if line.startswith("data: ")]
        trace = response.headers.get("x-trustusbank-trace-id")
    message = events[0]["message"]
    text = "".join(e.get("delta", {}).get("text", "") for e in events)
    assert message["usage"]["input_tokens"] > 18000, message["usage"]
    assert message["model"] == "gemma-3-27b-it" and len(text) > 80, message
    assert events[-1]["type"] == "message_stop"
    assert "Anna Schmidt" not in text and "CUS-20194" not in text, text
    print(f"PASS: {message['usage']['input_tokens']} input tokens + PDF -> Gemma summary, streamed to Desktop")
    print("Trace:", trace)
    print("Summary:", text)
    body.update(stream=False, system="context " * 30000, max_tokens=128)
    try:
        with client.request("/v1/messages", body, token=token) as response:
            raise AssertionError(f"Oversized request unexpectedly returned {response.status}")
    except urllib.error.HTTPError as error:
        parsed = json.loads(error.read())
        assert error.code == 400, (error.code, parsed)
        assert parsed["type"] == "error" and "maximum context length" in parsed["error"]["message"], parsed
        assert "missing field" not in parsed["error"]["message"]
        print("PASS: oversized request returns the actual context-limit error as HTTP 400, not converter HTTP 502")


if __name__ == "__main__":
    main()
