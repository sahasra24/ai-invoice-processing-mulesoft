#!/usr/bin/env python3
"""
Generates the illustrations used in README.md (docs/images/).

    python tools/generate_readme_images.py

* API example cards  - request + response, values taken from the project's
                       DataWeave pipeline outputs (sample-invoices/expected)
* Flow diagrams      - the main Mule flows as laid out in Anypoint Studio
* Approval routing   - threshold ladder from config/local.yaml
* Sample invoice     - preview of sample-invoices/images/INV-2026-1008_acme_scan.png
                       (needs Pillow; skipped otherwise)
"""
import json
from pathlib import Path
from xml.sax.saxutils import escape

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "docs" / "images"
EXPECTED = ROOT / "sample-invoices" / "expected"

FONT_MONO = "Consolas, 'SFMono-Regular', Menlo, monospace"
FONT_SANS = "'Segoe UI', Helvetica, Arial, sans-serif"


# ---------------------------------------------------------------------------
# Terminal-style API example cards
# ---------------------------------------------------------------------------
def color_json_line(line):
    """Very small JSON syntax colouring for one pretty-printed line."""
    stripped = line.lstrip()
    indent = len(line) - len(stripped)
    pad = "&#160;" * indent
    if stripped.startswith('"') and '":' in stripped:
        key, rest = stripped.split('":', 1)
        val = rest.strip()
        if val.startswith('"'):
            vcol = "#a5d6a7"
        elif val[:1].isdigit() or val[:1] == "-":
            vcol = "#ffcc80"
        elif val.startswith(("true", "false", "null")):
            vcol = "#ce93d8"
        else:
            vcol = "#e0e0e0"
        return (f'{pad}<tspan fill="#81d4fa">{escape(key)}"</tspan><tspan fill="#e0e0e0">:</tspan> '
                f'<tspan fill="{vcol}">{escape(val)}</tspan>')
    return f'{pad}<tspan fill="#e0e0e0">{escape(stripped)}</tspan>'


def terminal_card(path, title, command_lines, status_line, body, caption):
    body_lines = json.dumps(body, indent=2).splitlines()
    line_h = 19
    top = 74
    cmd_h = len(command_lines) * line_h
    height = top + cmd_h + 18 + line_h + 10 + len(body_lines) * line_h + 56
    width = 860
    out = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}">',
           f'<rect width="{width}" height="{height}" rx="12" fill="#1e1e2e"/>',
           f'<rect width="{width}" height="40" rx="12" fill="#2b2b3c"/><rect y="28" width="{width}" height="12" fill="#2b2b3c"/>',
           '<circle cx="22" cy="20" r="6" fill="#ff5f57"/><circle cx="42" cy="20" r="6" fill="#febc2e"/><circle cx="62" cy="20" r="6" fill="#28c840"/>',
           f'<text x="{width / 2}" y="25" text-anchor="middle" font-family="{FONT_SANS}" font-size="13" fill="#bdbdcf">{escape(title)}</text>']
    y = top
    for i, cl in enumerate(command_lines):
        prefix = '<tspan fill="#28c840">PS&gt; </tspan>' if i == 0 else '<tspan fill="#28c840">&#160;&#160;&#160;&#160;</tspan>'
        out.append(f'<text x="22" y="{y}" font-family="{FONT_MONO}" font-size="14" fill="#ffffff">{prefix}{escape(cl)}</text>')
        y += line_h
    y += 18
    out.append(f'<text x="22" y="{y}" font-family="{FONT_MONO}" font-size="14" fill="#ffd54f">{escape(status_line)}</text>')
    y += line_h + 10
    for bl in body_lines:
        out.append(f'<text x="22" y="{y}" font-family="{FONT_MONO}" font-size="14" xml:space="preserve">{color_json_line(bl)}</text>')
        y += line_h
    out.append(f'<text x="22" y="{height - 22}" font-family="{FONT_SANS}" font-size="12" fill="#8a8aa3">{escape(caption)}</text>')
    out.append('</svg>')
    path.write_text("\n".join(out) + "\n", encoding="utf-8")


