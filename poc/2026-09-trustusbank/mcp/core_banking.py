"""TrustUsBank AG — core banking MCP server (demo data, no real customers).

Four tools, and the interesting thing about them is the boundary between them:
get_account and list_transactions expose BEHAVIOUR, get_customer exposes a
PERSON. The fraud agent is granted the first two and denied the third, so it
reaches a conclusion about a payment without ever seeing who made it. That
denial is enforced at agentgateway by an AccessPolicy, not requested in a
prompt, which is the difference between a control and a suggestion.
"""
import os
from fastmcp import FastMCP

mcp = FastMCP("trustusbank-core-banking")

# ── demo book of record ──────────────────────────────────────────────────────
# One retail customer whose account has just done something out of character.
IBAN = "DE89370400440532013000"

_ACCOUNTS = {
    IBAN: {
        "account_id": "ACC-4471",
        "iban": IBAN,
        "product": "TrustUsBank GiroPlus",
        "status": "ACTIVE",
        "opened": "2014-03-11",
        "branch": "Frankfurt am Main, Zeil",
        "balance_band_eur": "10000-25000",
        "avg_weekly_outflow_eur": 280,
        "sepa_instant_enabled": True,
    }
}

# Four transfers in eighteen minutes, against a 280 EUR weekly average. The
# amounts sit just under the 10k reporting threshold, which is the pattern
# worth noticing (structuring), not the individual amount.
_TRANSACTIONS = {
    IBAN: [
        {"txn_id": "TXN-88213", "booked": "2026-09-07T08:41Z",
         "amount_eur": 9850.00, "scheme": "SEPA_INSTANT", "direction": "DEBIT",
         "counterparty_name": "Volkov Trading OOO",
         "counterparty_iban": "DE21500105170648489890",
         "reference": "Invoice 2026-4471", "status": "PENDING_REVIEW"},
        {"txn_id": "TXN-88209", "booked": "2026-09-07T08:33Z",
         "amount_eur": 9400.00, "scheme": "SEPA_INSTANT", "direction": "DEBIT",
         "counterparty_name": "Volkov Trading OOO",
         "counterparty_iban": "DE21500105170648489890",
         "reference": "Invoice 2026-4470", "status": "SETTLED"},
        {"txn_id": "TXN-88204", "booked": "2026-09-07T08:27Z",
         "amount_eur": 8300.00, "scheme": "SEPA_INSTANT", "direction": "DEBIT",
         "counterparty_name": "Volkov Trading OOO",
         "counterparty_iban": "DE21500105170648489890",
         "reference": "Invoice 2026-4469", "status": "SETTLED"},
        {"txn_id": "TXN-88198", "booked": "2026-09-07T08:23Z",
         "amount_eur": 3850.00, "scheme": "SEPA_INSTANT", "direction": "DEBIT",
         "counterparty_name": "Volkov Trading OOO",
         "counterparty_iban": "DE21500105170648489890",
         "reference": "Invoice 2026-4468", "status": "SETTLED"},
        {"txn_id": "TXN-87740", "booked": "2026-09-01T14:02Z",
         "amount_eur": 62.40, "scheme": "SEPA_CREDIT_TRANSFER", "direction": "DEBIT",
         "counterparty_name": "Stadtwerke Frankfurt",
         "counterparty_iban": "DE44500105175407324931",
         "reference": "Strom 09/2026", "status": "SETTLED"},
    ]
}

# The PII the fraud agent must never reach.
_CUSTOMERS = {
    IBAN: {
        "customer_id": "CUS-20194",
        "name": "Katrin Vogel",
        "date_of_birth": "1979-06-02",
        "address": "Hanauer Landstrasse 188, 60314 Frankfurt am Main",
        "phone": "+49 69 555 0184",
        "tax_id": "DE263412887",
        "kyc_review_due": "2027-01-30",
    }
}

_HELD: dict[str, str] = {}


@mcp.tool
def get_account(iban: str) -> dict:
    """Account standing and normal spending behaviour for an IBAN. No personal data."""
    a = _ACCOUNTS.get(iban.replace(" ", ""))
    return a or {"error": "unknown IBAN", "iban": iban}


@mcp.tool
def list_transactions(iban: str, limit: int = 10) -> dict:
    """Recent transactions for an IBAN, newest first. Counterparties, amounts, scheme."""
    t = _TRANSACTIONS.get(iban.replace(" ", ""), [])
    return {"iban": iban, "count": min(limit, len(t)), "transactions": t[:limit]}


@mcp.tool
def get_customer(iban: str) -> dict:
    """Full customer record: name, date of birth, address, phone, tax id.

    RESTRICTED. Personal data under GDPR and not needed to assess whether a
    payment pattern is anomalous.
    """
    c = _CUSTOMERS.get(iban.replace(" ", ""))
    return c or {"error": "unknown IBAN", "iban": iban}


@mcp.tool
def flag_transaction(txn_id: str, reason: str) -> dict:
    """Place a hold on a transaction pending human review."""
    _HELD[txn_id] = reason
    return {"txn_id": txn_id, "status": "HELD", "reason": reason,
            "note": "hold is provisional until a payments officer confirms"}


if __name__ == "__main__":
    mcp.run(transport="http", host="0.0.0.0",
            port=int(os.environ.get("PORT", "3000")), path="/mcp")
