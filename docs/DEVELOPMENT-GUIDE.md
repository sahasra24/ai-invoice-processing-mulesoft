# Step-by-Step Development Guide (Anypoint Studio)

This guide covers two things:
- **Part A:** how to get the finished project running from scratch.
- **Part B:** how each major flow is built: which Mule Palette components it uses, how they're configured, the XML, the DataWeave, inputs and outputs, and how to test it. Use Part B to rebuild the flows yourself or to explain them in an interview.

---

## Part A - Build and run from scratch

### A1. Prerequisites

| Tool | Version | Notes |
|---|---|---|
| Anypoint Studio | 7.21+ (bundles Mule 4.9.x) | Free 30-day trial runtime is enough |
| JDK | 17 | Studio ships with one |
| Maven | 3.9+ | Optional. Studio has an embedded Maven |
| MySQL | 8.0 / 8.4 | Or `docker compose up -d` |
| Python | 3.9+ | Mock AI + ERP service (no pip packages needed) |
| Postman | latest | Collection in `/postman` |

### A2. Database

**Option 1: Docker** (database and mock services together)
```bash
docker compose up -d
```

**Option 2: native MySQL**
```bash
mysql -u root -p < database/01-schema.sql
mysql -u root -p < database/02-sample-data.sql
```

The schema creates the least-privilege account `invoice_app` / `ChangeMe_Local_2026!`. For anything other than a local demo, change that password and set `DB_PASSWORD`.

### A3. Mock services

```bash
cd mock-services
python mock_server.py          # http://localhost:8090/health
```
Skip this step if you started them with Docker.

### A4. Import the three projects into Studio

1. Open Studio and choose **File > Import... > Anypoint Studio > Anypoint Studio project from File System**.
2. Choose `invoice-system-api` and finish. Repeat for `invoice-process-api` and `invoice-experience-api`.
3. Studio resolves Maven dependencies automatically (watch the progress bar at the bottom right). If a dependency fails, see TROUBLESHOOTING.md §1.
4. Check that the **Mule Palette** shows HTTP, Database, File, Object Store, Validation, JSON and Secure Properties. These come from each `pom.xml`.

### A5. Configure

Defaults in each app's `src/main/resources/config/local.yaml` work out of the box with the Docker setup.

To override a value without editing files, set an **environment variable with the same name**: `Run > Run Configurations > Mule Applications > (config) > Environment`. Common overrides:
- `DB_PASSWORD`
- `DOCUMENT_STORAGE_DIR`, `FILE_INBOUND_DIR`, `FILE_ARCHIVE_DIR` (on Windows, for example `C:/invoice-data/...`)

`config/.env.example` lists every variable.

### A6. Run all three apps together

1. Go to **Run > Run Configurations... > Mule Applications > New**.
2. On the **General** tab, tick all three projects (one runtime, three apps, ports 8081 / 8082 / 8083).
3. On the **Arguments** tab, add `-M-Denv=local`.
4. Click **Run**. The console should show `DEPLOYED` for each app.

Check that everything is up:
```bash
curl http://localhost:8083/sys/v1/health       # {"status":"UP","database":"UP"}
curl http://localhost:8082/process/v1/health   # {"status":"UP","aiProvider":"mock"}
curl http://localhost:8081/api/health
```

### A7. First invoice

```bash
curl -u supplier1:Supplier#2026 \
     -F "file=@sample-invoices/pdf/INV-2026-1001_acme_auto-approve.pdf" \
     http://localhost:8081/api/invoices/upload
```
Expected result: **201** with `"status": "POSTED_TO_ERP"` and an `erp.documentNumber`.

### A8. Postman

1. Import `postman/AI-Invoice-Processing.postman_collection.json` and `postman/AI-Invoice-local.postman_environment.json`.
2. Go to **Settings > General > Working directory** and set it to the repository root, so the `sample-invoices/...` file paths resolve.
3. Select the *AI Invoice - local* environment and open the **Collection Runner**.
4. Run the folders in order (00 to 06). Folder 04's ERP-failure invoice reaches `POSTED_TO_ERP` after about 2 to 4 minutes through the recovery scheduler.

To rerun the collection from a clean state, reload `database/02-sample-data.sql` and call `POST http://localhost:8090/admin/reset`.

### A9. Tests

