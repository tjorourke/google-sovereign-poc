"""to_uppercase — uppercase a string."""

from core.server import mcp


@mcp.tool(description="Convert text to UPPERCASE.")
def to_uppercase(text: str) -> str:
    """Return the text in uppercase.

    Args:
        text: The text to convert

    Returns:
        The text, uppercased
    """
    return text.upper()
