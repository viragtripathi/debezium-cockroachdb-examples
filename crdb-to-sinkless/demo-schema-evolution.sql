-- Schema evolution demo: ALTER TABLE ADD COLUMN without connector restart
USE demodb;

-- Add a new column to the orders table
ALTER TABLE orders ADD COLUMN priority STRING DEFAULT 'normal';

-- Insert a row with the new column
INSERT INTO orders (order_number, customer_name, email, amount, status, priority)
VALUES ('ORD-SCHEMA-001', 'Eve Schema', 'eve@example.com', 55.00, 'new', 'high');

-- Update an existing row to set the new column
UPDATE orders SET priority = 'urgent' WHERE order_number = 'ORD-LIVE-001';
