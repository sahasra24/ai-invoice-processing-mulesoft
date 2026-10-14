#!/usr/bin/env python3
"""
Offline DataWeave pipeline tests (no Mule runtime required).

Executes the Process API's .dwl scripts with the official DataWeave CLI, in the
same order and with the same variables the Mule orchestration flow uses, for
every sample invoice, and asserts the routing decision.

Prerequisites
  * DataWeave CLI 2.x  https://github.com/mulesoft/data-weave-cli/releases
  * export DW_CLI=/path/to/dw   (or have `dw` on PATH)

    python tools/dataweave-tests/run_pipeline_tests.py
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
RES = ROOT / "invoice-process-api" / "src" / "main" / "resources"
SYS_RES = ROOT / "invoice-system-api" / "src" / "main" / "resources"
EXP_RES = ROOT / "invoice-experience-api" / "src" / "main" / "resources"
sys.path.insert(0, str(ROOT / "mock-services"))
import mock_server  # noqa: E402

DW = os.environ.get("DW_CLI") or shutil.which("dw") or shutil.which("dw.exe")

# Mirrors config/local.yaml (approval.*, validation.*)
CONFIG = {
    "confidenceThreshold": 0.85, "minUsableConfidence": 0.50, "maxInvoiceAgeDays": 730,
    "allowedCurrencies": ["USD", "EUR", "GBP", "CAD", "INR"],
    "amountTolerance": 0.01, "taxTolerance": 0.02, "priceTolerancePct": 2,
    "autoApproveLimit": 1000, "approverLimit": 10000, "managerLimit": 50000,
}

# Mirrors database/02-sample-data.sql as returned by the System API
VENDORS = {
    "V-1001": {"vendorId": "V-1001", "vendorName": "Acme Office Supplies", "status": "ACTIVE", "currency": "USD", "defaultTaxRate": 0.08, "paymentTerms": "NET30"},
    "V-1002": {"vendorId": "V-1002", "vendorName": "Globex Industrial Parts", "status": "ACTIVE", "currency": "USD", "defaultTaxRate": 0.08, "paymentTerms": "NET45"},
    "V-1003": {"vendorId": "V-1003", "vendorName": "Initech IT Services", "status": "ACTIVE", "currency": "USD", "defaultTaxRate": 0.08, "paymentTerms": "NET60"},
    "V-1004": {"vendorId": "V-1004", "vendorName": "Umbrella Logistics", "status": "INACTIVE", "currency": "USD", "defaultTaxRate": 0.08, "paymentTerms": "NET30"},
    "V-1005": {"vendorId": "V-1005", "vendorName": "Stark Precision Components", "status": "ACTIVE", "currency": "USD", "defaultTaxRate": 0.10, "paymentTerms": "NET30"},
}


def po(number, vendor, sub, tax, lines, status="OPEN", invoiced=0):
    return {"poNumber": number, "vendorId": vendor, "status": status, "currency": "USD",
            "subtotalAmount": sub, "taxAmount": tax, "totalAmount": sub + tax, "invoicedAmount": invoiced,
            "lines": [{"lineNumber": i + 1, "itemCode": c, "description": d, "quantity": q, "unitPrice": p,
                       "lineAmount": q * p, "quantityInvoiced": 0} for i, (c, d, q, p) in enumerate(lines)]}


POS = {
    "PO-2026-0001": po("PO-2026-0001", "V-1001", 800, 64, [("PAP-A4-500", "A4 Copy Paper 80gsm (box of 5 reams)", 100, 5), ("TON-HP-26X", "HP 26X Black Toner Cartridge", 10, 30)]),
    "PO-2026-0002": po("PO-2026-0002", "V-1002", 5000, 400, [("HYD-PMP-220", "Hydraulic Pump 220V", 4, 1000), ("VLV-KIT-12", "Valve Repair Kit 12mm", 20, 50)]),
    "PO-2026-0003": po("PO-2026-0003", "V-1003", 60000, 4800, [("SRV-CLOUD", "Cloud Migration Services (hours)", 300, 150), ("SRV-SECAUD", "Security Audit (fixed fee)", 1, 15000)]),
    "PO-2026-0004": po("PO-2026-0004", "V-1002", 1200, 96, [("BRG-6204", "Deep Groove Ball Bearing 6204", 100, 12)]),
    "PO-2026-0005": po("PO-2026-0005", "V-1001", 100, 8, [("PEN-BLK-12", "Ballpoint Pens Black (box of 12)", 50, 2)]),
    "PO-2026-0006": po("PO-2026-0006", "V-1001", 450, 36, [("LMP-LED-DK", "LED Desk Lamp", 10, 45)]),
    "PO-2026-0007": po("PO-2026-0007", "V-1005", 2500, 250, [("CNC-SHAFT-8", "CNC Machined Shaft 8mm", 25, 100)]),
    "PO-2026-0008": po("PO-2026-0008", "V-1001", 300, 24, [("NTB-A5-DOT", "A5 Dotted Notebook", 100, 3)]),
}

# sample file -> (expected status, expected issue codes that must be present)
EXPECTATIONS = {
    "pdf/INV-2026-1001_acme_auto-approve.pdf": ("APPROVED", []),
    "pdf/INV-2026-1002_globex_single-approval.pdf": ("PENDING_APPROVAL", []),
    "pdf/INV-2026-1003_initech_two-level-approval.pdf": ("PENDING_APPROVAL", []),
    "pdf/INV-2026-1004_globex_price-variance.pdf": ("MANUAL_REVIEW", ["PRICE_VARIANCE", "PO_AMOUNT_EXCEEDED"]),
    "pdf/INV-2026-1005_unknown-vendor.pdf": ("VALIDATION_FAILED", ["VENDOR_NOT_FOUND"]),
    "pdf/INV-2026-1006_acme_incorrect-totals.pdf": ("MANUAL_REVIEW", ["SUBTOTAL_MISMATCH"]),
    "pdf/INV-2026-1007_acme_missing-fields.pdf": ("VALIDATION_FAILED", ["MISSING_REQUIRED_FIELD"]),
    "pdf/ERPFAIL-2026-0001_acme_erp-failure.pdf": ("APPROVED", []),
    "images/INV-2026-1008_acme_scan.png": ("APPROVED", []),
    "images/INV-2026-1009_acme_blurry-photo.jpg": ("MANUAL_REVIEW", ["LOW_CONFIDENCE"]),
    "images/unreadable-receipt.png": ("MANUAL_REVIEW", ["MISSING_REQUIRED_FIELD"]),
    "json/INV-2026-1010_stark_structured.json": ("PENDING_APPROVAL", []),
    "json/duplicate-of-INV-2026-1001.json": ("DUPLICATE", ["DUPLICATE_INVOICE"]),
}
CHAINS = {
    "pdf/INV-2026-1002_globex_single-approval.pdf": ["APPROVER"],
    "pdf/INV-2026-1003_initech_two-level-approval.pdf": ["MANAGER", "FINANCE_DIRECTOR"],
    "json/INV-2026-1010_stark_structured.json": ["APPROVER"],
}

MIME = {".pdf": "application/pdf", ".png": "image/png", ".jpg": "image/jpeg", ".json": "application/json"}


class DwRunner:
    def __init__(self, workdir: Path):
        self.workdir = workdir

    def run(self, resources: Path, script: str, **inputs):
        args = [DW, "run", "-s", "--path", "."]
        for name, value in inputs.items():
            f = self.workdir / f"in-{name}.json"
            f.write_text(json.dumps(value), encoding="utf-8")
            args += ["-i", f"{name}={f}"]
        args += ["-f", script]
        proc = subprocess.run(args, cwd=resources, capture_output=True, text=True, encoding="utf-8")
        out = "\n".join(l for l in proc.stdout.splitlines() if not l.startswith("WARNING"))
        try:
            return json.loads(out)
        except ValueError:
            raise AssertionError(f"{script} failed:\n{out}\n{proc.stderr[-2000:]}")


def run_pipeline(dw: DwRunner, rel: str, existing_invoices: list):
    path = ROOT / "sample-invoices" / rel
    mime = MIME[path.suffix]
    content = path.read_bytes()
    if mime == "application/json":
        data = json.loads(content)
        ai = {"provider": "JSON_UPLOAD", "model": None, "warnings": [], "extraction": data}
    else:
        r = mock_server.extract_document(path.name, mime, content)
        ai = {"provider": "MOCK_DOCUMENT_AI", "model": "mock-invoice-extractor-v1",
              "warnings": r["warnings"], "extraction": r["extraction"]}

    invoice_id = "00000000-0000-0000-0000-%012d" % (abs(hash(rel)) % 10**12)
    inv = dw.run(RES, "dwl/normalize-ai-response.dwl", payload=ai)
    v = {"config": CONFIG, "invoiceId": invoice_id, "schemaValidation": {"valid": True}}
    v["fieldValidation"] = dw.run(RES, "dwl/validate-invoice-fields.dwl", payload=inv, vars=v)

    if inv["vendor"]["id"]:
        vendor = VENDORS.get(inv["vendor"]["id"])
        v["vendorLookup"] = {"lookupType": "ID", "status": 200 if vendor else 404,
                             "body": vendor or {"error": {"code": "NOT_FOUND"}}}
    elif inv["vendor"]["name"]:
        hits = [x for x in VENDORS.values() if x["vendorName"].lower() == inv["vendor"]["name"].lower()]
        v["vendorLookup"] = {"lookupType": "NAME", "status": 200, "body": {"vendors": hits}}
    else:
        v["vendorLookup"] = {"lookupType": "NONE"}
    v["vendorCheck"] = dw.run(RES, "dwl/vendor-verification.dwl", payload=inv, vars=v)

    norm = inv["normalizedInvoiceNumber"]
    vid = (v["vendorCheck"].get("vendor") or {}).get("vendorId")
    exact = [e for e in existing_invoices if e["vendorId"] == vid and e["normalized"] == norm] if norm and vid else []
    dup_input = {"exactMatches": exact, "possibleMatches": []} if norm and vid else None
    v["duplicateCheck"] = dw.run(RES, "dwl/duplicate-detection.dwl", payload=dup_input, vars=v)

    v["poLookup"] = None
    if inv["poNumber"]:
        p = POS.get(inv["poNumber"])
        v["poLookup"] = {"status": 200 if p else 404, "body": p or {}}
    v["poMatch"] = dw.run(RES, "dwl/po-matching.dwl", payload=inv, vars=v)
    v["totals"] = dw.run(RES, "dwl/calculate-invoice-totals.dwl", payload=inv, vars=v)
    v["taxCheck"] = dw.run(RES, "dwl/tax-validation.dwl", payload=inv, vars=v)
    decision = dw.run(RES, "dwl/approval-routing.dwl", payload=inv, vars=v)
    return invoice_id, inv, decision, ai, v


def main():
    if not DW:
        print("DataWeave CLI not found. Set DW_CLI or put `dw` on PATH.")
        return 2
    failures = 0
    expected_dir = ROOT / "sample-invoices" / "expected"
    expected_dir.mkdir(exist_ok=True)
    existing = []
    with tempfile.TemporaryDirectory() as tmp:
        dw = DwRunner(Path(tmp))
        for rel, (want_status, want_codes) in EXPECTATIONS.items():
            invoice_id, inv, decision, ai, v = run_pipeline(dw, rel, existing)
            codes = {i["code"] for i in decision["validationErrors"] + decision["exceptions"]}
            ok = decision["status"] == want_status and all(c in codes for c in want_codes)
            if rel in CHAINS:
                ok = ok and decision["approvalChain"] == CHAINS[rel]
            failures += 0 if ok else 1
            print(f"{'PASS' if ok else 'FAIL'}  {rel:<50} -> {decision['status']:<18} {sorted(codes)}")
            if not ok:
                print("      expected", want_status, want_codes, CHAINS.get(rel, ""))
            if decision["status"] not in ("DUPLICATE", "VALIDATION_FAILED") and inv["normalizedInvoiceNumber"]:
                existing.append({"invoiceId": invoice_id, "invoiceNumber": inv["invoiceNumber"], "status": decision["status"],
                                 "vendorId": v["vendorCheck"]["vendor"]["vendorId"] if v["vendorCheck"]["vendor"] else None,
                                 "normalized": inv["normalizedInvoiceNumber"]})
            stem = Path(rel).stem
            (expected_dir / f"{stem}.expected.json").write_text(json.dumps({
                "sampleFile": rel, "rawExtraction": ai, "canonicalInvoice": inv, "routingDecision": decision},
                indent=2) + "\n", encoding="utf-8")

        # ---- Additional script tests ------------------------------------
        failures += extra_tests(dw)
    print(f"\n{'ALL PASSED' if failures == 0 else str(failures) + ' FAILURE(S)'}")
    return 1 if failures else 0


def check(name, cond, detail=""):
    print(f"{'PASS' if cond else 'FAIL'}  {name} {detail if not cond else ''}")
    return 0 if cond else 1


def extra_tests(dw: DwRunner):
    f = 0
    inv = json.loads((ROOT / "sample-invoices" / "expected" / "INV-2026-1003_initech_two-level-approval.expected.json").read_text())["canonicalInvoice"]
    pending = {"invoiceId": "inv-3", "status": "PENDING_APPROVAL", "submittedBy": "supplier1", "version": 3,
               "approvalChain": "MANAGER,FINANCE_DIRECTOR", "approvalsRequired": 2, "approvalsReceived": 0,
               "invoiceNumber": "INV-2026-1003", "vendorId": "V-1003", "totalAmount": 64800, "approvals": []}

    def auth(invoice, user, roles, decision="APPROVE", comments="ok"):
        return dw.run(RES, "dwl/approval-authorization.dwl", payload=invoice,
                      vars={"decisionRequest": {"decision": decision, "username": user, "roles": roles, "comments": comments}})

    r = auth(pending, "approver1", ["APPROVER"])
    f += check("authz: APPROVER cannot approve MANAGER level", not r["allowed"] and r["httpStatus"] == 403, r)
    r = auth(pending, "manager1", ["MANAGER"])
    f += check("authz: MANAGER approves level 1 -> still PENDING", r["allowed"] and r["newStatus"] == "PENDING_APPROVAL" and r["newApprovalsReceived"] == 1, r)
    after1 = dict(pending, approvalsReceived=1, approvals=[{"decidedBy": "manager1", "approvalLevel": "MANAGER", "decision": "APPROVED"}])
    r = auth(after1, "manager1", ["MANAGER", "FINANCE_DIRECTOR"])
    f += check("authz: same user cannot approve twice", not r["allowed"] and r["errorCode"] == "ALREADY_DECIDED", r)
    r = auth(after1, "director1", ["FINANCE_DIRECTOR"])
    f += check("authz: director final approval -> APPROVED", r["allowed"] and r["newStatus"] == "APPROVED" and r["isFinalApproval"], r)
    r = auth(pending, "supplier1", ["MANAGER"])
    f += check("authz: segregation of duties", not r["allowed"] and r["errorCode"] == "SEGREGATION_OF_DUTIES", r)
    r = auth(pending, "manager1", ["MANAGER"], decision="REJECT", comments="")
    f += check("authz: rejection needs a reason", not r["allowed"] and r["httpStatus"] == 400, r)
    r = auth(dict(pending, status="POSTED_TO_ERP"), "manager1", ["MANAGER"])
    f += check("authz: cannot approve posted invoice", not r["allowed"] and r["httpStatus"] == 409, r)

    rb = dw.run(RES, "dwl/recovery-backoff.dwl", payload={"queueId": 1, "attemptCount": 2, "maxAttempts": 5},
                vars={"config": {"recovery": {"baseDelaySec": 60, "maxDelaySec": 3600}}, "recoveryError": {"code": "X", "message": "y"}})
    f += check("backoff: attempt 3 -> 240s, PENDING", rb["status"] == "PENDING" and rb["delaySeconds"] == 240 and rb["attemptCount"] == 3, rb)
    rb = dw.run(RES, "dwl/recovery-backoff.dwl", payload={"queueId": 1, "attemptCount": 4, "maxAttempts": 5},
                vars={"config": {"recovery": {"baseDelaySec": 60, "maxDelaySec": 3600}}, "recoveryError": {"code": "X", "message": "y"}})
    f += check("backoff: max attempts -> DEAD", rb["status"] == "DEAD", rb)

    req = dw.run(RES, "dwl/claude-request.dwl", payload={"fileName": "a.pdf", "mimeType": "application/pdf", "contentBase64": "JVBERi0x"},
                 vars={"config": {"anthropic": {"model": "claude-opus-5-5", "maxTokens": 16000, "effort": "medium"}},
                       "claudeSchema": json.loads((RES / "schemas" / "claude-extraction-schema.json").read_text())})
    f += check("claude request: document block + json_schema format",
               req["messages"][0]["content"][0]["type"] == "document" and req["output_config"]["format"]["type"] == "json_schema"
               and req["model"] == "claude-opus-5-5" and req["fallbacks"] == "default", req.get("model"))
    claude_resp = {"id": "msg_1", "model": "claude-opus-5-5", "stop_reason": "end_turn",
                   "content": [{"type": "thinking", "thinking": ""},
                               {"type": "text", "text": json.dumps({"invoice_number": "INV-1", "overall_confidence": 0.9})}],
                   "usage": {"input_tokens": 1000, "output_tokens": 200}}
    out = dw.run(RES, "dwl/claude-response.dwl", payload=claude_resp)
    f += check("claude response: parses text block", out["ok"] and out["extraction"]["invoice_number"] == "INV-1", out)
    out = dw.run(RES, "dwl/claude-response.dwl", payload=dict(claude_resp, stop_reason="refusal", content=[]))
    f += check("claude response: refusal -> ok=false", not out["ok"], out)

    # System API: ERP JSON -> XML payload, XML -> JSON response
    sys_invoice = {"invoiceId": "11111111-2222-3333-4444-555555555555", "invoiceNumber": "INV-2026-1001", "vendorId": "V-1001",
                   "poNumber": "PO-2026-0001", "invoiceDate": "2026-09-15", "dueDate": "2026-10-15", "currency": "USD",
                   "paymentTerms": "Net 30", "subtotalAmount": 800, "taxAmount": 64, "totalAmount": 864,
                   "lineItems": [{"lineNumber": 1, "itemCode": "PAP-A4-500", "description": "A4 Copy Paper", "quantity": 100,
                                  "unitPrice": 5, "lineAmount": 500, "poLineNumber": 1}]}
    xml_out = run_text(dw, SYS_RES, "dwl/erp-payload.dwl", payload=sys_invoice)
    f += check("erp payload: XML with namespace", 'xmlns:erp="urn:example:erp:ap:v1"' in xml_out and "PaymentTermCode>NET30<" in xml_out, xml_out[:300])
    status, _ = mock_server.post_ap_invoice(xml_out.encode())
    f += check("erp payload: accepted by mock ERP", status == 200, status)

    # Experience API: upload validation
    pdf = (ROOT / "sample-invoices" / "pdf" / "INV-2026-1001_acme_auto-approve.pdf").read_bytes()
    import base64
    up = dw.run(EXP_RES, "dwl/upload-validation.dwl",
                vars={"config": {"maxFileSizeBytes": 10485760}},
                payload={"fileName": "INV-2026-1001.pdf", "contentType": "application/pdf", "contentBase64": base64.b64encode(pdf).decode()})
    f += check("upload validation: valid PDF accepted", up["valid"] and up["detectedType"] == "application/pdf" and len(up["sha256"]) == 64, up)
    up = dw.run(EXP_RES, "dwl/upload-validation.dwl", vars={"config": {"maxFileSizeBytes": 10485760}},
                payload={"fileName": "x.pdf", "contentType": "application/pdf", "contentBase64": base64.b64encode(b"plain text").decode()})
    f += check("upload validation: magic-byte mismatch -> 415", (not up["valid"]) and up["httpStatus"] == 415, up)
    up = dw.run(EXP_RES, "dwl/upload-validation.dwl", vars={"config": {"maxFileSizeBytes": 100}},
                payload={"fileName": "a.pdf", "contentType": "application/pdf", "contentBase64": base64.b64encode(pdf).decode()})
    f += check("upload validation: too large -> 413", (not up["valid"]) and up["httpStatus"] == 413, up)
    up = dw.run(EXP_RES, "dwl/upload-validation.dwl", vars={"config": {"maxFileSizeBytes": 10485760}},
                payload={"fileName": "notes.txt", "contentType": "text/plain", "contentBase64": base64.b64encode(b"hello").decode()})
    f += check("upload validation: .txt -> 415", (not up["valid"]) and up["httpStatus"] == 415, up)

    users = json.loads((EXP_RES / "security" / "users.json").read_text())
    token = base64.b64encode(b"manager1:Manager#2026").decode()
    a = dw.run(EXP_RES, "dwl/authenticate.dwl", attributes={"headers": {"authorization": "Basic " + token}}, vars={"users": users})
    f += check("auth: valid basic credentials", a["authenticated"] and a["user"]["roles"] == ["MANAGER"], a)
    bad = base64.b64encode(b"manager1:wrong").decode()
    a = dw.run(EXP_RES, "dwl/authenticate.dwl", attributes={"headers": {"authorization": "Basic " + bad}}, vars={"users": users})
    f += check("auth: wrong password rejected", not a["authenticated"], a)

    err = dw.run(EXP_RES, "dwl/error-response.dwl",
                 error={"errorType": {"namespace": "APP", "identifier": "FORBIDDEN"}, "description": "nope"},
                 vars={"correlationIdValue": "c-1"})
    f += check("error mapping: APP:FORBIDDEN -> 403", err["httpStatus"] == 403 and err["body"]["error"]["code"] == "FORBIDDEN", err)
    err = dw.run(EXP_RES, "dwl/error-response.dwl",
                 error={"errorType": {"namespace": "HTTP", "identifier": "NOT_FOUND"}, "description": "x",
                        "errorMessage": {"attributes": {"statusCode": 404},
                                         "payload": {"error": {"code": "INVOICE_NOT_FOUND", "message": "Invoice x not found"}}}},
                 vars={})
    f += check("error mapping: downstream 404 propagated", err["httpStatus"] == 404 and err["body"]["error"]["code"] == "INVOICE_NOT_FOUND", err)
    return f


def run_text(dw: DwRunner, resources: Path, script: str, **inputs):
    args = [DW, "run", "-s", "--path", "."]
    for name, value in inputs.items():
        fpath = dw.workdir / f"in-{name}.json"
        fpath.write_text(json.dumps(value), encoding="utf-8")
        args += ["-i", f"{name}={fpath}"]
    args += ["-f", script]
    proc = subprocess.run(args, cwd=resources, capture_output=True, text=True, encoding="utf-8")
    return "\n".join(l for l in proc.stdout.splitlines() if not l.startswith("WARNING"))


if __name__ == "__main__":
    sys.exit(main())