| What | How | Needs |
|---|---|---|
| MUnit (unit) | Right-click the project, then **Run MUnit**, or `mvn clean test` in an app folder | nothing external |
| MUnit (DB integration) | `cd invoice-system-api && mvn test -Dmunit.tags=integration` | MySQL with sample data |
| DataWeave pipeline | `DW_CLI=/path/to/dw python tools/dataweave-tests/run_pipeline_tests.py` | DataWeave CLI |
| Mock services | `cd mock-services && python -m unittest discover -s tests -v` | Python |

When running MUnit from Studio, add `-Denv=test` as a VM argument. The Maven build sets it automatically.

---

## Part B - Flow-by-flow walkthrough

Conventions used in every app:
- Each HTTP listener returns `vars.httpStatus` (or a default) and echoes `X-Correlation-ID`.
- A single `global-error-handler`, referenced through `<configuration defaultErrorHandler-ref>`, turns any error into the standard error body.
- Business decisions are made only in DataWeave files; flows only orchestrate.

### B1. System API: `sys-create-invoice-flow` (Database + File connector, transaction)

**Purpose:** register an invoice and its source document exactly once.

| # | Palette component | Configuration | Why |
|---|---|---|---|
| 1 | HTTP **Listener** | config `sys-api-listener-config`, path `/sys/v1/invoices`, method POST, response status `#[vars.httpStatus default 201]` | REST entry point |
| 2 | **Flow Reference** | `sys-client-auth-sub-flow` | Internal client credentials (Choice + Raise Error) |
| 3 | Validation **Is true** (x3) | source channel, submittedBy, document fields with SHA-256 regex | Fail fast with 400 |
| 4 | Database **Select** (target `existingDocs`) | `SELECT ... WHERE d.content_sha256 = :sha256` | Content idempotency |
| 5 | **Choice** | when not empty: replay (200) | Same file returns the same invoice |
| 6 | **Set Variable** | `invoiceId = uuid()` | Primary key |
| 7 | File **Write** | `document-storage-config`, path `<invoiceId>/<safeName>`, mode CREATE_NEW, content `fromBase64(...)` | Store the bytes outside the DB |
| 8 | **Try** (Transactional action ALWAYS_BEGIN, LOCAL) | contains 3 Database **Insert**s (invoice, document, audit) | All or nothing |
| 9 | Transform Message | response `{invoiceId, status: "RECEIVED"}` | |

XML: `invoice-system-api/src/main/mule/invoices.xml`. Parameterized SQL example:
```xml
<db:insert config-ref="invoice-db-config" doc:name="Insert invoice">
  <db:sql><![CDATA[INSERT INTO invoices (invoice_id, status, source_channel, submitted_by, correlation_id)
VALUES (:invoiceId, 'RECEIVED', :sourceChannel, :submittedBy, :correlationId)]]></db:sql>
  <db:input-parameters><![CDATA[#[{ invoiceId: vars.invoiceId, sourceChannel: vars.request.sourceChannel,
     submittedBy: vars.request.submittedBy, correlationId: correlationId }]]]></db:input-parameters>
</db:insert>
```
**Input:** `{ "sourceChannel": "API_UPLOAD", "submittedBy": "supplier1", "document": { "fileName": "a.pdf", "mimeType": "application/pdf", "sizeBytes": 2011, "sha256": "<64 hex>", "contentBase64": "JVBERi0x..." } }`
**Output:** `201 { "invoiceId": "...", "status": "RECEIVED", "idempotentReplay": false }`. Sending the same body again returns `200 ... "idempotentReplay": true`.
**Test:** `sys-db-integration-test-suite.xml > it-create-and-idempotent-replay`.

### B2. System API: `sys-update-status-flow` (optimistic locking, For Each)

| # | Component | Configuration |
|---|---|---|
| 1 | Listener | PATCH `/sys/v1/invoices/{invoiceId}/status` |
| 2 | Validation Is true | status is in the allowed list |
| 3 | DB Select | current status and version |
| 4 | Try (transaction) / DB **Update** | `... WHERE invoice_id = :invoiceId AND (:expectedStatus IS NULL OR status = :expectedStatus) AND (:expectedVersion IS NULL OR version = :expectedVersion)` |
| 5 | Choice | `affectedRows == 0` raises APP:CONFLICT (409 STALE_UPDATE) |
| 6 | **For Each** | `vars.change.fields.lineMatches`, then DB Update `invoice_line_items` (PO line, match status) |
| 7 | DB Insert | audit row (from and to status) |

