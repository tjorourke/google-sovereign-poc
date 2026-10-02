"""Protocol regressions for the ported Desktop attachment/SSE adapter."""
import copy
import importlib.util
import json
from pathlib import Path
import unittest

PATH = Path(__file__).resolve().parents[1] / "yaml/dlp/desktop_adapter.py"
SPEC = importlib.util.spec_from_file_location("desktop_adapter", PATH)
adapter = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(adapter)


class DesktopAdapterTests(unittest.TestCase):
    def test_documents_replaced_in_place_across_conversation(self):
        body = {"messages": [{"role": "user", "content": [
            {"type": "text", "text": "Summarise"},
            {"type": "document", "title": "review.pdf", "source": {
                "type": "base64", "media_type": "application/pdf", "data": "PDF"}}]},
            {"role": "assistant", "content": "Previous summary"},
            {"role": "user", "content": [{"type": "document", "title": "note.txt", "source": {
                "type": "text", "data": "Follow-up note"}}]}]}
        calls = []
        def reader(name, data):
            calls.append((name, data))
            return ("Extracted customer record", 2) if name.endswith(".pdf") else ("Follow-up note", 1)
        files = adapter.open_attachments(body, reader)
        self.assertEqual(files, [{"name": "review.pdf", "pages": 2}, {"name": "note.txt", "pages": 1}])
        self.assertEqual(body["messages"][0]["content"][0]["text"], "Summarise")
        self.assertIn("Extracted customer record", body["messages"][0]["content"][1]["text"])
        self.assertEqual(body["messages"][1]["content"], "Previous summary")
        self.assertEqual(calls[0], ("review.pdf", "PDF"))

    def test_unsupported_inputs_do_not_disappear_silently(self):
        for block in ({"type": "image"}, {"type": "tool_result"}, {"type": "tool_use"},
                      {"type": "document", "source": {"type": "url", "url": "http://internal/secret"}}):
            with self.subTest(block=block), self.assertRaises(ValueError):
                adapter.open_attachments({"messages": [{"content": [block]}]}, lambda *_: self.fail("must not extract"))

    def test_stream_preserves_text_usage_and_stop_sequence(self):
        message = {"id": "msg_test", "type": "message", "role": "assistant", "model": "gemma-3-27b-it",
                   "content": [{"type": "text", "text": "Summary of {NAME}\nSecond line"}],
                   "usage": {"input_tokens": 100, "output_tokens": 12}, "stop_reason": "end_turn", "stop_sequence": None}
        original = copy.deepcopy(message)
        events = [json.loads(line[6:]) for line in adapter.sse(message).decode().splitlines() if line.startswith("data: ")]
        self.assertEqual([e["type"] for e in events], ["message_start", "content_block_start", "content_block_delta",
                                                     "content_block_stop", "message_delta", "message_stop"])
        self.assertEqual(events[0]["message"]["usage"], {"input_tokens": 100, "output_tokens": 0})
        self.assertEqual(events[2]["delta"]["text"], message["content"][0]["text"])
        self.assertEqual(events[-2]["usage"]["output_tokens"], 12)
        self.assertEqual(events[-2]["delta"]["stop_reason"], "end_turn")
        self.assertEqual(message, original)


if __name__ == "__main__":
    unittest.main()
