-- Enable rangefeed (required for changefeeds)
SET CLUSTER SETTING kv.rangefeed.enabled = true;

-- Create demo database and user
CREATE DATABASE IF NOT EXISTS demodb;
CREATE USER IF NOT EXISTS demo;
GRANT CONNECT ON DATABASE demodb TO demo;
GRANT SYSTEM VIEWCLUSTERSETTING TO demo;

USE demodb;

-- Create orders table with various CockroachDB data types
CREATE TABLE IF NOT EXISTS orders (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    order_number STRING UNIQUE NOT NULL,
    customer_name STRING NOT NULL,
    email STRING,
    amount DECIMAL(12,2) NOT NULL CHECK (amount >= 0),
    currency STRING DEFAULT 'USD',
    status STRING NOT NULL DEFAULT 'pending',
    items JSONB,
    tags STRING[],
    shipping_weight_kg DECIMAL(8,2),
    is_express BOOLEAN DEFAULT false,
    notes TEXT,
    created_at TIMESTAMPTZ DEFAULT current_timestamp(),
    updated_at TIMESTAMPTZ DEFAULT current_timestamp()
);

-- Create customers table (for multi-table changefeed demo)
CREATE TABLE IF NOT EXISTS customers (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name STRING NOT NULL,
    email STRING UNIQUE NOT NULL,
    tier STRING DEFAULT 'standard',
    created_at TIMESTAMPTZ DEFAULT current_timestamp()
);

-- Create signaling table for incremental snapshots
CREATE TABLE IF NOT EXISTS debezium_signal (
    id STRING PRIMARY KEY,
    type STRING NOT NULL,
    data STRING
);

-- Grant permissions
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE orders TO demo;
GRANT CHANGEFEED ON TABLE orders TO demo;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE customers TO demo;
GRANT CHANGEFEED ON TABLE customers TO demo;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE debezium_signal TO demo;
GRANT CHANGEFEED ON TABLE debezium_signal TO demo;

-- Insert sample customers
INSERT INTO customers (name, email, tier) VALUES
    ('Alice Johnson', 'alice@example.com', 'gold'),
    ('Bob Smith', 'bob@example.com', 'standard'),
    ('Carol Davis', 'carol@example.com', 'platinum');

-- Insert sample data
INSERT INTO orders (order_number, customer_name, email, amount, status, items, tags, shipping_weight_kg, is_express) VALUES
    ('ORD-1001', 'Alice Johnson', 'alice@example.com', 129.99, 'confirmed',
     '{"products": [{"name": "Wireless Headphones", "qty": 1, "price": 79.99}, {"name": "Phone Case", "qty": 2, "price": 25.00}]}',
     ARRAY['electronics', 'priority'], 0.45, true),
    ('ORD-1002', 'Bob Smith', 'bob@example.com', 249.50, 'pending',
     '{"products": [{"name": "Mechanical Keyboard", "qty": 1, "price": 149.50}, {"name": "Mouse Pad", "qty": 1, "price": 100.00}]}',
     ARRAY['electronics', 'office'], 1.20, false),
    ('ORD-1003', 'Carol Davis', 'carol@example.com', 34.99, 'shipped',
     '{"products": [{"name": "Programming Book", "qty": 1, "price": 34.99}]}',
     ARRAY['books', 'education'], 0.55, false);
