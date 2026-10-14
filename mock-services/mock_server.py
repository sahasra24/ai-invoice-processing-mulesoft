#!/usr/bin/env python3
"""
Mock external services for the AI Invoice Processing demo.

Runs two simulated third-party systems on one port (default 8090) using only
the Python standard library (Python 3.9+):

  1. Mock AI Document Extraction service   POST /ai/v1/extract
     - PDF  : real text extraction from text-based PDFs (uncompressed or
              FlateDecode streams) followed by label/regex field parsing.
     - Image: simulated OCR. Known sample images are resolved from
              fixtures/image-fixtures.json (by SHA-256 or file name);
              unknown images return a low-confidence partial result.
     - JSON : structured supplier invoice, echoed with confidence 1.0.
     - File names containing "ai-fail" -> HTTP 500, "ai-unavailable" -> 503
       (deterministic failure simulation for testing).

  2. Mock ERP (Accounts Payable) API        POST /erp/v1/ap-invoices (XML)
     - Basic auth, XML request/response, idempotent on ExternalReference.
     - Invoice numbers starting with "ERPFAIL" fail the first
       ERP_FAIL_ATTEMPTS calls with 503, then succeed (to demonstrate the
       recovery queue + exponential backoff).
     - POST /erp/v1/admin/failure-mode {"mode":"DOWN"|"NORMAL"} simulates
       a full outage.

Usage:
    python mock_server.py                 # port 8090
    MOCK_PORT=9090 python mock_server.py

Environment variables (all optional, local defaults shown):
    MOCK_PORT=8090
    MOCK_AI_API_KEY=mock-ai-key-local
    ERP_USERNAME=erp_integration
    ERP_PASSWORD=erp-local-pass
    ERP_FAIL_ATTEMPTS=3
"""
import base64
import hashlib
import json
import logging
import os
import re
import threading
import time
import uuid
import zlib
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from xml.etree import ElementTree as ET

PORT = int(os.environ.get("MOCK_PORT", "8090"))
AI_API_KEY = os.environ.get("MOCK_AI_API_KEY", "mock-ai-key-local")
ERP_USERNAME = os.environ.get("ERP_USERNAME", "erp_integration")
ERP_PASSWORD = os.environ.get("ERP_PASSWORD", "erp-local-pass")
ERP_FAIL_ATTEMPTS = int(os.environ.get("ERP_FAIL_ATTEMPTS", "3"))
MAX_BODY_BYTES = 15 * 1024 * 1024
ERP_NS = "urn:example:erp:ap:v1"
FIXTURES_FILE = Path(__file__).parent / "fixtures" / "image-fixtures.json"

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s [mock] %(message)s")
log = logging.getLogger("mock")

# ---------------------------------------------------------------------------
# Shared in-memory state (guarded by a lock, server is multi-threaded)
# ---------------------------------------------------------------------------
_state_lock = threading.Lock()
_state = {
    "erp_mode": "NORMAL",          # NORMAL | DOWN
    "erp_postings": {},            # externalReference -> posting
    "erp_fail_counter": {},        # invoiceNumber -> attempts so far
    "erp_next_doc": 5100000001,
}


def reset_state():
    with _state_lock:
        _state["erp_mode"] = "NORMAL"
        _state["erp_postings"].clear()
        _state["erp_fail_counter"].clear()
        _state["erp_next_doc"] = 5100000001


# ---------------------------------------------------------------------------
# PDF text extraction (no third-party libraries)
# ---------------------------------------------------------------------------
_STREAM_RE = re.compile(rb"<<(.*?)>>\s*stream\r?\n(.*?)\r?\nendstream", re.DOTALL)
_BT_ET_RE = re.compile(rb"BT(.*?)ET", re.DOTALL)
_STRING_RE = re.compile(rb"\((?:\\.|[^\\)])*\)")


def _unescape_pdf_string(raw: bytes) -> str:
    s = raw[1:-1]
    out = bytearray()
    i = 0
    escapes = {b"n": b"\n", b"r": b"\r", b"t": b"\t", b"b": b"\b", b"f": b"\f",
               b"(": b"(", b")": b")", b"\\": b"\\"}
    while i < len(s):
        c = s[i:i + 1]
        if c == b"\\" and i + 1 < len(s):
            nxt = s[i + 1:i + 2]
            if nxt in escapes:
                out += escapes[nxt]
                i += 2
                continue
            m = re.match(rb"[0-7]{1,3}", s[i + 1:i + 4])
            if m:
                out.append(int(m.group(0), 8) & 0xFF)
                i += 1 + len(m.group(0))
                continue
            i += 1
            continue
        out += c
        i += 1
    return out.decode("latin-1")


