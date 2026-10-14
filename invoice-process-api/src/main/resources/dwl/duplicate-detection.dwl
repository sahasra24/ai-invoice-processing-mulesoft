%dw 2.0
/**
 * Duplicate invoice detection support
 * ------------------------------------------------------------------
 * The System API returns two candidate lists for (vendor, normalized number):
 *   exactMatches    - same vendor + same normalized invoice number
 *                     ("INV-2026-1001" == "inv/2026/1001")
 *   possibleMatches - same vendor + same total + invoice date within +/- N days
 *                     but a different number (typical re-keyed duplicate)
 * The database additionally enforces uniqueness through invoices.dedupe_key.
 *
 * Input  payload       : { exactMatches[], possibleMatches[] }  (or null when check skipped)
 *        vars.invoiceId : current invoice (excluded server side, filtered again here)
 * Output               : { checked, isDuplicate, duplicateOf, possibleDuplicates[], issues[] }
 *
 * Used in: process-invoice-orchestration-sub-flow > "Check duplicates"
 */
output application/json
import * from modules::InvoiceUtils

var result = payload default {}
var exact = (result.exactMatches default []) filter ((m) -> m.invoiceId != vars.invoiceId)
var possible = (result.possibleMatches default []) filter ((m) -> m.invoiceId != vars.invoiceId)
---
{
  checked: payload != null,
  isDuplicate: !isEmpty(exact),
  duplicateOf: exact[0].invoiceId,
  possibleDuplicates: possible map ((m) -> m.invoiceId),
  issues: flatten([
    if (!isEmpty(exact))
      [issue("DUPLICATE_INVOICE", "DUPLICATE",
        "Invoice $(exact[0].invoiceNumber) was already submitted for this vendor (status $(exact[0].status))",
        { duplicateOf: exact[0].invoiceId })] else [],
    if (isEmpty(exact) and !isEmpty(possible))
      [issue("POSSIBLE_DUPLICATE", "REVIEW",
        "$(sizeOf(possible)) other invoice(s) from this vendor have the same total and a similar date",
        { candidates: possible map ((m) -> m.invoiceId) })] else []
  ])
}