**Why:** two approvers or two workers can never overwrite each other. The unique `dedupe_key` index makes a concurrent duplicate fail with `Duplicate entry`, which the error handler maps to 409 `DUPLICATE_RECORD`. The Process API then marks the invoice as DUPLICATE.
**Test:** `it-optimistic-lock-conflict`.

### B3. System API: `sys-post-invoice-to-erp-flow` (JSON to XML, retry, idempotency)

| # | Component | Configuration |
|---|---|---|
| 1 | Listener | POST `/sys/v1/erp/invoices` |
| 2 | Flow Ref | `sys-load-invoice-sub-flow` (4 DB selects + `invoice-view.dwl`) |
| 3 | Choice | already has an ERP doc number, so return ALREADY_POSTED; not APPROVED, so 409 |
| 4 | Transform | `dwl/erp-payload.dwl` (namespaced XML) |
| 5 | Try > **Until Successful** (`maxRetries=${erp.retry.maxRetries}`) > HTTP **Request** | `erp-request-config` with Basic auth; response validator `200..299,400..499`, so 4xx is not retried |
| 6 | Transform | `dwl/erp-response.dwl` (XML to JSON) |
| 7 | Choice | not success raises 422 ERP_REJECTED |
| 8 | Try (transaction) | store doc number (guard `erp_document_number IS NULL`), consume PO amount, For Each consumes PO line quantities, audit |

**Output:** `{ "erpStatus": "POSTED", "erpDocumentNumber": "5100000001", "fiscalYear": "2026", "postedAt": "..." }`
**Tests:** `sys-erp-test-suite.xml` covers success, 503 retried then 502, and 400 not retried then 422.

### B4. Process API: `process-create-invoice-flow` + `process-invoice-orchestration-sub-flow`

This is the heart of the system. It implements business steps 3 to 13.

```
Listener POST /process/v1/invoices
 ├─ process-client-auth-sub-flow
 ├─ init-context-sub-flow            (vars.config, vars.sysHeaders)
 ├─ Validation: document complete, supported mime
 └─ register-invoice-sub-flow
     ├─ HTTP Request: SYS - Create invoice
     └─ Choice: replay | autoProcess=false | orchestration
          process-invoice-orchestration-sub-flow
           ├─ SYS - Update status (PROCESSING)
           ├─ Try: Choice(json?) -> JSON envelope | ai-extraction-sub-flow
           │     on-error-continue APP:AI_EXTRACTION_FAILED -> enqueue + EXTRACTION_FAILED
           ├─ validate-and-route-sub-flow
           │   ├─ Transform  normalize-ai-response.dwl
           │   ├─ Try: JSON Validate schema (canonical-invoice-schema.json)
           │   ├─ Transform  validate-invoice-fields.dwl          -> vars.fieldValidation
           │   ├─ SYS - Save extraction, audit
           │   ├─ Choice: vendor id | name | none -> SYS - Get vendor / Search vendor
           │   ├─ Transform  vendor-verification.dwl             -> vars.vendorCheck
           │   ├─ SYS - Duplicate check + duplicate-detection.dwl -> vars.duplicateCheck
           │   ├─ SYS - Get purchase order
           │   ├─ Transform  po-matching.dwl + calculate-invoice-totals.dwl
           │   ├─ Transform  tax-validation.dwl
           │   ├─ Transform  approval-routing.dwl                -> vars.decision
           │   ├─ Try: SYS - Update status (decision) [409 DUPLICATE_RECORD -> DUPLICATE]
           │   └─ Choice: APPROVED -> erp-posting-sub-flow
           └─ Transform  processing-result.dwl
```

Key component settings:
- **HTTP Request** to the System API: `config-ref="sys-api-request-config"`, headers `#[vars.sysHeaders]` (client credentials plus `X-Correlation-ID`), response validator `200..499`, followed by `check-downstream-sub-flow`. This sub-flow turns a 4xx into `APP:DOWNSTREAM_REJECTED` while keeping the downstream status and code.
- For lookups where 404 is a normal business answer (vendor, PO), the validator is `200..299,400,404`, and the status is stored: `vars.vendorLookup = { lookupType: 'ID', status: attributes.statusCode, body: payload }`.
- **Transform Message** with `<ee:variables>` writes check results into variables, so the canonical invoice stays in the payload.
- **JSON Validate schema**: errors of type `JSON:SCHEMA_NOT_HONOURED` are caught and recorded, not thrown. That way the response lists every problem.

