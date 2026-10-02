#!/usr/bin/env python3
"""Generate a fictional TrustUsBank PDF for the upload demo (requires reportlab)."""
from pathlib import Path

from reportlab.lib import colors
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import getSampleStyleSheet
from reportlab.platypus import SimpleDocTemplate, Paragraph, Spacer

DEST = Path(__file__).resolve().parents[1] / "deploy" / "trustusbank-case.pdf"


def main():
    styles = getSampleStyleSheet()
    styles["Title"].textColor = colors.HexColor("#14532d")
    story = [Paragraph("TrustUsBank | Payment review", styles["Title"]),
             Paragraph("Fictional training document - no real customer data", styles["Heading2"]), Spacer(1, 20)]
    for text in (
        "Case: TUB-2026-1187. Customer: Anna Schmidt. Customer number: CUS-20194.",
        "IBAN: DE89 3704 0044 0532 0130 00. Email: anna.schmidt@example.com.",
        "Four SEPA Instant transfers went to the same new beneficiary within 18 minutes. "
        "Total value: EUR 31,400. The latest payment is EUR 9,850; each payment is below EUR 10,000.",
        "The account's normal weekly outflow is EUR 280. The latest transfer is held for review.",
        "Task: summarise the unusual behaviour and suggest the next review steps. Do not release "
        "payments or file a suspicious activity report; those decisions require an authorised officer.",
    ):
        story.extend((Paragraph(text, styles["BodyText"]), Spacer(1, 12)))
    SimpleDocTemplate(str(DEST), pagesize=A4, title="TrustUsBank fictional payment case").build(story)
    print(DEST)


if __name__ == "__main__":
    main()
