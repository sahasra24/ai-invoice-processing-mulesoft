%dw 2.0
/**
 * AI response normalization
 * ------------------------------------------------------------------
 * Converts the raw output of ANY extraction provider (mock document AI,
 * Claude, or a structured supplier JSON upload) into the canonical
 * invoice model used by every downstream step.
 *
 * Input  (payload): { provider, model, warnings?, extraction: { snake_case raw fields,
 *                     field_confidence?, overall_confidence? } }
 * Output          : canonical invoice (see schemas/canonical-invoice-schema.json)
 *
 * Used in: process-invoice-orchestration-sub-flow > "Normalize AI response"
 */
output application/json skipNullOn="nothing"
import * from modules::InvoiceUtils
import * from dw::core::Strings

var raw = payload.extraction default {}
var conf = raw.field_confidence default {}

/** Missing confidence (e.g. structured JSON) -> 1.0 when the value exists, 0.0 otherwise. */
fun confidenceOf(field: String, value: Any): Number =
  if (conf[field] != null) conf[field] as Number
  else if (value == null or (value is String and isBlank(value as String))) 0
  else 1

fun clean(s: Any): String | Null =
  if (s == null) null
  else do {
    var v = trim(s as String)
    ---
    if (isBlank(v)) null else v
  }

var invoiceNumber = clean(raw.invoice_number)
var invoiceDate = parseDate(raw.invoice_date)
var paymentTerms = clean(raw.payment_terms)
var statedDueDate = parseDate(raw.due_date)
var termDays = paymentTermDays(paymentTerms)
var derivedDueDate = if (statedDueDate == null and invoiceDate != null and termDays != null)
                       invoiceDate + ("P$(termDays)D" as Period)
                     else null

var lineItems = (raw.line_items default []) map ((li, idx) -> do {
    var qty = parseAmount(li.quantity)
    var price = parseAmount(li.unit_price)
    var stated = parseAmount(li.amount)
    ---
    {
      lineNumber: (li.line_number default (idx + 1)) as Number,
      itemCode: clean(li.item_code),
      description: clean(li.description),
      quantity: qty,
      unitPrice: price,
      amount: if (stated != null) round2(stated)
              else if (qty != null and price != null) round2(qty * price)
              else null,
      amountDerived: stated == null and qty != null and price != null
    }
  })

var subtotal = round2(parseAmount(raw.subtotal))
var tax = round2(parseAmount(raw.tax))
var total = round2(parseAmount(raw.total_amount))
var taxRate = parseAmount(raw.tax_rate) match {
  case r is Number -> if (r > 1) r / 100 else r      // "8" (percent) -> 0.08
  else -> if (subtotal != null and tax != null and subtotal > 0) round(tax / subtotal * 10000) / 10000 else null
}

var fieldConfidence = {
  invoiceNumber: confidenceOf("invoice_number", raw.invoice_number),
  invoiceDate:   confidenceOf("invoice_date", raw.invoice_date),
  vendorName:    confidenceOf("vendor_name", raw.vendor_name),
  vendorId:      confidenceOf("vendor_id", raw.vendor_id),
  poNumber:      confidenceOf("purchase_order_number", raw.purchase_order_number),
  billingAddress: confidenceOf("billing_address", raw.billing_address),
  currency:      confidenceOf("currency", raw.currency),
  lineItems:     confidenceOf("line_items", if (isEmpty(lineItems)) null else lineItems),
  subtotal:      confidenceOf("subtotal", raw.subtotal),
  tax:           confidenceOf("tax", raw.tax),
  total:         confidenceOf("total_amount", raw.total_amount),
  paymentTerms:  confidenceOf("payment_terms", raw.payment_terms),
  dueDate:       confidenceOf("due_date", raw.due_date)
}
---
{
  invoiceNumber: invoiceNumber,
  normalizedInvoiceNumber: normalizeInvoiceNumber(invoiceNumber),
  invoiceDate: formatDate(invoiceDate),
  dueDate: formatDate(statedDueDate default derivedDueDate),
  dueDateDerived: statedDueDate == null and derivedDueDate != null,
  vendor: {
    id: upper(clean(raw.vendor_id)),
    name: clean(raw.vendor_name)
  },
  poNumber: upper(clean(raw.purchase_order_number)),
  billingAddress: clean(raw.billing_address),
  currency: normalizeCurrency(raw.currency),
  paymentTerms: paymentTerms,
  lineItems: lineItems,
  subtotal: subtotal,
  tax: tax,
  taxRate: taxRate,
  total: total,
  extraction: {
    provider: payload.provider default "UNKNOWN",
    model: payload.model,
    overallConfidence: (raw.overall_confidence default (avg(valuesOf(fieldConfidence)) default 0)) as Number,
    fieldConfidence: fieldConfidence,
    warnings: payload.warnings default []
  }
}
