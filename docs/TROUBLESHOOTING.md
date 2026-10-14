# Troubleshooting Guide

Start every investigation with the **correlation id**. It's in the `X-Correlation-ID` response header and in `error.correlationId`. Then:
```bash
grep <correlationId> <mule-home>/logs/invoice-*.log       # all three apps
```
```sql
SELECT * FROM processing_audit_logs WHERE correlation_id = '<correlationId>';
```

## 1. Build / import

| Symptom | Cause | Fix |
|---|---|---|
| `Could not resolve dependencies ... mule-secure-configuration-property-module` | MuleSoft repository unreachable | Check proxy settings. The module is public at `https://repository.mulesoft.org/releases/` (already declared in the pom) |
| `Failed to execute goal ... munit-maven-plugin` downloading the runtime | MUnit downloads the Mule runtime the first time | Run from Studio (uses the bundled runtime) or add Anypoint credentials to `~/.m2/settings.xml` |
| Studio shows red XML: "Invalid content was found starting with element ..." | Child element order differs from the connector's XSD | Open the component in the visual editor and save; Studio rewrites the element order. Report which element in an issue |
| `minMuleVersion 4.9.0` not satisfied | Older Studio runtime | Install Mule 4.9.x via *Help > Install New Software*, or lower `app.runtime` and `minMuleVersion` (all connectors support 4.4+) |
| `Unable to resolve module with identifier modules::InvoiceUtils` (VS Code) | Editor does not know the Mule classpath | Ignore it; it works in Studio and the CLI tests |

## 2. Startup

