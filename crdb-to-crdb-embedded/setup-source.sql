SET CLUSTER SETTING kv.rangefeed.enabled = true;
CREATE DATABASE IF NOT EXISTS demodb;
USE demodb;
CREATE TABLE IF NOT EXISTS orders (
    id INT PRIMARY KEY,
    name STRING NOT NULL,
    amount DECIMAL(10,2)
);
INSERT INTO orders (id, name, amount) VALUES
    (1, 'Alice', 100.00),
    (2, 'Bob', 200.50),
    (3, 'Carol', 320.00);