**Input/output:** see `docs/API-REFERENCE.md` (ProcessingResult) and `sample-invoices/expected/*.expected.json`.
**Tests:** `process-orchestration-test-suite.xml` has 10 tests: success, duplicate, invalid vendor, missing fields, AI failure, incorrect totals, low confidence, ERP failure, 401, 400.

### B5. Process API: AI extraction sub-flow

**`ai-extraction-mock-sub-flow`**
- **Try > Until Successful** (`maxRetries=${ai.retry.maxRetries}`, `millisBetweenRetries=${ai.retry.intervalMs}`) > HTTP Request `POST /ai/v1/extract` with `Authorization: Bearer <MOCK_AI_API_KEY>`.
- Response validator `200..299,400..499`: permanent errors are not retried.
- The error handler uses **On Error Propagate** containing **Raise Error** `APP:AI_EXTRACTION_FAILED`. This maps any technical failure to one business error type.


The sub-flow returns a provider-neutral envelope, `{provider, model, warnings, extraction}`, so everything downstream is provider-agnostic. To plug in a commercial OCR or document-AI service, replace only the HTTP request and map its response to this envelope.

### B6. Process API: `process-invoice-decision-flow` (approvals, Object Store)

| # | Component | Configuration |
|---|---|---|
| 1 | Listener | POST `/process/v1/invoices/{invoiceId}/decisions` |
| 2 | Validation | decision is APPROVE or REJECT; username not blank |
| 3 | Object Store **Store** | key `decision-<invoiceId>`, `approval-lock-store` (TTL 60s), **failIfPresent=true**. A concurrent request gets `OS:KEY_ALREADY_EXISTS`, which becomes 409 |
| 4 | Try | load invoice, run `approval-authorization.dwl`, Choice (not allowed raises a 403/409/400 override), record approval, update status with optimistic lock, Choice (APPROVED triggers ERP posting), Object Store **Remove** |
| 5 | Error handler | On Error Propagate removes the lock (nested Try), then the global handler responds |

**Input:** `{ "decision": "APPROVE", "username": "manager1", "roles": ["MANAGER"], "comments": "ok" }`
**Tests:** `process-approval-test-suite.xml` covers insufficient authority, level 1 of 2, final approval posting to the ERP, segregation of duties, and rejection without a reason.

### B7. Process API: `file-intake-flow` (File connector, idempotent receiver)

| Component | Configuration |
|---|---|
| File **On New or Updated File** | `inbound-file-config`, directory `.`, matcher `regex:(?i)^[^.].*\.(pdf\|png\|jpg\|jpeg\|json)$`, `autoDelete=true`, `timeBetweenSizeCheck=2s` (waits for complete files), polling `${file.pollFrequencyMs}` |
| **Idempotent Message Validator** | `idExpression = fileName \| size \| lastModifiedTime`, objectStore `file-idempotency-store` (7 days) |
| Transform | builds the document (MIME by extension, SHA-256, base64) |
| Flow Ref | `register-invoice-sub-flow` (same pipeline as the API) |
| File **Write** | `archive/processed/<timestamp>_<name>`, or `failed/` in the error handler |

`initialState="${file.flowState}"` lets you disable the flow per environment. It's `stopped` on CloudHub, where there's no shared disk.
**Try it:** copy `sample-invoices/pdf/INV-2026-1002_globex_single-approval.pdf` into `FILE_INBOUND_DIR`. Within about 10 seconds the log shows `file.processed` and the invoice appears in `GET /api/invoices`.

### B8. Process API: `recovery-scheduler-flow` (Scheduler + Batch Job, dead letter)

| Component | Configuration |
|---|---|
| **Scheduler** | fixed frequency `${recovery.pollFrequencyMs}`, `disallowConcurrentExecution=true` |
| HTTP Request | `POST /sys/v1/recovery-queue/claim?limit=10` (FOR UPDATE SKIP LOCKED) |
| Set Payload | `output application/java` (Batch needs a collection) |
| **Batch Job** | `maxFailedRecords=-1`, `blockSize=5`, `maxConcurrency=2` |
| Batch Step `recover-item-step` | Flow Ref `recover-queue-item-sub-flow` |
| Batch Step (ONLY_FAILURES) | logs unexpected failures |
| On Complete | logs `totalRecords`, `successfulRecords`, `failedRecords` |

`recover-queue-item-sub-flow` sets `vars.recoveryFailureType`, so the AI and ERP sub-flows **propagate** errors instead of re-queueing them. On error, `recovery-backoff.dwl` computes the next attempt (`60s * 2^(n-1)`, capped at 1h) or marks the item `DEAD`. The invoice then becomes `FAILED`, which is the dead letter.

