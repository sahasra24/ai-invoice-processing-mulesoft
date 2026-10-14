#!/usr/bin/env python3
"""
Generates every sample invoice used by the demo, Postman collection and tests.

    python tools/generate_samples.py

Outputs
  sample-invoices/pdf/*.pdf        text-based PDFs (pure Python, no libraries)
  sample-invoices/images/*.png|jpg scanned-looking invoices (requires Pillow;
                                   skipped with a warning if Pillow is missing)
  sample-invoices/json/*.json      structured supplier JSON invoices
  sample-invoices/invalid/*        files that must be rejected (415)
  mock-services/fixtures/image-fixtures.json
                                   "OCR ground truth" for the mock AI service
"""
import hashlib
import json
import random
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "sample-invoices"
FIXTURES = ROOT / "mock-services" / "fixtures" / "image-fixtures.json"

BILL_TO = "Contoso Ltd, Accounts Payable, 1 Microsoft Way, Redmond WA 98052"

VENDORS = {
    "V-1001": "Acme Office Supplies",
    "V-1002": "Globex Industrial Parts",
    "V-1003": "Initech IT Services",
    "V-1005": "Stark Precision Components",
    "V-9999": "Northwind Traders",
}


def money(v):
    return f"{v:,.2f}"


def invoice(number, vendor_id, po, date, terms, due, lines, tax_rate,
            subtotal_override=None, omit=(), currency="USD", scenario=""):
    subtotal = round(sum(q * p for _, _, q, p in lines), 2)
    stated_subtotal = subtotal_override if subtotal_override is not None else subtotal
    tax = round(stated_subtotal * tax_rate, 2)
    total = round(stated_subtotal + tax, 2)
    return {
        "scenario": scenario,
        "invoice_number": number, "vendor_id": vendor_id, "vendor_name": VENDORS[vendor_id],
        "purchase_order_number": po, "invoice_date": date, "payment_terms": terms, "due_date": due,
        "currency": currency, "billing_address": BILL_TO,
        "line_items": [
            {"line_number": i + 1, "item_code": code, "description": desc,
             "quantity": q, "unit_price": p, "amount": round(q * p, 2)}
            for i, (code, desc, q, p) in enumerate(lines)
        ],
        "subtotal": stated_subtotal, "tax_rate": tax_rate, "tax": tax, "total_amount": total,
        "omit": list(omit),
    }


