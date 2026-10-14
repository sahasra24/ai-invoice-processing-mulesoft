%dw 2.0
/**
 * Approval routing - the single decision point of the pipeline
 * ------------------------------------------------------------------
 * Precedence:
 *   1. DUPLICATE          exact duplicate found
 *   2. VALIDATION_FAILED  BLOCKING issues AND the extraction was reliable
 *                         (the document itself is wrong -> back to supplier)
 *   3. MANUAL_REVIEW      BLOCKING issues on an unreliable extraction, any
 *                         REVIEW issue, or low AI confidence
 *   4. APPROVED           total <= autoApproveLimit   (touchless processing)
 *   5. PENDING_APPROVAL   threshold-based approval chain
 *
 * Thresholds (configurable, see config/*.yaml -> approval.*):
 *   total <= autoApproveLimit                 -> auto-approved
 *   total <= approverLimit                    -> [APPROVER]
 *   total <= managerLimit                     -> [MANAGER]
 *   total >  managerLimit                     -> [MANAGER, FINANCE_DIRECTOR]
 *   MANUAL_REVIEW                             -> [MANAGER] or [FINANCE_DIRECTOR] above managerLimit
 *
 * Input  payload : canonical invoice
 *        vars    : schemaValidation, fieldValidation, vendorCheck, duplicateCheck,
 *                  poMatch, totals, taxCheck, config
 * Output         : decision object persisted on the invoice
 *
 * Used in: process-invoice-orchestration-sub-flow > "Route for approval"
 */
output application/json
import * from modules::InvoiceUtils

var inv = payload
var cfg = vars.config
var fv = vars.fieldValidation
var total = inv.total

var schemaIssues = if (vars.schemaValidation.valid default true) []
  else [issue("SCHEMA_VALIDATION_FAILED", "BLOCKING", vars.schemaValidation.message default "Canonical schema validation failed")]

var confidenceIssues = flatten([
  if ((fv.overallConfidence default 0) < (cfg.confidenceThreshold as Number))
    [issue("LOW_CONFIDENCE", "REVIEW",
      "Overall extraction confidence $(fv.overallConfidence) is below the $(cfg.confidenceThreshold) threshold")] else [],
  if (!isEmpty(fv.lowConfidenceFields default []))
    [issue("LOW_CONFIDENCE_FIELDS", "REVIEW",
      "Low-confidence fields: " ++ ((fv.lowConfidenceFields default []) joinBy ", "),
      { fields: fv.lowConfidenceFields })] else []
])

var allIssues = flatten([
  schemaIssues,
  fv.errors default [],
  fv.warnings default [],
  confidenceIssues,
  vars.vendorCheck.issues default [],
  vars.duplicateCheck.issues default [],
  vars.poMatch.issues default [],
  vars.totals.issues default [],
  vars.taxCheck.issues default []
])

var blocking = allIssues filter ((i) -> i.severity == "BLOCKING")
var review = allIssues filter ((i) -> i.severity == "REVIEW")
var reliableExtraction = (fv.overallConfidence default 0) >= (cfg.minUsableConfidence as Number)

var status =
  if (vars.duplicateCheck.isDuplicate default false) "DUPLICATE"
  else if (!isEmpty(blocking) and reliableExtraction) "VALIDATION_FAILED"
  else if (!isEmpty(blocking) or !isEmpty(review)) "MANUAL_REVIEW"
  else if (total <= (cfg.autoApproveLimit as Number)) "APPROVED"
  else "PENDING_APPROVAL"

var approvalChain = status match {
  case "PENDING_APPROVAL" ->
    if (total <= (cfg.approverLimit as Number)) ["APPROVER"]
    else if (total <= (cfg.managerLimit as Number)) ["MANAGER"]
    else ["MANAGER", "FINANCE_DIRECTOR"]
  case "MANUAL_REVIEW" ->
    if (total == null or total > (cfg.managerLimit as Number)) ["FINANCE_DIRECTOR"] else ["MANAGER"]
  else -> []
}

var reason = status match {
  case "DUPLICATE" -> "Duplicate of invoice $(vars.duplicateCheck.duplicateOf)"
  case "VALIDATION_FAILED" -> "$(sizeOf(blocking)) blocking validation error(s): " ++ ((blocking map $.code) distinctBy $ joinBy ", ")
  case "MANUAL_REVIEW" -> "Requires review: " ++ (((blocking ++ review) map $.code) distinctBy $ joinBy ", ")
  case "APPROVED" -> "Auto-approved: all checks passed and total $(total) <= $(cfg.autoApproveLimit)"
  else -> "Approval required: " ++ (approvalChain joinBy " -> ")
}
---
{
  status: status,
  autoApproved: status == "APPROVED",
  approvalChain: approvalChain,
  approvalsRequired: sizeOf(approvalChain),
  nextApprovalLevel: approvalChain[0],
  duplicateOf: vars.duplicateCheck.duplicateOf,
  decisionReason: reason,
  validationErrors: blocking,
  exceptions: allIssues filter ((i) -> i.severity != "BLOCKING"),
  checks: {
    schemaValid: vars.schemaValidation.valid default true,
    fieldsValid: fv.valid default false,
    vendorVerified: vars.vendorCheck.verified default false,
    duplicateChecked: vars.duplicateCheck.checked default false,
    poMatched: vars.poMatch.matched default false,
    totalsValid: vars.totals.valid default false,
    taxValid: vars.taxCheck.valid default false,
    extractionConfidence: fv.overallConfidence
  }
}
