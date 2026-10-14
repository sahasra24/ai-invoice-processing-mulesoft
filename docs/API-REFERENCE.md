# API Reference (Experience API)

Base URL (local): `http://localhost:8081`. Every endpoint except `/api/health` requires **HTTP Basic** authentication.

| Demo user | Password | Role |
|---|---|---|
| supplier1, supplier2 | Supplier#2026 | SUPPLIER |
| apclerk1 | Clerk#2026 | AP_CLERK |
| approver1 | Approver#2026 | APPROVER |
| manager1 | Manager#2026 | MANAGER |
| director1 | Director#2026 | FINANCE_DIRECTOR |
| admin1 | Admin#2026 | ADMIN |

**Common headers**
| Header | Direction | Meaning |
|---|---|---|
| `Authorization: Basic ...` | request | credentials |
| `X-Correlation-ID` | request (optional) / response | trace id; generated when absent and echoed on every response |
| `Idempotency-Key` | request (optional, POST) | the same key from the same user within 24h replays the stored response |
| `Idempotent-Replay: true` | response | the response is a replay |

**Error body (all endpoints, all layers)**
```json
{
  "error": {
    "code": "INSUFFICIENT_APPROVAL_AUTHORITY",
    "message": "Step 1 requires MANAGER or higher; user has APPROVER",
    "httpStatus": 403,
    "correlationId": "4b0c3c6e-9a3e-4a7e-bb0e-1c0c7e5f3a11",
    "timestamp": "2026-10-14T09:12:44.120Z"
  }
}
```

| HTTP | Typical codes |
|---|---|
| 400 | VALIDATION_ERROR, FILE_REQUIRED, BAD_REQUEST, REJECTION_REASON_REQUIRED |
| 401 | UNAUTHORIZED (with `WWW-Authenticate: Basic realm="invoice-api"`) |
| 403 | FORBIDDEN, NOT_AN_APPROVER, INSUFFICIENT_APPROVAL_AUTHORITY, SEGREGATION_OF_DUTIES |
| 404 | INVOICE_NOT_FOUND, VENDOR_NOT_FOUND, PO_NOT_FOUND |
| 409 | INVALID_INVOICE_STATE, ALREADY_DECIDED, CONCURRENT_REQUEST, STALE_UPDATE, DUPLICATE_RECORD |
| 413 | FILE_TOO_LARGE |
| 415 | UNSUPPORTED_MEDIA_TYPE, UNSUPPORTED_FILE_TYPE, FILE_CONTENT_MISMATCH |
| 422 | (upload result) VALIDATION_FAILED |
| 502 / 503 / 504 | BAD_GATEWAY, DOWNSTREAM_UNAVAILABLE, DATABASE_UNAVAILABLE, DOWNSTREAM_TIMEOUT |

---

## POST /api/invoices/upload

Uploads a document and (by default) processes it synchronously. Roles: SUPPLIER, AP_CLERK, ADMIN.

**Request:** `multipart/form-data`
| Field | Required | Rules |
|---|---|---|
| `file` | yes | `.pdf .png .jpg .jpeg .json`; content must match the extension (magic bytes); 1 B to 10 MB |
| `autoProcess` | no | `true` (default) or `false`. With `false` the document is only stored and the API returns 202 RECEIVED |

```bash
curl -u supplier1:Supplier#2026 -F "file=@sample-invoices/pdf/INV-2026-1001_acme_auto-approve.pdf" \
     http://localhost:8081/api/invoices/upload
```

**Response:** `ProcessingResult`
```json
{
  "invoiceId": "0b5e3f7a-6c1d-4f7e-9a52-2b8e4b1d9c10",
  "invoiceNumber": "INV-2026-1001",
  "status": "POSTED_TO_ERP",
  "idempotentReplay": false,
  "vendorId": "V-1001",
  "vendorName": "Acme Office Supplies",
  "poNumber": "PO-2026-0001",
  "currency": "USD",
  "totalAmount": 864,
  "extractionProvider": "MOCK_DOCUMENT_AI",
  "extractionConfidence": 0.958,
  "decisionReason": "Auto-approved: all checks passed and total 864 <= 1000",
  "approval": { "required": false, "chain": [], "approvalsRequired": 0, "approvalsReceived": 0, "nextApprovalLevel": null },
  "duplicateOf": null,
  "validationErrors": [],
  "exceptions": [],
  "erp": { "documentNumber": "5100000001", "postedAt": "2026-10-14T09:00:06Z" },
  "recovery": null,
  "correlationId": "4b0c3c6e-9a3e-4a7e-bb0e-1c0c7e5f3a11",
  "processedAt": "2026-10-14T09:00:06.412Z"
}
```

