%dw 2.0
/**
 * Extracts the "file" part of a multipart/form-data upload.
 * `.^raw` returns the original bytes even when Mule auto-parsed the part
 * (e.g. a .json file sent with Content-Type application/json), so the
 * SHA-256 / magic-byte checks always run on the exact uploaded bytes.
 *
 * Input  payload : multipart/form-data  (form fields: file [required], autoProcess [optional])
 * Output         : { fileName, contentType, contentBase64, autoProcess }
 *
 * Used in: post-invoice-upload-flow > "Extract file part"
 */
output application/java
import toBase64 from dw::core::Binaries

var filePart = payload.parts.file
var raw = if (filePart == null) null else (filePart.content.^raw default filePart.content)
var autoProcessPart = payload.parts.autoProcess.content.^raw
var autoProcessText = if (autoProcessPart == null) "true" else lower(trim(autoProcessPart as String))
---
{
  fileName: filePart.headers."Content-Disposition".filename,
  contentType: filePart.headers."Content-Type",
  contentBase64: if (raw == null) null else toBase64(raw as Binary),
  autoProcess: autoProcessText != "false"
}
