-- =====================================================================
-- AI-Powered Invoice Processing & ERP Integration
-- Database schema (MySQL 8.0 / 8.4)
--
-- Run as a privileged user:
--   mysql -u root -p < database/01-schema.sql
-- =====================================================================

CREATE DATABASE IF NOT EXISTS invoice_db
  CHARACTER SET utf8mb4
  COLLATE utf8mb4_unicode_ci;

USE invoice_db;

SET FOREIGN_KEY_CHECKS = 0;
DROP TABLE IF EXISTS recovery_queue;
DROP TABLE IF EXISTS processing_audit_logs;
DROP TABLE IF EXISTS approval_records;
DROP TABLE IF EXISTS invoice_line_items;
DROP TABLE IF EXISTS invoice_documents;
DROP TABLE IF EXISTS invoices;
DROP TABLE IF EXISTS purchase_order_lines;
DROP TABLE IF EXISTS purchase_orders;
DROP TABLE IF EXISTS vendors;
SET FOREIGN_KEY_CHECKS = 1;

-- ---------------------------------------------------------------------
-- Vendors (supplier master data, normally mastered in the ERP)
-- ---------------------------------------------------------------------
CREATE TABLE vendors (
  vendor_id          VARCHAR(20)   NOT NULL,
  vendor_name        VARCHAR(150)  NOT NULL,
  tax_id             VARCHAR(30)   NULL,
  email              VARCHAR(150)  NULL,
  phone              VARCHAR(30)   NULL,
  address_line1      VARCHAR(200)  NULL,
  city               VARCHAR(80)   NULL,
  state              VARCHAR(80)   NULL,
  postal_code        VARCHAR(20)   NULL,
  country            CHAR(2)       NOT NULL DEFAULT 'US',
  currency           CHAR(3)       NOT NULL DEFAULT 'USD',
  default_tax_rate   DECIMAL(6,4)  NOT NULL DEFAULT 0.0000,
  payment_terms      VARCHAR(20)   NOT NULL DEFAULT 'NET30',
  status             VARCHAR(10)   NOT NULL DEFAULT 'ACTIVE',
  created_at         DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at         DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  CONSTRAINT pk_vendors PRIMARY KEY (vendor_id),
  CONSTRAINT uq_vendors_tax_id UNIQUE (tax_id),
  CONSTRAINT ck_vendors_status CHECK (status IN ('ACTIVE','INACTIVE','BLOCKED')),
  CONSTRAINT ck_vendors_tax_rate CHECK (default_tax_rate >= 0 AND default_tax_rate < 1)
) ENGINE=InnoDB;

CREATE INDEX ix_vendors_name ON vendors (vendor_name);

-- ---------------------------------------------------------------------
-- Purchase orders (simulated ERP data)
-- ---------------------------------------------------------------------
CREATE TABLE purchase_orders (
  po_number          VARCHAR(30)    NOT NULL,
  vendor_id          VARCHAR(20)    NOT NULL,
  po_date            DATE           NOT NULL,
  currency           CHAR(3)        NOT NULL,
  subtotal_amount    DECIMAL(14,2)  NOT NULL,
  tax_amount         DECIMAL(14,2)  NOT NULL DEFAULT 0.00,
  total_amount       DECIMAL(14,2)  NOT NULL,
  invoiced_amount    DECIMAL(14,2)  NOT NULL DEFAULT 0.00,
  status             VARCHAR(20)    NOT NULL DEFAULT 'OPEN',
  buyer_email        VARCHAR(150)   NULL,
  created_at         DATETIME       NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at         DATETIME       NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  CONSTRAINT pk_purchase_orders PRIMARY KEY (po_number),
  CONSTRAINT fk_po_vendor FOREIGN KEY (vendor_id) REFERENCES vendors (vendor_id),
  CONSTRAINT ck_po_status CHECK (status IN ('OPEN','PARTIALLY_INVOICED','FULLY_INVOICED','CLOSED','CANCELLED')),
  CONSTRAINT ck_po_amounts CHECK (total_amount >= 0 AND invoiced_amount >= 0)
) ENGINE=InnoDB;

CREATE INDEX ix_po_vendor ON purchase_orders (vendor_id);
CREATE INDEX ix_po_status ON purchase_orders (status);

