#!/usr/bin/env python3
"""Create a readable, fictional confidential finance PDF for the Desktop DLP demo."""
import argparse
from pathlib import Path

from reportlab.lib import colors
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import ParagraphStyle, getSampleStyleSheet
from reportlab.platypus import Paragraph, SimpleDocTemplate, Spacer, Table, TableStyle


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=Path.home() / "Downloads/TrustUsBank-Confidential-Mortgage-Review.pdf")
    dest = parser.parse_args().output.expanduser()
    if not dest.parent.is_dir():
        raise SystemExit(f"Output directory does not exist: {dest.parent}")
    navy, teal = colors.HexColor("#123047"), colors.HexColor("#176A63")
    styles = getSampleStyleSheet()
    styles.add(ParagraphStyle("BankBody", fontName="Helvetica", fontSize=10, leading=14,
                              textColor=navy, spaceAfter=8))
    styles.add(ParagraphStyle("BankSection", fontName="Helvetica-Bold", fontSize=11, leading=15,
                              textColor=teal, spaceBefore=11, spaceAfter=7))
    styles.add(ParagraphStyle("BankTitle", fontName="Helvetica-Bold", fontSize=24, leading=28,
                              textColor=navy, spaceAfter=8))
    styles.add(ParagraphStyle("BankSmall", fontName="Helvetica", fontSize=8.5, leading=12,
                              textColor=colors.HexColor("#506170"), spaceAfter=6))
    p = lambda text, style="BankBody": Paragraph(text, styles[style])
    width = A4[0] - 88
    story = [p("TRUSTUSBANK", "BankSection"),
             p("Mortgage payment support", "BankTitle"),
             p("<b>TRUSTUSBANK RESTRICTED</b> | Customer financial information | 02 October 2026", "BankSmall"),
             p("Fictional training document. All customer details and financial figures are synthetic.", "BankSmall"),
             Spacer(1, 5)]
    customer = Table([
        [p("<b>Customer</b>"), p("Anna Schmidt | CUS-20194")],
        [p("<b>Account IBAN</b>"), p("DE89 3704 0044 0532 0130 00")],
        [p("<b>Contact / case</b>"), p("anna.schmidt@example.com | TUB-2026-1042")],
    ], colWidths=[115, width - 115])
    customer.setStyle(TableStyle([
        ("BACKGROUND", (0, 0), (-1, -1), colors.HexColor("#F0F5F7")),
        ("VALIGN", (0, 0), (-1, -1), "TOP"),
        ("LEFTPADDING", (0, 0), (-1, -1), 10),
        ("RIGHTPADDING", (0, 0), (-1, -1), 10),
        ("TOPPADDING", (0, 0), (-1, -1), 5),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 0),
    ]))
    story.extend([customer, p("1. Why the customer contacted us", "BankSection"),
                  p("Anna's paid working hours will be reduced for three months. Her monthly take-home pay "
                    "falls from <b>EUR 2,600 to EUR 1,900</b> from November 2026 through January 2027. "
                    "She expects to return to normal hours in February 2027 and has asked for temporary mortgage relief."),
                  p("The outstanding mortgage is <b>EUR 148,000</b>. Her current payment is <b>EUR 900 per month</b>. "
                    "She has made every payment on time over the last 12 months and has <b>EUR 620 in savings</b>."),
                  p("2. Simple monthly budget during reduced hours", "BankSection")])
    rows = [["Item", "Amount"],
            ["Take-home pay", "EUR 1,900"],
            ["Essential living costs, excluding mortgage", "EUR 1,100"],
            ["Current mortgage payment", "EUR 900"],
            ["Total spending", "EUR 2,000"],
            ["Monthly shortfall", "EUR 100"]]
    budget = Table(rows, colWidths=[width - 115, 115], rowHeights=[23] * len(rows))
    budget.setStyle(TableStyle([
        ("FONTNAME", (0, 0), (-1, -1), "Helvetica"),
        ("FONTSIZE", (0, 0), (-1, -1), 10),
        ("FONTNAME", (0, 0), (-1, 0), "Helvetica-Bold"),
        ("BACKGROUND", (0, 0), (-1, 0), navy),
        ("TEXTCOLOR", (0, 0), (-1, 0), colors.white),
        ("TEXTCOLOR", (0, 1), (-1, -1), navy),
        ("ALIGN", (1, 0), (1, -1), "RIGHT"),
        ("VALIGN", (0, 0), (-1, -1), "MIDDLE"),
        ("LEFTPADDING", (0, 0), (-1, -1), 10),
        ("RIGHTPADDING", (0, 0), (-1, -1), 10),
        ("LINEBELOW", (0, 1), (-1, -1), 0.4, colors.HexColor("#DAE3E9")),
        ("BACKGROUND", (0, -1), (-1, -1), colors.HexColor("#FFF3E5")),
        ("FONTNAME", (0, -1), (-1, -1), "Helvetica-Bold"),
    ]))
    story.extend([budget, p("3. Proposed support - not yet approved", "BankSection"),
                  p("Reduce the mortgage payment to <b>EUR 650 per month for November-January</b>. "
                    "This leaves EUR 150 per month after essential costs. The difference of EUR 250 per month "
                    "would defer <b>EUR 750 in total</b> over three months; it would not be written off."),
                  p("Before approval, confirm the reduced hours and expected return date, agree how deferred "
                    "payments and any interest will be handled, and schedule a review before February. "
                    "Only an authorised loan officer may approve a change or contact the customer."),
                  p("Handling note", "BankSection"),
                  p("This case links a named customer and bank account to an income reduction, savings balance "
                    "and mortgage-support request. It is internal customer information, not public material. "
                    "Keep summaries within TrustUsBank's approved processing environment.", "BankSmall")])

    def footer(canvas, doc):
        canvas.setStrokeColor(colors.HexColor("#DAE3E9"))
        canvas.line(44, 36, A4[0] - 44, 36)
        canvas.setFont("Helvetica", 8)
        canvas.setFillColor(colors.HexColor("#506170"))
        canvas.drawString(44, 23, "TRUSTUSBANK RESTRICTED | Fictional demo data")
        canvas.drawRightString(A4[0] - 44, 23, f"Page {doc.page}")

    SimpleDocTemplate(str(dest), pagesize=A4, leftMargin=44, rightMargin=44,
                      topMargin=28, bottomMargin=48, title="TrustUsBank - Confidential mortgage support review",
                      author="TrustUsBank fictional demonstration").build(story, onFirstPage=footer, onLaterPages=footer)
    print(dest)


if __name__ == "__main__":
    main()