| Result status | HTTP |
|---|---|
| POSTED_TO_ERP, APPROVED, PENDING_APPROVAL, MANUAL_REVIEW | **201** |
| RECEIVED (autoProcess=false), EXTRACTION_FAILED, ERP_POSTING_FAILED (queued for retry) | **202** |
| Same file uploaded again (`idempotentReplay: true`) | **200** |
| DUPLICATE | **409** (body still contains the result and `duplicateOf`) |
| VALIDATION_FAILED | **422** (body lists `validationErrors`) |

Example `422` body (excerpt, unknown vendor):
```json
{
  "status": "VALIDATION_FAILED",
  "decisionReason": "1 blocking validation error(s): VENDOR_NOT_FOUND",
  "validationErrors": [
    { "code": "VENDOR_NOT_FOUND", "severity": "BLOCKING", "message": "Vendor V-9999 does not exist in the vendor master", "details": { "vendorId": "V-9999" } }
  ],
  "exceptions": [ { "code": "PO_VENDOR_MISMATCH", "severity": "REVIEW", "message": "PO PO-2026-0008 belongs to vendor V-1001, not V-9999" } ]
}
```

Errors: 400 FILE_REQUIRED · 401 · 403 · 413 FILE_TOO_LARGE · 415 UNSUPPORTED_MEDIA_TYPE / UNSUPPORTED_FILE_TYPE / FILE_CONTENT_MISMATCH · 502/503 when a downstream system is unavailable.

---

## POST /api/invoices/process

Roles: SUPPLIER, AP_CLERK, ADMIN. `Content-Type: application/json`.

**Form A: process a stored invoice** (RECEIVED or EXTRACTION_FAILED)
```json
{ "invoiceId": "0b5e3f7a-6c1d-4f7e-9a52-2b8e4b1d9c10" }
```
**Form B: submit a structured JSON invoice** (supplier JSON format, see `sample-invoices/json/`)
```json
{
  "invoice": {
    "invoice_number": "INV-2026-1010",
    "invoice_date": "2026-10-07",
    "vendor_name": "Stark Precision Components",
    "vendor_id": "V-1005",
    "purchase_order_number": "PO-2026-0007",
    "billing_address": "Contoso Ltd, Accounts Payable, 1 Microsoft Way, Redmond WA 98052",
    "currency": "USD",
    "line_items": [ { "line_number": 1, "item_code": "CNC-SHAFT-8", "description": "CNC Machined Shaft 8mm", "quantity": 25, "unit_price": 100.0, "amount": 2500.0 } ],
    "subtotal": 2500.0, "tax_rate": 0.1, "tax": 250.0, "total_amount": 2750.0,
    "payment_terms": "Net 30", "due_date": "2026-11-06"
  }
}
```
**Response:** `ProcessingResult`, with the same status mapping as upload (e.g. 201 `PENDING_APPROVAL` with `approval.chain = ["APPROVER"]`).

Validation: the body must contain `invoiceId` (UUID) or `invoice` (object, at most 10 MB serialized). Errors: 400, 401, 403, 404 INVOICE_NOT_FOUND, 409 INVALID_INVOICE_STATE (Form A on an invoice that is not RECEIVED or EXTRACTION_FAILED), 409 DUPLICATE, 422.

---

## GET /api/invoices/{invoiceId}

All roles. Suppliers can only read invoices they submitted (otherwise 404). `invoiceId` must be a UUID (400).

