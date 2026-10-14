%dw 2.0
/**
 * Claude response -> provider-neutral extraction envelope
 * ------------------------------------------------------------------
 * Checks stop_reason BEFORE reading content:
 *   refusal    -> ok=false (safety decline, not retried)
 *   max_tokens -> ok=false (truncated JSON)
 * The JSON answer is in the first "text" content block; "thinking" blocks
 * (adaptive thinking) and "fallback" blocks are skipped.
 *
 * Input  payload : Anthropic Messages API response
 * Output         : { ok, reason?, provider, model, extraction, usage }
 *
 * Used in: ai-extraction-claude-sub-flow > "Parse Claude response"
 */
output application/json
import try from dw::Runtime

var textBlocks = (payload.content default []) filter ((b) -> b."type" == "text")
var parsed = if (isEmpty(textBlocks)) null else try(() -> read(textBlocks[0].text, "application/json"))
var stop = payload.stop_reason
---
if (stop == "refusal")
  { ok: false, reason: "REFUSAL", message: "Model declined the request (category: $(payload.stop_details.category default 'unknown'))" }
else if (stop == "max_tokens")
  { ok: false, reason: "TRUNCATED", message: "Model output was truncated (max_tokens reached)" }
else if (parsed == null or !parsed.success)
  { ok: false, reason: "INVALID_OUTPUT", message: "Model response did not contain parseable JSON" }
else {
  ok: true,
  provider: "CLAUDE",
  model: payload.model,
  warnings: [],
  extraction: parsed.result,
  usage: {
    inputTokens: payload.usage.input_tokens,
    outputTokens: payload.usage.output_tokens
  }
}
