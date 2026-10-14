-- Handy queries for demos, debugging and interviews (not run automatically)
USE invoice_db;

-- Invoice pipeline overview
SELECT status, COUNT(*) AS invoices, SUM(total_amount) AS amount
FROM invoices GROUP BY status ORDER BY status;

-- Latest invoices with their decision
SELECT invoice_id, invoice_number, COALESCE(vendor_id, extracted_vendor_id) AS vendor, total_amount, status,
       approval_chain, approvals_received, erp_document_number, created_at
FROM invoices ORDER BY created_at DESC LIMIT 20;

-- Full audit trail of one invoice
SELECT created_at, step, outcome, from_status, to_status, actor, message
FROM processing_audit_logs WHERE invoice_id = '<invoice-id>' ORDER BY created_at, audit_id;

-- Trace one request across all three APIs (the same id appears in the Mule logs)
SELECT * FROM processing_audit_logs WHERE correlation_id = '<correlation-id>';

-- Recovery queue / dead letters
SELECT queue_id, invoice_id, failure_type, attempt_count, max_attempts, status, next_attempt_at, error_code
FROM recovery_queue ORDER BY created_at DESC;

-- Purchase order consumption after ERP posting
SELECT po.po_number, po.total_amount, po.invoiced_amount, po.status,
       l.line_number, l.quantity, l.quantity_invoiced
FROM purchase_orders po JOIN purchase_order_lines l ON l.po_number = po.po_number
ORDER BY po.po_number, l.line_number;

-- Approval decisions
SELECT invoice_id, approval_level, decision, decided_by, decided_by_role, decided_at, comments
FROM approval_records ORDER BY decided_at DESC;

-- Make a dead-lettered item retry again (manual intervention)
-- UPDATE recovery_queue SET status = 'PENDING', attempt_count = 0, next_attempt_at = NOW() WHERE queue_id = <id>;

-- Reset demo data (keeps the schema):   mysql -u root -p < database/02-sample-data.sql