def extract_pdf_text(pdf_bytes: bytes) -> list:
    """Return the text lines of a simple text-based PDF, in content order."""
    if not pdf_bytes.startswith(b"%PDF"):
        raise ValueError("Not a PDF document")
    lines = []
    for dict_bytes, data in _STREAM_RE.findall(pdf_bytes):
        if b"FlateDecode" in dict_bytes:
            try:
                data = zlib.decompress(data)
            except zlib.error:
                continue
        if b"BT" not in data:
            continue
        for block in _BT_ET_RE.findall(data):
            text = "".join(_unescape_pdf_string(m) for m in _STRING_RE.findall(block))
            if text.strip():
                lines.append(text.rstrip())
    return lines


# ---------------------------------------------------------------------------
# Field parsing ("AI" extraction over OCR/text lines)
# ---------------------------------------------------------------------------
FIELD_PATTERNS = {
    "invoice_number": r"^invoice\s*(?:number|no\.?|#)\s*[:#]?\s*(\S+)",
    "invoice_date": r"^invoice\s*date\s*:\s*(.+)$",
    "due_date": r"^due\s*date\s*:\s*(.+)$",
    "vendor_name": r"^(?:vendor|supplier|from)\s*:\s*(.+)$",
    "vendor_id": r"^(?:vendor|supplier)\s*(?:id|code|no\.?)\s*:\s*(\S+)",
    "purchase_order_number": r"^(?:po|purchase\s*order)\s*(?:number|no\.?|#)?\s*:\s*(\S+)",
    "billing_address": r"^bill\s*to\s*:\s*(.+)$",
    "currency": r"^currency\s*:\s*(\S+)",
    "payment_terms": r"^(?:payment\s*)?terms\s*:\s*(.+)$",
    "subtotal": r"^sub\s*-?\s*total\s*:\s*(.+)$",
    "total_amount": r"^(?:total\s*due|total\s*amount|amount\s*due|grand\s*total|total)\s*:\s*(.+)$",
}
TAX_PATTERN = r"^(?:tax|vat|gst|sales\s*tax)\s*(?:\(\s*(\d+(?:\.\d+)?)\s*%\s*\))?\s*:\s*(.+)$"
LINE_HEADER_PATTERN = r"^\s*(?:line|#)\s{2,}.*description"


def _stable_confidence(key: str, value, base: float = 0.95, spread: float = 0.04) -> float:
    """Deterministic pseudo-confidence so test expectations are repeatable."""
    if value in (None, "", []):
        return 0.0
    h = int(hashlib.md5(f"{key}:{value}".encode()).hexdigest()[:6], 16) / 0xFFFFFF
    return round(base + spread * h, 2)


def parse_invoice_lines(lines: list) -> dict:
    fields = {k: None for k in FIELD_PATTERNS}
    fields["tax"] = None
    fields["tax_rate"] = None
    line_items = []
    in_table = False
    for raw in lines:
        line = raw.strip()
        if re.match(LINE_HEADER_PATTERN, line, re.IGNORECASE):
            in_table = True
            continue
        if in_table:
            if re.match(r"^sub\s*-?\s*total", line, re.IGNORECASE) or not line:
                in_table = False
            else:
                cols = re.split(r"\s{2,}", line)
                if len(cols) >= 6 and cols[0].isdigit():
                    line_items.append({
                        "line_number": int(cols[0]),
                        "item_code": cols[1],
                        "description": " ".join(cols[2:-3]),
                        "quantity": cols[-3],
                        "unit_price": cols[-2],
                        "amount": cols[-1],
                    })
                    continue
                if len(cols) >= 5 and cols[0].isdigit():
                    line_items.append({
                        "line_number": int(cols[0]), "item_code": None,
                        "description": " ".join(cols[1:-3]), "quantity": cols[-3],
                        "unit_price": cols[-2], "amount": cols[-1],
                    })
                    continue
        tax_match = re.match(TAX_PATTERN, line, re.IGNORECASE)
        if tax_match and fields["tax"] is None:
            if tax_match.group(1):
                fields["tax_rate"] = round(float(tax_match.group(1)) / 100.0, 4)
            fields["tax"] = tax_match.group(2).strip()
            continue
        for key, pattern in FIELD_PATTERNS.items():
            if fields[key] is not None:
                continue
            m = re.match(pattern, line, re.IGNORECASE)
            if m:
                fields[key] = m.group(1).strip()
                break
    fields["line_items"] = line_items
    return fields


