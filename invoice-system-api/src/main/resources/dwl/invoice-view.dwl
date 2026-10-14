%dw 2.0
/**
 * Database rows -> Invoice JSON view (System API contract)
 * ------------------------------------------------------------------
 * Input  vars.invoiceRow   : single row from invoices (dates pre-formatted in SQL)
 *        vars.lineRows     : rows from invoice_line_items
 *        vars.approvalRows : rows from approval_records
 *        vars.documentRow  : row from invoice_documents (or null)
 * Output                   : invoice view (camelCase, JSON columns parsed)
 *
 * Used in: sys-load-invoice-sub-flow > "Build invoice view"
 */
output application/json
import try from dw::Runtime

var r = vars.invoiceRow
fun parseJson(s) = if (s == null) [] else do {
  var t = try(() -> read(s as String, "application/json"))
  ---
  if (t.success) t.result else []
}
---
{
  invoiceId: r.invoice_id,
  invoiceNumber: r.invoice_number,
  normalizedInvoiceNumber: r.normalized_invoice_number,
  vendorId: r.vendor_id,
  extractedVendorId: r.extracted_vendor_id,
  extractedVendorName: r.extracted_vendor_name,
  poNumber: r.po_number,
  invoiceDate: r.invoice_date,
  dueDate: r.due_date,
  currency: r.currency,
  billingAddress: r.billing_address,
  paymentTerms: r.payment_terms,
  subtotalAmount: r.subtotal_amount,
  taxAmount: r.tax_amount,
  taxRate: r.tax_rate,
  totalAmount: r.total_amount,
  status: r.status,
  approvalChain: r.approval_chain,
  approvalsRequired: r.approvals_required,
  approvalsReceived: r.approvals_received,
  extractionProvider: r.extraction_provider,
  extractionConfidence: r.extraction_confidence,
  sourceChannel: r.source_channel,
  validationErrors: parseJson(r.validation_errors),
  exceptions: parseJson(r.exceptions),
  duplicateOf: r.duplicate_of,
  erpDocumentNumber: r.erp_document_number,
  erpPostedAt: r.erp_posted_at,
  rejectionReason: r.rejection_reason,
  submittedBy: r.submitted_by,
  correlationId: r.correlation_id,
  version: r.version,
  createdAt: r.created_at,
  updatedAt: r.updated_at,
  lineItems: (vars.lineRows default []) map ((l) -> {
    lineNumber: l.line_number,
    itemCode: l.item_code,
    description: l.description,
    quantity: l.quantity,
    unitPrice: l.unit_price,
    lineAmount: l.line_amount,
    poLineNumber: l.po_line_number,
    matchStatus: l.match_status
  }),
  approvals: (vars.approvalRows default []) map ((a) -> {
    approvalLevel: a.approval_level,
    decision: a.decision,
    decidedBy: a.decided_by,
    decidedByRole: a.decided_by_role,
    comments: a.comments,
    decidedAt: a.decided_at
  }),
  document: if (vars.documentRow == null) null else {
    fileName: vars.documentRow.file_name,
    mimeType: vars.documentRow.mime_type,
    sizeBytes: vars.documentRow.file_size_bytes,
    sha256: vars.documentRow.content_sha256,
    uploadedBy: vars.documentRow.uploaded_by,
    uploadedAt: vars.documentRow.uploaded_at
  }
}