```json
{
  "invoiceId": "7d3e8f00-1c2b-4d6e-8f90-a1b2c3d4e5f6",
  "invoiceNumber": "INV-2026-1003",
  "status": "PENDING_APPROVAL",
  "vendor": { "vendorId": "V-1003", "name": "Initech IT Services", "verified": true },
  "poNumber": "PO-2026-0003",
  "invoiceDate": "2026-09-25",
  "dueDate": "2026-11-24",
  "currency": "USD",
  "billingAddress": "Contoso Ltd, Accounts Payable, 1 Microsoft Way, Redmond WA 98052",
  "paymentTerms": "Net 60",
  "amounts": { "subtotal": 60000.00, "tax": 4800.00, "taxRate": 0.0800, "total": 64800.00 },
  "lineItems": [
    { "lineNumber": 1, "itemCode": "SRV-CLOUD", "description": "Cloud Migration Services (hours)", "quantity": 300.000, "unitPrice": 150.0000, "amount": 45000.00, "poLineNumber": 1, "matchStatus": "MATCHED" },
    { "lineNumber": 2, "itemCode": "SRV-SECAUD", "description": "Security Audit (fixed fee)", "quantity": 1.000, "unitPrice": 15000.0000, "amount": 15000.00, "poLineNumber": 2, "matchStatus": "MATCHED" }
  ],
  "extraction": { "provider": "MOCK_DOCUMENT_AI", "confidence": 0.9660 },
  "approval": {
    "chain": ["MANAGER", "FINANCE_DIRECTOR"],
    "approvalsRequired": 2,
    "approvalsReceived": 1,
    "nextApprovalLevel": "FINANCE_DIRECTOR",
    "decisions": [ { "approvalLevel": "MANAGER", "decision": "APPROVED", "decidedBy": "manager1", "decidedByRole": "MANAGER", "comments": "Services delivered", "decidedAt": "2026-10-14T09:20:11Z" } ]
  },
  "validationErrors": [],
  "exceptions": [],
  "duplicateOf": null,
  "rejectionReason": null,
  "erp": null,
  "document": { "fileName": "INV-2026-1003_initech_two-level-approval.pdf", "mimeType": "application/pdf", "sizeBytes": 2020, "uploadedAt": "2026-10-14T09:15:02Z" },
  "sourceChannel": "API_UPLOAD",
  "submittedBy": "supplier1",
  "createdAt": "2026-10-14T09:15:02Z",
  "updatedAt": "2026-10-14T09:20:11Z"
}
```
Errors: 400 (not a UUID), 401, 404 INVOICE_NOT_FOUND.

## GET /api/invoices/{invoiceId}/status

All roles (with the same ownership rule).
```json
{
  "invoiceId": "7d3e8f00-1c2b-4d6e-8f90-a1b2c3d4e5f6",
  "invoiceNumber": "INV-2026-1003",
  "status": "PENDING_APPROVAL",
  "statusDescription": "Waiting for approval",
  "approvalsRequired": 2,
  "approvalsReceived": 1,
  "nextApprovalLevel": "FINANCE_DIRECTOR",
  "erpDocumentNumber": null,
  "openIssues": 0,
  "lastUpdated": "2026-10-14T09:20:11Z"
}
```

## GET /api/invoices/{invoiceId}/history

All roles (with the same ownership rule). Returns the audit trail.
```json
{
  "invoiceId": "0b5e3f7a-6c1d-4f7e-9a52-2b8e4b1d9c10",
  "events": [
    { "auditId": 1, "timestamp": "2026-10-14T09:00:05.101Z", "step": "RECEIVE", "outcome": "SUCCESS", "fromStatus": null, "toStatus": "RECEIVED", "message": "Document received via API_UPLOAD (application/pdf, 2011 bytes)", "actor": "supplier1", "correlationId": "4b0c...", "details": null },
    { "auditId": 2, "timestamp": "2026-10-14T09:00:05.160Z", "step": "PROCESSING_STARTED", "outcome": "SUCCESS", "fromStatus": "RECEIVED", "toStatus": "PROCESSING", "message": "Processing started (mock extraction)", "actor": "system" },
    { "auditId": 3, "timestamp": "2026-10-14T09:00:05.420Z", "step": "EXTRACTION_VALIDATED", "outcome": "SUCCESS", "message": "Extracted by MOCK_DOCUMENT_AI (confidence 0.958); 0 field error(s), 0 low-confidence field(s)", "actor": "system", "details": { "schemaValid": true, "errors": [], "lowConfidenceFields": [] } },
    { "auditId": 4, "timestamp": "2026-10-14T09:00:05.610Z", "step": "ROUTING", "outcome": "SUCCESS", "fromStatus": "PROCESSING", "toStatus": "APPROVED", "message": "Auto-approved: all checks passed and total 864 <= 1000", "actor": "system" },
    { "auditId": 5, "timestamp": "2026-10-14T09:00:06.380Z", "step": "ERP_POSTING", "outcome": "SUCCESS", "message": "Posted to ERP as document 5100000001", "actor": "system" },
    { "auditId": 6, "timestamp": "2026-10-14T09:00:06.402Z", "step": "ERP_POSTING", "outcome": "SUCCESS", "fromStatus": "APPROVED", "toStatus": "POSTED_TO_ERP", "message": "Posted to ERP as document 5100000001", "actor": "system" }
  ]
}
```