CREATE TABLE purchase_order_lines (
  po_line_id         BIGINT         NOT NULL AUTO_INCREMENT,
  po_number          VARCHAR(30)    NOT NULL,
  line_number        INT            NOT NULL,
  item_code          VARCHAR(40)    NULL,
  description        VARCHAR(255)   NOT NULL,
  quantity           DECIMAL(12,3)  NOT NULL,
  unit_price         DECIMAL(14,4)  NOT NULL,
  line_amount        DECIMAL(14,2)  NOT NULL,
  quantity_invoiced  DECIMAL(12,3)  NOT NULL DEFAULT 0.000,
  CONSTRAINT pk_po_lines PRIMARY KEY (po_line_id),
  CONSTRAINT fk_po_lines_po FOREIGN KEY (po_number) REFERENCES purchase_orders (po_number) ON DELETE CASCADE,
  CONSTRAINT uq_po_lines UNIQUE (po_number, line_number),
  CONSTRAINT ck_po_lines_qty CHECK (quantity > 0 AND quantity_invoiced >= 0)
) ENGINE=InnoDB;

-- ---------------------------------------------------------------------
-- Invoices
--   * vendor_id is only populated once the vendor has been VERIFIED
--     (FK to vendors). Raw AI output is kept in extracted_vendor_*.
--   * dedupe_key is a STORED generated column used to enforce, at the
--     database level, that a vendor cannot have two "live" invoices
--     with the same normalized invoice number (race-condition proof
--     duplicate protection). Rejected/duplicate/failed rows are
--     excluded so that corrected re-submissions are possible.
-- ---------------------------------------------------------------------
CREATE TABLE invoices (
  invoice_id                 CHAR(36)       NOT NULL,
  invoice_number             VARCHAR(50)    NULL,
  normalized_invoice_number  VARCHAR(50)    NULL,
  vendor_id                  VARCHAR(20)    NULL,
  extracted_vendor_id        VARCHAR(20)    NULL,
  extracted_vendor_name      VARCHAR(150)   NULL,
  po_number                  VARCHAR(30)    NULL,
  invoice_date               DATE           NULL,
  due_date                   DATE           NULL,
  currency                   CHAR(3)        NULL,
  billing_address            VARCHAR(500)   NULL,
  payment_terms              VARCHAR(30)    NULL,
  subtotal_amount            DECIMAL(14,2)  NULL,
  tax_amount                 DECIMAL(14,2)  NULL,
  tax_rate                   DECIMAL(6,4)   NULL,
  total_amount               DECIMAL(14,2)  NULL,
  status                     VARCHAR(30)    NOT NULL DEFAULT 'RECEIVED',
  approval_chain             VARCHAR(100)   NULL COMMENT 'Comma separated approval levels, e.g. MANAGER,FINANCE_DIRECTOR',
  approvals_required         TINYINT        NOT NULL DEFAULT 0,
  approvals_received         TINYINT        NOT NULL DEFAULT 0,
  extraction_provider        VARCHAR(30)    NULL,
  extraction_confidence      DECIMAL(5,4)   NULL,
  source_channel             VARCHAR(20)    NOT NULL,
  validation_errors          JSON           NULL,
  exceptions                 JSON           NULL,
  duplicate_of               CHAR(36)       NULL,
  erp_document_number        VARCHAR(40)    NULL,
  erp_posted_at              DATETIME       NULL,
  rejection_reason           VARCHAR(1000)  NULL,
  submitted_by               VARCHAR(100)   NOT NULL,
  correlation_id             VARCHAR(64)    NULL,
  version                    INT            NOT NULL DEFAULT 0,
  created_at                 DATETIME       NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at                 DATETIME       NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  dedupe_key                 VARCHAR(80) GENERATED ALWAYS AS (
                               CASE
                                 WHEN vendor_id IS NOT NULL
                                  AND normalized_invoice_number IS NOT NULL
                                  AND status NOT IN ('DUPLICATE','REJECTED','VALIDATION_FAILED','FAILED')
                                 THEN CONCAT(vendor_id, '|', normalized_invoice_number)
                                 ELSE NULL
                               END) STORED,
  CONSTRAINT pk_invoices PRIMARY KEY (invoice_id),
  CONSTRAINT fk_invoices_vendor FOREIGN KEY (vendor_id) REFERENCES vendors (vendor_id),
  CONSTRAINT uq_invoices_dedupe UNIQUE (dedupe_key),
  CONSTRAINT ck_invoices_status CHECK (status IN (
      'RECEIVED','PROCESSING','EXTRACTION_FAILED','VALIDATION_FAILED','DUPLICATE',
      'MANUAL_REVIEW','PENDING_APPROVAL','APPROVED','REJECTED','POSTED_TO_ERP',
      'ERP_POSTING_FAILED','FAILED')),
  CONSTRAINT ck_invoices_channel CHECK (source_channel IN ('API_UPLOAD','API_JSON','FILE_DROP')),
  CONSTRAINT ck_invoices_amounts CHECK (
      (subtotal_amount IS NULL OR subtotal_amount >= 0) AND
      (tax_amount IS NULL OR tax_amount >= 0) AND
      (total_amount IS NULL OR total_amount >= 0)),
  CONSTRAINT ck_invoices_approvals CHECK (approvals_received <= approvals_required OR approvals_required = 0)
) ENGINE=InnoDB;

