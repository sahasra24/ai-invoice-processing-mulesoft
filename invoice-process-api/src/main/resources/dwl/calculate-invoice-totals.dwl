%dw 2.0
/**
 * Invoice total calculation & arithmetic verification
 * ------------------------------------------------------------------
 *   line:     quantity x unitPrice  == amount       (LINE_AMOUNT_MISMATCH)
 *   subtotal: sum(line amounts)     == subtotal     (SUBTOTAL_MISMATCH)
 *   total:    subtotal + tax        == total        (TOTAL_MISMATCH)
 *
 * Input  payload     : canonical invoice
 *        vars.config : { amountTolerance }
 * Output             : { valid, calculatedSubtotal, statedSubtotal, calculatedTotal, statedTotal, lineChecks[], issues[] }
 *
 * Used in: process-invoice-orchestration-sub-flow > "Calculate & verify totals"
 */
output application/json
import * from modules::InvoiceUtils

var inv = payload
var tol = (vars.config.amountTolerance default 0.01) as Number
var lines = inv.lineItems default []

var lineChecks = lines map ((li) -> do {
    var expected = if (li.quantity != null and li.unitPrice != null) round2(li.quantity * li.unitPrice) else null
    var diff = if (expected != null and li.amount != null) round2(abs(expected - li.amount)) else null
    ---
    {
      lineNumber: li.lineNumber,
      expectedAmount: expected,
      statedAmount: li.amount,
      difference: diff,
      ok: diff == null or diff <= tol
    }
  })

var calculatedSubtotal = round2(sum(lines map ((li) -> li.amount default 0)))
var baseSubtotal = inv.subtotal default calculatedSubtotal
var calculatedTotal = if (inv.tax != null) round2(baseSubtotal + inv.tax) else null

var issues = flatten([
  (lineChecks filter ((c) -> !c.ok)) map ((c) ->
    issue("LINE_AMOUNT_MISMATCH", "REVIEW",
      "Line $(c.lineNumber): quantity x unit price = $(c.expectedAmount) but line amount is $(c.statedAmount)",
      { expected: c.expectedAmount, actual: c.statedAmount })),
  if (inv.subtotal != null and !isEmpty(lines) and abs(calculatedSubtotal - inv.subtotal) > tol)
    [issue("SUBTOTAL_MISMATCH", "REVIEW",
      "Line items add up to $(calculatedSubtotal) but the stated subtotal is $(inv.subtotal)",
      { expected: calculatedSubtotal, actual: inv.subtotal })] else [],
  if (calculatedTotal != null and inv.total != null and abs(calculatedTotal - inv.total) > tol)
    [issue("TOTAL_MISMATCH", "REVIEW",
      "Subtotal + tax = $(calculatedTotal) but the stated total is $(inv.total)",
      { expected: calculatedTotal, actual: inv.total })] else []
])
---
{
  valid: isEmpty(issues),
  calculatedSubtotal: calculatedSubtotal,
  statedSubtotal: inv.subtotal,
  calculatedTotal: calculatedTotal,
  statedTotal: inv.total,
  lineChecks: lineChecks,
  issues: issues
}
