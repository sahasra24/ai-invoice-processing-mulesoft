%dw 2.0
/**
 * Reusable invoice helper functions.
 * Import from any script with:  import * from modules::InvoiceUtils
 */
import * from dw::core::Strings
import try from dw::Runtime

var DATE_FORMATS = [
  "yyyy-MM-dd", "MM/dd/yyyy", "yyyy/MM/dd", "dd-MM-yyyy", "dd.MM.yyyy",
  "MMM d, yyyy", "MMMM d, yyyy", "MMM dd, yyyy", "d MMM yyyy", "dd MMM yyyy", "yyyyMMdd"
]

// "\$" escapes DataWeave string interpolation
var CURRENCY_SYMBOLS = { "\$": "USD", "US\$": "USD", "€": "EUR", "£": "GBP", "₹": "INR", "¥": "JPY", "C\$": "CAD", "A\$": "AUD" }

/** Rounds to 2 decimal places (half-up on BigDecimal). */
fun round2(n: Number | Null): Number | Null =
  if (n == null) null else round(n * 100) / 100

/** Absolute value that tolerates nulls. */
fun absOrNull(n: Number | Null): Number | Null = if (n == null) null else abs(n)

/** "$1,234.50" | "1234.5" | 1234.5 -> 1234.5 ; garbage -> null */
fun parseAmount(v: Any): Number | Null =
  v match {
    case n is Number -> n
    case s is String -> do {
      var cleaned = s replace /[^0-9.\-]/ with ""
      var attempt = try(() -> cleaned as Number)
      ---
      if (isBlank(cleaned) or cleaned == "-" or cleaned == ".") null
      else if (attempt.success) attempt.result
      else null
    }
    else -> null
  }

/** Tries every supported format and returns the first successful Date, or null. */
fun parseDate(v: Any): Date | Null =
  v match {
    case d is Date -> d
    case s is String -> do {
      var value = trim(s)
      var parsed = DATE_FORMATS map ((f) -> try(() -> value as Date { format: f }))
      var ok = parsed filter ((r) -> r.success)
      ---
      if (isBlank(value) or isEmpty(ok)) null else ok[0].result as Date
    }
    else -> null
  }

fun formatDate(d: Date | Null): String | Null =
  if (d == null) null else d as String { format: "yyyy-MM-dd" }

/** Upper-case, alphanumerics only:  "inv/2026/1001" and "INV-2026-1001" -> "INV20261001" */
fun normalizeInvoiceNumber(n: String | Null): String | Null =
  if (n == null or isBlank(n)) null
  else upper(n) replace /[^A-Z0-9]/ with ""

/** "$" -> "USD", "usd" -> "USD", "US Dollars" -> null */
fun normalizeCurrency(c: String | Null): String | Null = do {
  var value = trim(c default "")
  var mapped = CURRENCY_SYMBOLS[value]
  ---
  if (isBlank(value)) null
  else if (mapped != null) mapped
  else if (upper(value) matches /^[A-Z]{3}$/) upper(value)
  else null
}

/** "Net 30" | "NET30" | "2/10 Net 45" -> 30 | 30 | 45 ; "Due on receipt" -> 0 ; unknown -> null */
fun paymentTermDays(terms: String | Null): Number | Null = do {
  var t = lower(terms default "")
  var netMatch = t scan /net\s*(\d+)/
  ---
  if (isBlank(t)) null
  else if (!isEmpty(netMatch)) netMatch[0][1] as Number
  else if (t contains "receipt") 0
  else null
}

/** "Net 30" -> "NET30" (ERP payment term code) */
fun paymentTermCode(terms: String | Null): String | Null = do {
  var days = paymentTermDays(terms)
  ---
  if (days == null) null else if (days == 0) "DUE_ON_RECEIPT" else "NET" ++ (days as String)
}

/** Lower-case alphanumeric "fingerprint" used for fuzzy text comparison. */
fun textKey(s: String | Null): String = lower(s default "") replace /[^a-z0-9]/ with ""

/** true when either normalized name contains the other ("Acme Office Supplies Inc." ~ "Acme Office Supplies"). */
fun namesMatch(a: String | Null, b: String | Null): Boolean = do {
  var ka = textKey(a)
  var kb = textKey(b)
  ---
  !isEmpty(ka) and !isEmpty(kb) and ((ka contains kb) or (kb contains ka))
}

/** Builds a structured issue object used by every validation step. */
fun issue(code: String, severity: String, message: String, details: Object = {}): Object =
  { code: code, severity: severity, message: message } ++ (if (isEmpty(details)) {} else { details: details })