SAMPLES = {
    # ---- PDFs ------------------------------------------------------------
    "pdf/INV-2026-1001_acme_auto-approve.pdf": invoice(
        "INV-2026-1001", "V-1001", "PO-2026-0001", "2026-09-15", "Net 30", "2026-10-15",
        [("PAP-A4-500", "A4 Copy Paper 80gsm (box of 5 reams)", 100, 5.00),
         ("TON-HP-26X", "HP 26X Black Toner Cartridge", 10, 30.00)], 0.08,
        scenario="Happy path: total <= 1,000 -> auto-approved -> posted to ERP"),
    "pdf/INV-2026-1002_globex_single-approval.pdf": invoice(
        "INV-2026-1002", "V-1002", "PO-2026-0002", "2026-09-20", "Net 45", "2026-11-04",
        [("HYD-PMP-220", "Hydraulic Pump 220V", 4, 1000.00),
         ("VLV-KIT-12", "Valve Repair Kit 12mm", 20, 50.00)], 0.08,
        scenario="1,000 < total <= 10,000 -> PENDING_APPROVAL (APPROVER)"),
    "pdf/INV-2026-1003_initech_two-level-approval.pdf": invoice(
        "INV-2026-1003", "V-1003", "PO-2026-0003", "2026-09-25", "Net 60", "2026-11-24",
        [("SRV-CLOUD", "Cloud Migration Services (hours)", 300, 150.00),
         ("SRV-SECAUD", "Security Audit (fixed fee)", 1, 15000.00)], 0.08,
        scenario="total > 50,000 -> PENDING_APPROVAL (MANAGER then FINANCE_DIRECTOR)"),
    "pdf/INV-2026-1004_globex_price-variance.pdf": invoice(
        "INV-2026-1004", "V-1002", "PO-2026-0004", "2026-09-28", "Net 45", "2026-11-12",
        [("BRG-6204", "Deep Groove Ball Bearing 6204", 100, 13.50)], 0.08,
        scenario="Unit price 13.50 vs PO 12.00 (12.5% variance) -> MANUAL_REVIEW"),
    "pdf/INV-2026-1005_unknown-vendor.pdf": invoice(
        "INV-2026-1005", "V-9999", "PO-2026-0008", "2026-09-29", "Net 30", "2026-10-29",
        [("NTB-A5-DOT", "A5 Dotted Notebook", 10, 3.00)], 0.08,
        scenario="Vendor V-9999 not in vendor master -> VALIDATION_FAILED"),
    "pdf/INV-2026-1006_acme_incorrect-totals.pdf": invoice(
        "INV-2026-1006", "V-1001", "PO-2026-0008", "2026-10-01", "Net 30", "2026-10-31",
        [("NTB-A5-DOT", "A5 Dotted Notebook", 100, 3.00)], 0.08, subtotal_override=350.00,
        scenario="Line items sum to 300.00 but subtotal says 350.00 -> MANUAL_REVIEW"),
    "pdf/INV-2026-1007_acme_missing-fields.pdf": invoice(
        "INV-2026-1007", "V-1001", "PO-2026-0008", "2026-10-02", "Net 30", "2026-11-01",
        [("NTB-A5-DOT", "A5 Dotted Notebook", 20, 3.00)], 0.08,
        omit=("invoice_number", "total_amount"),
        scenario="No invoice number and no total -> VALIDATION_FAILED"),
    "pdf/ERPFAIL-2026-0001_acme_erp-failure.pdf": invoice(
        "ERPFAIL-2026-0001", "V-1001", "PO-2026-0005", "2026-10-03", "Net 30", "2026-11-02",
        [("PEN-BLK-12", "Ballpoint Pens Black (box of 12)", 50, 2.00)], 0.08,
        scenario="Auto-approved, ERP returns 503 -> ERP_POSTING_FAILED -> recovery queue"),
    "pdf/ai-fail_scan_INV-2026-1011.pdf": invoice(
        "INV-2026-1011", "V-1001", "PO-2026-0008", "2026-10-04", "Net 30", "2026-11-03",
        [("NTB-A5-DOT", "A5 Dotted Notebook", 5, 3.00)], 0.08,
        scenario="Mock AI returns HTTP 500 -> EXTRACTION_FAILED -> recovery queue -> DEAD"),
    # ---- Images ----------------------------------------------------------
    "images/INV-2026-1008_acme_scan.png": invoice(
        "INV-2026-1008", "V-1001", "PO-2026-0006", "2026-10-05", "Net 30", "2026-11-04",
        [("LMP-LED-DK", "LED Desk Lamp", 10, 45.00)], 0.08,
        scenario="Clean scan (PNG) -> auto-approved -> posted to ERP"),
    "images/INV-2026-1009_acme_blurry-photo.jpg": invoice(
        "INV-2026-1009", "V-1001", "PO-2026-0008", "2026-10-06", "Net 30", "2026-11-05",
        [("NTB-A5-DOT", "A5 Dotted Notebook", 50, 3.00)], 0.08,
        scenario="Blurry phone photo (JPG) -> low confidence -> MANUAL_REVIEW"),
    # ---- JSON ------------------------------------------------------------
    "json/INV-2026-1010_stark_structured.json": invoice(
        "INV-2026-1010", "V-1005", "PO-2026-0007", "2026-10-07", "Net 30", "2026-11-06",
        [("CNC-SHAFT-8", "CNC Machined Shaft 8mm", 25, 100.00)], 0.10,
        scenario="Structured JSON, 10% tax vendor -> PENDING_APPROVAL (APPROVER)"),
    "json/duplicate-of-INV-2026-1001.json": invoice(
        "inv/2026/1001", "V-1001", "PO-2026-0001", "2026-09-15", "Net 30", "2026-10-15",
        [("PAP-A4-500", "A4 Copy Paper 80gsm (box of 5 reams)", 100, 5.00),
         ("TON-HP-26X", "HP 26X Black Toner Cartridge", 10, 30.00)], 0.08,
        scenario="Same vendor + normalized number as INV-2026-1001 -> DUPLICATE (409)"),
}


