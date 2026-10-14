"""
Unit + HTTP tests for the mock AI / ERP services.

    cd mock-services
    python -m unittest discover -s tests -v
"""
import base64
import json
import sys
import threading
import unittest
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
import mock_server as m  # noqa: E402

SAMPLES = HERE.parent.parent / "sample-invoices"

ERP_XML = """<?xml version="1.0" encoding="UTF-8"?>
<APInvoice xmlns="urn:example:erp:ap:v1">
  <Header>
    <ExternalReference>{ref}</ExternalReference>
    <InvoiceNumber>{num}</InvoiceNumber>
    <VendorCode>V-1001</VendorCode>
    <Amounts><Net>100.00</Net><Tax>8.00</Tax><Gross>108.00</Gross></Amounts>
  </Header>
  <Lines><Line number="1"><ItemCode>PEN-BLK-12</ItemCode><Quantity>50</Quantity><UnitPrice>2.00</UnitPrice><Amount>100.00</Amount></Line></Lines>
</APInvoice>"""


class ExtractionTests(unittest.TestCase):
    def test_pdf_happy_path(self):
        pdf = (SAMPLES / "pdf" / "INV-2026-1001_acme_auto-approve.pdf").read_bytes()
        e = m.extract_document("INV-2026-1001.pdf", "application/pdf", pdf)["extraction"]
        self.assertEqual(e["invoice_number"], "INV-2026-1001")
        self.assertEqual(e["vendor_id"], "V-1001")
        self.assertEqual(e["purchase_order_number"], "PO-2026-0001")
        self.assertEqual(e["total_amount"], "864.00")
        self.assertEqual(e["tax_rate"], 0.08)
        self.assertEqual(len(e["line_items"]), 2)
        self.assertGreaterEqual(e["overall_confidence"], 0.9)

    def test_compressed_pdf(self):
        pdf = (SAMPLES / "pdf" / "INV-2026-1002_globex_single-approval.pdf").read_bytes()
        self.assertIn(b"FlateDecode", pdf)
        e = m.extract_document("x.pdf", "application/pdf", pdf)["extraction"]
        self.assertEqual(e["total_amount"], "5,400.00")

    def test_missing_fields_have_zero_confidence(self):
        pdf = (SAMPLES / "pdf" / "INV-2026-1007_acme_missing-fields.pdf").read_bytes()
        e = m.extract_document("x.pdf", "application/pdf", pdf)["extraction"]
        self.assertIsNone(e["invoice_number"])
        self.assertIsNone(e["total_amount"])
        self.assertEqual(e["field_confidence"]["invoice_number"], 0.0)
        self.assertLess(e["overall_confidence"], 0.85)

    def test_blurry_image_is_low_confidence(self):
        img = SAMPLES / "images" / "INV-2026-1009_acme_blurry-photo.jpg"
        if not img.exists():
            self.skipTest("image samples not generated (Pillow missing)")
        r = m.extract_document(img.name, "image/jpeg", img.read_bytes())
        self.assertLess(r["extraction"]["overall_confidence"], 0.85)
        self.assertTrue(r["warnings"])

    def test_not_a_pdf(self):
        with self.assertRaises(ValueError):
            m.extract_document("x.pdf", "application/pdf", b"hello")


class ErpTests(unittest.TestCase):
    def setUp(self):
        m.reset_state()

    def test_post_and_idempotency(self):
        status, body = m.post_ap_invoice(ERP_XML.format(ref="abc", num="INV-1").encode())
        self.assertEqual(status, 200)
        self.assertIn("<Status>POSTED</Status>", body)
        status, body = m.post_ap_invoice(ERP_XML.format(ref="abc", num="INV-1").encode())
        self.assertIn("<Status>ALREADY_POSTED</Status>", body)

    def test_erpfail_recovers_after_configured_attempts(self):
        xml = ERP_XML.format(ref="r1", num="ERPFAIL-1").encode()
        for _ in range(m.ERP_FAIL_ATTEMPTS):
            self.assertEqual(m.post_ap_invoice(xml)[0], 503)
        self.assertEqual(m.post_ap_invoice(xml)[0], 200)

    def test_validation_error(self):
        status, body = m.post_ap_invoice(b'<APInvoice xmlns="urn:example:erp:ap:v1"><Header/></APInvoice>')
        self.assertEqual(status, 400)
        self.assertIn("VALIDATION_ERROR", body)

    def test_malformed_xml(self):
        self.assertEqual(m.post_ap_invoice(b"<oops")[0], 400)


class HttpTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), m.Handler)
        cls.base = f"http://127.0.0.1:{cls.server.server_address[1]}"
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()

    def _post(self, path, body, headers):
        req = urllib.request.Request(self.base + path, data=body, headers=headers, method="POST")
        try:
            with urllib.request.urlopen(req) as resp:
                return resp.status, resp.read()
        except urllib.error.HTTPError as err:
            return err.code, err.read()

    def _extract(self, file_name, key=m.AI_API_KEY):
        pdf = (SAMPLES / "pdf" / "INV-2026-1001_acme_auto-approve.pdf").read_bytes()
        body = json.dumps({"fileName": file_name, "mimeType": "application/pdf",
                           "contentBase64": base64.b64encode(pdf).decode()}).encode()
        return self._post("/ai/v1/extract", body,
                          {"Content-Type": "application/json", "Authorization": f"Bearer {key}"})

    def test_extract_ok(self):
        status, body = self._extract("INV-2026-1001.pdf")
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body)["extraction"]["invoice_number"], "INV-2026-1001")

    def test_extract_requires_key(self):
        self.assertEqual(self._extract("a.pdf", key="wrong")[0], 401)

    def test_extract_simulated_failure(self):
        self.assertEqual(self._extract("ai-fail_scan.pdf")[0], 500)

    def test_erp_requires_basic_auth(self):
        status, _ = self._post("/erp/v1/ap-invoices", ERP_XML.format(ref="z", num="N").encode(),
                               {"Content-Type": "application/xml"})
        self.assertEqual(status, 401)

    def test_erp_post_ok(self):
        auth = base64.b64encode(f"{m.ERP_USERNAME}:{m.ERP_PASSWORD}".encode()).decode()
        status, body = self._post("/erp/v1/ap-invoices", ERP_XML.format(ref="http-1", num="INV-H1").encode(),
                                  {"Content-Type": "application/xml", "Authorization": f"Basic {auth}"})
        self.assertEqual(status, 200)
        self.assertIn(b"DocumentNumber", body)


if __name__ == "__main__":
    unittest.main()
