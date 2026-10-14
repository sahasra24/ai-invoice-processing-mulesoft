%dw 2.0
/**
 * Exponential backoff for the recoverable failure queue
 * ------------------------------------------------------------------
 *   delay = min(baseDelaySec * 2^attemptCount, maxDelaySec)
 *   attempt 1 -> 60s, 2 -> 120s, 3 -> 240s, 4 -> 480s ... capped at 1h
 * When attemptCount reaches maxAttempts the item becomes DEAD (dead letter)
 * and the invoice is marked FAILED for manual intervention.
 *
 * Input  payload            : queue item { queueId, attemptCount, maxAttempts }
 *        vars.config.recovery: { baseDelaySec, maxDelaySec }
 *        vars.recoveryError  : { code, message }
 * Output                    : PATCH body for /recovery-queue/{queueId}
 *
 * Used in: recover-queue-item-sub-flow > error handler
 */
output application/json

var cfg = vars.config.recovery
var attempts = ((payload.attemptCount default 0) as Number) + 1
var exhausted = attempts >= ((payload.maxAttempts default 5) as Number)
var delay = min([(cfg.baseDelaySec as Number) * (2 pow (attempts - 1)), cfg.maxDelaySec as Number])
var nextAt = (now() >> "UTC") + ("PT$(delay)S" as Period)
var message = (vars.recoveryError.message default "Unknown error") as String
---
{
  status: if (exhausted) "DEAD" else "PENDING",
  attemptCount: attempts,
  delaySeconds: if (exhausted) null else delay,
  nextAttemptAt: nextAt as String { format: "yyyy-MM-dd HH:mm:ss" },
  errorCode: vars.recoveryError.code default "UNKNOWN",
  errorMessage: if (sizeOf(message) > 1000) message[0 to 999] else message
}
