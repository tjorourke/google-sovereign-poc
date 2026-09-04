"""reverse_text — reverse a string."""

from core.server import mcp


@mcp.tool(description="Reverse the characters in a string.")
def reverse_text(text: str) -> str:
    """Return the text reversed.

    Args:
        text: The text to reverse

    Returns:
        The text with its characters in reverse order
    """
    return text[::-1]
