%dw 2.0
/**
 * Vendor verification
 * ------------------------------------------------------------------
 * Input  payload           : canonical invoice
 *        vars.vendorLookup : { lookupType: "ID"|"NAME"|"NONE", status: <http status>, body: <System API response> }
 *          - ID   lookup body = vendor object (200) or error (404)
 *          - NAME lookup body = { vendors: [ ... ] }
 * Output                   : { verified, vendor, resolvedBy, issues[] }
 *
 * Used in: process-invoice-orchestration-sub-flow > "Verify vendor"
 */
output application/json
import * from modules::InvoiceUtils

var inv = payload
var lookup = vars.vendorLookup default { lookupType: "NONE" }

var candidates =
  if (lookup.lookupType == "ID" and lookup.status == 200) [lookup.body]
  else if (lookup.lookupType == "NAME" and lookup.status == 200) (lookup.body.vendors default [])
  else []

var vendor = if (sizeOf(candidates) == 1) candidates[0] else null

var issues = flatten([
  if (lookup.lookupType == "NONE")
    [issue("VENDOR_NOT_IDENTIFIED", "BLOCKING", "No vendor ID or vendor name could be extracted")] else [],
  if (lookup.lookupType == "ID" and vendor == null)
    [issue("VENDOR_NOT_FOUND", "BLOCKING", "Vendor $(inv.vendor.id) does not exist in the vendor master", { vendorId: inv.vendor.id })] else [],
  if (lookup.lookupType == "NAME" and isEmpty(candidates))
    [issue("VENDOR_NOT_FOUND", "BLOCKING", "No vendor named '$(inv.vendor.name)' exists in the vendor master")] else [],
  if (lookup.lookupType == "NAME" and sizeOf(candidates) > 1)
    [issue("VENDOR_AMBIGUOUS", "REVIEW", "$(sizeOf(candidates)) vendors match the name '$(inv.vendor.name)'")] else [],
  if (vendor != null and vendor.status != "ACTIVE")
    [issue("VENDOR_INACTIVE", "BLOCKING", "Vendor $(vendor.vendorId) is $(vendor.status)", { vendorId: vendor.vendorId })] else [],
  if (vendor != null and inv.vendor.name != null and !namesMatch(inv.vendor.name, vendor.vendorName))
    [issue("VENDOR_NAME_MISMATCH", "REVIEW",
      "Invoice vendor name '$(inv.vendor.name)' does not match master record '$(vendor.vendorName)'")] else [],
  if (vendor != null and inv.currency != null and vendor.currency != inv.currency)
    [issue("VENDOR_CURRENCY_MISMATCH", "REVIEW",
      "Invoice currency $(inv.currency) differs from vendor currency $(vendor.currency)")] else []
])
---
{
  verified: vendor != null and isEmpty(issues filter ((i) -> i.severity == "BLOCKING")),
  vendor: vendor,
  resolvedBy: if (vendor == null) null else lookup.lookupType,
  issues: issues
}
