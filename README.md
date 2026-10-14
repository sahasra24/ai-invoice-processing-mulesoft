# AI-Powered Invoice Processing & ERP Integration (MuleSoft Mule 4)

An end-to-end, enterprise-style integration platform. It receives supplier invoices as **PDF, image or JSON**, extracts the data with an **AI document-extraction service** (a free local mock is included), validates it, detects duplicates, matches it against **purchase orders**, routes it through a **role-based approval workflow**, and posts approved invoices to a **simulated ERP**, with a full audit trail and automatic recovery from failures.

Built with **API-led connectivity** (Experience, Process and System APIs) on **Mule 4.9 / Java 17**.

![Architecture](docs/architecture.svg)

## Highlights

| Area | What it demonstrates |
|---|---|
| API-led design | 3 Mule apps with clear responsibilities; [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) |
| AI document processing | Pluggable document-AI extraction (zero-cost local mock service included) with per-field confidence scores, JSON-schema validation and manual review for uncertain results |
| DataWeave 2.0 | 20+ scripts: normalization, validation, duplicate detection, PO matching, totals/tax, approval routing, JSON to XML ERP mapping, error formatting |
| Connectors & scopes | HTTP, Database (MySQL), File, Object Store, Validation, JSON schema, Secure Properties, Scheduler, Batch Job, For Each, Choice, Try/transactions, Until Successful, Idempotent Message Validator |
| Reliability | Retries, recoverable failure queue with exponential backoff + dead letter, 3-level idempotency, optimistic locking, race-proof duplicate protection |
| Security | Basic auth + RBAC, segregation of duties, client credentials between layers, encrypted properties, file magic-byte checks, no sensitive data in logs |
| Testing | 36 MUnit tests, 32 offline DataWeave checks, 14 mock-service tests, 49-request Postman collection; [docs/TESTING.md](docs/TESTING.md) |

## Repository layout

```
ai-invoice-processing/
├── invoice-experience-api/     # :8081  public API: upload, status, approve/reject, search
├── invoice-process-api/        # :8082  orchestration, AI, validation, routing, approvals, recovery
├── invoice-system-api/         # :8083  MySQL, vendors, POs, ERP adapter, recovery queue
│   └── src/main/{mule,resources/{dwl,config,schemas}}, src/test/{munit,resources}
├── database/                   # 01-schema.sql, 02-sample-data.sql, 03-useful-queries.sql
├── mock-services/              # mock AI extraction + mock ERP (Python, no dependencies)
├── sample-invoices/            # pdf/, images/, json/, invalid/, expected/ (extracted JSON)
├── postman/                    # collection + local environment
├── tools/                      # sample generator, DataWeave test harness, env loader
├── config/                     # .env.example, Studio VM arguments
├── docs/                       # architecture, API reference, guides, troubleshooting, resume
└── docker-compose.yml          # MySQL + mock services
```

## Quick start (about 10 minutes)

```bash
# 1. Infrastructure: MySQL with schema + sample data, and the mock AI/ERP on :8090
docker compose up -d
#    (no Docker? run database/*.sql in MySQL and: python mock-services/mock_server.py)

# 2. Anypoint Studio: File > Import > Anypoint Studio project from File System (x3)
#    Run > Run Configurations > Mule Applications > tick all three apps > VM args: -M-Denv=local > Run

# 3. Upload an invoice
curl -u supplier1:Supplier#2026 \
     -F "file=@sample-invoices/pdf/INV-2026-1001_acme_auto-approve.pdf" \
     http://localhost:8081/api/invoices/upload
# -> 201 {"status":"POSTED_TO_ERP","erp":{"documentNumber":"5100000001",...}, ...}
```
Then import the Postman collection and run all scenarios. The full walkthrough is in [docs/DEVELOPMENT-GUIDE.md](docs/DEVELOPMENT-GUIDE.md).

### Demo users (local only)

