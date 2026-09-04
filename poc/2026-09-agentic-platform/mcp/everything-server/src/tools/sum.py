"""sum — add two numbers."""

from core.server import mcp


@mcp.tool(description="Add two numbers together. Use this when you need to sum or add two numbers.")
def sum(a: float | int, b: float | int) -> float | int:
    """Add two numbers together.

    Args:
        a: The first number to add
        b: The second number to add

    Returns:
        The sum of the two numbers
    """
    return a + b
