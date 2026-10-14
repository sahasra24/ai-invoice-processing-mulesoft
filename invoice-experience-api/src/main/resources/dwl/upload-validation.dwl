%dw 2.0
/**
 * Upload validation: file type, magic bytes, size, file name, SHA-256
 * ------------------------------------------------------------------
 *  - allowed extensions: .pdf .png .jpg .jpeg .json             (else 415)
 *  - magic bytes must match the extension (renamed files fail)  (else 415)
 *        PDF  %PDF-       -> base64 prefix "JVBER"
 *        PNG  \x89PNG     -> base64 prefix "iVBORw0KGgo"
 *        JPEG \xFF\xD8\xFF-> base64 prefix "/9j/"
 *        JSON must parse as a JSON object
 *  - size: 1 byte .. config.maxFileSizeBytes                   (else 400 / 413)
 *  - file name is reduced to its base name and sanitised (no path traversal)
 *  - SHA-256 of the content is the idempotency key for duplicate uploads
 *
 * Input  payload     : { fileName, contentType, contentBase64 }
 *        vars.config : { maxFileSizeBytes }
 * Output             : { valid, httpStatus, errorCode, message, fileName, mimeType,
 *                        detectedType, sizeBytes, sha256, contentBase64 }
 *
 * Used in: post-invoice-upload-flow > "Validate upload"
 */
output application/json
import * from dw::core::Binaries
import * from dw::core::Strings
import hashWith from dw::Crypto
import try from dw::Runtime

var MIME_BY_EXT = { pdf: "application/pdf", png: "image/png", jpg: "image/jpeg", jpeg: "image/jpeg", json: "application/json" }
var b64 = payload.contentBase64 default ""
var originalName = payload.fileName default ""
var baseName = (originalName splitBy /[\\\/]/)[-1] default ""
var safeName = baseName replace /[^A-Za-z0-9._\-]/ with "_"
var ext = lower((safeName splitBy ".")[-1] default "")
var expectedMime = MIME_BY_EXT[ext]
var padding = if (b64 endsWith "==") 2 else if (b64 endsWith "=") 1 else 0
var sizeBytes = if (isEmpty(b64)) 0 else floor(sizeOf(b64) * 3 / 4) - padding
var maxBytes = (vars.config.maxFileSizeBytes default 10485760) as Number

var bytes = if (isEmpty(b64)) null else fromBase64(b64)
var jsonCheck = if (expectedMime == "application/json" and bytes != null)
                  try(() -> read((bytes as Binary) as String { encoding: "UTF-8" }, "application/json"))
                else null

var detectedType =
  if (b64 startsWith "JVBER") "application/pdf"
  else if (b64 startsWith "iVBORw0KGgo") "image/png"
  else if (b64 startsWith "/9j/") "image/jpeg"
  else if ((jsonCheck.success default false) and (jsonCheck.result is Object)) "application/json"
  else "unknown"

fun fail(status: Number, code: String, message: String) =
  { valid: false, httpStatus: status, errorCode: code, message: message }

var verdict =
  if (isEmpty(originalName) or bytes == null)
    fail(400, "FILE_REQUIRED", "A non-empty multipart field named 'file' is required")
  else if (expectedMime == null)
    fail(415, "UNSUPPORTED_FILE_TYPE", "Only .pdf, .png, .jpg, .jpeg and .json files are accepted")
  else if (sizeBytes > maxBytes)
    fail(413, "FILE_TOO_LARGE", "File is $(sizeBytes) bytes; the maximum is $(maxBytes) bytes")
  else if (detectedType != expectedMime)
    fail(415, "FILE_CONTENT_MISMATCH", "File content does not match its .$(ext) extension")
  else { valid: true, httpStatus: 200, errorCode: null, message: "OK" }
---
verdict ++ {
  fileName: safeName,
  mimeType: expectedMime,
  detectedType: detectedType,
  sizeBytes: sizeBytes,
  sha256: if (verdict.valid) lower(toHex(hashWith(bytes as Binary, "SHA-256"))) else null,
  contentBase64: if (verdict.valid) b64 else null
}