| User | Password | Role | Can |
|---|---|---|---|
| supplier1 / supplier2 | Supplier#2026 | SUPPLIER | upload, see own invoices |
| apclerk1 | Clerk#2026 | AP_CLERK | upload, see all, vendors/POs |
| approver1 | Approver#2026 | APPROVER | approve up to 10,000 |
| manager1 | Manager#2026 | MANAGER | approve up to 50,000, resolve manual review |
| director1 | Director#2026 | FINANCE_DIRECTOR | final approval above 50,000 |
| admin1 | Admin#2026 | ADMIN | upload, view |

Passwords are stored only as SHA-256 hashes in `invoice-experience-api/src/main/resources/security/users.json`.

## Business workflow

1. A supplier uploads a PDF, image or JSON invoice (API or drop folder).
2. The Experience API authenticates the user and validates file type, magic bytes and size.
3. The System API stores the document (idempotent on SHA-256) and the invoice is registered as `RECEIVED`.
4. AI extraction runs with retries.
5. DataWeave normalizes the result to canonical JSON, then it is validated against a JSON schema.
6. Required fields, formats, dates and confidence are validated.
7. The vendor is verified against the vendor master.
8. Duplicates are checked (normalized number, same total and date, DB unique key).
9. Two-way PO matching runs (vendor, status, currency, quantities, price tolerance, remaining amount).
10. Line, subtotal, total and tax arithmetic is verified.
11. Routing: `DUPLICATE` / `VALIDATION_FAILED` / `MANUAL_REVIEW` / auto-approve (≤ 1,000) / approval chain by threshold.
12. Approved invoices are posted to the ERP (XML) and the PO is consumed.
13. Every step is written to the audit trail, and the final status is returned.

Approval thresholds: ≤ 1,000 auto-approve · ≤ 10,000 APPROVER · ≤ 50,000 MANAGER · > 50,000 MANAGER, then FINANCE_DIRECTOR. All thresholds are configurable in `invoice-process-api/.../config/*.yaml`.

## Documentation

| Document | Contents |
|---|---|
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | Diagrams, sequence, state machine, routing rules, reliability and security design |
| [docs/API-REFERENCE.md](docs/API-REFERENCE.md) | Every endpoint: request/response JSON, status codes, validation rules, errors |
| [docs/DEVELOPMENT-GUIDE.md](docs/DEVELOPMENT-GUIDE.md) | Build and run from scratch; flow-by-flow components, configuration, XML, DataWeave, tests |
| [docs/DATAWEAVE-GUIDE.md](docs/DATAWEAVE-GUIDE.md) | Every script, where it lives in Studio, inputs/outputs, lessons learned |
| [docs/TESTING.md](docs/TESTING.md) | What was executed vs. what still needs a Mule runtime; coverage map |
| [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md) | Standalone runtime, CloudHub 2.0, hardening checklist, monitoring |
| [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) | Build, startup, runtime, AI, recovery queue, Postman issues |
| [docs/RESUME.md](docs/RESUME.md) | Resume bullets, elevator pitch, interview Q&A |

## Versions

| Component | Version |
|---|---|
| Mule runtime | 4.9.0 (Java 17) |
| mule-maven-plugin | 4.10.2 |
| HTTP connector | 1.12.2 |
| Database connector | 1.16.3 + mysql-connector-j 8.4.0 |
| File connector | 1.5.6 |
| Object Store connector | 1.3.2 |
| Validation module | 2.0.10 |
| JSON module | 2.5.5 |
| Secure Configuration Properties | 1.3.1 |
| MUnit | 3.7.5 |

All versions were confirmed to exist in the MuleSoft repository and to support Java 17.

## Verification status

The DataWeave logic, mock services, sample data and file formats were **executed and tested**. The Mule flows and MUnit suites are complete but were **not run** in the authoring environment, which had no Mule runtime. See [docs/TESTING.md](docs/TESTING.md) for the exact list.

## License
MIT
