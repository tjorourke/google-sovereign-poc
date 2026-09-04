"""echo — return the message back to the caller."""

from core.server import mcp


@mcp.tool(description="Echo a message back to the caller.")
def echo(message: str) -> str:
    """Echo a message back to the caller.

    Args:
        message: The message to echo

    Returns:
        The same message
    """
    return message
