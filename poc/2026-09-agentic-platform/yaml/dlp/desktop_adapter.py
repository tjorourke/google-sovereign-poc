"""Kernwerk's proven Desktop reader/SSE adapter, adapted for the Berlin gateway.

AGW performs Messages ↔ OpenAI conversion. This reader only extracts documents,
keeps inference non-streaming until response DLP has completed, and then emits
the Anthropic SSE envelope that Desktop expects. No laptop-side extraction.
"""
import base64
import http.client
import json
import secrets
import time

PREFIX = "/trustusbank"
OPEN_PREFIX = "/trustusbank-open"
PATHS = {PREFIX + "/v1/messages", PREFIX + "/v1/messages/count_tokens"}


def text_of(content):
    if isinstance(content, str):
        return content
    return "\n".join(p.get("text", "") for p in content or [] if isinstance(p, dict))


def open_attachments(body, read_file):
    opened = []
    for message in body.get("messages", []):
        parts = message.get("content")
        if not isinstance(parts, list):
            continue
        for index, part in enumerate(parts):
            if not isinstance(part, dict):
                raise ValueError("Invalid message content block")
            kind = part.get("type")
            if kind == "image":
                raise ValueError("This document-summary endpoint accepts text PDFs, not images or scans")
            if kind in ("tool_use", "tool_result"):
                raise ValueError("Use a new chat without tools for the document-summary demo")
            if kind != "document":
                continue
            source = part.get("source") or {}
            name = part.get("title") or "attached document"
            if source.get("type") == "base64" and source.get("media_type") == "application/pdf":
                text, pages = read_file(name if name.lower().endswith(".pdf") else name + ".pdf", source.get("data", ""))
            elif source.get("type") == "text":
                text, pages = read_file("document.txt", base64.b64encode(source.get("data", "").encode()).decode())
            else:
                raise ValueError("Unsupported attachment: attach a text PDF or plain-text document")
            parts[index] = {"type": "text", "text": f"[{name}, {pages} page(s)]\n{text}"}
            opened.append({"name": name, "pages": pages})
    return opened


def sse(message):
    """Replay a complete, response-guarded Messages answer as Anthropic events."""
    def event(kind, data):
        return f"event: {kind}\ndata: {json.dumps({'type': kind, **data})}\n\n".encode()
    blocks, usage = message.get("content", []), message.get("usage", {})
    result = [event("message_start", {"message": {
        **message, "content": [], "stop_reason": None, "stop_sequence": None,
        "usage": {**usage, "output_tokens": 0}}})]
    for index, block in enumerate(blocks):
        if block.get("type") != "text":
            raise ValueError("The document-summary model returned an unsupported response block")
        result.extend((event("content_block_start", {"index": index, "content_block": {"type": "text", "text": ""}}),
                       event("content_block_delta", {"index": index, "delta": {"type": "text_delta", "text": block["text"]}}),
                       event("content_block_stop", {"index": index})))
    result.extend((event("message_delta", {"delta": {"stop_reason": message.get("stop_reason", "end_turn"),
                                                    "stop_sequence": message.get("stop_sequence")},
                                           "usage": {"output_tokens": usage.get("output_tokens", 0)}}),
                   event("message_stop", {})))
    return b"".join(result)


def handle(handler, read_file, record, gateway, llm_host):
    path = handler.path.split("?", 1)[0]
    if path not in PATHS:
        handler.send_error(404)
        return
    is_count = path.endswith("/count_tokens")
    rid, started = secrets.token_hex(12), time.time()
    parts = handler.headers.get("traceparent", "").split("-")
    trace = parts[1] if len(parts) == 4 else secrets.token_hex(16)
    traceparent = handler.headers.get("traceparent") or f"00-{trace}-{secrets.token_hex(8)}-01"
    status, data, ctype = 400, b"", "application/json"
    recorded = False
    try:
        size = int(handler.headers.get("Content-Length") or 0)
        if size <= 0 or size > 7 * 1024 * 1024:
            raise ValueError("Request body must be between 1 byte and 7 MiB")
        body = json.loads(handler.rfile.read(size))
        if not isinstance(body, dict) or not isinstance(body.get("messages"), list) or not body["messages"]:
            raise ValueError("messages must be a non-empty list")
        stream = bool(body.pop("stream", False))
        users = [m for m in body["messages"] if m.get("role") == "user"]
        if not is_count:
            record(kind="incoming", id=rid, trace=trace, client="claude-desktop",
                   text=text_of(users[-1].get("content")) if users else "", files=[], turns=len(users))
            recorded = True
        opened = open_attachments(body, read_file)
        if not is_count:
            # Update the same record with extracted text and the real filenames.
            record(kind="incoming", id=rid, trace=trace, client="claude-desktop",
                   text=text_of(users[-1].get("content")) if users else "", files=opened, turns=len(users))
        body["model"] = "gemma-3-27b-it"
        if not is_count:
            body["max_tokens"] = min(max(int(body.get("max_tokens", 1500)), 1), 2048)
        # Gemini/cloud-only tools have no backend in this summary endpoint.
        body.pop("tools", None)
        body.pop("tool_choice", None)
        headers = {"Host": llm_host, "Content-Type": "application/json", "traceparent": traceparent,
                   "anthropic-version": handler.headers.get("anthropic-version", "2023-06-01"),
                   "Authorization": handler.headers.get("Authorization", ""),
                   "x-selected-model": "gemma-3-27b-it"}
        connection = http.client.HTTPConnection(*gateway, timeout=300)
        try:
            connection.request("POST", OPEN_PREFIX + path[len(PREFIX):], json.dumps(body).encode(), headers)
            response = connection.getresponse()
            status, data = response.status, response.read()
        finally:
            connection.close()
        if status >= 400:
            try:
                err = json.loads(data)
                detail = (err.get("error") or {}).get("message", "")
            except (ValueError, AttributeError):
                detail = data.decode(errors="replace")[:400]
            # The conversion hop may wrap a plain-text guardrail rejection as 502.
            # Preserve that status instead of falsely labelling every 502 as DLP.
            data = json.dumps({"type": "error", "error": {
                "type": "permission_error" if status in (401, 403, 409) else "api_error",
                "message": detail or "Berlin gateway rejected the request; inspect the trace for the reason"}}).encode()
        else:
            message = json.loads(data)
            if stream and not is_count:
                data, ctype = sse(message), "text/event-stream"
            if not is_count:
                record(kind="answer", id=rid, trace=trace, client="claude-desktop", status=status,
                       model=message.get("model", ""), text=text_of(message.get("content")),
                       elapsed=round(time.time() - started, 2))
    except (ValueError, TypeError, KeyError) as error:
        status = 400
        data = json.dumps({"type": "error", "error": {"type": "invalid_request_error", "message": str(error)}}).encode()
    except (OSError, http.client.HTTPException):
        status = 502
        data = json.dumps({"type": "error", "error": {"type": "api_error", "message": "Berlin inference connection failed"}}).encode()
    if status >= 400 and recorded:
        record(kind="answer", id=rid, trace=trace, client="claude-desktop", status=status,
               text="", error=json.loads(data)["error"]["message"], elapsed=round(time.time() - started, 2))
    handler.send_response(status)
    handler.send_header("Content-Type", ctype)
    handler.send_header("Content-Length", str(len(data)))
    handler.send_header("x-trustusbank-trace-id", trace)
    handler.send_header("Connection", "close")
    handler.end_headers()
    handler.wfile.write(data)
