-- Demo DML operations: UPDATE and DELETE to show full CDC round-trip
USE demodb;

-- UPDATE: Change order status and amount
UPDATE orders SET status = 'shipped', amount = 249.99, updated_at = current_timestamp()
    WHERE order_number = 'ORD-LIVE-001';

UPDATE orders SET status = 'confirmed', amount = 99.00, updated_at = current_timestamp()
    WHERE order_number = 'ORD-LIVE-002';

-- DELETE: Cancel an order
DELETE FROM orders WHERE order_number = 'ORD-LIVE-003';

-- Customer operations (multi-table demo)
UPDATE customers SET tier = 'platinum' WHERE email = 'alice@example.com';
INSERT INTO customers (name, email, tier) VALUES ('Dan Evans', 'dan@example.com', 'gold');
