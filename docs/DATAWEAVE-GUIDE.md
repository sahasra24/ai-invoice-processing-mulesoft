# DataWeave Guide

All business logic lives in `.dwl` files under each app's `src/main/resources/dwl/`. This folder is on the classpath, so XML references a script with `resource="dwl/<name>.dwl"`. In Anypoint Studio, open a **Transform Message** component and you'll see the script linked under *Resource*. Click **Edit current target** to open it in the graphical editor.

Shared functions live in a DataWeave **module**, `src/main/resources/modules/InvoiceUtils.dwl` (Process and System APIs). Scripts import it with `import * from modules::InvoiceUtils`.

## How the scripts receive data

Scripts never call `p()`. All configuration arrives in `vars.config`, which the `init-context-sub-flow` builds from properties. This keeps every script a pure function of `payload` + `vars`, so it can be unit-tested with the DataWeave CLI outside Mule (see `tools/dataweave-tests/run_pipeline_tests.py`, 32 passing checks).

## Script catalogue

### Process API (`invoice-process-api/src/main/resources/dwl`)

| Script | Requirement | Used in (flow > component) | Input | Output |
|---|---|---|---|---|
| `normalize-ai-response.dwl` | AI response normalization | `validate-and-route-sub-flow` > *Normalize AI response* | `{provider, model, warnings, extraction}` from any provider | canonical invoice |
| `validate-invoice-fields.dwl` | Invoice field validation | *Validate invoice fields* (sets `vars.fieldValidation`) | canonical invoice, `vars.config` | `{valid, errors[], warnings[], lowConfidenceFields[], overallConfidence}` |
| `vendor-verification.dwl` | Invalid vendor detection | *Verify vendor* | invoice, `vars.vendorLookup` | `{verified, vendor, issues[]}` |
| `duplicate-detection.dwl` | Duplicate detection support | *Check duplicates* | System API candidates | `{isDuplicate, duplicateOf, possibleDuplicates, issues[]}` |
| `po-matching.dwl` | Purchase order matching | *Match PO, verify totals and tax* | invoice, `vars.poLookup` | `{matched, lineMatches[], issues[]}` |
| `calculate-invoice-totals.dwl` | Invoice total calculation | same component | invoice | `{calculatedSubtotal, calculatedTotal, lineChecks[], issues[]}` |
| `tax-validation.dwl` | Tax validation | *Validate tax* | invoice, `vars.vendorCheck`, `vars.totals` | `{expectedRate, expectedTax, issues[]}` |
| `approval-routing.dwl` | Approval routing | *Route for approval* | invoice + all check results | `{status, approvalChain, validationErrors, exceptions, ...}` |
| `approval-authorization.dwl` | Role-based approval authorization | `process-invoice-decision-flow` > *Authorize decision* | invoice, `vars.decisionRequest` | `{allowed, httpStatus, errorCode, newStatus, ...}` |
| `recovery-backoff.dwl` | Retry with backoff | `recover-queue-item-sub-flow` > *Exponential backoff* | queue item | `{status: PENDING/DEAD, attemptCount, delaySeconds, ...}` |
| `processing-result.dwl` | Final API response | *Build processing result* | vars | ProcessingResult |
| `error-response.dwl` | Error response formatting | `global-error-handler` | `error`, `vars.errorOverride` | `{httpStatus, body}` |

### System API (`invoice-system-api/src/main/resources/dwl`)

| Script | Requirement | Used in | Notes |
|---|---|---|---|
| `erp-payload.dwl` | **JSON to XML** / ERP payload transformation | `sys-post-invoice-to-erp-flow` > *Transform to ERP XML* | namespaced XML (`ns erp urn:example:erp:ap:v1`), attributes, number formatting |
| `erp-response.dwl` | **XML to JSON** | *Transform ERP response* | handles `APInvoiceResponse` and `ErrorResponse` |
| `invoice-view.dwl` | DB rows to API model | `sys-load-invoice-sub-flow` | parses JSON columns safely with `try` |
| `vendor-view.dwl` | DB row to vendor view | `sys-get-vendor-flow` | |
| `error-response.dwl` | Error formatting | `global-error-handler` | |

### Experience API (`invoice-experience-api/src/main/resources/dwl`)

| Script | Requirement | Used in |
|---|---|---|
| `extract-upload-part.dwl` | Multipart parsing (`.^raw` keeps exact bytes) | `post-invoice-upload-flow` > *Extract file part* |
| `upload-validation.dwl` | File type and size validation, magic bytes, SHA-256 | *Validate upload* |
| `authenticate.dwl` | Basic auth against hashed users | `authenticate-sub-flow` |
| `invoice-public-view.dwl` | Public representation (hides internals) | `get-invoice-flow` |
| `result-http-status.dwl` | Business result to HTTP status | upload / process flows |
| `error-response.dwl` | Error formatting | `global-error-handler` |

## Worked example: normalization

Raw mock-AI output (excerpt):
```json
{ "invoice_number": "INV-2026-1001", "invoice_date": "2026-09-15", "currency": "USD",
  "subtotal": "800.00", "tax": "64.00", "tax_rate": 0.08, "total_amount": "864.00",
  "line_items": [ { "line_number": 1, "item_code": "PAP-A4-500", "quantity": "100", "unit_price": "5.00", "amount": "500.00" } ],
  "field_confidence": { "invoice_number": 0.96, "total_amount": 0.95 }, "overall_confidence": 0.958 }
```
Canonical output:
```json
{ "invoiceNumber": "INV-2026-1001", "normalizedInvoiceNumber": "INV20261001", "invoiceDate": "2026-09-15",
  "dueDate": "2026-10-15", "vendor": { "id": "V-1001", "name": "Acme Office Supplies" }, "currency": "USD",
  "lineItems": [ { "lineNumber": 1, "itemCode": "PAP-A4-500", "quantity": 100, "unitPrice": 5, "amount": 500, "amountDerived": false } ],
  "subtotal": 800, "tax": 64, "taxRate": 0.08, "total": 864,
  "extraction": { "provider": "MOCK_DOCUMENT_AI", "overallConfidence": 0.958, "fieldConfidence": { "invoiceNumber": 0.96, "...": 0.95 } } }
```
Techniques shown: tolerant number parsing (`"$1,234.50"` becomes `1234.5`), multi-format date parsing with `dw::Runtime::try`, currency symbol mapping, due date derived from "Net 30", percent-or-fraction tax rate, per-field confidence defaults for structured JSON.

The full expected output for every sample is in `sample-invoices/expected/*.expected.json`, generated by running the real scripts.

## Gotchas found while testing these scripts (good interview material)

1. **`$` inside double-quoted strings is interpolation.** `"$"` fails to compile; write `"\$"`.
2. **The static type checker is path-insensitive.** For `if (x != null) f(x)` where `x: Binary | Null`, `f` still complains. Use `x as Binary` inside the guarded branch, or `default`.
3. **`"abc"[0 to 999]` returns `null`, not `"abc"`.** Truncate with `if (sizeOf(s) > n) s[0 to n-1] else s`.
4. **`type` is a reserved word.** Quote it in object keys (`"type": "document"`), which matters for many external JSON APIs.
5. **Multipart parts are auto-parsed by MIME type.** A `.json` upload arrives as an Object, so use `.^raw` to hash the original bytes.

## Running the scripts outside Mule

```bash
# DataWeave CLI: https://github.com/mulesoft/data-weave-cli/releases
export DW_CLI=/path/to/dw
python tools/dataweave-tests/run_pipeline_tests.py
```
