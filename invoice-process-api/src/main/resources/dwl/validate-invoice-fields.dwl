%dw 2.0
/**
 * Invoice field validation
 * ------------------------------------------------------------------
 * Collects ALL field-level problems (not fail-fast) so that a reviewer
 * or supplier sees every issue at once.
 *
 * Input  payload     : canonical invoice
 *        vars.config : { confidenceThreshold, maxInvoiceAgeDays, allowedCurrencies }
 * Output             : { valid, errors[], warnings[], lowConfidenceFields[], overallConfidence, requiresManualReview }
 *
 * Severity: BLOCKING = cannot be posted as-is; REVIEW = human should look; INFO = note only.
 * Used in: process-invoice-orchestration-sub-flow > "Validate invoice fields"
 */
output application/json
import * from modules::InvoiceUtils

var inv = payload
var cfg = vars.config
var today = now() as Date
var threshold = cfg.confidenceThreshold as Number

var requiredFields = [
  { field: "invoiceNumber", value: inv.invoiceNumber },
  { field: "invoiceDate",   value: inv.invoiceDate },
  { field: "vendor",        value: inv.vendor.id default inv.vendor.name },
  { field: "currency",      value: inv.currency },
  { field: "total",         value: inv.total },
  { field: "lineItems",     value: if (isEmpty(inv.lineItems default [])) null else inv.lineItems }
]

var missing = requiredFields filter ((f) -> f.value == null) map ((f) ->
  issue("MISSING_REQUIRED_FIELD", "BLOCKING", "Required field '$(f.field)' is missing or unreadable", { field: f.field }))

var formatErrors = flatten([
  if (inv.invoiceNumber != null and !(inv.invoiceNumber matches /^[A-Za-z0-9][A-Za-z0-9\-\/_.]{1,49}$/))
    [issue("INVALID_FORMAT", "BLOCKING", "Invoice number contains unsupported characters", { field: "invoiceNumber" })] else [],
  if (inv.currency != null and !((cfg.allowedCurrencies default []) contains inv.currency))
    [issue("UNSUPPORTED_CURRENCY", "BLOCKING", "Currency $(inv.currency) is not supported", { field: "currency" })] else [],
  if (inv.vendor.id != null and !(inv.vendor.id matches /^V-\d{4}$/))
    [issue("INVALID_FORMAT", "BLOCKING", "Vendor ID must look like V-1234", { field: "vendor.id" })] else []
])

var dateErrors = do {
  var invDate = parseDate(inv.invoiceDate)
  var dueDate = parseDate(inv.dueDate)
  ---
  flatten([
    if (invDate != null and invDate > today)
      [issue("INVALID_DATE", "BLOCKING", "Invoice date is in the future", { field: "invoiceDate" })] else [],
    if (invDate != null and (today - invDate).days > (cfg.maxInvoiceAgeDays as Number))
      [issue("INVOICE_TOO_OLD", "BLOCKING", "Invoice is older than $(cfg.maxInvoiceAgeDays) days", { field: "invoiceDate" })] else [],
    if (invDate != null and dueDate != null and dueDate < invDate)
      [issue("INVALID_DATE", "BLOCKING", "Due date is before invoice date", { field: "dueDate" })] else []
  ])
}

var amountErrors = flatten([
  (inv.lineItems default []) flatMap ((li) -> flatten([
    if (li.quantity == null or li.unitPrice == null)
      [issue("MISSING_REQUIRED_FIELD", "BLOCKING", "Line $(li.lineNumber): quantity and unit price are required", { field: "lineItems[$(li.lineNumber)]" })] else [],
    if (li.quantity != null and li.quantity <= 0)
      [issue("INVALID_VALUE", "BLOCKING", "Line $(li.lineNumber): quantity must be greater than zero", { field: "lineItems[$(li.lineNumber)].quantity" })] else [],
    if (li.unitPrice != null and li.unitPrice < 0)
      [issue("INVALID_VALUE", "BLOCKING", "Line $(li.lineNumber): unit price cannot be negative", { field: "lineItems[$(li.lineNumber)].unitPrice" })] else []
  ])),
  if (inv.total != null and inv.total <= 0)
    [issue("INVALID_VALUE", "BLOCKING", "Invoice total must be greater than zero", { field: "total" })] else []
])

var lowConfidenceFields = (inv.extraction.fieldConfidence default {}) pluck ((score, field) -> { field: field as String, score: score })
  filter ((f) -> f.score > 0 and f.score < threshold)
  map ((f) -> f.field)

var warnings = flatten([
  if (inv.dueDateDerived default false) [issue("DUE_DATE_DERIVED", "INFO", "Due date derived from payment terms '$(inv.paymentTerms)'")] else [],
  if (inv.subtotal == null) [issue("SUBTOTAL_MISSING", "REVIEW", "Subtotal not found; calculated from line items")] else [],
  (inv.extraction.warnings default []) map ((w) -> issue("EXTRACTION_WARNING", "INFO", w))
])

var errors = missing ++ formatErrors ++ dateErrors ++ amountErrors
var overall = inv.extraction.overallConfidence default 0
---
{
  valid: isEmpty(errors),
  errors: errors,
  warnings: warnings,
  lowConfidenceFields: lowConfidenceFields,
  overallConfidence: overall,
  requiresManualReview: overall < threshold or !isEmpty(lowConfidenceFields)
}
