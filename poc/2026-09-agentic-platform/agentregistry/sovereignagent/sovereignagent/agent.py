import random
import os

from google.adk import Agent
from google.adk.tools.tool_context import ToolContext

from google.adk.models.lite_llm import LiteLlm

from .mcp_tools import get_mcp_tools
from .prompts_loader import build_instruction

# Initialize OpenTelemetry
# Set service name from environment variable for OpenTelemetry
os.environ.setdefault('OTEL_SERVICE_NAME', 'sovereignagent')

from google.adk.telemetry.setup import maybe_set_otel_providers
maybe_set_otel_providers()


def roll_die(sides: int, tool_context: ToolContext) -> int:
    """Roll a die and record the outcome for later reference."""
    result = random.randint(1, sides)
    if "rolls" not in tool_context.state:
        tool_context.state["rolls"] = []

    tool_context.state["rolls"] = tool_context.state["rolls"] + [result]
    return result


async def check_prime(nums: list[int]) -> str:
    """Check whether the provided numbers are prime."""
    primes = set()
    for number in nums:
        number = int(number)
        if number <= 1:
            continue
        is_prime = True
        for i in range(2, int(number**0.5) + 1):
            if number % i == 0:
                is_prime = False
                break
        if is_prime:
            primes.add(number)
    return "No prime numbers found." if not primes else f"{', '.join(str(num) for num in primes)} are prime numbers."


def create_model():
    """Use an OpenAI model via LiteLLM."""
    return LiteLlm(model="openai/Qwen2.5-3B-Instruct")


mcp_tools = get_mcp_tools()
root_agent = Agent(
    model=create_model(),
    name="sovereignagent_agent",
    description="Sovereign demo agent: pushed to kagent from AgentRegistry, reaches its model and tools only through agentgateway.",
    instruction=build_instruction("""

    """),
    tools=[
        roll_die,
        check_prime,
    ] + (mcp_tools if mcp_tools else []),
)

