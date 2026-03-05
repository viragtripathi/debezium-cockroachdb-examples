# Debezium CockroachDB Connector Demo

End-to-end demo of **CockroachDB-to-CockroachDB replication** via Kafka Connect, using the
[Debezium CockroachDB source connector](https://github.com/debezium/debezium-connector-cockroachdb)
and the [Debezium JDBC sink connector](https://debezium.io/documentation/reference/stable/connectors/jdbc.html).

## Architecture

```
Source CockroachDB (demodb.orders)
       |
       v  CockroachDB enriched changefeed (native CDC)
Kafka  (intermediate topic: cockroachdb.demodb.public.orders)
       |
       v  Debezium CockroachDB Source Connector
Kafka  (output topic: crdb.public.orders)
       |
       v  Debezium JDBC Sink Connector
Target CockroachDB (targetdb.orders_replica)
```

All DML operations (INSERT, UPDATE, DELETE) on the source are captured and replicated
to the target with full before/after images and Debezium envelope metadata.

## Prerequisites

- Docker and Docker Compose
- JDK 21+
- Maven 3.9.8+
- The connector source at `../debezium-connector-cockroachdb`

## Quick Start

```bash
./run-demo.sh
```

The script is fully automated and runs through 20 steps:

1. **Build** the connector plugin from source (`mvn package`)
2. **Extract** the plugin into `connect-plugins/`
3. **Start** Docker Compose (source CRDB, target CRDB, Zookeeper, Kafka, Kafka Connect)
4. **Wait** for source CockroachDB (port 26257)
5. **Wait** for target CockroachDB (port 26258)
6. **Setup source database**: create `demodb`, `orders` table, enable rangefeed, grant permissions
7. **Setup target database**: create `targetdb` (table auto-created by sink connector)
8. **Wait** for Kafka Connect REST API (port 8083)
9. **Verify** both connector plugins are discovered (source + sink)
10. **Deploy** the Debezium CockroachDB source connector
11. **Insert** 3 rows into source (after changefeed creation so they are captured)
12. **Deploy** the Debezium JDBC sink connector (writes to target CRDB)
13. **Run DML** operations: 2 UPDATEs, 1 DELETE
14. **Show source connector debug logs** (changefeed processing, event dispatching)
15. **Show JDBC sink connector debug logs** (CREATE TABLE, flushing records, tombstones)
16. **Error check** (verify zero connector errors)
17. **List Kafka topics**
18. **Display Debezium change events** from the output topic (op=c, op=u, op=d)
19. **Verify data in target CRDB** and compare source vs target row counts
20. **Print summary** with all service URLs and interactive commands

## What the Demo Proves

| Capability | Status |
|---|---|
| INSERT replication | Rows inserted in source appear in target |
| UPDATE replication | Column changes (amount, status) propagated to target |
| DELETE replication | Deleted rows removed from target via tombstone events |
| Schema auto-creation | Target table created automatically by JDBC sink (`schema.evolution=basic`) |
| Upsert mode | Idempotent writes using `INSERT ... ON CONFLICT ... DO UPDATE` |
| Heartbeat support | Resolved timestamps advance offsets and emit heartbeat records |
| Debug logging | Full event pipeline visible in connector logs |
| Data types | UUID, STRING, DECIMAL, BOOLEAN, JSONB, TIMESTAMPTZ, arrays |

## Services

| Service | Port | URL |
|---|---|---|
| Source CockroachDB (SQL) | 26257 | `postgresql://root@localhost:26257/demodb` |
| Source CockroachDB (UI) | 8080 | http://localhost:8080 |
| Target CockroachDB (SQL) | 26258 | `postgresql://root@localhost:26258/targetdb` |
| Target CockroachDB (UI) | 8081 | http://localhost:8081 |
| Kafka (external) | 29092 | `localhost:29092` |
| Kafka Connect REST API | 8083 | http://localhost:8083 |

## Connector Configurations

### Source Connector (`connector-config.json`)

| Property | Value | Description |
|---|---|---|
| `connector.class` | `CockroachDBConnector` | Debezium CockroachDB source connector |
| `topic.prefix` | `crdb` | Prefix for output Kafka topics |
| `table.include.list` | `public.orders` | Tables to capture (schema.table format) |
| `cockroachdb.changefeed.envelope` | `enriched` | Uses CockroachDB enriched changefeed format |
| `cockroachdb.changefeed.include.diff` | `true` | Include before-image for updates |
| `cockroachdb.changefeed.cursor` | `now` | Start from current time (no historical backfill) |
| `heartbeat.interval.ms` | `10000` | Emit heartbeat records every 10s using resolved timestamps |
| `cockroachdb.changefeed.sink.type` | `kafka` | Changefeed sinks to Kafka |
| `cockroachdb.changefeed.sink.uri` | `kafka://kafka:9092` | Internal Kafka bootstrap server |

### Sink Connector (`sink-connector-config.json`)

| Property | Value | Description |
|---|---|---|
| `connector.class` | `JdbcSinkConnector` | Debezium JDBC sink connector |
| `topics` | `crdb.public.orders` | Consumes from the source connector's output topic |
| `connection.url` | `jdbc:postgresql://cockroachdb-target:26257/targetdb` | Target CockroachDB JDBC URL |
| `insert.mode` | `upsert` | Idempotent writes (INSERT or UPDATE) |
| `delete.enabled` | `true` | Propagate DELETE events to target |
| `primary.key.mode` | `record_key` | Use the Kafka record key as the primary key |
| `schema.evolution` | `basic` | Auto-create and alter target tables |
| `collection.name.format` | `orders_replica` | Target table name |
| `hibernate.dialect` | `PostgreSQLDialect` | Required for CockroachDB (PostgreSQL wire-compatible) |

## Manual Interaction

### Interactive SQL on Source

```bash
docker exec -it demo-cockroachdb cockroach sql --insecure -d demodb
```

Try inserting, updating, or deleting rows -- changes replicate to the target in seconds:

```sql
INSERT INTO orders (order_number, customer_name, email, amount, status)
VALUES ('ORD-MANUAL-001', 'Manual Test', 'test@example.com', 42.00, 'new');
```

### Interactive SQL on Target

```bash
docker exec -it demo-cockroachdb-target cockroach sql --insecure -d targetdb
```

Verify replicated data:

```sql
SELECT order_number, customer_name, amount, status FROM orders_replica ORDER BY order_number;
```

### Watch Events in Real-Time

```bash
docker exec demo-kafka kafka-console-consumer \
  --bootstrap-server localhost:9092 \
  --topic crdb.public.orders
```

### View Debug Logs

Source connector (changefeed processing):
```bash
docker compose logs -f connect 2>&1 | grep -E 'DEBUG|INFO' | grep -i cockroachdb
```

JDBC sink connector (writes to target):
```bash
docker compose logs -f connect 2>&1 | grep -E 'DEBUG|INFO' | grep -i jdbc
```

### Check Connector Status

```bash
# Source connector
curl -s http://localhost:8083/connectors/cockroachdb-demo-connector/status | python3 -m json.tool

# Sink connector
curl -s http://localhost:8083/connectors/cockroachdb-jdbc-sink/status | python3 -m json.tool
```

## Source Database Schema

The `demodb.orders` table uses a variety of CockroachDB data types:

```sql
CREATE TABLE orders (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    order_number    STRING UNIQUE NOT NULL,
    customer_name   STRING NOT NULL,
    email           STRING,
    amount          DECIMAL(12,2) NOT NULL CHECK (amount >= 0),
    currency        STRING DEFAULT 'USD',
    status          STRING NOT NULL DEFAULT 'pending',
    items           JSONB,
    tags            STRING[],
    shipping_weight_kg DECIMAL(8,2),
    is_express      BOOLEAN DEFAULT false,
    notes           TEXT,
    created_at      TIMESTAMPTZ DEFAULT current_timestamp(),
    updated_at      TIMESTAMPTZ DEFAULT current_timestamp()
);
```

## Files

| File | Description |
|---|---|
| `run-demo.sh` | Fully automated demo script (build, deploy, verify) |
| `docker-compose.yml` | 5-service stack: Zookeeper, Kafka, source CRDB, target CRDB, Kafka Connect |
| `connector-config.json` | Debezium CockroachDB source connector configuration |
| `sink-connector-config.json` | Debezium JDBC sink connector configuration |
| `setup-cockroachdb.sql` | Source DB setup: database, table, permissions, sample data |
| `setup-target-cockroachdb.sql` | Target DB setup: database creation |
| `demo-operations.sql` | DML operations (UPDATE, DELETE) run during the demo |

## Known Limitations

- **Schema evolution**: Adding/dropping columns after changefeed creation is not yet handled. Restart the connector after schema changes.
- **CockroachDB insecure mode**: The demo uses `--insecure` for simplicity. For production, use SSL certificates.
- **Hibernate dialect**: The JDBC sink requires `hibernate.dialect=org.hibernate.dialect.PostgreSQLDialect`. While CockroachDB has a first-class [`CockroachDialect`](https://docs.hibernate.org/orm/6.3/javadocs/org/hibernate/dialect/CockroachDialect.html) in Hibernate 6.x ([CockroachDB + Hibernate docs](https://www.cockroachlabs.com/docs/stable/build-a-java-app-with-cockroachdb-hibernate)), the Debezium JDBC sink's `DatabaseDialectResolver` does not yet have a CockroachDB-specific `DatabaseDialectProvider`. Since `CockroachDialect` extends `Dialect` directly (not `PostgreSQLDialect`), the resolver falls back to `GeneralDatabaseDialect` which lacks upsert support. Using `PostgreSQLDialect` correctly maps to the Debezium `PostgresDatabaseDialect`, which generates the `INSERT ... ON CONFLICT ... DO UPDATE` syntax that CockroachDB supports. Adding a `CockroachDBDatabaseDialectProvider` to the Debezium JDBC sink is a natural follow-up enhancement.

## Cleanup

```bash
docker compose down -v
rm -rf connect-plugins
```
