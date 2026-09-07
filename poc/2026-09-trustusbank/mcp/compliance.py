"""TrustUsBank AG — compliance MCP server (demo data, no real screening).

Screening and case management. The separation that matters here is between
ASSESSING and FILING: screen_sanctions and check_pep inform a decision,
create_case records one, and file_sar submits a Geldwaescheverdachtsanzeige to
the German FIU under GwG section 43. No agent is granted file_sar. A regulatory
filing is a legal act by a named officer, so the chain deliberately stops one
step short and hands over.
"""
import os
from fastmcp import FastMCP

mcp = FastMCP("trustusbank-compliance")

# Cut-down stand-in for the EU consolidated list. Real screening is fuzzy,
# multilingual and transliteration-aware; this is a substring match so the demo
# is deterministic.
_SANCTIONS = [
    {"entry_id": "EU-2024-0412", "name": "Volkov Trading OOO",
     "programme": "EU consolidated list — Regulation 269/2014",
     "listed": "2024-03-15", "type": "ENTITY"},
    {"entry_id": "EU-2023-1188", "name": "Severnaya Logistika ZAO",
     "programme": "EU consolidated list — Regulation 269/2014",
     "listed": "2023-11-02", "type": "ENTITY"},
]

_PEP = [
    {"name": "Dmitri Volkov", "role": "Deputy regional finance minister",
     "country": "RU", "since": "2021", "relationship": "controls Volkov Trading OOO"},
]

_CASES: dict[str, dict] = {}
_SEQ = [4100]


@mcp.tool
def screen_sanctions(name: str) -> dict:
    """Screen a counterparty name against the EU consolidated sanctions list."""
    n = name.strip().lower()
    hits = [e for e in _SANCTIONS if e["name"].lower() in n or n in e["name"].lower()]
    return {"query": name, "match": bool(hits), "hits": hits,
            "list_version": "2026-09-01"}


@mcp.tool
def check_pep(name: str) -> dict:
    """Check a name against the politically exposed persons register."""
    n = name.strip().lower()
    hits = [p for p in _PEP if p["name"].lower() in n or n in p["name"].lower()]
    return {"query": name, "pep": bool(hits), "hits": hits}


@mcp.tool
def create_case(iban: str, summary: str, severity: str = "MEDIUM") -> dict:
    """Open an internal investigation case. Internal record only, not a filing."""
    _SEQ[0] += 1
    cid = f"CASE-{_SEQ[0]}"
    _CASES[cid] = {"case_id": cid, "iban": iban, "summary": summary,
                   "severity": severity.upper(), "status": "OPEN_PENDING_OFFICER"}
    return _CASES[cid]


@mcp.tool
def file_sar(case_id: str) -> dict:
    """Submit a suspicious activity report to the German FIU under GwG section 43.

    RESTRICTED. A regulatory filing is a legal act attributable to a named
    compliance officer. No agent identity is granted this tool.
    """
    return {"case_id": case_id, "status": "FILED",
            "authority": "FIU Germany (Zentralstelle fuer Finanztransaktionsuntersuchungen)"}


if __name__ == "__main__":
    mcp.run(transport="http", host="0.0.0.0",
            port=int(os.environ.get("PORT", "3000")), path="/mcp")