| Symptom | Cause | Fix |
|---|---|---|
| `Couldn't find configuration property value for key ${X}` | Missing property / env var | Every key exists in `config/local.yaml`; check `-M-Denv=local` and the file name |
| `Address already in use: 8081` | Another app on that port | Change `http.port` (and the calling app's `*_PORT`) or stop the other process |
| `Communications link failure` / `DB:CONNECTIVITY` | MySQL not running or wrong host/port | `docker compose ps`; `mysql -h localhost -u invoice_app -p` |
| `Public Key Retrieval is not allowed` | MySQL 8 `caching_sha2_password` without TLS | Enable TLS on MySQL (Docker image does), or for local only add `<db:connection-property key="allowPublicKeyRetrieval" value="true"/>` and `useSSL=false` |
| `Access denied for user 'invoice_app'` | Schema script not run / password changed | Rerun `database/01-schema.sql` or set `DB_PASSWORD` |
| Secure properties: `Error decrypting` / `BadPaddingException` | Wrong `mule.key` or placeholder values in `secure-prod.yaml` | Encrypt real values with the Secure Properties Tool using the same key (algorithm AES, mode CBC) |
| File listener: `Path ... doesn't exist` | Inbound folder missing | Create `FILE_INBOUND_DIR` / `FILE_ARCHIVE_DIR`, or set `file.flowState: "stopped"` |

## 3. Runtime: what each status / error means

| Response | Meaning | Action |
|---|---|---|
| 401 UNAUTHORIZED | Missing or wrong Basic credentials | Use the demo users from README |
| 403 FORBIDDEN | Role not allowed for this endpoint | e.g. suppliers cannot approve |
| 403 INSUFFICIENT_APPROVAL_AUTHORITY | Approver level too low for the next step | Use MANAGER / FINANCE_DIRECTOR |
| 403 SEGREGATION_OF_DUTIES | Submitter tried to approve own invoice | Use a different user |
| 409 CONCURRENT_REQUEST | Another decision for the same invoice is in flight | Retry after a second (lock TTL 60s) |
| 409 STALE_UPDATE | Invoice changed since it was read | Reload and retry |
| 409 ALREADY_DECIDED | User already approved/rejected | Expected behaviour |
| 413 / 415 | File too large / wrong type / renamed file | PDF, PNG, JPG, JSON up to 10 MB |
| 422 VALIDATION_FAILED | Invoice stored but cannot be paid (missing fields, unknown vendor) | Supplier resubmits a corrected invoice |
| 202 EXTRACTION_FAILED | AI service down | Automatic retry (recovery queue); check `GET /sys/v1/recovery-queue` |
| 202 ERP_POSTING_FAILED | ERP down | Automatic retry; check the mock ERP mode: `curl localhost:8090/health` |
| 502 BAD_GATEWAY | A downstream returned 5xx | Check the downstream app's log with the correlation id |
| 503 DOWNSTREAM_UNAVAILABLE | Downstream not reachable | Is the System/Process API running on the configured port? |

## 4. AI extraction

| Symptom | Fix |
|---|---|
| Every upload ends EXTRACTION_FAILED with mock AI | Mock not running (`curl localhost:8090/health`) or `MOCK_AI_API_KEY` mismatch (mock returns 401, not retried) |
| Claude: `HTTP 401` | `ANTHROPIC_API_KEY` missing/invalid. It must be an **environment variable or -D property**, not committed to YAML |
| Claude: `HTTP 400` | Usually an unsupported/oversized file (PDF max 32 MB / 600 pages) or invalid schema change in `claude-extraction-schema.json` |
| Claude: timeouts | Raise `ai.anthropic.timeoutMs` or lower `ai.anthropic.effort` (e.g. `low`) |
| Claude: `REFUSAL` | The request was declined by safety classifiers; invoice goes to the recovery queue. Inspect the document |
| Image uploads always MANUAL_REVIEW with mock AI | Expected for images that are not in `mock-services/fixtures/image-fixtures.json`; use Claude for real OCR |
| Low confidence everywhere | Adjust `validation.confidenceThreshold` (default 0.85) |

## 5. Recovery queue

```sql
SELECT queue_id, invoice_id, failure_type, attempt_count, status, next_attempt_at, error_code FROM recovery_queue ORDER BY created_at DESC;
```
| Observation | Explanation |
|---|---|
| Item stays `PENDING` | `next_attempt_at` is in the future (backoff), or `recovery.flowState` is `stopped` |
| Item `IN_PROGRESS` for long | Worker crashed; it is re-claimed after 15 minutes |
| Item `DEAD`, invoice `FAILED` | Max attempts reached. Fix the cause, then `UPDATE recovery_queue SET status='PENDING', attempt_count=0, next_attempt_at=NOW() WHERE queue_id=...` and set the invoice back to `EXTRACTION_FAILED` / `ERP_POSTING_FAILED` |
| `ai-fail_*` sample becomes DEAD | By design: its file name always triggers the mock failure |

## 6. Postman

| Symptom | Fix |
|---|---|
| Upload requests send an empty file | Set *Settings > General > Working directory* to the repository root |
| Second run: many 409/200 replays | Data from the previous run. Reload `database/02-sample-data.sql`, `POST localhost:8090/admin/reset`, and delete the documents folder |
| ERP failure scenario never recovers | Wait for the scheduler (~1-3 min); ensure the mock ERP mode is `NORMAL` |

## 7. Logs and monitoring

**Local log files**
- Location: `<Studio workspace>/.mule/logs` or `$MULE_HOME/logs/invoice-*.log`.
- Each line shows `[correlationId=...]` followed by a JSON event, e.g. `{"event":"invoice.processed","invoiceId":"...","status":"POSTED_TO_ERP"}`.
- Useful events to search for:

| Event | Meaning |
|---|---|
| `invoice.registered` | document stored |
| `invoice.processed` | pipeline finished |
| `ai.claude.usage` | Claude token usage |
| `erp.post.failed` | ERP call failed |
| `recovery.enqueued` | item queued for retry |
| `recovery.rescheduled` | retry failed; next attempt scheduled |
| `recovery.dead_letter` | max attempts reached |
| `approval.denied` | decision refused |
| `access.denied` | role check failed |
| `request.failed` | 5xx returned |

**On CloudHub 2.0**
- Runtime Manager > Applications > Logs: search for the correlation id.
- Anypoint Monitoring: dashboards for response times and failures. Create alerts on `recovery.dead_letter` log events and on HTTP 5xx rate.
