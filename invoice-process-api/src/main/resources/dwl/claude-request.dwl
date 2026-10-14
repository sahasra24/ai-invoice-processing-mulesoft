%dw 2.0
/**
 * Claude (Anthropic Messages API) extraction request
 * ------------------------------------------------------------------
 * POST https://api.anthropic.com/v1/messages
 *   - PDF   -> "document" content block (base64)
 *   - Image -> "image" content block (base64)
 *   - output_config.format = json_schema  => the response text is guaranteed
 *     to be JSON matching schemas/claude-extraction-schema.json
 *   - fallbacks: "default" (+ header anthropic-beta: server-side-fallback-2026-07-01)
 *     re-runs a safety-declined request on Anthropic's recommended fallback model
 *
 * Input  payload          : { fileName, mimeType, contentBase64 }
 *        vars.config      : { anthropic: { model, maxTokens, effort } }
 *        vars.claudeSchema: JSON schema (loaded from classpath in the flow)
 *
 * Used in: ai-extraction-claude-sub-flow > "Build Claude request"
 */
output application/json

var cfg = vars.config.anthropic
var isPdf = payload.mimeType == "application/pdf"

var documentBlock =
  if (isPdf) {
    "type": "document",
    source: { "type": "base64", media_type: "application/pdf", data: payload.contentBase64 }
  }
  else {
    "type": "image",
    source: { "type": "base64", media_type: payload.mimeType, data: payload.contentBase64 }
  }

var instructions = "Extract the invoice in this document into the required JSON structure.
Rules:
- Copy values exactly as printed; do not invent data. Use null for anything not present or illegible.
- Dates must be YYYY-MM-DD. Currency must be an ISO 4217 code (\$ -> USD).
- Amounts and quantities are plain numbers without currency symbols or thousands separators.
- tax_rate is a decimal fraction (8% -> 0.08).
- line_number starts at 1 in document order.
- field_confidence: your confidence (0.0-1.0) that each extracted value is correct; 0.0 for null values.
- overall_confidence: your confidence (0.0-1.0) that the whole extraction is correct and complete."
---
{
  model: cfg.model,
  max_tokens: (cfg.maxTokens default 16000) as Number,
  fallbacks: "default",
  system: "You are an accounts-payable document extraction engine. You read supplier invoices and return structured data only.",
  output_config: {
    effort: cfg.effort default "medium",
    format: { "type": "json_schema", schema: vars.claudeSchema }
  },
  messages: [
    {
      role: "user",
      content: [ documentBlock, { "type": "text", text: instructions } ]
    }
  ]
}