# ---------------------------------------------------------------------------
# Rendering helpers
# ---------------------------------------------------------------------------
def text_lines(inv):
    """The visual text of the invoice, top to bottom: (font, size, text)."""
    omit = set(inv["omit"])
    out = [("H", 20, "INVOICE"), ("H", 11, inv["vendor_name"])]
    out.append(("H", 10, f"Vendor: {inv['vendor_name']}"))
    out.append(("H", 10, f"Vendor ID: {inv['vendor_id']}"))
    if "invoice_number" not in omit:
        out.append(("H", 10, f"Invoice Number: {inv['invoice_number']}"))
    out.append(("H", 10, f"Invoice Date: {inv['invoice_date']}"))
    out.append(("H", 10, f"PO Number: {inv['purchase_order_number']}"))
    out.append(("H", 10, f"Bill To: {inv['billing_address']}"))
    out.append(("H", 10, f"Currency: {inv['currency']}"))
    out.append(("H", 10, f"Payment Terms: {inv['payment_terms']}"))
    out.append(("H", 10, f"Due Date: {inv['due_date']}"))
    out.append(("C", 8, f"{'Line':<4}  {'Item Code':<12}  {'Description':<40}  {'Qty':>6}  {'Unit Price':>10}  {'Amount':>11}"))
    for li in inv["line_items"]:
        out.append(("C", 8, f"{li['line_number']:<4}  {li['item_code']:<12}  {li['description']:<40}  "
                            f"{li['quantity']:>6}  {money(li['unit_price']):>10}  {money(li['amount']):>11}"))
    out.append(("H", 10, f"Subtotal: {money(inv['subtotal'])}"))
    out.append(("H", 10, f"Tax ({inv['tax_rate'] * 100:g}%): {money(inv['tax'])}"))
    if "total_amount" not in omit:
        out.append(("H", 12, f"Total Due: {money(inv['total_amount'])}"))
    out.append(("H", 8, "Thank you for your business. Please quote the invoice number on remittance."))
    return out


def pdf_escape(s):
    return s.replace("\\", "\\\\").replace("(", "\\(").replace(")", "\\)")


def build_pdf(inv, compress):
    y = 790
    parts = []
    for font, size, text in text_lines(inv):
        f = "/F1" if font == "H" else "/F2"
        parts.append(f"BT {f} {size} Tf 40 {y} Td ({pdf_escape(text)}) Tj ET")
        y -= size + 9
    stream = "\n".join(parts).encode("latin-1")
    if compress:
        stream = zlib.compress(stream)
        stream_dict = f"<< /Length {len(stream)} /Filter /FlateDecode >>".encode()
    else:
        stream_dict = f"<< /Length {len(stream)} >>".encode()

    objects = [
        b"<< /Type /Catalog /Pages 2 0 R >>",
        b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 842] /Contents 4 0 R "
        b"/Resources << /Font << /F1 5 0 R /F2 6 0 R >> >> >>",
        stream_dict + b"\nstream\n" + stream + b"\nendstream",
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Courier >>",
        f"<< /Title ({pdf_escape(inv['invoice_number'])}) /Producer (generate_samples.py) >>".encode("latin-1"),
    ]
    out = bytearray(b"%PDF-1.4\n%\xe2\xe3\xcf\xd3\n")
    offsets = []
    for i, obj in enumerate(objects, start=1):
        offsets.append(len(out))
        out += f"{i} 0 obj\n".encode() + obj + b"\nendobj\n"
    xref = len(out)
    out += f"xref\n0 {len(objects) + 1}\n0000000000 65535 f \n".encode()
    for off in offsets:
        out += f"{off:010d} 00000 n \n".encode()
    out += (f"trailer\n<< /Size {len(objects) + 1} /Root 1 0 R /Info {len(objects)} 0 R >>\n"
            f"startxref\n{xref}\n%%EOF\n").encode()
    return bytes(out)


def build_image(inv, path, blurry):
    from PIL import Image, ImageDraw, ImageFilter, ImageFont

    def font(size, mono=False):
        candidates = (["consola.ttf", "cour.ttf", "DejaVuSansMono.ttf"] if mono
                      else ["arial.ttf", "DejaVuSans.ttf", "LiberationSans-Regular.ttf"])
        for name in candidates:
            try:
                return ImageFont.truetype(name, size)
            except OSError:
                continue
        return ImageFont.load_default()

    img = Image.new("RGB", (1240, 1754), (252, 252, 248))
    draw = ImageDraw.Draw(img)
    y = 60
    for kind, size, text in text_lines(inv):
        f = font(int(size * 2.2), mono=(kind == "C"))
        draw.text((70, y), text, fill=(25, 25, 25), font=f)
        y += int(size * 2.2) + 18
    rnd = random.Random(inv["invoice_number"])
    for _ in range(2500):  # paper noise
        x, yy = rnd.randrange(img.width), rnd.randrange(img.height)
        draw.point((x, yy), fill=(200, 200, 195))
    if blurry:
        img = img.rotate(1.8, expand=False, fillcolor=(235, 235, 230)).filter(ImageFilter.GaussianBlur(2.2))
        img = img.resize((620, 877))
        img.save(path, "JPEG", quality=55)
    else:
        img.save(path, "PNG", optimize=True)


