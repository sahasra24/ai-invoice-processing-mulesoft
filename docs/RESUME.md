# Resume & Interview Material

## Project title
**AI-Powered Invoice Processing & ERP Integration Platform** (MuleSoft Mule 4, API-led connectivity)

## One-line summary
Built an AI-powered invoice processing platform on MuleSoft Mule 4 with three API-led layers. It extracts invoice data from PDFs and images with AI, validates the results, and routes each invoice to touchless ERP posting or a role-based approval workflow.

## Resume bullets (pick 3-5)
- Designed and built a **3-layer API-led integration** (Experience / Process / System APIs) in **MuleSoft Mule 4.9** that automates accounts-payable invoice processing end to end, from PDF/image upload to ERP posting.
- Integrated **AI document extraction** behind a provider-neutral contract, with a locally runnable document-AI service. Added per-field confidence scoring, JSON-schema validation and human-in-the-loop routing for uncertain extractions.
- Implemented the core business rules in **12 modular DataWeave 2.0 scripts**: normalization, field and tax validation, duplicate detection, two-way PO matching with price and quantity tolerances, and threshold-based multi-level approval routing. Built a **32-check offline test harness** with the DataWeave CLI.
- Engineered **enterprise reliability patterns**:
  - `until-successful` retries
  - a MySQL-backed recoverable failure queue processed by **Scheduler + Batch Job** with exponential backoff and dead-lettering
  - three-level idempotency: Idempotency-Key, SHA-256 content hash, and ERP external reference
  - race-proof duplicate protection with a unique generated column
- Secured the platform with **Basic auth + role-based access control**, segregation of duties, Object Store approval locks, optimistic locking, file magic-byte and size validation, encrypted **secure properties**, and correlation-ID structured logging that never logs sensitive data.
- Delivered **36 MUnit tests** with mocked AI, ERP and DB dependencies, a **49-request Postman collection**, Docker Compose infrastructure, and CloudHub 2.0 deployment configuration.

**Skills line:** MuleSoft Anypoint Studio · Mule 4 · DataWeave 2.0 · API-led connectivity · HTTP / Database / File / Object Store connectors · Batch processing · MUnit · MySQL · REST · XML/JSON · AI document extraction · Maven · Postman · Docker · Git

## 60-second pitch
"Accounts-payable teams still key invoices in by hand. I built a MuleSoft platform where a supplier uploads a PDF or a phone photo and an AI model extracts the fields. The Process API then normalizes the data with DataWeave and runs the same checks an AP clerk would: does the vendor exist, is it a duplicate, does it match the purchase order, do the totals and tax add up? Small, clean invoices are posted to the ERP automatically. Larger ones go through a manager or finance-director approval chain, and anything uncertain, like low AI confidence or a price variance, goes to manual review. Every step is audited and traceable by correlation ID. Failures in the AI or the ERP aren't lost; they go to a retry queue with exponential backoff and a dead letter."

## Likely interview questions and answers

| Question | Answer |
|---|---|
| Why API-led and not one app? | Each layer changes for a different reason. A new channel means a new Experience API. A new ERP means only the System API changes. The Process API is the reusable business capability. |
| How do you stop AI hallucinations reaching the ERP? | Five gates: structured output, then JSON schema, then business field rules, then cross-checks against master data (vendor, PO, totals, tax), then confidence thresholds. Anything doubtful goes to a human. |
| How is duplicate processing prevented? | Three idempotency layers (client key, file hash, ERP reference), duplicate invoice-number detection with normalization, and a DB unique index on a generated column for race conditions. |
| What happens if the ERP is down for an hour? | The ERP call is retried inline. Then the invoice becomes ERP_POSTING_FAILED and is queued. A scheduler and batch job retry with backoff (60s, 120s, 240s ... up to 1h). After 5 attempts it's dead-lettered and flagged for operations. |
| Two managers click Approve at the same time? | An Object Store lock (`failIfPresent`) plus an optimistic `version` check plus unique DB constraints. The second request gets 409. |
| How do you test without external systems? | MUnit mocks every `http:request` and DB operation by `doc:name`. The DataWeave logic is also tested outside Mule with the DataWeave CLI, and a Python mock simulates the AI and the ERP, including outages. |
| Where do secrets live? | Never in code. Locally they're environment variables that override YAML defaults. In production they're encrypted with Secure Properties, decrypted with a runtime `mule.key`, and hidden in Runtime Manager through `mule-artifact.json`. |
| What would you add next? | API Manager OAuth policies, S3 document storage, three-way matching with goods receipts, a reviewer UI for correcting extracted fields, Anypoint MQ instead of the DB queue, and per-vendor learning of tolerances. |
