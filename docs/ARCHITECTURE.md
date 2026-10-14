# Architecture

![Architecture](architecture.svg)

## 1. API-led layers

```mermaid
flowchart LR
    subgraph Consumers
        SP[Supplier portal]
        AA[Approver app]
        DF[(Scanner drop folder)]
    end
    subgraph Experience["Experience layer"]
        XAPI["invoice-experience-api :8081<br/>auth, RBAC, upload validation,<br/>idempotency keys, public views"]
    end
    subgraph Process["Process layer"]
        PAPI["invoice-process-api :8082<br/>orchestration, AI extraction,<br/>validation, matching, routing,<br/>approvals, ERP coordination, recovery"]
    end
    subgraph System["System layer"]
        SAPI["invoice-system-api :8083<br/>MySQL, vendor master, POs,<br/>ERP adapter, recovery queue"]
    end
    AI1[Document AI service - mock]
    DB[(MySQL 8)]
    ERP[Simulated ERP - XML]
    FS[(Document storage)]

    SP --> XAPI
    AA --> XAPI
    DF --> PAPI
    XAPI -->|upload / process / decisions| PAPI
    XAPI -->|simple reads| SAPI
    PAPI --> SAPI
    PAPI -->|extract| AI1
    SAPI --> DB
    SAPI --> ERP
    SAPI --> FS
```

| Layer | Owns | Does **not** do |
|---|---|---|
| Experience | Consumer-facing contract, authentication, role checks, file validation, HTTP status mapping, Idempotency-Key | Business rules, persistence |
| Process | The invoice workflow and every business decision (DataWeave), retries, recovery, approval rules | SQL, ERP protocol details |
| System | Data access (parameterized SQL), transactions, ERP XML protocol, document storage | Business decisions |

**Design decision:** the Experience API reads invoices, vendors, POs and history directly from the System API. These reads need no orchestration, and an extra hop through the Process API would add latency without adding value. All writes go through the Process API.

## 2. Processing sequence (upload of a PDF)

```mermaid
sequenceDiagram
    autonumber
    participant S as Supplier
    participant X as Experience API
    participant P as Process API
    participant Y as System API
    participant A as Document AI
    participant E as ERP
    S->>X: POST /api/invoices/upload (multipart, Basic auth)
    X->>X: authenticate, authorize, type/size/magic bytes, SHA-256
    X->>P: POST /process/v1/invoices {document}
    P->>Y: POST /sys/v1/invoices (store file + row, idempotent on SHA-256)
    P->>Y: PATCH status PROCESSING
    P->>A: extract (until-successful)
    A-->>P: raw fields + confidence
    P->>P: normalize -> JSON schema -> field validation
    P->>Y: PUT extraction (+ line items, bulk insert)
    P->>Y: GET vendor / GET duplicates / GET purchase order
    P->>P: vendor check, duplicate check, PO match, totals, tax, routing
    P->>Y: PATCH status (decision, optimistic lock, audit, line matches)
    alt auto-approved (total <= 1,000, no exceptions)
        P->>Y: POST /sys/v1/erp/invoices
        Y->>E: APInvoice XML (retry)
        E-->>Y: DocumentNumber
        Y->>Y: store doc no. + consume PO (transaction)
        P->>Y: PATCH status POSTED_TO_ERP
    end
    P-->>X: ProcessingResult
    X-->>S: 201 / 202 / 409 / 422 + result
```

## 3. Invoice state machine

```mermaid
stateDiagram-v2
    [*] --> RECEIVED
    RECEIVED --> PROCESSING
    PROCESSING --> EXTRACTION_FAILED: AI failed (queued)
    EXTRACTION_FAILED --> PROCESSING: recovery retry
    EXTRACTION_FAILED --> FAILED: max attempts (dead letter)
    PROCESSING --> DUPLICATE
    PROCESSING --> VALIDATION_FAILED
    PROCESSING --> MANUAL_REVIEW
    PROCESSING --> PENDING_APPROVAL
    PROCESSING --> APPROVED: auto-approve
    MANUAL_REVIEW --> APPROVED: MANAGER+ approves
    MANUAL_REVIEW --> REJECTED
    PENDING_APPROVAL --> PENDING_APPROVAL: level 1 of 2 approved
    PENDING_APPROVAL --> APPROVED: last level approved
    PENDING_APPROVAL --> REJECTED
    APPROVED --> POSTED_TO_ERP
    APPROVED --> ERP_POSTING_FAILED: ERP down (queued)
    ERP_POSTING_FAILED --> POSTED_TO_ERP: recovery retry
    ERP_POSTING_FAILED --> FAILED: max attempts (dead letter)
    POSTED_TO_ERP --> [*]
    REJECTED --> [*]
    DUPLICATE --> [*]
    VALIDATION_FAILED --> [*]
```

## 4. Routing rules (approval-routing.dwl)

