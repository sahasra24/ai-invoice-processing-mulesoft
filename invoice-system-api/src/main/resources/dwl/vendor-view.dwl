%dw 2.0
/**
 * vendors row -> Vendor JSON view
 * Used in: sys-get-vendor-flow > "Vendor view"
 */
output application/json
var v = payload[0]
---
{
  vendorId: v.vendor_id,
  vendorName: v.vendor_name,
  taxId: v.tax_id,
  email: v.email,
  phone: v.phone,
  address: {
    line1: v.address_line1,
    city: v.city,
    state: v.state,
    postalCode: v.postal_code,
    country: v.country
  },
  currency: v.currency,
  defaultTaxRate: v.default_tax_rate,
  paymentTerms: v.payment_terms,
  status: v.status
}
