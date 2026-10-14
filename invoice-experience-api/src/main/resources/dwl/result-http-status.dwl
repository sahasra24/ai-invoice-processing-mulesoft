%dw 2.0
/**
 * Maps the Process API ProcessingResult.status to the public HTTP status
 *   idempotent replay                      -> 200 OK
 *   RECEIVED (deferred)                    -> 202 Accepted
 *   EXTRACTION_FAILED / ERP_POSTING_FAILED -> 202 Accepted (queued for automatic retry)
 *   VALIDATION_FAILED                      -> 422 Unprocessable Entity (stored, not payable)
 *   DUPLICATE                              -> 409 Conflict
 *   everything else (APPROVED, POSTED_TO_ERP, PENDING_APPROVAL, MANUAL_REVIEW) -> 201 Created
 * Used in: post-invoice-upload-flow / post-invoice-process-flow
 */
output application/java
---
if (payload.idempotentReplay default false) 200
else payload.status match {
  case "RECEIVED" -> 202
  case "EXTRACTION_FAILED" -> 202
  case "ERP_POSTING_FAILED" -> 202
  case "VALIDATION_FAILED" -> 422
  case "DUPLICATE" -> 409
  else -> 201
}
