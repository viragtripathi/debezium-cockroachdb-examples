-- Schema evolution demo: ALTER TABLE ADD COLUMN without connector restart
USE demodb;

-- Add a new column to the orders table
ALTER TABLE orders ADD COLUMN priority STRING DEFAULT 'normal';

-- Add a NOT NULL JSONB column mid-stream (debezium/dbz#2253): events written before this DDL
-- must still convert, so the JSONB field is mapped as optional like every other type.
ALTER TABLE orders ADD COLUMN audit JSONB NOT NULL DEFAULT '{"source": "demo"}';

-- Insert a row with the new columns
INSERT INTO orders (order_number, customer_name, email, amount, status, priority, audit)
VALUES ('ORD-SCHEMA-001', 'Eve Schema', 'eve@example.com', 55.00, 'new', 'high', '{"source": "schema-evolution"}');

-- Update an existing row to set the new column
UPDATE orders SET priority = 'urgent' WHERE order_number = 'ORD-LIVE-001';
