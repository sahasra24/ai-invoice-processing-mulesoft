%dw 2.0
/**
 * Error response formatting (identical copy in all three APIs)
 * ------------------------------------------------------------------
 * Maps a Mule error to { httpStatus, body } using:
 *   1. vars.errorOverride   - explicit { httpStatus, code, message, details } set by a flow
 *   2. downstream HTTP error - status + error body of the called API are propagated
 *                              (4xx as-is, 5xx -> 502 Bad Gateway)
 *   3. the static mapping table below
 * 5xx responses never expose internal error descriptions (no stack traces,
 * SQL, hostnames or credentials) - only a generic message + correlation id.
 *
 * Input  error, vars.errorOverride?, vars.correlationIdValue
 * Output { httpStatus, body: { error: { code, message, httpStatus, correlationId, timestamp, details } } }
 *
 * Used in: global-error-handler (global.xml)
 */
output application/json

var errType = (error.errorType.namespace default "MULE") ++ ":" ++ (error.errorType.identifier default "UNKNOWN")
var override = vars.errorOverride
var downstreamStatus = error.errorMessage.attributes.statusCode default null
var downstreamError = error.errorMessage.payload.error default null

var MAPPING = {
  "APP:UNAUTHORIZED":           { status: 401, code: "UNAUTHORIZED" },
  "APP:FORBIDDEN":              { status: 403, code: "FORBIDDEN" },
  "APP:NOT_FOUND":              { status: 404, code: "NOT_FOUND" },
  "APP:BAD_REQUEST":            { status: 400, code: "BAD_REQUEST" },
  "APP:CONFLICT":               { status: 409, code: "CONFLICT" },
  "APP:INVALID_STATE":          { status: 409, code: "INVALID_STATE" },
  "APP:UNSUPPORTED_MEDIA_TYPE": { status: 415, code: "UNSUPPORTED_MEDIA_TYPE" },
  "APP:PAYLOAD_TOO_LARGE":      { status: 413, code: "PAYLOAD_TOO_LARGE" },
  "APP:AI_EXTRACTION_FAILED":   { status: 502, code: "AI_EXTRACTION_FAILED" },
  "APP:ERP_POSTING_FAILED":     { status: 502, code: "ERP_POSTING_FAILED" },
  "JSON:SCHEMA_NOT_HONOURED":   { status: 400, code: "SCHEMA_VALIDATION_FAILED" },
  "HTTP:CONNECTIVITY":          { status: 503, code: "DOWNSTREAM_UNAVAILABLE" },
  "HTTP:TIMEOUT":               { status: 504, code: "DOWNSTREAM_TIMEOUT" },
  "HTTP:PARSING":               { status: 502, code: "DOWNSTREAM_INVALID_RESPONSE" },
  "DB:CONNECTIVITY":            { status: 503, code: "DATABASE_UNAVAILABLE" },
  "DB:QUERY_EXECUTION":         { status: 500, code: "DATABASE_ERROR" },
  "MULE:RETRY_EXHAUSTED":       { status: 503, code: "RETRIES_EXHAUSTED" },
  "MULE:DUPLICATE_MESSAGE":     { status: 409, code: "DUPLICATE_REQUEST" },
  "OS:KEY_ALREADY_EXISTS":      { status: 409, code: "CONCURRENT_REQUEST" },
  "MULE:EXPRESSION":            { status: 500, code: "INTERNAL_ERROR" }
}

var isDuplicateKey = errType == "DB:QUERY_EXECUTION" and ((error.description default "") contains "Duplicate entry")

var resolved =
  if (override != null)
    { status: override.httpStatus as Number, code: override.code, message: override.message, details: override.details }
  else if (isDuplicateKey)
    { status: 409, code: "DUPLICATE_RECORD", message: "The record already exists (unique constraint)" }
  else if (error.errorType.namespace == "HTTP" and downstreamStatus != null and downstreamStatus >= 400 and downstreamStatus < 500)
    { status: downstreamStatus as Number,
      code: downstreamError.code default "DOWNSTREAM_CLIENT_ERROR",
      message: downstreamError.message default error.description,
      details: downstreamError.details }
  else if (error.errorType.namespace == "HTTP" and downstreamStatus != null and downstreamStatus >= 500)
    { status: 502, code: "BAD_GATEWAY", message: "A downstream service failed (HTTP $(downstreamStatus))" }
  else if (error.errorType.namespace == "VALIDATION")
    { status: 400, code: "VALIDATION_ERROR", message: error.description }
  else if (MAPPING[errType] != null)
    { status: MAPPING[errType].status, code: MAPPING[errType].code, message: error.description }
  else
    { status: 500, code: "INTERNAL_ERROR" }

// Our own APP:* errors and explicit overrides carry curated messages; any other
// 5xx (connectivity, DB, expression...) gets a generic text so that hostnames,
// SQL or stack details never reach the client. Full details stay in the logs.
var curated = override != null or error.errorType.namespace == "APP" or resolved.code == "BAD_GATEWAY"
var GENERIC = {
  "503": "A required service is temporarily unavailable. Please retry later.",
  "504": "A required service did not respond in time. Please retry later."
}
var safeMessage =
  if (resolved.status >= 500 and !curated)
    GENERIC[resolved.status as String] default "An unexpected error occurred. Quote the correlationId when contacting support."
  else (resolved.message default error.description default "Request failed")
---
{
  httpStatus: resolved.status,
  body: {
    error: {
      code: resolved.code,
      message: safeMessage,
      httpStatus: resolved.status,
      correlationId: vars.correlationIdValue,
      timestamp: now() >> "UTC",
      (details: resolved.details) if (resolved.details != null)
    }
  }
}
