-- Incremental snapshot demo: signal-based re-snapshot of existing data without restart
USE demodb;

-- Trigger an incremental snapshot of the orders table via the signaling table.
-- The connector will re-read all rows from orders and emit them as op=r (read) events.
INSERT INTO debezium_signal (id, type, data) VALUES
    ('demo-inc-snap-1', 'execute-snapshot', '{"data-collections": ["demodb.public.orders"]}');
