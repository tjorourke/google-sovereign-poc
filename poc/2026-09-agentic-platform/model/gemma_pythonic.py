# gemma_pythonic.py — vLLM tool parser plugin: the pythonic parser, forgiving
# of Gemma's bracket slips.
#
# Gemma 3 writes tool calls as a Python list, [create_issue(title="...", body="...")],
# and the stock pythonic parser runs it through ast.parse. On long string
# arguments Gemma sometimes closes with one bracket too many ("))]") or too
# few. ast.parse then raises, vLLM logs "Error in extracting tool call from
# response" and hands the whole call back as chat text: the agent shows raw
# Python and the tool never runs (seen on the PM agent's create_issue, 2026-10-02).
#
# This parser repairs the brackets outside string literals and retries. It also
# finds a call Gemma wrote after a sentence of prose ("Okay, I'll create the
# issue.\n\n[create_issue(...)]"), or followed by one ("[open_pull_request(...)]\nI
# opened pull request 4.", seen on the dev agent, 2026-10-02), both of which the stock
# parser treats as text: only a call to one of the request's own tools counts. Output that parses already is
# untouched, so it only changes calls that would fail.
# Loaded with --tool-parser-plugin; selected with --tool-call-parser=gemma_pythonic.
import ast
import re

from vllm.entrypoints.openai.tool_parsers.abstract_tool_parser import ToolParserManager
from vllm.entrypoints.openai.tool_parsers.pythonic_tool_parser import PythonicToolParser
from vllm.logger import init_logger

logger = init_logger(__name__)
PAIRS = {")": "(", "]": "[", "}": "{"}
CLOSE = {v: k for k, v in PAIRS.items()}


def scan(text, first=False):
    """Walk text outside string literals. Returns (kept text, unclosed openers, the
    index just past the bracket that closes the first opener), or None when a
    string is left open. Closers with no matching opener are dropped. With first,
    stop at that closing bracket, so an apostrophe in prose after it ("I've") is
    never read as an open string."""
    out, stack, quote, i, end = [], [], None, 0, None
    while i < len(text):
        c = text[i]
        if quote:
            out.append(c)
            if c == "\\" and i + 1 < len(text):
                out.append(text[i + 1])
                i += 1
            elif text.startswith(quote, i):
                out.extend(quote[1:])
                i += len(quote) - 1
                quote = None
        elif c in "\"'":
            quote = c * 3 if text.startswith(c * 3, i) else c
            out.append(quote)
            i += len(quote) - 1
        elif c in CLOSE:
            stack.append(c)
            out.append(c)
        elif c in PAIRS:
            if stack and stack[-1] == PAIRS[c]:
                stack.pop()
                out.append(c)
                if not stack and end is None:
                    end = i + 1
                    if first:
                        break
            # else: a stray closer, dropped
        else:
            out.append(c)
        i += 1
    return None if quote else ("".join(out), stack, end)


def balance(text):
    """Drop closers with no matching opener and append the missing closers."""
    s = scan(text)
    if not s:
        return text  # an unterminated string is not a bracket slip
    kept, stack, _ = s
    return kept.rstrip() + "".join(CLOSE[o] for o in reversed(stack))


def parses(text):
    try:
        ast.parse(text)
        return True
    except SyntaxError:
        return False


def tool_names(request):
    return {t.function.name for t in (getattr(request, "tools", None) or [])}


def embedded_call(text, names):
    """A [tool(...)] list for one of this request's tools with prose before or after it
    ("Okay, I'll create the issue.\n\n[create_issue(...)]"). Returns (prose, call)
    or None. Prose after the call is dropped: it is the model guessing the result."""
    for m in re.finditer(r"\[\s*([A-Za-z_]\w*)\s*\(", text):
        if m.group(1) not in names:
            continue
        s = scan(text[m.start():], first=True)
        call = text[m.start():m.start() + s[2]] if s and s[2] else balance(text[m.start():])
        if not parses(call):
            call = balance(call)
        if parses(call):
            return text[:m.start()].strip(), call
    return None


@ToolParserManager.register_module("gemma_pythonic")
class GemmaPythonicToolParser(PythonicToolParser):

    def extract_tool_calls(self, model_output, request):
        text = model_output.strip()
        if text.startswith("[") and parses(text):
            return super().extract_tool_calls(model_output, request)
        if text.startswith("["):
            fixed = balance(text)
            if fixed != text and parses(fixed):
                logger.warning("Repaired unbalanced brackets in a tool call")
                return super().extract_tool_calls(fixed, request)
        found = embedded_call(text, tool_names(request))
        if not found:
            return super().extract_tool_calls(model_output, request)
        prose, call = found
        result = super().extract_tool_calls(call, request)
        if result.tools_called:
            logger.warning("Took a tool call out of surrounding text")
            result.content = prose or None
        return result
