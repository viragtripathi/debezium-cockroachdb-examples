-- Enable rangefeed (required for changefeeds)
SET CLUSTER SETTING kv.rangefeed.enabled = true;

-- Create demo database and user
CREATE DATABASE IF NOT EXISTS demodb;
CREATE USER IF NOT EXISTS demo;
GRANT CONNECT ON DATABASE demodb TO demo;
GRANT SYSTEM VIEWCLUSTERSETTING TO demo;

USE demodb;

-- INT primary keys on purpose: they become the node keys in Neo4j, and the
-- (:Customer)-[:PLACED]->(:Order) relationship is built from orders.customer_id.
CREATE TABLE IF NOT EXISTS customers (
    id INT8 PRIMARY KEY,
    name STRING NOT NULL,
    email STRING,
    tier STRING NOT NULL DEFAULT 'standard'
);

CREATE TABLE IF NOT EXISTS orders (
    id INT8 PRIMARY KEY,
    customer_id INT8 NOT NULL REFERENCES customers (id),
    amount DECIMAL(12,2) NOT NULL CHECK (amount >= 0),
    status STRING NOT NULL DEFAULT 'pending'
);

GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE customers TO demo;
GRANT CHANGEFEED ON TABLE customers TO demo;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE orders TO demo;
GRANT CHANGEFEED ON TABLE orders TO demo;
