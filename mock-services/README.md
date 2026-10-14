# Mock services (AI extraction + ERP)

A Python 3.9+ server with no dependencies. It stands in for the paid or external systems so the whole platform runs locally for free.

```bash
python mock_server.py                      # http://localhost:8090
python -m unittest discover -s tests -v    # 14 tests
```

| Endpoint | Purpose |
|---|---|
| `GET  /health` | Liveness check |
| `POST /ai/v1/extract` | Header `Authorization: Bearer mock-ai-key-local`; body `{fileName, mimeType, contentBase64}` |
| `POST /erp/v1/ap-invoices` | Basic auth `erp_integration:erp-local-pass`; XML `APInvoice` in namespace `urn:example:erp:ap:v1` |
| `GET  /erp/v1/ap-invoices` | Lists postings (Basic auth) |
| `POST /erp/v1/admin/failure-mode` | `{"mode":"DOWN"}` or `{"mode":"NORMAL"}` |
| `POST /admin/reset` | Clears ERP state |

**Failure simulation**
- File names containing `ai-fail` return 500; names containing `ai-unavailable` return 503.
- Invoice numbers starting with `ERPFAIL` fail the first `ERP_FAIL_ATTEMPTS` (default 3) ERP calls, then succeed.

**How extraction works**
- PDF: real extraction. It parses the text layer, including FlateDecode streams, then applies label and regex parsing.
- Images: simulated OCR using `fixtures/image-fixtures.json`, which `tools/generate_samples.py` generates.
- Unknown images: return an empty, low-confidence result, which the platform routes to manual review.
- For real OCR or LLM extraction, switch the Process API to `AI_PROVIDER=claude`.