def api_cards():
    auto = json.loads((EXPECTED / "INV-2026-1001_acme_auto-approve.expected.json").read_text())
    inv = auto["canonicalInvoice"]
    terminal_card(
        OUT / "api-upload-auto-approved.svg",
        "Upload a PDF invoice - auto-approved and posted to the ERP",
        ['curl -u supplier1:Supplier#2026 \\',
         '-F "file=@sample-invoices/pdf/INV-2026-1001_acme_auto-approve.pdf" \\',
         'http://localhost:8081/api/invoices/upload'],
        "HTTP/1.1 201 Created   X-Correlation-ID: 4b0c3c6e-9a3e-4a7e-bb0e-1c0c7e5f3a11",
        {
            "invoiceId": "0b5e3f7a-6c1d-4f7e-9a52-2b8e4b1d9c10",
            "invoiceNumber": inv["invoiceNumber"],
            "status": "POSTED_TO_ERP",
            "vendorId": inv["vendor"]["id"],
            "vendorName": inv["vendor"]["name"],
            "poNumber": inv["poNumber"],
            "totalAmount": inv["total"],
            "extractionConfidence": inv["extraction"]["overallConfidence"],
            "decisionReason": auto["routingDecision"]["decisionReason"],
            "exceptions": [],
            "erp": {"documentNumber": "5100000001", "postedAt": "2026-10-14T09:00:06Z"},
        },
        "Example response. Business values come from the DataWeave pipeline run on sample INV-2026-1001 (sample-invoices/expected).")

    bad = json.loads((EXPECTED / "INV-2026-1005_unknown-vendor.expected.json").read_text())
    rd = bad["routingDecision"]
    terminal_card(
        OUT / "api-upload-validation-failed.svg",
        "Unknown vendor - stored but rejected with 422",
        ['curl -u supplier1:Supplier#2026 \\',
         '-F "file=@sample-invoices/pdf/INV-2026-1005_unknown-vendor.pdf" \\',
         'http://localhost:8081/api/invoices/upload'],
        "HTTP/1.1 422 Unprocessable Entity",
        {
            "invoiceNumber": bad["canonicalInvoice"]["invoiceNumber"],
            "status": rd["status"],
            "decisionReason": rd["decisionReason"],
            "validationErrors": [{k: v for k, v in e.items() if k != "details"} for e in rd["validationErrors"]],
            "exceptions": rd["exceptions"],
        },
        "Example response. Values come from the DataWeave pipeline run on sample INV-2026-1005 (sample-invoices/expected).")

    two = json.loads((EXPECTED / "INV-2026-1003_initech_two-level-approval.expected.json").read_text())
    terminal_card(
        OUT / "api-approve-first-level.svg",
        "Two-level approval - manager approves step 1 of 2",
        ['curl -u manager1:Manager#2026 -X POST \\',
         '-H "Content-Type: application/json" -d \'{"comments":"Services delivered"}\' \\',
         'http://localhost:8081/api/invoices/7d3e8f00-1c2b-4d6e-8f90-a1b2c3d4e5f6/approve'],
        "HTTP/1.1 200 OK",
        {
            "invoiceNumber": two["canonicalInvoice"]["invoiceNumber"],
            "decision": "APPROVED",
            "approvalLevel": two["routingDecision"]["approvalChain"][0],
            "decidedBy": "manager1",
            "status": "PENDING_APPROVAL",
            "approvalsReceived": 1,
            "approvalsRequired": len(two["routingDecision"]["approvalChain"]),
            "nextApprovalLevel": two["routingDecision"]["approvalChain"][1],
        },
        "Example response. The approval chain (MANAGER -> FINANCE_DIRECTOR for 64,800.00) is the routing result for sample INV-2026-1003.")


# ---------------------------------------------------------------------------
# Flow diagram in the style of the Anypoint Studio canvas
# ---------------------------------------------------------------------------
COLORS = {
    "source": ("#e3f2fd", "#1e88e5"), "transform": ("#f3e5f5", "#8e24aa"), "http": ("#e8f5e9", "#43a047"),
    "router": ("#fff8e1", "#f9a825"), "scope": ("#fbe9e7", "#e64a19"), "ref": ("#eceff1", "#546e7a"),
    "db": ("#e0f7fa", "#00838f"), "validation": ("#fce4ec", "#d81b60"),
}
GLYPH = {"source": "&#9654;", "transform": "DW", "http": "&#8644;", "router": "&#9670;", "scope": "{ }",
         "ref": "&#8618;", "db": "DB", "validation": "&#10003;"}


