%dw 2.0
/**
 * ERP payload transformation (JSON -> XML)
 * ------------------------------------------------------------------
 * The simulated ERP exposes a legacy-style XML Accounts Payable endpoint
 * (namespace urn:example:erp:ap:v1). This script maps the approved invoice
 * (System API JSON view) to the ERP's APInvoice document.
 *
 * Input  payload : invoice view { invoiceId, invoiceNumber, vendorId, poNumber, invoiceDate,
 *                  dueDate, currency, paymentTerms, subtotalAmount, taxAmount, totalAmount, lineItems[] }
 * Output         : application/xml APInvoice
 *
 * Used in: post-invoice-to-erp-flow > "Transform to ERP XML"
 */
output application/xml encoding="UTF-8", writeDeclaration=true
ns erp urn:example:erp:ap:v1
import * from modules::InvoiceUtils

fun amount(n) = (n default 0) as String { format: "0.00" }
---
erp#APInvoice @(version: "1.0"): {
  erp#Header: {
    erp#ExternalReference: payload.invoiceId,
    erp#InvoiceNumber: payload.invoiceNumber,
    erp#VendorCode: payload.vendorId,
    erp#PurchaseOrder: payload.poNumber,
    erp#InvoiceDate: payload.invoiceDate,
    erp#DueDate: payload.dueDate,
    erp#Currency: payload.currency,
    erp#PaymentTermCode: paymentTermCode(payload.paymentTerms) default "NET30",
    erp#Amounts: {
      erp#Net: amount(payload.subtotalAmount),
      erp#Tax: amount(payload.taxAmount),
      erp#Gross: amount(payload.totalAmount)
    },
    erp#Source: "MULESOFT_AI_INVOICE"
  },
  erp#Lines: {
    ((payload.lineItems default []) map ((li) -> {
      erp#Line @(number: li.lineNumber): {
        erp#ItemCode: li.itemCode,
        erp#Description: li.description,
        erp#Quantity: (li.quantity default 0) as String { format: "0.###" },
        erp#UnitPrice: (li.unitPrice default 0) as String { format: "0.00##" },
        erp#Amount: amount(li.lineAmount),
        erp#POLine: li.poLineNumber
      }
    }))
  }
}
