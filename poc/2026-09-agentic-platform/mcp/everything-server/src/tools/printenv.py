"""printenv — return the server's environment variables.

A deliberately sensitive tool: it exposes the tool server's process
environment. It is the tool we later restrict with an AccessPolicy so the
agent can use `sum` but is denied `printenv`.
"""

import os

from core.server import mcp


@mcp.tool(description="Return the tool server's environment variables as a dictionary.")
def printenv() -> dict:
    """Return all environment variables visible to the tool server.

    Returns:
        A mapping of environment variable name to value.
    """
    return dict(os.environ)