def component(x, y, kind, label, sub=""):
    fill, stroke = COLORS[kind]
    parts = [f'<rect x="{x}" y="{y}" width="118" height="78" rx="8" fill="#ffffff" stroke="#cfd8dc"/>',
             f'<rect x="{x + 39}" y="{y + 8}" width="40" height="32" rx="6" fill="{fill}" stroke="{stroke}"/>',
             f'<text x="{x + 59}" y="{y + 29}" text-anchor="middle" font-family="{FONT_SANS}" font-size="12" font-weight="700" fill="{stroke}">{GLYPH[kind]}</text>',
             f'<text x="{x + 59}" y="{y + 56}" text-anchor="middle" font-family="{FONT_SANS}" font-size="11" fill="#263238">{escape(label)}</text>']
    if sub:
        parts.append(f'<text x="{x + 59}" y="{y + 70}" text-anchor="middle" font-family="{FONT_SANS}" font-size="9.5" fill="#78909c">{escape(sub)}</text>')
    return "\n".join(parts)


def flow_row(x0, y, items):
    parts = []
    x = x0
    for i, (kind, label, sub) in enumerate(items):
        parts.append(component(x, y, kind, label, sub))
        if i < len(items) - 1:
            parts.append(f'<path d="M{x + 118},{y + 39} L{x + 134},{y + 39}" stroke="#90a4ae" stroke-width="1.6" marker-end="url(#arr)"/>')
        x += 136
    return "\n".join(parts)


def flow_box(y, height, name, subtitle):
    return (f'<rect x="20" y="{y}" width="1100" height="{height}" rx="6" fill="#fafcfd" stroke="#b0bec5"/>'
            f'<rect x="20" y="{y}" width="1100" height="30" rx="6" fill="#eef3f6"/><rect x="20" y="{y + 24}" width="1100" height="6" fill="#eef3f6"/>'
            f'<text x="34" y="{y + 20}" font-family="{FONT_SANS}" font-size="13" font-weight="700" fill="#37474f">{escape(name)}</text>'
            f'<text x="1106" y="{y + 20}" text-anchor="end" font-family="{FONT_SANS}" font-size="11" fill="#78909c">{escape(subtitle)}</text>')


def flow_diagram():
    w, h = 1140, 660
    parts = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {w} {h}">',
             '<defs><marker id="arr" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="6" markerHeight="6" orient="auto"><path d="M0,0 L10,5 L0,10 z" fill="#90a4ae"/></marker></defs>',
             f'<rect width="{w}" height="{h}" fill="#ffffff"/>',
             f'<text x="20" y="30" font-family="{FONT_SANS}" font-size="17" font-weight="700" fill="#263238">invoice-process-api - invoice processing flows</text>',
             f'<text x="20" y="50" font-family="{FONT_SANS}" font-size="12" fill="#78909c">Diagram of src/main/mule/process-invoice.xml (component names match doc:name in the XML)</text>']
    parts.append(flow_box(66, 130, "process-create-invoice-flow", "HTTP POST /process/v1/invoices"))
    parts.append(flow_row(34, 106, [
        ("source", "Listener", "POST /invoices"), ("ref", "Authenticate", "client credentials"),
        ("ref", "Init context", "vars.config"), ("validation", "Is true", "document complete"),
        ("http", "SYS - Create", "invoice + file"), ("router", "Replay?", "SHA-256 idempotency"),
        ("ref", "Process invoice", "orchestration"), ("transform", "Build result", "processing-result")]))
    parts.append(flow_box(214, 420, "validate-and-route-sub-flow", "business workflow steps 4 - 12"))
    parts.append(flow_row(34, 254, [
        ("ref", "AI extraction", "until-successful"), ("transform", "Normalize", "normalize-ai-response"),
        ("validation", "Validate schema", "canonical JSON"), ("transform", "Validate fields", "+ confidence"),
        ("http", "SYS - Save", "extraction"), ("http", "SYS - Get vendor", "200 / 404"),
        ("transform", "Verify vendor", "vendor-verification"), ("http", "SYS - Duplicates", "invoice-duplicates")]))
    parts.append(f'<path d="M1070,332 C1100,360 1100,370 1070,380 L100,380 C70,385 70,395 93,405" fill="none" stroke="#90a4ae" stroke-width="1.6" marker-end="url(#arr)"/>')
    parts.append(flow_row(34, 410, [
        ("transform", "Check duplicates", "duplicate-detection"), ("http", "SYS - Get PO", "purchase order"),
        ("transform", "Match PO + totals", "po-matching"), ("transform", "Validate tax", "tax-validation"),
        ("transform", "Route approval", "approval-routing"), ("scope", "Try", "persist decision"),
        ("router", "Auto-approved?", "total <= 1,000"), ("ref", "Post to ERP", "erp-posting")]))
    legend = [("source", "Event source"), ("ref", "Flow reference"), ("transform", "Transform Message (DataWeave)"),
              ("http", "HTTP Request"), ("router", "Choice router"), ("scope", "Try scope"), ("validation", "Validation / JSON")]
    x = 34
    for kind, label in legend:
        fill, stroke = COLORS[kind]
        parts.append(f'<rect x="{x}" y="560" width="14" height="14" rx="3" fill="{fill}" stroke="{stroke}"/>'
                     f'<text x="{x + 20}" y="572" font-family="{FONT_SANS}" font-size="11" fill="#546e7a">{escape(label)}</text>')
        x += 20 + len(label) * 6.2 + 22
    parts.append(f'<text x="34" y="605" font-family="{FONT_SANS}" font-size="11.5" fill="#546e7a">Errors: AI failures are queued for automatic retry (EXTRACTION_FAILED); ERP failures are queued (ERP_POSTING_FAILED);</text>')
    parts.append(f'<text x="34" y="622" font-family="{FONT_SANS}" font-size="11.5" fill="#546e7a">a concurrent duplicate caught by the database unique key becomes DUPLICATE; everything else goes to the global error handler.</text>')
    parts.append('</svg>')
    (OUT / "flow-process-invoice.svg").write_text("\n".join(parts) + "\n", encoding="utf-8")