| Precedence | Condition | Result |
|---|---|---|
| 1 | Exact duplicate (same vendor and normalized number) | `DUPLICATE` |
| 2 | BLOCKING issue and AI confidence >= 0.50 | `VALIDATION_FAILED` (back to supplier) |
| 3 | BLOCKING issue with unreliable extraction, any REVIEW issue, or confidence < 0.85 | `MANUAL_REVIEW` (MANAGER, or FINANCE_DIRECTOR above 50k) |
| 4 | total <= 1,000 | `APPROVED`, then posted to the ERP automatically |
| 5 | total <= 10,000 | `PENDING_APPROVAL` [APPROVER] |
| 6 | total <= 50,000 | `PENDING_APPROVAL` [MANAGER] |
| 7 | total > 50,000 | `PENDING_APPROVAL` [MANAGER, FINANCE_DIRECTOR] |

All thresholds and tolerances are properties in `invoice-process-api/src/main/resources/config/*.yaml` (`approval.*`, `validation.*`).

**Issue catalogue**

| Severity | Codes |
|---|---|
| BLOCKING | MISSING_REQUIRED_FIELD, INVALID_FORMAT, UNSUPPORTED_CURRENCY, INVALID_DATE, INVOICE_TOO_OLD, INVALID_VALUE, VENDOR_NOT_FOUND, VENDOR_INACTIVE, VENDOR_NOT_IDENTIFIED, SCHEMA_VALIDATION_FAILED |
| REVIEW | LOW_CONFIDENCE, LOW_CONFIDENCE_FIELDS, PO_MISSING, PO_NOT_FOUND, PO_VENDOR_MISMATCH, PO_NOT_OPEN, PO_CURRENCY_MISMATCH, PO_AMOUNT_EXCEEDED, UNMATCHED_LINE, QUANTITY_EXCEEDS_PO, PRICE_VARIANCE, LINE_AMOUNT_MISMATCH, SUBTOTAL_MISMATCH, TOTAL_MISMATCH, TAX_RATE_MISMATCH, TAX_AMOUNT_MISMATCH, TAX_MISSING, VENDOR_NAME_MISMATCH, VENDOR_CURRENCY_MISMATCH, VENDOR_AMBIGUOUS, POSSIBLE_DUPLICATE, SUBTOTAL_MISSING |
| INFO | DUE_DATE_DERIVED, EXTRACTION_WARNING |

## 5. Reliability patterns

| Concern | Implementation | Where |
|---|---|---|
| Transient AI failures | `until-successful` (3 attempts); 4xx are not retried; 429/529/5xx are | `ai-extraction-*-sub-flow` |
| Transient ERP failures | `until-successful` in the System API, then the recoverable queue | `erp.xml`, `erp-posting-sub-flow` |
| Long outages | `recovery_queue` table, Scheduler + Batch Job, exponential backoff `60s * 2^(n-1)` capped at 1h, `DEAD` after 5 attempts (dead letter), invoice `FAILED` | `recovery.xml`, `recovery-queue.xml`, `recovery-backoff.dwl` |
| Multiple workers | `SELECT ... FOR UPDATE SKIP LOCKED` claim, stale `IN_PROGRESS` reclaimed after 15 min | `sys-claim-recovery-flow` |
| Duplicate uploads | SHA-256 unique index, so the same file returns the same invoice (`idempotentReplay`) | `sys-create-invoice-flow` |
| Client retries | `Idempotency-Key` header, so the stored response is replayed for 24h (Object Store) | Experience `idempotency-*-sub-flow` |
| Duplicate invoices | Normalized number check + `dedupe_key` STORED generated column with a UNIQUE index (race-proof) | `duplicate-detection.dwl`, `invoices.dedupe_key` |
| Double ERP posting | `erp_document_number IS NULL` guard + ERP idempotent on `ExternalReference` | `erp.xml`, mock ERP |
| Concurrent approvals | Object Store lock (`failIfPresent`), unique `(invoice, level)` and `(invoice, user)`, optimistic `version` check | `approvals.xml` |
| DB outages | Connection pool + reconnection strategy; `DB:CONNECTIVITY` maps to 503 | `global.xml` (System) |
| Traceability | `X-Correlation-ID` on every hop, MDC in log4j pattern, `processing_audit_logs.correlation_id` | all apps |

## 6. Security

| Control | Implementation |
|---|---|
| Authentication (public) | HTTP Basic against SHA-256 hashed users (`security/users.json`). In production, replace with an API Manager OAuth 2.0 / JWT policy |
| Authorization | Role checks per endpoint (`authorize-sub-flow`); approval levels APPROVER < MANAGER < FINANCE_DIRECTOR; segregation of duties; suppliers see only their own invoices |
| Service-to-service | `client_id` / `client_secret` headers between layers (replace with Client ID Enforcement policies in Anypoint) |
| Secrets | Never in code. `UPPER_SNAKE` properties are overridden by environment variables; prod uses `secure::` encrypted values plus `-Dmule.key`; `mule-artifact.json` marks them as secure (hidden in Runtime Manager) |
| Input validation | Extension allow-list, magic-byte check, size limit (Content-Length precheck and decoded size), file-name sanitising, UUID/regex checks on path params, JSON schema, parameterized SQL only |
| Transport | HTTPS on CloudHub ingress; TLS listener template in Experience `global.xml` |
| Logging | JSON event logs with ids and statuses only; no payloads, documents, credentials or tokens; 5xx bodies never expose internals |