def build_extraction(fields: dict, file_name: str, degraded: bool = False) -> dict:
    confidence = {}
    for key, value in fields.items():
        if key in ("line_items", "tax_rate"):
            continue
        confidence[key] = _stable_confidence(key, value)
    confidence["line_items"] = 0.0 if not fields.get("line_items") else _stable_confidence(
        "line_items", json.dumps(fields["line_items"], sort_keys=True), base=0.93)
    if degraded:
        for key in ("invoice_number", "total_amount", "subtotal", "tax", "line_items", "invoice_date"):
            if confidence.get(key):
                confidence[key] = round(confidence[key] - 0.33, 2)
    key_fields = ["invoice_number", "invoice_date", "vendor_name", "total_amount", "line_items"]
    present = [confidence[k] for k in key_fields if confidence.get(k)]
    completeness = len(present) / len(key_fields)
    overall = round((sum(present) / len(present)) * completeness, 4) if present else 0.0
    extraction = dict(fields)
    extraction["field_confidence"] = confidence
    extraction["overall_confidence"] = overall
    return extraction


def load_image_fixtures() -> dict:
    if FIXTURES_FILE.exists():
        try:
            return json.loads(FIXTURES_FILE.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            log.warning("Could not read image fixtures file")
    return {"bySha256": {}, "byFileName": {}}


def extract_document(file_name: str, mime_type: str, content: bytes) -> dict:
    name_lower = (file_name or "").lower()
    degraded = "lowconf" in name_lower or "blurry" in name_lower
    if mime_type == "application/pdf":
        lines = extract_pdf_text(content)
        if not lines:
            fields = parse_invoice_lines([])
            return {"pages": 1, "extraction": build_extraction(fields, file_name, degraded=True),
                    "warnings": ["NO_TEXT_LAYER: scanned PDF without text layer, OCR quality low"]}
        fields = parse_invoice_lines(lines)
        return {"pages": max(1, content.count(b"/Type /Page") - content.count(b"/Type /Pages")),
                "extraction": build_extraction(fields, file_name, degraded), "warnings": []}
    if mime_type in ("image/png", "image/jpeg"):
        fixtures = load_image_fixtures()
        digest = hashlib.sha256(content).hexdigest()
        stem = Path(file_name or "").name
        fixture = fixtures.get("bySha256", {}).get(digest) or fixtures.get("byFileName", {}).get(stem)
        if fixture:
            fields = dict(fixture["fields"])
            return {"pages": 1, "extraction": build_extraction(fields, file_name, fixture.get("degraded", degraded)),
                    "warnings": fixture.get("warnings", [])}
        fields = parse_invoice_lines([])
        extraction = build_extraction(fields, file_name, degraded=True)
        return {"pages": 1, "extraction": extraction,
                "warnings": ["UNRECOGNISED_IMAGE: simulated OCR could not read this image; manual review required"]}
    if mime_type == "application/json":
        data = json.loads(content.decode("utf-8"))
        fields = {k: data.get(k) for k in list(FIELD_PATTERNS) + ["tax", "tax_rate", "line_items"]}
        extraction = dict(fields)
        extraction["field_confidence"] = {k: (1.0 if v not in (None, "", []) else 0.0)
                                          for k, v in fields.items() if k != "tax_rate"}
        extraction["overall_confidence"] = 1.0
        return {"pages": 1, "extraction": extraction, "warnings": []}
    raise ValueError(f"Unsupported mimeType '{mime_type}'")


# ---------------------------------------------------------------------------
# ERP simulation
# ---------------------------------------------------------------------------
def _erp_text(root, path):
    el = root.find(path, {"e": ERP_NS})
    return el.text.strip() if el is not None and el.text else None


def erp_error_xml(code: str, message: str) -> str:
    return (f'<?xml version="1.0" encoding="UTF-8"?>'
            f'<ErrorResponse xmlns="{ERP_NS}"><Code>{code}</Code><Message>{message}</Message></ErrorResponse>')


def post_ap_invoice(xml_bytes: bytes):
    """Returns (http_status, xml_body)."""
    try:
        root = ET.fromstring(xml_bytes)
    except ET.ParseError as exc:
        return 400, erp_error_xml("MALFORMED_XML", f"Request is not well-formed XML: {exc}")
    if root.tag != f"{{{ERP_NS}}}APInvoice":
        return 400, erp_error_xml("INVALID_DOCUMENT", "Root element must be APInvoice in namespace " + ERP_NS)

    ext_ref = _erp_text(root, "e:Header/e:ExternalReference")
    inv_no = _erp_text(root, "e:Header/e:InvoiceNumber")
    vendor = _erp_text(root, "e:Header/e:VendorCode")
    gross = _erp_text(root, "e:Header/e:Amounts/e:Gross")
    missing = [n for n, v in (("ExternalReference", ext_ref), ("InvoiceNumber", inv_no),
                              ("VendorCode", vendor), ("Gross", gross)) if not v]
    if missing:
        return 400, erp_error_xml("VALIDATION_ERROR", "Missing required elements: " + ", ".join(missing))
    lines = root.findall("e:Lines/e:Line", {"e": ERP_NS})
    if not lines:
        return 400, erp_error_xml("VALIDATION_ERROR", "At least one Line is required")

    with _state_lock:
        if _state["erp_mode"] == "DOWN":
            return 503, erp_error_xml("ERP_UNAVAILABLE", "ERP is in maintenance mode")
        if inv_no.upper().startswith("ERPFAIL"):
            attempts = _state["erp_fail_counter"].get(inv_no, 0) + 1
            _state["erp_fail_counter"][inv_no] = attempts
            if attempts <= ERP_FAIL_ATTEMPTS:
                return 503, erp_error_xml(
                    "ERP_UNAVAILABLE",
                    f"Simulated outage for {inv_no} (attempt {attempts} of {ERP_FAIL_ATTEMPTS} failing)")
        existing = _state["erp_postings"].get(ext_ref)
        if existing:
            status = "ALREADY_POSTED"
            posting = existing
        else:
            status = "POSTED"
            posting = {
                "documentNumber": str(_state["erp_next_doc"]),
                "fiscalYear": str(datetime.now(timezone.utc).year),
                "postedAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                "invoiceNumber": inv_no, "vendorCode": vendor, "gross": gross,
                "lineCount": len(lines), "externalReference": ext_ref,
            }
            _state["erp_next_doc"] += 1
            _state["erp_postings"][ext_ref] = posting

    body = (f'<?xml version="1.0" encoding="UTF-8"?>'
            f'<APInvoiceResponse xmlns="{ERP_NS}">'
            f'<Status>{status}</Status>'
            f'<DocumentNumber>{posting["documentNumber"]}</DocumentNumber>'
            f'<FiscalYear>{posting["fiscalYear"]}</FiscalYear>'
            f'<PostedAt>{posting["postedAt"]}</PostedAt>'
            f'<ExternalReference>{ext_ref}</ExternalReference>'
            f'</APInvoiceResponse>')
    return 200, body


# ---------------------------------------------------------------------------
# HTTP layer
# ---------------------------------------------------------------------------
class Handler(BaseHTTPRequestHandler):
    server_version = "InvoiceMock/1.0"

    def log_message(self, fmt, *args):  # route through logging, never log bodies
        log.info("%s %s", self.address_string(), fmt % args)

    def _send(self, status, body, content_type="application/json"):
        data = body.encode("utf-8") if isinstance(body, str) else body
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        corr = self.headers.get("X-Correlation-ID")
        if corr:
            self.send_header("X-Correlation-ID", corr)
        self.end_headers()
        self.wfile.write(data)

    def _json(self, status, obj):
        self._send(status, json.dumps(obj), "application/json")

    def _read_body(self):
        length = int(self.headers.get("Content-Length") or 0)
        if length > MAX_BODY_BYTES:
            raise OverflowError("Request body too large")
        return self.rfile.read(length) if length else b""

    def _basic_auth_ok(self):
        header = self.headers.get("Authorization", "")
        if not header.startswith("Basic "):
            return False
        try:
            user, _, pwd = base64.b64decode(header[6:]).decode("utf-8").partition(":")
        except (ValueError, UnicodeDecodeError):
            return False
        return user == ERP_USERNAME and pwd == ERP_PASSWORD

    # ---- GET ---------------------------------------------------------------
    def do_GET(self):
        if self.path == "/health":
            return self._json(200, {"status": "UP", "services": ["ai-extraction", "erp"],
                                    "erpMode": _state["erp_mode"]})
        if self.path.startswith("/erp/v1/ap-invoices"):
            if not self._basic_auth_ok():
                return self._send(401, erp_error_xml("UNAUTHORIZED", "Invalid ERP credentials"), "application/xml")
            with _state_lock:
                return self._json(200, {"postings": list(_state["erp_postings"].values())})
        return self._json(404, {"error": "NOT_FOUND", "message": f"No route for GET {self.path}"})

    # ---- POST --------------------------------------------------------------
    def do_POST(self):
        try:
            body = self._read_body()
        except OverflowError as exc:
            return self._json(413, {"error": "PAYLOAD_TOO_LARGE", "message": str(exc)})
        if self.path == "/ai/v1/extract":
            return self._handle_extract(body)
        if self.path == "/erp/v1/ap-invoices":
            if not self._basic_auth_ok():
                return self._send(401, erp_error_xml("UNAUTHORIZED", "Invalid ERP credentials"), "application/xml")
            status, xml = post_ap_invoice(body)
            return self._send(status, xml, "application/xml")
        if self.path == "/erp/v1/admin/failure-mode":
            try:
                mode = json.loads(body or b"{}").get("mode", "NORMAL").upper()
            except ValueError:
                return self._json(400, {"error": "BAD_REQUEST", "message": "Body must be JSON"})
            if mode not in ("NORMAL", "DOWN"):
                return self._json(400, {"error": "BAD_REQUEST", "message": "mode must be NORMAL or DOWN"})
            with _state_lock:
                _state["erp_mode"] = mode
            return self._json(200, {"erpMode": mode})
        if self.path == "/admin/reset":
            reset_state()
            return self._json(200, {"reset": True})
        return self._json(404, {"error": "NOT_FOUND", "message": f"No route for POST {self.path}"})

    def _handle_extract(self, body):
        started = time.time()
        if self.headers.get("Authorization", "") != f"Bearer {AI_API_KEY}":
            return self._json(401, {"error": "UNAUTHORIZED", "message": "Missing or invalid API key"})
        try:
            req = json.loads(body or b"{}")
        except ValueError:
            return self._json(400, {"error": "BAD_REQUEST", "message": "Body must be valid JSON"})
        file_name = req.get("fileName") or "document"
        mime_type = req.get("mimeType")
        content_b64 = req.get("contentBase64")
        if not mime_type or not content_b64:
            return self._json(400, {"error": "BAD_REQUEST", "message": "mimeType and contentBase64 are required"})
        name_lower = file_name.lower()
        if "ai-fail" in name_lower:
            return self._json(500, {"error": "MODEL_ERROR", "message": "Simulated extraction model failure"})
        if "ai-unavailable" in name_lower:
            return self._json(503, {"error": "SERVICE_UNAVAILABLE", "message": "Simulated capacity issue"})
        try:
            content = base64.b64decode(content_b64, validate=True)
            result = extract_document(file_name, mime_type, content)
        except (ValueError, base64.binascii.Error) as exc:
            return self._json(422, {"error": "UNPROCESSABLE_DOCUMENT", "message": str(exc)})
        response = {
            "requestId": str(uuid.uuid4()),
            "provider": "MOCK_DOCUMENT_AI",
            "model": "mock-invoice-extractor-v1",
            "status": "SUCCEEDED",
            "pages": result["pages"],
            "warnings": result["warnings"],
            "processingTimeMs": int((time.time() - started) * 1000),
            "extraction": result["extraction"],
        }
        log.info("extraction completed mime=%s overallConfidence=%s", mime_type,
                 result["extraction"].get("overall_confidence"))
        return self._json(200, response)


def main():
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    log.info("Mock AI + ERP services listening on http://localhost:%d", PORT)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