## GET /api/invoices

All roles. SUPPLIER users always get only their own submissions.

| Query param | Rules |
|---|---|
| `status` | one of the 12 statuses |
| `vendorId` | e.g. V-1001 |
| `fromDate`, `toDate` | `YYYY-MM-DD` (creation date) |
| `page` | integer >= 1 (default 1) |
| `size` | 1..100 (default 20) |

```json
{
  "page": 1, "size": 20, "totalElements": 2, "totalPages": 1,
  "items": [
    { "invoiceId": "...", "invoiceNumber": "INV-2026-1002", "vendorId": "V-1002", "vendorName": "Globex Industrial Parts", "poNumber": "PO-2026-0002",
      "invoiceDate": "2026-09-20", "currency": "USD", "totalAmount": 5400.00, "status": "PENDING_APPROVAL", "extractionConfidence": 0.974,
      "submittedBy": "supplier2", "createdAt": "2026-10-14T09:05:00Z", "updatedAt": "2026-10-14T09:05:01Z" }
  ]
}
```
Errors: 400 (paging, status or date format), 401.

---

## POST /api/invoices/{invoiceId}/approve

Roles: APPROVER, MANAGER, FINANCE_DIRECTOR. Body (optional): `{ "comments": "Goods received in full" }` (at most 1000 characters).

## POST /api/invoices/{invoiceId}/reject

Same roles. Body: `{ "reason": "Quantity does not match goods receipt" }` (required, 5 to 1000 characters).

**Rules** (enforced in the Process API, `approval-authorization.dwl`):
1. The invoice must be `PENDING_APPROVAL` or `MANUAL_REVIEW`, otherwise 409 INVALID_INVOICE_STATE.
2. The user's highest role must be at least the next level in the chain, otherwise 403 INSUFFICIENT_APPROVAL_AUTHORITY.
3. The submitter can never decide their own invoice: 403 SEGREGATION_OF_DUTIES.
4. One decision per user per invoice, otherwise 409 ALREADY_DECIDED. Unique DB keys back this up.
5. Only one decision per invoice can be in flight at a time (Object Store lock), otherwise 409 CONCURRENT_REQUEST.
6. A MANUAL_REVIEW invoice missing its number, vendor or total cannot be approved: 409 INVOICE_INCOMPLETE.
7. The final approval posts the invoice to the ERP automatically.

**Response 200**
```json
{
  "invoiceId": "7d3e8f00-1c2b-4d6e-8f90-a1b2c3d4e5f6",
  "invoiceNumber": "INV-2026-1003",
  "decision": "APPROVED",
  "approvalLevel": "MANAGER",
  "decidedBy": "manager1",
  "decidedByRole": "MANAGER",
  "status": "PENDING_APPROVAL",
  "approvalsReceived": 1,
  "approvalsRequired": 2,
  "nextApprovalLevel": "FINANCE_DIRECTOR",
  "erp": null,
  "recovery": null,
  "correlationId": "...",
  "decidedAt": "2026-10-14T09:20:11.532Z"
}
```
After the final approval: `"status": "POSTED_TO_ERP", "erp": { "documentNumber": "5100000003", "postedAt": "..." }`. If the ERP is down: `"status": "ERP_POSTING_FAILED", "recovery": { "queued": true, ... }`.

