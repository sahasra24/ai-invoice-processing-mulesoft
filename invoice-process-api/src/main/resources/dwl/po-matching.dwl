%dw 2.0
/**
 * Purchase order matching (two-way match: invoice <-> PO)
 * ------------------------------------------------------------------
 * Header checks : PO exists, belongs to the vendor, is open, same currency,
 *                 invoice gross does not exceed the PO's remaining amount.
 * Line checks   : each invoice line is matched to a PO line by item code,
 *                 then description, then line number; quantity must not
 *                 exceed the remaining PO quantity and unit price must be
 *                 within the configured tolerance (%).
 *
 * Input  payload           : canonical invoice
 *        vars.poLookup     : { status, body: PO with lines } or null when no PO number
 *        vars.vendorCheck  : output of vendor-verification.dwl
 *        vars.config       : { priceTolerancePct, amountTolerance }
 * Output                   : { matched, poNumber, poStatus, lineMatches[], issues[] }
 *
 * Used in: process-invoice-orchestration-sub-flow > "Match purchase order"
 */
output application/json
import * from modules::InvoiceUtils

var inv = payload
var cfg = vars.config
var priceTol = (cfg.priceTolerancePct default 2) as Number
var amountTol = (cfg.amountTolerance default 0.01) as Number
var lookup = vars.poLookup
var po = if (lookup != null and lookup.status == 200) lookup.body else null
var vendorId = vars.vendorCheck.vendor.vendorId default inv.vendor.id
var poLines = po.lines default []

fun findPoLine(li) = do {
  var byCode = poLines filter ((pl) -> li.itemCode != null and upper(pl.itemCode default "") == upper(li.itemCode))
  var byDesc = poLines filter ((pl) -> li.description != null and textKey(pl.description) == textKey(li.description))
  var byLine = poLines filter ((pl) -> pl.lineNumber == li.lineNumber)
  ---
  if (!isEmpty(byCode)) { line: byCode[0], method: "ITEM_CODE" }
  else if (!isEmpty(byDesc)) { line: byDesc[0], method: "DESCRIPTION" }
  else if (!isEmpty(byLine)) { line: byLine[0], method: "LINE_NUMBER" }
  else null
}

var lineMatches = if (po == null) [] else (inv.lineItems default []) map ((li) -> do {
    var m = findPoLine(li)
    var pl = m.line
    var remainingQty = if (pl != null) (pl.quantity - (pl.quantityInvoiced default 0)) else null
    var variancePct = if (pl != null and li.unitPrice != null and pl.unitPrice > 0)
                        round2(abs(li.unitPrice - pl.unitPrice) / pl.unitPrice * 100) else null
    var qtyOk = pl == null or li.quantity == null or li.quantity <= remainingQty
    var priceOk = variancePct == null or variancePct <= priceTol
    ---
    {
      invoiceLine: li.lineNumber,
      poLine: pl.lineNumber,
      matchMethod: m.method,
      invoiceQuantity: li.quantity,
      remainingPoQuantity: remainingQty,
      invoiceUnitPrice: li.unitPrice,
      poUnitPrice: pl.unitPrice,
      priceVariancePct: variancePct,
      status: if (pl == null) "UNMATCHED" else if (qtyOk and priceOk) "MATCHED" else "VARIANCE"
    }
  })

var remainingAmount = if (po != null) (po.totalAmount - (po.invoicedAmount default 0)) else null

var issues = flatten([
  if (inv.poNumber == null) [issue("PO_MISSING", "REVIEW", "Invoice does not reference a purchase order")] else [],
  if (inv.poNumber != null and po == null)
    [issue("PO_NOT_FOUND", "REVIEW", "Purchase order $(inv.poNumber) was not found", { poNumber: inv.poNumber })] else [],
  if (po != null and vendorId != null and po.vendorId != vendorId)
    [issue("PO_VENDOR_MISMATCH", "REVIEW", "PO $(po.poNumber) belongs to vendor $(po.vendorId), not $(vendorId)")] else [],
  if (po != null and !(["OPEN", "PARTIALLY_INVOICED"] contains po.status))
    [issue("PO_NOT_OPEN", "REVIEW", "PO $(po.poNumber) has status $(po.status)")] else [],
  if (po != null and inv.currency != null and po.currency != inv.currency)
    [issue("PO_CURRENCY_MISMATCH", "REVIEW", "Invoice currency $(inv.currency) differs from PO currency $(po.currency)")] else [],
  if (po != null and inv.total != null and inv.total > ((remainingAmount default 0) + amountTol))
    [issue("PO_AMOUNT_EXCEEDED", "REVIEW",
      "Invoice total $(inv.total) exceeds the remaining PO amount $(remainingAmount)",
      { remaining: remainingAmount, invoiced: inv.total })] else [],
  (lineMatches filter ((lm) -> lm.status == "UNMATCHED")) map ((lm) ->
    issue("UNMATCHED_LINE", "REVIEW", "Invoice line $(lm.invoiceLine) does not match any PO line")),
  (lineMatches filter ((lm) -> lm.remainingPoQuantity != null and lm.invoiceQuantity != null and lm.invoiceQuantity > lm.remainingPoQuantity)) map ((lm) ->
    issue("QUANTITY_EXCEEDS_PO", "REVIEW",
      "Line $(lm.invoiceLine): invoiced quantity $(lm.invoiceQuantity) exceeds remaining PO quantity $(lm.remainingPoQuantity)")),
  (lineMatches filter ((lm) -> lm.priceVariancePct != null and lm.priceVariancePct > priceTol)) map ((lm) ->
    issue("PRICE_VARIANCE", "REVIEW",
      "Line $(lm.invoiceLine): unit price $(lm.invoiceUnitPrice) vs PO $(lm.poUnitPrice) ($(lm.priceVariancePct)% > $(priceTol)% tolerance)",
      { variancePct: lm.priceVariancePct }))
])
---
{
  matched: po != null and isEmpty(issues),
  matchType: "TWO_WAY",
  poNumber: inv.poNumber,
  poStatus: po.status,
  remainingAmount: remainingAmount,
  lineMatches: lineMatches,
  issues: issues
}
