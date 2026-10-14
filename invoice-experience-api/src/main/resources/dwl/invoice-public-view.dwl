%dw 2.0
/**
 * System API invoice view -> public Experience API representation
 * Removes internal fields (normalized number, correlation id, storage details,
 * optimistic-lock version) and adds derived approval information.
 *
 * Input  payload : System API invoice view
 * Output         : InvoiceDetails (docs/API-REFERENCE.md)
 * Used in: get-invoice-flow > "Public view"
 */
output application/json
var inv = payload
var chain = (inv.approvalChain default "") splitBy "," filter (!isEmpty($))
var received = (inv.approvalsReceived default 0) as Number
---
{
  invoiceId: inv.invoiceId,
  invoiceNumber: inv.invoiceNumber,
  status: inv.status,
  vendor: {
    vendorId: inv.vendorId default inv.extractedVendorId,
    name: inv.extractedVendorName,
    verified: inv.vendorId != null
  },
  poNumber: inv.poNumber,
  invoiceDate: inv.invoiceDate,
  dueDate: inv.dueDate,
  currency: inv.currency,
  billingAddress: inv.billingAddress,
  paymentTerms: inv.paymentTerms,
  amounts: {
    subtotal: inv.subtotalAmount,
    tax: inv.taxAmount,
    taxRate: inv.taxRate,
    total: inv.totalAmount
  },
  lineItems: (inv.lineItems default []) map ((l) -> {
    lineNumber: l.lineNumber,
    itemCode: l.itemCode,
    description: l.description,
    quantity: l.quantity,
    unitPrice: l.unitPrice,
    amount: l.lineAmount,
    poLineNumber: l.poLineNumber,
    matchStatus: l.matchStatus
  }),
  extraction: {
    provider: inv.extractionProvider,
    confidence: inv.extractionConfidence
  },
  approval: {
    chain: chain,
    approvalsRequired: inv.approvalsRequired,
    approvalsReceived: received,
    nextApprovalLevel: if (["PENDING_APPROVAL", "MANUAL_REVIEW"] contains inv.status) chain[received] else null,
    decisions: inv.approvals default []
  },
  validationErrors: inv.validationErrors default [],
  exceptions: inv.exceptions default [],
  duplicateOf: inv.duplicateOf,
  rejectionReason: inv.rejectionReason,
  erp: if (inv.erpDocumentNumber != null) { documentNumber: inv.erpDocumentNumber, postedAt: inv.erpPostedAt } else null,
  document: if (inv.document != null) {
    fileName: inv.document.fileName,
    mimeType: inv.document.mimeType,
    sizeBytes: inv.document.sizeBytes,
    uploadedAt: inv.document.uploadedAt
  } else null,
  sourceChannel: inv.sourceChannel,
  submittedBy: inv.submittedBy,
  createdAt: inv.createdAt,
  updatedAt: inv.updatedAt
}
