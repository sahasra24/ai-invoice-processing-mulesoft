%dw 2.0
/**
 * ERP response transformation (XML -> JSON)
 * ------------------------------------------------------------------
 * Success: <APInvoiceResponse><Status/><DocumentNumber/><FiscalYear/><PostedAt/>...
 * Error:   <ErrorResponse><Code/><Message/></ErrorResponse>
 *
 * Input  payload : ERP XML response, vars.erpHttpStatus
 * Output         : { success, erpStatus, erpDocumentNumber, fiscalYear, postedAt, errorCode, errorMessage }
 *
 * Used in: post-invoice-to-erp-flow > "Transform ERP response"
 */
output application/json
ns erp urn:example:erp:ap:v1

var ok = payload.erp#APInvoiceResponse != null
---
if (ok) {
  success: true,
  erpStatus: payload.erp#APInvoiceResponse.erp#Status,
  erpDocumentNumber: payload.erp#APInvoiceResponse.erp#DocumentNumber,
  fiscalYear: payload.erp#APInvoiceResponse.erp#FiscalYear,
  postedAt: payload.erp#APInvoiceResponse.erp#PostedAt,
  externalReference: payload.erp#APInvoiceResponse.erp#ExternalReference
}
else {
  success: false,
  httpStatus: vars.erpHttpStatus,
  errorCode: payload.erp#ErrorResponse.erp#Code default "ERP_ERROR",
  errorMessage: payload.erp#ErrorResponse.erp#Message default "Unexpected ERP response"
}