# ---------------------------------------------------------------------------
# Approval routing ladder
# ---------------------------------------------------------------------------
def routing_diagram():
    w, h = 1000, 400
    rows = [
        ("DUPLICATE", "Exact duplicate (same vendor + normalized invoice number)", "#eceff1", "#546e7a", "409"),
        ("VALIDATION_FAILED", "Blocking error on a reliable extraction (missing fields, unknown vendor)", "#ffebee", "#c62828", "422"),
        ("MANUAL_REVIEW", "Low AI confidence, PO / price / total / tax exceptions -> MANAGER (FINANCE_DIRECTOR > 50k)", "#fff8e1", "#ef6c00", "201"),
        ("AUTO-APPROVED", "Total <= 1,000 and all checks passed -> posted to the ERP automatically", "#e8f5e9", "#2e7d32", "201"),
        ("APPROVER", "1,000 < total <= 10,000", "#e3f2fd", "#1565c0", "201"),
        ("MANAGER", "10,000 < total <= 50,000", "#e8eaf6", "#3949ab", "201"),
        ("MANAGER > FINANCE_DIRECTOR", "Total > 50,000 (two-level approval)", "#f3e5f5", "#6a1b9a", "201"),
    ]
    parts = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {w} {h}">',
             f'<rect width="{w}" height="{h}" fill="#ffffff"/>',
             f'<text x="24" y="32" font-family="{FONT_SANS}" font-size="17" font-weight="700" fill="#263238">Invoice routing (approval-routing.dwl) - evaluated top to bottom</text>']
    y = 54
    for name, desc, fill, stroke, code in rows:
        parts.append(f'<rect x="24" y="{y}" width="952" height="40" rx="8" fill="{fill}" stroke="{stroke}" stroke-opacity="0.45"/>')
        parts.append(f'<text x="40" y="{y + 25}" font-family="{FONT_SANS}" font-size="13.5" font-weight="700" fill="{stroke}">{escape(name)}</text>')
        parts.append(f'<text x="300" y="{y + 25}" font-family="{FONT_SANS}" font-size="13" fill="#37474f">{escape(desc)}</text>')
        parts.append(f'<text x="960" y="{y + 25}" text-anchor="end" font-family="{FONT_MONO}" font-size="12" fill="#78909c">HTTP {code}</text>')
        y += 46
    parts.append(f'<text x="24" y="{y + 18}" font-family="{FONT_SANS}" font-size="11.5" fill="#78909c">Thresholds and tolerances are configurable in invoice-process-api/src/main/resources/config/*.yaml (approval.*, validation.*).</text>')
    parts.append('</svg>')
    (OUT / "approval-routing.svg").write_text("\n".join(parts) + "\n", encoding="utf-8")


def sample_invoice_preview():
    try:
        from PIL import Image
    except ImportError:
        print("Pillow not installed - skipping sample invoice preview")
        return
    src = ROOT / "sample-invoices" / "images" / "INV-2026-1008_acme_scan.png"
    img = Image.open(src).convert("RGB")
    img = img.crop((0, 0, int(img.width * 0.8), int(img.height * 0.44)))
    img.thumbnail((720, 720))
    img.save(OUT / "sample-invoice-scan.png", optimize=True)


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    api_cards()
    flow_diagram()
    routing_diagram()
    sample_invoice_preview()
    for p in sorted(OUT.iterdir()):
        print("wrote", p.relative_to(ROOT))


if __name__ == "__main__":
    main()
