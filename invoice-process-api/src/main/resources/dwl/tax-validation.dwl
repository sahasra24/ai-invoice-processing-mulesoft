%dw 2.0
/**
 * Tax validation
 * ------------------------------------------------------------------
 * Compares the invoice tax with the vendor master tax rate.
 *   TAX_RATE_MISMATCH   stated rate differs from vendor master rate
 *   TAX_AMOUNT_MISMATCH tax <> round(subtotal x expected rate) beyond tolerance
 *   TAX_MISSING         no tax amount on invoice while vendor charges tax
 *
 * Input  payload          : canonical invoice
 *        vars.vendorCheck : output of vendor-verification.dwl
 *        vars.totals      : output of calculate-invoice-totals.dwl
 *        vars.config      : { taxTolerance }
 * Output                  : { valid, expectedRate, expectedTax, statedTax, rateSource, issues[] }
 *
 * Used in: process-invoice-orchestration-sub-flow > "Validate tax"
 */
output application/json
import * from modules::InvoiceUtils

var inv = payload
var tol = (vars.config.taxTolerance default 0.02) as Number
var vendorRate = vars.vendorCheck.vendor.defaultTaxRate
var expectedRate = vendorRate default inv.taxRate
var base = inv.subtotal default vars.totals.calculatedSubtotal
var expectedTax = if (expectedRate != null and base != null) round2(base * expectedRate) else null

var issues = flatten([
  if (vendorRate != null and inv.taxRate != null and abs(inv.taxRate - vendorRate) > 0.0001)
    [issue("TAX_RATE_MISMATCH", "REVIEW",
      "Invoice tax rate $(inv.taxRate * 100)% differs from vendor master rate $(vendorRate * 100)%",
      { expected: vendorRate, actual: inv.taxRate })] else [],
  if (inv.tax == null and (expectedRate default 0) > 0)
    [issue("TAX_MISSING", "REVIEW", "Vendor charges tax but no tax amount was found on the invoice")] else [],
  if (inv.tax != null and expectedTax != null and abs(inv.tax - expectedTax) > tol)
    [issue("TAX_AMOUNT_MISMATCH", "REVIEW",
      "Expected tax $(expectedTax) ($(expectedRate * 100)% of $(base)) but invoice states $(inv.tax)",
      { expected: expectedTax, actual: inv.tax })] else []
])
---
{
  valid: isEmpty(issues),
  expectedRate: expectedRate,
  expectedTax: expectedTax,
  statedTax: inv.tax,
  rateSource: if (vendorRate != null) "VENDOR_MASTER" else if (inv.taxRate != null) "INVOICE" else "UNKNOWN",
  issues: issues
}