def supplier_json(inv):
    keys = ["invoice_number", "invoice_date", "vendor_name", "vendor_id", "purchase_order_number",
            "billing_address", "currency", "line_items", "subtotal", "tax_rate", "tax",
            "total_amount", "payment_terms", "due_date"]
    return {k: inv[k] for k in keys}


def main():
    for sub in ("pdf", "images", "json", "invalid"):
        (OUT / sub).mkdir(parents=True, exist_ok=True)
    FIXTURES.parent.mkdir(parents=True, exist_ok=True)
    fixtures = {"bySha256": {}, "byFileName": {}}
    manifest = []
    try:
        import PIL  # noqa: F401
        have_pil = True
    except ImportError:
        have_pil = False
        print("WARNING: Pillow not installed - image samples skipped (pip install pillow)")

    for i, (rel, inv) in enumerate(SAMPLES.items()):
        path = OUT / rel
        if rel.startswith("pdf/"):
            path.write_bytes(build_pdf(inv, compress=(i % 2 == 1)))
        elif rel.startswith("images/"):
            if not have_pil:
                continue
            blurry = "blurry" in rel
            build_image(inv, path, blurry)
            fields = supplier_json(inv)
            fields["line_items"] = [
                {"line_number": li["line_number"], "item_code": li["item_code"], "description": li["description"],
                 "quantity": str(li["quantity"]), "unit_price": money(li["unit_price"]), "amount": money(li["amount"])}
                for li in inv["line_items"]]
            for k in ("subtotal", "tax", "total_amount"):
                fields[k] = money(fields[k])
            fixture = {"fields": fields, "degraded": blurry,
                       "warnings": ["IMAGE_QUALITY_LOW: blur and skew detected"] if blurry else []}
            fixtures["bySha256"][hashlib.sha256(path.read_bytes()).hexdigest()] = fixture
            fixtures["byFileName"][path.name] = fixture
        elif rel.startswith("json/"):
            path.write_text(json.dumps(supplier_json(inv), indent=2) + "\n", encoding="utf-8")
        manifest.append({"file": rel, "invoiceNumber": inv["invoice_number"], "scenario": inv["scenario"],
                         "total": None if "total_amount" in inv["omit"] else inv["total_amount"]})
        print("generated", rel)

    if have_pil:
        from PIL import Image, ImageDraw
        img = Image.new("RGB", (800, 600), (240, 238, 230))
        d = ImageDraw.Draw(img)
        rnd = random.Random(42)
        for _ in range(400):
            x, y = rnd.randrange(800), rnd.randrange(600)
            d.line((x, y, x + rnd.randrange(-40, 40), y + rnd.randrange(-8, 8)), fill=(90, 90, 110), width=2)
        p = OUT / "images" / "unreadable-receipt.png"
        img.save(p, "PNG")
        manifest.append({"file": "images/unreadable-receipt.png", "invoiceNumber": None,
                         "scenario": "Unrecognised image -> very low confidence -> MANUAL_REVIEW", "total": None})
        print("generated images/unreadable-receipt.png")

    (OUT / "invalid" / "not-an-invoice.txt").write_text("This is a plain text file, not an invoice.\n", encoding="utf-8")
    (OUT / "invalid" / "renamed-text-file.pdf").write_text("Plain text pretending to be a PDF.\n", encoding="utf-8")
    manifest += [
        {"file": "invalid/not-an-invoice.txt", "invoiceNumber": None, "scenario": "Unsupported extension -> 415", "total": None},
        {"file": "invalid/renamed-text-file.pdf", "invoiceNumber": None,
         "scenario": "Extension says PDF but magic bytes do not -> 415", "total": None},
    ]
    FIXTURES.write_text(json.dumps(fixtures, indent=2) + "\n", encoding="utf-8")
    (OUT / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print("wrote", FIXTURES.relative_to(ROOT), "and sample-invoices/manifest.json")


if __name__ == "__main__":
    main()
