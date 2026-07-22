-- Enable rangefeed (required for changefeeds)
SET CLUSTER SETTING kv.rangefeed.enabled = true;

-- Create demo database and user
CREATE DATABASE IF NOT EXISTS demodb;
CREATE USER IF NOT EXISTS demo;
GRANT CONNECT ON DATABASE demodb TO demo;
GRANT SYSTEM VIEWCLUSTERSETTING TO demo;

USE demodb;

-- Orders table, same shape as the other demos so the type coverage carries over:
-- JSONB (nullable and NOT NULL), a high-precision DECIMAL, arrays, and temporal types.
CREATE TABLE IF NOT EXISTS orders (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    order_number STRING UNIQUE NOT NULL,
    customer_name STRING NOT NULL,
    email STRING,
    amount DECIMAL(12,2) NOT NULL CHECK (amount >= 0),
    currency STRING DEFAULT 'USD',
    status STRING NOT NULL DEFAULT 'pending',
    items JSONB,
    metadata JSONB NOT NULL DEFAULT '{}',
    precise_qty DECIMAL(28,18) NOT NULL DEFAULT 0.0,
    tags STRING[],
    is_express BOOLEAN DEFAULT false,
    created_at TIMESTAMPTZ DEFAULT current_timestamp()
);

CREATE TABLE IF NOT EXISTS customers (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name STRING NOT NULL,
    email STRING UNIQUE NOT NULL,
    tier STRING DEFAULT 'standard',
    created_at TIMESTAMPTZ DEFAULT current_timestamp()
);

GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE orders TO demo;
GRANT CHANGEFEED ON TABLE orders TO demo;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE customers TO demo;
GRANT CHANGEFEED ON TABLE customers TO demo;

INSERT INTO customers (name, email, tier) VALUES
    ('Alice Johnson', 'alice@example.com', 'gold'),
    ('Bob Smith', 'bob@example.com', 'standard'),
    ('Carol Davis', 'carol@example.com', 'platinum');

INSERT INTO orders (order_number, customer_name, email, amount, status, items, metadata, precise_qty, tags, is_express) VALUES
    ('ORD-1001', 'Alice Johnson', 'alice@example.com', 129.99, 'confirmed',
     '{"products": [{"name": "Wireless Headphones", "qty": 1, "price": 79.99}]}',
     '{"channel": "web"}',
     9999999999.999999999,
     ARRAY['electronics', 'priority'], true),
    ('ORD-1002', 'Bob Smith', 'bob@example.com', 249.50, 'pending',
     '{"products": [{"name": "Mechanical Keyboard", "qty": 1, "price": 149.50}]}',
     '{"channel": "mobile"}',
     0.000000000000000001,
     ARRAY['electronics', 'office'], false),
    ('ORD-1003', 'Carol Davis', 'carol@example.com', 34.99, 'shipped',
     '{"products": [{"name": "Programming Book", "qty": 1, "price": 34.99}]}',
     '{}',
     0.0,
     ARRAY['books', 'education'], false);