---

## GET /api/vendors/{vendorId}

Roles: AP_CLERK, APPROVER, MANAGER, FINANCE_DIRECTOR, ADMIN. `vendorId` must match `^V-\d{4}$`.
```json
{
  "vendorId": "V-1001", "vendorName": "Acme Office Supplies", "taxId": "91-1000001",
  "email": "billing@acme-office.example", "phone": "+1-206-555-0101",
  "address": { "line1": "100 Paper Lane", "city": "Seattle", "state": "WA", "postalCode": "98101", "country": "US" },
  "currency": "USD", "defaultTaxRate": 0.0800, "paymentTerms": "NET30", "status": "ACTIVE"
}
```
Errors: 400, 401, 403, 404 VENDOR_NOT_FOUND.

## GET /api/purchase-orders/{poNumber}

Same roles. `poNumber` matches `^[A-Za-z0-9-]{3,30}$`.
```json
{
  "poNumber": "PO-2026-0002", "vendorId": "V-1002", "poDate": "2026-09-02", "currency": "USD", "status": "OPEN",
  "subtotalAmount": 5000.00, "taxAmount": 400.00, "totalAmount": 5400.00, "invoicedAmount": 0.00, "remainingAmount": 5400.00,
  "buyerEmail": "buyer.plant@contoso.example",
  "lines": [
    { "lineNumber": 1, "itemCode": "HYD-PMP-220", "description": "Hydraulic Pump 220V", "quantity": 4.000, "unitPrice": 1000.0000, "lineAmount": 4000.00, "quantityInvoiced": 0.000, "remainingQuantity": 4.000 },
    { "lineNumber": 2, "itemCode": "VLV-KIT-12", "description": "Valve Repair Kit 12mm", "quantity": 20.000, "unitPrice": 50.0000, "lineAmount": 1000.00, "quantityInvoiced": 0.000, "remainingQuantity": 20.000 }
  ]
}
```
Errors: 400, 401, 403, 404 PO_NOT_FOUND.

## GET /api/health

No authentication. `{ "status": "UP", "service": "invoice-experience-api", "timestamp": "..." }`

---

# Internal APIs (for reference)

Internal calls require `client_id` and `client_secret` headers.

**Process API** (`:8082`, base `/process/v1`)
| Method | Path | Purpose |
|---|---|---|
| POST | `/invoices` | register + process `{ sourceChannel, submittedBy, autoProcess, document{fileName,mimeType,sizeBytes,sha256,contentBase64} }` |
| POST | `/invoices/{id}/process` | re-process RECEIVED / EXTRACTION_FAILED |
| POST | `/invoices/{id}/decisions` | `{ decision: APPROVE\|REJECT, username, roles[], comments }` |
| GET | `/health` | liveness |

**System API** (`:8083`, base `/sys/v1`)
| Method | Path | Purpose |
|---|---|---|
| POST | `/invoices` | create (idempotent on SHA-256), store document |
| GET | `/invoices`, `/invoices/{id}` | list (filters, paging) / full view |
| PUT | `/invoices/{id}/extraction` | save canonical invoice + line items |
| PATCH | `/invoices/{id}/status` | status change with `expectedStatus` / `expectedVersion`, audit, line matches |
| GET | `/invoices/{id}/document` | stored document (base64) |
| GET | `/invoices/{id}/history` | audit trail |
| POST | `/invoices/{id}/audit` | append audit event |
| POST | `/invoices/{id}/approvals` | record decision |
| GET | `/invoice-duplicates?vendorId&normalizedInvoiceNumber&totalAmount&invoiceDate&excludeInvoiceId` | exact + possible duplicates |
| GET | `/vendors/{id}`, `/vendors?name=` | vendor master |
| GET | `/purchase-orders/{po}` | PO with lines and remaining quantities |
| POST | `/erp/invoices` | post an APPROVED invoice to the ERP (XML) |
| POST / GET | `/recovery-queue` | enqueue / list |
| POST | `/recovery-queue/claim?limit=` | claim due items |
| PATCH | `/recovery-queue/{queueId}` | RESOLVED / PENDING (+delaySeconds) / DEAD |
| GET | `/health` | DB readiness |