**Try it:** upload `ERPFAIL-2026-0001_acme_erp-failure.pdf`. The mock ERP fails 3 times, so the result is 202 ERP_POSTING_FAILED. About 1 to 3 minutes later the scheduler retries and the status becomes POSTED_TO_ERP. The `history` endpoint shows each attempt.

### B9. Experience API: `post-invoice-upload-flow` (security and validation)

| # | Component | Purpose |
|---|---|---|
| 1 | Listener | POST `/api/invoices/upload`; adds `Idempotent-Replay` and `WWW-Authenticate` headers |
| 2 | Flow Ref `authenticate-sub-flow` | `authenticate.dwl`: Basic header, then SHA-256 compare against `security/users.json` |
| 3 | Set Variable + Flow Ref `authorize-sub-flow` | `requiredRoles = ['SUPPLIER','AP_CLERK','ADMIN']` |
| 4 | Choice | not multipart returns 415; Content-Length over the limit returns 413 before the body is parsed |
| 5 | Flow Ref `idempotency-lookup-sub-flow` | Object Store `contains`/`retrieve` keyed by user, path and Idempotency-Key |
| 6 | Transform `extract-upload-part.dwl` | `payload.parts.file`, using `.^raw` bytes |
| 7 | Transform `upload-validation.dwl` | extension allow-list, magic bytes, size, safe name, SHA-256 |
| 8 | HTTP Request | Process API, then `check-downstream-sub-flow` |
| 9 | Transform `result-http-status.dwl` | 200/201/202/409/422 |
| 10 | Flow Ref `idempotency-save-sub-flow` | stores `{httpStatus, body}` for 24h |

**Tests:** `experience-api-test-suite.xml` (9 tests).

### B10. Global error handling (all apps)

```xml
<configuration defaultErrorHandler-ref="global-error-handler"/>
<error-handler name="global-error-handler">
  <on-error-continue type="ANY" logException="false">
    <set-variable variableName="correlationIdValue" value="#[correlationId]"/>
    <ee:transform><ee:message><ee:set-payload resource="dwl/error-response.dwl"/></ee:message></ee:transform>
    <set-variable variableName="httpStatus" value="#[payload.httpStatus]"/>
    <!-- ERROR log for 5xx, WARN for 4xx (no payloads) -->
    <set-payload value="#[output application/json --- payload.body]" mimeType="application/json"/>
  </on-error-continue>
</error-handler>
```
**Why `on-error-continue`:** the flow completes "successfully" with an error body. The listener's normal response then returns `vars.httpStatus` (4xx/5xx), and the error body format is consistent everywhere.

**Error type map:**

| Error type | HTTP status |
|---|---|
| APP:UNAUTHORIZED | 401 |
| APP:FORBIDDEN | 403 |
| VALIDATION:* | 400 |
| JSON:SCHEMA_NOT_HONOURED | 400 |
| OS:KEY_ALREADY_EXISTS | 409 |
| MULE:DUPLICATE_MESSAGE | 409 |
| DB:QUERY_EXECUTION with "Duplicate entry" | 409 |
| HTTP:CONNECTIVITY | 503 |
| DB:CONNECTIVITY | 503 |
| HTTP:TIMEOUT | 504 |
| Downstream 4xx | propagated as-is |
| Downstream 5xx | 502 |
| Anything else | 500, generic message |

### B11. Interview talking points

- **Why three APIs?** Reuse and change isolation. A new mobile channel only needs a new Experience API, and replacing MySQL or the ERP only touches the System API.
- **Where is the business logic?** In 12 small, pure DataWeave scripts. They're testable with the DataWeave CLI and MUnit, and reviewers can read the rules in one place.
- **AI safety net:** structured output, then JSON schema, then field rules, then confidence thresholds, then human review. The AI never posts to the ERP unchecked, and AI failures go to a retry queue rather than being lost.
- **Idempotency at three levels:**
  - the client's Idempotency-Key
  - the document's SHA-256
  - the ERP's ExternalReference, plus the DB `dedupe_key` for duplicate invoices
- **Concurrency:** an Object Store lock, unique keys, optimistic `version` checks, and `SKIP LOCKED` queue claims.
- **Observability:** correlation IDs across every hop, JSON event logs, and a DB audit trail you can query per invoice or per request.
