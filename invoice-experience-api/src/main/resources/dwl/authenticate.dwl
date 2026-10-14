%dw 2.0
/**
 * HTTP Basic authentication against the local demo user store
 * ------------------------------------------------------------------
 * Passwords are never stored in clear text: security/users.json holds
 * SHA-256("username:password") hashes. In production, replace this with
 * an API Manager policy (OAuth 2.0 / JWT validation) and an IdP; the
 * downstream contract (vars.user = { username, roles }) stays the same.
 *
 * Input  attributes.headers.authorization, vars.users (security/users.json)
 * Output { authenticated, user: { username, displayName, roles } | null, reason }
 *
 * Used in: authenticate-sub-flow > "Authenticate"
 */
output application/json
import * from dw::core::Binaries
import * from dw::core::Strings
import hashWith from dw::Crypto
import try from dw::Runtime

var header = (attributes.headers.authorization default "") as String
var hasBasic = lower(header) startsWith "basic "
var token = if (hasBasic) trim(header[6 to -1]) else ""
var decoded = try(() -> fromBase64(token) as String { encoding: "UTF-8" })
var credentials = if (hasBasic and (decoded.success default false)) (decoded.result default "") as String else ""
var username = if (credentials contains ":") substringBefore(credentials, ":") else ""
var password = if (credentials contains ":") substringAfter(credentials, ":") else ""
var hash = lower(toHex(hashWith(("$(username):$(password)") as Binary { encoding: "UTF-8" }, "SHA-256")))
var account = ((vars.users.users default []) filter ((u) -> (u.username == username) and (u.enabled default false)))[0]
---
if (!hasBasic or isEmpty(username))
  { authenticated: false, user: null, reason: "Missing Basic Authorization header" }
else if (account == null or account.passwordSha256 != hash)
  { authenticated: false, user: null, reason: "Invalid credentials" }
else
  { authenticated: true, user: { username: account.username, displayName: account.displayName, roles: account.roles }, reason: null }
