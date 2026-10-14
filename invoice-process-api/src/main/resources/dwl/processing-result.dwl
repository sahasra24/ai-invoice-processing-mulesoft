%dw 2.0
/**
 * Final processing result returned by the Process API
 * ------------------------------------------------------------------
 * Input  vars.invoiceId, vars.invoice (canonical), vars.decision (routing),
 *        vars.finalStatus, vars.erpResult?, vars.vendorCheck?, vars.failure?,
 *        vars.idempotentReplay?
 * Output : ProcessingResult (see docs/API-REFERENCE.md)
 *
 * Used in: process-invoice-orchestration-sub-flow > "Build processing result"
 */
output application/json

var decision = vars.decision default {}
var inv = vars.invoice default {}
var status = vars.finalStatus default decision.status default "RECEIVED"
var chain = decision.approvalChain default []
---
{
  invoiceId: vars.invoiceId,
  invoiceNumber: inv.invoiceNumber,
  status: status,
  idempotentReplay: vars.idempotentReplay default false,
  vendorId: vars.vendorCheck.vendor.vendorId default inv.vendor.id,
  vendorName: vars.vendorCheck.vendor.vendorName default inv.vendor.name,
  poNumber: inv.poNumber,
  currency: inv.currency,
  totalAmount: inv.total,
  extractionProvider: inv.extraction.provider,
  extractionConfidence: inv.extraction.overallConfidence,
  decisionReason: vars.failure.message default decision.decisionReason,
  approval: {
    required: !isEmpty(chain),
    chain: chain,
    approvalsRequired: sizeOf(chain),
    approvalsReceived: 0,
    nextApprovalLevel: chain[0]
  },
  duplicateOf: decision.duplicateOf,
  validationErrors: decision.validationErrors default [],
  exceptions: decision.exceptions default [],
  erp: if (vars.erpResult != null) {
    documentNumber: vars.erpResult.erpDocumentNumber,
    postedAt: vars.erpResult.postedAt
  } else null,
  recovery: if (vars.failure != null) {
    queued: vars.failure.queued default false,
    failureType: vars.failure.failureType,
    errorCode: vars.failure.errorCode
  } else null,
  correlationId: correlationId,
  processedAt: now() >> "UTC"
}
