%dw 2.0
/**
 * Role-based approval authorization
 * ------------------------------------------------------------------
 * Decides whether the calling user may APPROVE / REJECT the invoice at its
 * current approval step and computes the resulting state.
 *
 * Rules
 *  - invoice must be PENDING_APPROVAL or MANUAL_REVIEW            (409)
 *  - user's highest approval role must be >= the next level       (403)
 *  - the submitter can never approve their own invoice (SoD)      (403)
 *  - a user can decide only once per invoice                      (409)
 *  - a MANUAL_REVIEW invoice can only be approved when complete   (409)
 *  - rejection requires a reason of at least 5 characters         (400)
 *
 * Input  payload               : invoice from System API (incl. approvals[])
 *        vars.decisionRequest  : { decision: APPROVE|REJECT, username, roles[], comments }
 * Output                       : { allowed, httpStatus, errorCode, message, approvalLevel,
 *                                  decidedByRole, newStatus, newApprovalsReceived, isFinalApproval,
 *                                  expectedStatus, expectedVersion }
 *
 * Used in: invoice-decision-flow > "Authorize decision"
 */
output application/json
import * from dw::core::Strings

var ROLE_RANK = { APPROVER: 1, MANAGER: 2, FINANCE_DIRECTOR: 3 }
var inv = payload
var req = vars.decisionRequest
var chain = (inv.approvalChain default "") splitBy "," map trim($) filter (!isEmpty($))
var received = (inv.approvalsReceived default 0) as Number
var required = (inv.approvalsRequired default sizeOf(chain)) as Number
var nextLevel = chain[received]
var userRoles = (req.roles default []) filter ((r) -> ROLE_RANK[r] != null)
var userRank = max(userRoles map ((r) -> ROLE_RANK[r] as Number)) default 0
var userRole = (userRoles orderBy ((r) -> -(ROLE_RANK[r] as Number)))[0]
var alreadyDecided = !isEmpty((inv.approvals default []) filter ((a) -> lower(a.decidedBy default "") == lower(req.username default "")))
var incomplete = inv.invoiceNumber == null or inv.vendorId == null or inv.totalAmount == null
var isApprove = req.decision == "APPROVE"

fun deny(status: Number, code: String, message: String) =
  { allowed: false, httpStatus: status, errorCode: code, message: message }

var verdict =
  if (!(["PENDING_APPROVAL", "MANUAL_REVIEW"] contains inv.status))
    deny(409, "INVALID_INVOICE_STATE", "Invoice is $(inv.status); only PENDING_APPROVAL or MANUAL_REVIEW invoices can be decided")
  else if (nextLevel == null)
    deny(409, "NO_PENDING_APPROVAL", "Invoice has no outstanding approval step")
  else if (userRank == 0)
    deny(403, "NOT_AN_APPROVER", "User $(req.username) has no approval role")
  else if (userRank < (ROLE_RANK[nextLevel] as Number))
    deny(403, "INSUFFICIENT_APPROVAL_AUTHORITY", "Step $(received + 1) requires $(nextLevel) or higher; user has $(userRole)")
  else if (lower(req.username default "") == lower(inv.submittedBy default ""))
    deny(403, "SEGREGATION_OF_DUTIES", "The submitter of an invoice cannot approve or reject it")
  else if (alreadyDecided)
    deny(409, "ALREADY_DECIDED", "User $(req.username) has already recorded a decision for this invoice")
  else if (isApprove and inv.status == "MANUAL_REVIEW" and incomplete)
    deny(409, "INVOICE_INCOMPLETE", "Invoice is missing invoice number, verified vendor or total; reject it and request a corrected invoice")
  else if (!isApprove and sizeOf(trim(req.comments default "")) < 5)
    deny(400, "REJECTION_REASON_REQUIRED", "A rejection reason of at least 5 characters is required")
  else { allowed: true, httpStatus: 200, errorCode: null, message: "Authorized" }

var isFinal = isApprove and (received + 1) >= required
---
verdict ++ {
  approvalLevel: nextLevel,
  decidedByRole: userRole,
  decision: if (isApprove) "APPROVED" else "REJECTED",
  newStatus: if (!isApprove) "REJECTED" else if (isFinal) "APPROVED" else "PENDING_APPROVAL",
  newApprovalsReceived: if (isApprove) received + 1 else received,
  isFinalApproval: isFinal,
  nextApprovalLevel: if (isApprove and !isFinal) chain[received + 1] else null,
  expectedStatus: inv.status,
  expectedVersion: inv.version
}
