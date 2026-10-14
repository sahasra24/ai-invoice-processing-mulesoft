-- =====================================================================
-- Sample master data for the local demo
--   mysql -u root -p < database/02-sample-data.sql
-- Every sample invoice in /sample-invoices maps to one of these POs.
-- =====================================================================
USE invoice_db;

SET FOREIGN_KEY_CHECKS = 0;
TRUNCATE TABLE recovery_queue;
TRUNCATE TABLE processing_audit_logs;
TRUNCATE TABLE approval_records;
TRUNCATE TABLE invoice_line_items;
TRUNCATE TABLE invoice_documents;
TRUNCATE TABLE invoices;
TRUNCATE TABLE purchase_order_lines;
TRUNCATE TABLE purchase_orders;
TRUNCATE TABLE vendors;
SET FOREIGN_KEY_CHECKS = 1;

-- ---------------------------------------------------------------------
-- Vendors
-- ---------------------------------------------------------------------
INSERT INTO vendors (vendor_id, vendor_name, tax_id, email, phone, address_line1, city, state, postal_code, country, currency, default_tax_rate, payment_terms, status) VALUES
 ('V-1001', 'Acme Office Supplies',      '91-1000001', 'billing@acme-office.example',   '+1-206-555-0101', '100 Paper Lane',        'Seattle',   'WA', '98101', 'US', 'USD', 0.0800, 'NET30', 'ACTIVE'),
 ('V-1002', 'Globex Industrial Parts',   '91-1000002', 'ar@globex-parts.example',       '+1-312-555-0102', '42 Foundry Road',       'Chicago',   'IL', '60601', 'US', 'USD', 0.0800, 'NET45', 'ACTIVE'),
 ('V-1003', 'Initech IT Services',       '91-1000003', 'invoices@initech.example',      '+1-512-555-0103', '7 Cubicle Court',       'Austin',    'TX', '73301', 'US', 'USD', 0.0800, 'NET60', 'ACTIVE'),
 ('V-1004', 'Umbrella Logistics',        '91-1000004', 'finance@umbrella-log.example',  '+1-404-555-0104', '13 Raccoon Street',     'Atlanta',   'GA', '30301', 'US', 'USD', 0.0800, 'NET30', 'INACTIVE'),
 ('V-1005', 'Stark Precision Components','91-1000005', 'ap@stark-precision.example',    '+1-212-555-0105', '890 Fifth Avenue',      'New York',  'NY', '10001', 'US', 'USD', 0.1000, 'NET30', 'ACTIVE');

-- ---------------------------------------------------------------------
-- Purchase orders + lines
-- ---------------------------------------------------------------------
INSERT INTO purchase_orders (po_number, vendor_id, po_date, currency, subtotal_amount, tax_amount, total_amount, invoiced_amount, status, buyer_email) VALUES
 ('PO-2026-0001', 'V-1001', '2026-09-01', 'USD',   800.00,   64.00,   864.00, 0.00, 'OPEN',   'buyer.ops@contoso.example'),
 ('PO-2026-0002', 'V-1002', '2026-09-02', 'USD',  5000.00,  400.00,  5400.00, 0.00, 'OPEN',   'buyer.plant@contoso.example'),
 ('PO-2026-0003', 'V-1003', '2026-09-03', 'USD', 60000.00, 4800.00, 64800.00, 0.00, 'OPEN',   'it.procurement@contoso.example'),
 ('PO-2026-0004', 'V-1002', '2026-09-04', 'USD',  1200.00,   96.00,  1296.00, 0.00, 'OPEN',   'buyer.plant@contoso.example'),
 ('PO-2026-0005', 'V-1001', '2026-09-05', 'USD',   100.00,    8.00,   108.00, 0.00, 'OPEN',   'buyer.ops@contoso.example'),
 ('PO-2026-0006', 'V-1001', '2026-09-06', 'USD',   450.00,   36.00,   486.00, 0.00, 'OPEN',   'buyer.ops@contoso.example'),
 ('PO-2026-0007', 'V-1005', '2026-09-07', 'USD',  2500.00,  250.00,  2750.00, 0.00, 'OPEN',   'buyer.plant@contoso.example'),
 ('PO-2026-0008', 'V-1001', '2026-09-08', 'USD',   300.00,   24.00,   324.00, 0.00, 'OPEN',   'buyer.ops@contoso.example'),
 ('PO-2026-0099', 'V-1002', '2026-01-15', 'USD',   500.00,   40.00,   540.00, 540.00, 'CLOSED', 'buyer.plant@contoso.example');

INSERT INTO purchase_order_lines (po_number, line_number, item_code, description, quantity, unit_price, line_amount) VALUES
 ('PO-2026-0001', 1, 'PAP-A4-500', 'A4 Copy Paper 80gsm (box of 5 reams)', 100,   5.0000,   500.00),
 ('PO-2026-0001', 2, 'TON-HP-26X', 'HP 26X Black Toner Cartridge',          10,  30.0000,   300.00),
 ('PO-2026-0002', 1, 'HYD-PMP-220','Hydraulic Pump 220V',                     4, 1000.0000, 4000.00),
 ('PO-2026-0002', 2, 'VLV-KIT-12', 'Valve Repair Kit 12mm',                  20,  50.0000,  1000.00),
 ('PO-2026-0003', 1, 'SRV-CLOUD',  'Cloud Migration Services (hours)',      300, 150.0000, 45000.00),
 ('PO-2026-0003', 2, 'SRV-SECAUD', 'Security Audit (fixed fee)',              1, 15000.0000,15000.00),
 ('PO-2026-0004', 1, 'BRG-6204',   'Deep Groove Ball Bearing 6204',         100,  12.0000,  1200.00),
 ('PO-2026-0005', 1, 'PEN-BLK-12', 'Ballpoint Pens Black (box of 12)',       50,   2.0000,   100.00),
 ('PO-2026-0006', 1, 'LMP-LED-DK', 'LED Desk Lamp',                          10,  45.0000,   450.00),
 ('PO-2026-0007', 1, 'CNC-SHAFT-8','CNC Machined Shaft 8mm',                 25, 100.0000,  2500.00),
 ('PO-2026-0008', 1, 'NTB-A5-DOT', 'A5 Dotted Notebook',                    100,   3.0000,   300.00),
 ('PO-2026-0099', 1, 'GRS-EP2',    'Industrial Grease EP2 (tub)',            10,  50.0000,   500.00);