CREATE INDEX ix_invoices_status       ON invoices (status);
CREATE INDEX ix_invoices_vendor       ON invoices (vendor_id);
CREATE INDEX ix_invoices_ext_vendor   ON invoices (extracted_vendor_id);
CREATE INDEX ix_invoices_po           ON invoices (po_number);
CREATE INDEX ix_invoices_created      ON invoices (created_at);
CREATE INDEX ix_invoices_submitted_by ON invoices (submitted_by);
CREATE INDEX ix_invoices_vendor_total ON invoices (vendor_id, total_amount, invoice_date);

-- ---------------------------------------------------------------------
-- Uploaded source documents. File bytes live on disk / object storage;
-- the database keeps metadata + SHA-256 for content idempotency.
-- ---------------------------------------------------------------------
CREATE TABLE invoice_documents (
  document_id        BIGINT        NOT NULL AUTO_INCREMENT,
  invoice_id         CHAR(36)      NOT NULL,
  file_name          VARCHAR(255)  NOT NULL,
  mime_type          VARCHAR(100)  NOT NULL,
  file_size_bytes    INT           NOT NULL,
  content_sha256     CHAR(64)      NOT NULL,
  storage_path       VARCHAR(500)  NOT NULL,
  uploaded_by        VARCHAR(100)  NOT NULL,
  uploaded_at        DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT pk_invoice_documents PRIMARY KEY (document_id),
  CONSTRAINT fk_documents_invoice FOREIGN KEY (invoice_id) REFERENCES invoices (invoice_id) ON DELETE CASCADE,
  CONSTRAINT uq_documents_invoice UNIQUE (invoice_id),
  CONSTRAINT uq_documents_sha256 UNIQUE (content_sha256),
  CONSTRAINT ck_documents_size CHECK (file_size_bytes > 0)
) ENGINE=InnoDB;

-- ---------------------------------------------------------------------
-- Invoice line items
-- ---------------------------------------------------------------------
CREATE TABLE invoice_line_items (
  line_item_id       BIGINT         NOT NULL AUTO_INCREMENT,
  invoice_id         CHAR(36)       NOT NULL,
  line_number        INT            NOT NULL,
  item_code          VARCHAR(40)    NULL,
  description        VARCHAR(255)   NULL,
  quantity           DECIMAL(12,3)  NULL,
  unit_price         DECIMAL(14,4)  NULL,
  line_amount        DECIMAL(14,2)  NULL,
  po_line_number     INT            NULL,
  match_status       VARCHAR(20)    NULL,
  CONSTRAINT pk_invoice_line_items PRIMARY KEY (line_item_id),
  CONSTRAINT fk_lines_invoice FOREIGN KEY (invoice_id) REFERENCES invoices (invoice_id) ON DELETE CASCADE,
  CONSTRAINT uq_lines_invoice_line UNIQUE (invoice_id, line_number)
) ENGINE=InnoDB;

-- ---------------------------------------------------------------------
-- Approval decisions.
--   uq_approval_level -> one decision per approval level
--   uq_approval_user  -> the same person cannot approve twice
-- ---------------------------------------------------------------------
CREATE TABLE approval_records (
  approval_id        BIGINT         NOT NULL AUTO_INCREMENT,
  invoice_id         CHAR(36)       NOT NULL,
  approval_level     VARCHAR(30)    NOT NULL,
  decision           VARCHAR(10)    NOT NULL,
  decided_by         VARCHAR(100)   NOT NULL,
  decided_by_role    VARCHAR(30)    NOT NULL,
  comments           VARCHAR(1000)  NULL,
  decided_at         DATETIME       NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT pk_approval_records PRIMARY KEY (approval_id),
  CONSTRAINT fk_approvals_invoice FOREIGN KEY (invoice_id) REFERENCES invoices (invoice_id) ON DELETE CASCADE,
  CONSTRAINT uq_approval_level UNIQUE (invoice_id, approval_level),
  CONSTRAINT uq_approval_user  UNIQUE (invoice_id, decided_by),
  CONSTRAINT ck_approval_decision CHECK (decision IN ('APPROVED','REJECTED')),
  CONSTRAINT ck_approval_level CHECK (approval_level IN ('APPROVER','MANAGER','FINANCE_DIRECTOR'))
) ENGINE=InnoDB;

CREATE INDEX ix_approvals_user ON approval_records (decided_by);

-- ---------------------------------------------------------------------
-- Processing audit trail (append-only)
-- ---------------------------------------------------------------------
CREATE TABLE processing_audit_logs (
  audit_id           BIGINT         NOT NULL AUTO_INCREMENT,
  invoice_id         CHAR(36)       NOT NULL,
  correlation_id     VARCHAR(64)    NULL,
  step               VARCHAR(50)    NOT NULL,
  outcome            VARCHAR(10)    NOT NULL,
  from_status        VARCHAR(30)    NULL,
  to_status          VARCHAR(30)    NULL,
  message            VARCHAR(1000)  NULL,
  actor              VARCHAR(100)   NOT NULL DEFAULT 'system',
  details            JSON           NULL,
  created_at         DATETIME(3)    NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  CONSTRAINT pk_audit PRIMARY KEY (audit_id),
  CONSTRAINT fk_audit_invoice FOREIGN KEY (invoice_id) REFERENCES invoices (invoice_id) ON DELETE CASCADE,
  CONSTRAINT ck_audit_outcome CHECK (outcome IN ('STARTED','SUCCESS','FAILED','WARNING','INFO'))
) ENGINE=InnoDB;

CREATE INDEX ix_audit_invoice     ON processing_audit_logs (invoice_id, created_at);
CREATE INDEX ix_audit_correlation ON processing_audit_logs (correlation_id);

-- ---------------------------------------------------------------------
-- Recoverable failure queue / dead-letter store.
--   PENDING -> IN_PROGRESS -> RESOLVED
--                           \-> PENDING (attempt_count+1, exponential backoff)
--                           \-> DEAD    (max attempts reached = dead letter)
-- ---------------------------------------------------------------------
CREATE TABLE recovery_queue (
  queue_id           BIGINT         NOT NULL AUTO_INCREMENT,
  invoice_id         CHAR(36)       NOT NULL,
  failure_type       VARCHAR(20)    NOT NULL,
  error_code         VARCHAR(60)    NULL,
  error_message      VARCHAR(1000)  NULL,
  attempt_count      INT            NOT NULL DEFAULT 0,
  max_attempts       INT            NOT NULL DEFAULT 5,
  next_attempt_at    DATETIME       NOT NULL DEFAULT CURRENT_TIMESTAMP,
  status             VARCHAR(15)    NOT NULL DEFAULT 'PENDING',
  correlation_id     VARCHAR(64)    NULL,
  created_at         DATETIME       NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at         DATETIME       NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  CONSTRAINT pk_recovery_queue PRIMARY KEY (queue_id),
  CONSTRAINT fk_recovery_invoice FOREIGN KEY (invoice_id) REFERENCES invoices (invoice_id) ON DELETE CASCADE,
  CONSTRAINT ck_recovery_type CHECK (failure_type IN ('AI_EXTRACTION','ERP_POSTING','DATABASE','UNKNOWN')),
  CONSTRAINT ck_recovery_status CHECK (status IN ('PENDING','IN_PROGRESS','RESOLVED','DEAD'))
) ENGINE=InnoDB;

CREATE INDEX ix_recovery_due ON recovery_queue (status, next_attempt_at);
CREATE INDEX ix_recovery_invoice ON recovery_queue (invoice_id);

-- ---------------------------------------------------------------------
-- Least-privilege application account (change the password!)
-- ---------------------------------------------------------------------
CREATE USER IF NOT EXISTS 'invoice_app'@'%' IDENTIFIED BY 'ChangeMe_Local_2026!';
GRANT SELECT, INSERT, UPDATE, DELETE ON invoice_db.* TO 'invoice_app'@'%';
FLUSH PRIVILEGES;
