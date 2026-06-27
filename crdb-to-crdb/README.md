# CockroachDB to CockroachDB Replication

End-to-end example of **CockroachDB-to-CockroachDB replication** via Kafka Connect, using the
[Debezium CockroachDB source connector](https://github.com/debezium/debezium-connector-cockroachdb)
and the [Debezium JDBC sink connector](https://debezium.io/documentation/reference/stable/connectors/jdbc.html).

## Architecture

```
Source CockroachDB (demodb.orders)
       |
       v  CockroachDB enriched changefeed (native CDC)
Kafka  (intermediate topic: crdb.demodb.public.orders)
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

- Docker and Docker Compose (or Podman)

**To build from source (optional):**
- JDK 21+
- Maven 3.9.8+
- The connector source at `../../debezium-connector-cockroachdb`

## Quick Start

By default, the script downloads the released connector plugin from Maven Central -- no build required:

```bash
./run-demo.sh
```

To build from source instead:
```bash
BUILD_FROM_SOURCE=true ./run-demo.sh
```

Override component versions via environment variables:
```bash
CONNECTOR_VERSION=3.5.0.Final COCKROACHDB_VERSION=v25.4.11 DEBEZIUM_VERSION=3.5.0.Final ./run-demo.sh
```

| Variable              | Default       | Description                                                  |
|-----------------------|---------------|--------------------------------------------------------------|
| `CONNECTOR_VERSION`   | `3.5.0.Final` | Connector plugin version to download from Maven Central      |
| `COCKROACHDB_VERSION` | `v25.4.11`    | CockroachDB image tag                                        |
| `DEBEZIUM_VERSION`    | `3.5.0.Final` | Debezium Connect image tag                                   |
| `CONFLUENT_VERSION`   | `7.4.0`       | Confluent Platform (Kafka/ZK) image tag                      |
| `BUILD_FROM_SOURCE`   | `false`       | Build connector from local source instead of downloading     |
| `SKIP_BUILD`          | `false`       | Skip download/build, use existing jars in `connect-plugins/` |
| `OBSERVABILITY`       | `false`       | Also start the Prometheus + Grafana metrics overlay (`observability/`) |

The script is fully automated and runs through 22 steps:

1. **Obtain** the connector plugin (download from Maven Central, build from source, or use existing)
2. **Extract** the plugin into `connect-plugins/`
3. **Start** Docker Compose (source CRDB, target CRDB, Zookeeper, Kafka, Kafka Connect)
4. **Wait** for source CockroachDB (port 26257)
5. **Wait** for target CockroachDB (port 26258)
6. **Setup source database**: create `demodb`, `public.orders` + `public.customers` + `inventory.warehouse_items` tables (multi-schema), enable rangefeed, grant permissions
7. **Setup target database**: create `targetdb` (tables auto-created by sink connector)
8. **Wait** for Kafka Connect REST API (port 8083)
9. **Verify** both connector plugins are discovered (source + sink)
10. **Deploy** the Debezium CockroachDB source connector
11. **Insert** 3 rows into source (after changefeed creation so they are captured)
12. **Deploy** the Debezium JDBC sink connector (writes to target CRDB)
13. **Run DML** operations: 2 UPDATEs, 1 DELETE, 1 customer UPDATE, 1 customer INSERT
14. **Schema evolution demo**: `ALTER TABLE ADD COLUMN priority` -- detected without restart
15. **Incremental snapshot demo**: signal-based re-snapshot of orders table -- no restart
16. **Show source connector debug logs** (changefeed processing, schema detection)
17. **Show JDBC sink connector debug logs** (CREATE TABLE, flushing records, tombstones)
18. **Error check** (verify zero connector errors)
19. **List Kafka topics**
20. **Display Debezium change events** from the output topic (op=c, op=u, op=d)
20b. **Multi-schema regression check** ([debezium/dbz#1973](https://issues.redhat.com/browse/DBZ-1973)): verify events from `inventory.warehouse_items` appear on `crdb.inventory.warehouse_items`
21. **Verify data in target CRDB** and compare source vs target row counts
22. **Print summary** with all service URLs and interactive commands

## What the Demo Proves

| Capability            | Status                                                                     |
|-----------------------|----------------------------------------------------------------------------|
| INSERT replication    | Rows inserted in source appear in target                                   |
| UPDATE replication    | Column changes (amount, status) propagated to target                       |
| DELETE replication    | Deleted rows removed from target via tombstone events                      |
| Multi-schema capture  | Tables from non-`public` schemas (e.g. `inventory.warehouse_items`) flow through with their schema name in the topic ([debezium/dbz#1973](https://issues.redhat.com/browse/DBZ-1973)) |
| Schema evolution      | `ALTER TABLE ADD COLUMN` detected automatically without restart            |
| Incremental snapshots | Signal-based re-snapshot of existing data without stopping the connector   |
| Schema auto-creation  | Target table created automatically by JDBC sink (`schema.evolution=basic`) |
| Upsert mode           | Idempotent writes using `INSERT ... ON CONFLICT ... DO UPDATE`             |
| Heartbeat support     | Resolved timestamps advance offsets and emit heartbeat records             |
| Restart resume        | A source connector restart resumes from its persisted position without replaying the backlog |
| Debug logging         | Full event pipeline visible in connector logs                              |
| Data types            | UUID, STRING, DECIMAL, BOOLEAN, JSONB, TIMESTAMPTZ, arrays                 |

## Services

| Service                  | Port  | URL                                          |
|--------------------------|-------|----------------------------------------------|
| Source CockroachDB (SQL) | 26257 | `postgresql://root@localhost:26257/demodb`   |
| Source CockroachDB (UI)  | 8080  | http://localhost:8080                        |
| Target CockroachDB (SQL) | 26258 | `postgresql://root@localhost:26258/targetdb` |
| Target CockroachDB (UI)  | 8081  | http://localhost:8081                        |
| Kafka (external)         | 29092 | `localhost:29092`                            |
| Kafka Connect REST API   | 8083  | http://localhost:8083                        |

## Connector Configurations

### Source Connector (`connector-config.json`)

| Property                              | Value                                                   | Description                                                |
|---------------------------------------|---------------------------------------------------------|------------------------------------------------------------|
| `connector.class`                     | `CockroachDBConnector`                                  | Debezium CockroachDB source connector                      |
| `topic.prefix`                        | `crdb`                                                  | Prefix for output Kafka topics                             |
| `table.include.list`                  | `public.orders,public.customers,public.debezium_signal,inventory.warehouse_items` | Tables to capture (schema.table format) — includes a non-`public` schema to exercise [debezium/dbz#1973](https://issues.redhat.com/browse/DBZ-1973) |
| `signal.data.collection`              | `demodb.public.debezium_signal`                         | Signaling table for incremental snapshots                  |
| `cockroachdb.changefeed.max.tables.per.changefeed` | `2`                                        | Split the 4 captured tables across 2 changefeeds to avoid per-table coupling ([debezium/dbz#2014](https://issues.redhat.com/browse/DBZ-2014)). `0` would put them all in one changefeed |
| `cockroachdb.changefeed.include.diff` | `true`                                                  | Include before-image for updates                           |
| `cockroachdb.changefeed.cursor`       | `now`                                                   | Start from current time (no historical backfill)           |
| `heartbeat.interval.ms`               | `10000`                                                 | Emit heartbeat records every 10s using resolved timestamps |
| `cockroachdb.changefeed.sink.type`    | `kafka`                                                 | Changefeed sinks to Kafka                                  |
| `cockroachdb.changefeed.sink.uri`     | `kafka://kafka:9092`                                    | Internal Kafka bootstrap server                            |

### Sink Connector (`sink-connector-config.json`)

| Property                 | Value                                                 | Description                                           |
|--------------------------|-------------------------------------------------------|-------------------------------------------------------|
| `connector.class`        | `JdbcSinkConnector`                                   | Debezium JDBC sink connector                          |
| `topics`                 | `crdb.public.orders`                                  | Consumes from the source connector's output topic     |
| `connection.url`         | `jdbc:postgresql://cockroachdb-target:26257/targetdb` | Target CockroachDB JDBC URL                           |
| `insert.mode`            | `upsert`                                              | Idempotent writes (INSERT or UPDATE)                  |
| `delete.enabled`         | `true`                                                | Propagate DELETE events to target                     |
| `primary.key.mode`       | `record_key`                                          | Use the Kafka record key as the primary key           |
| `schema.evolution`       | `basic`                                               | Auto-create and alter target tables                   |
| `collection.name.format` | `orders_replica`                                      | Target table name                                     |
| `hibernate.dialect`      | `PostgreSQLDialect`                                   | Required for CockroachDB (PostgreSQL wire-compatible) |

## Topic Naming and Changefeed Grouping

**Intermediate topic names.** The connector names the CockroachDB-to-Kafka topics
`<prefix><database>.<schema>.<table>`, where `<prefix>` is
`cockroachdb.changefeed.sink.topic.prefix` used *verbatim* (or `<topic.prefix>.` when
the sink topic prefix is not set, which is the case in this demo, giving `crdb.`). The
prefix is used as-is, so include your own separator if you want one: `crdb.` yields
`crdb.demodb.public.orders`, while `env-prod-` would yield `env-prod-demodb.public.orders`.
Do not put `topic_name` or `topic_prefix` in `cockroachdb.changefeed.sink.uri`; the
connector manages topic naming and rejects those at startup.

**Changefeed grouping.** By default the connector puts all captured tables in a single
changefeed. This demo sets `cockroachdb.changefeed.max.tables.per.changefeed=2`, so its 4
tables are split across 2 changefeeds (see STEP 11b, which checks
`SHOW CHANGEFEED JOBS` returns 2 running jobs). Splitting avoids the performance coupling
CockroachDB warns about when one changefeed watches very many tables. Set it to `0` to keep
everything in one changefeed.

## Reusing an Existing Changefeed

By default the source connector creates and manages its own CockroachDB changefeed.
Before it creates one, it checks whether a running changefeed already covers the
configured tables. If a match is found, the connector skips creation and consumes
the existing changefeed instead. This makes connector restarts idempotent, avoids
duplicate changefeed jobs on the cluster, and lets you pre-provision a changefeed
that the connector then attaches to.

A changefeed is treated as a match only when its `SHOW CHANGEFEED JOBS` description
contains both:

- the fully-qualified name of each configured table, and
- `topic_prefix=<prefix>.`, where `<prefix>` is `cockroachdb.changefeed.sink.topic.prefix`
  (or `topic.prefix` when the sink topic prefix is not set, which is `crdb` in this demo).

For the connector to consume it correctly, the changefeed must publish to the same
topic names the connector subscribes to (`<prefix>.<database>.<schema>.<table>`).
To get that layout and the event structure the connector expects, create the
changefeed with options that match the connector configuration. The equivalent of
what this demo's connector creates for `public.orders` is:

```sql
CREATE CHANGEFEED FOR TABLE public.orders
  INTO 'kafka://kafka:9092?topic_prefix=crdb.'
  WITH full_table_name,
       format = 'json',
       envelope = 'enriched',
       enriched_properties = 'source',
       diff,
       updated,
       resolved = '10s';
```

This produces the topic `crdb.demodb.public.orders`, which is exactly what the
connector subscribes to, so the connector detects the running job and skips
creating its own. A changefeed created with a different `topic_prefix` or without
`full_table_name` is not recognized as a match, and the connector creates its own.
If a running changefeed does match the topic prefix and tables but uses an
envelope other than `enriched`, the connector cannot consume it and fails to
start with an error asking you to recreate it with `envelope='enriched'`. The
`enriched_properties` value does not affect reuse: the connector reads the base
enriched fields (`op`, `ts_ns`, `after`, and `before` when `diff` is set), so
`source` alone is sufficient.

For most setups, letting the connector own the changefeed is simpler. Reuse an
existing changefeed only when you have a specific reason, such as preserving an
existing cursor position or a custom partitioning scheme.

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
curl -s http://localhost:8083/connectors/debezium-cockroachdb-source/status | python3 -m json.tool

# Sink connector
curl -s http://localhost:8083/connectors/debezium-jdbc-sink/status | python3 -m json.tool
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

| File                            | Description                                                                |
|---------------------------------|----------------------------------------------------------------------------|
| `run-demo.sh`                   | Fully automated demo script (build, deploy, verify)                        |
| `docker-compose.yml`            | 5-service stack: Zookeeper, Kafka, source CRDB, target CRDB, Kafka Connect |
| `connector-config.json`         | Debezium CockroachDB source connector configuration                        |
| `sink-connector-config.json`    | Debezium JDBC sink connector configuration                                 |
| `setup-cockroachdb.sql`         | Source DB setup: database, `public.orders` + `public.customers` + `inventory.warehouse_items` (multi-schema), permissions, sample data |
| `setup-target-cockroachdb.sql`  | Target DB setup: database creation                                         |
| `demo-operations.sql`           | DML operations (UPDATE, DELETE) run during the demo                        |
| `demo-schema-evolution.sql`     | Schema evolution demo: ALTER TABLE ADD COLUMN without restart              |
| `demo-incremental-snapshot.sql` | Incremental snapshot demo: signal-based re-snapshot via signaling table    |
| `observability/`                | Prometheus + Grafana metrics overlay (see `observability/README.md`)       |

## Observability (Prometheus + Grafana)

The `observability/` overlay exposes the connector's JMX metrics through the Prometheus JMX exporter
java agent, scrapes them with Prometheus, and visualizes them in Grafana. Start it together with the
demo:

```bash
OBSERVABILITY=true ./run-demo.sh
```

- Grafana: http://localhost:3000 (admin / admin) -> dashboard "Debezium CockroachDB"
- Prometheus: http://localhost:9090
- Connector metrics: http://localhost:9404/metrics (`debezium_metrics_*`)

The dashboard shows a Connectors table (name, version, type, status), a live data-flow view
(records/sec at each hop: CRDB -> connector -> Kafka -> JDBC sink -> CRDB target), snapshot state,
lag, throughput, and create/update/delete counts. To drive sustained traffic, run
`./observability/continuous-writer.sh`. See `observability/README.md` for details.

## Known Limitations

- **CockroachDB insecure mode**: The demo uses `--insecure` for simplicity. For production, use SSL certificates.
- **Hibernate dialect**: The JDBC sink requires `hibernate.dialect=org.hibernate.dialect.PostgreSQLDialect`. While CockroachDB has a first-class [`CockroachDialect`](https://docs.hibernate.org/orm/6.3/javadocs/org/hibernate/dialect/CockroachDialect.html) in Hibernate 6.x ([CockroachDB + Hibernate docs](https://www.cockroachlabs.com/docs/stable/build-a-java-app-with-cockroachdb-hibernate)), the Debezium JDBC sink's `DatabaseDialectResolver` does not yet have a CockroachDB-specific `DatabaseDialectProvider`. Since `CockroachDialect` extends `Dialect` directly (not `PostgreSQLDialect`), the resolver falls back to `GeneralDatabaseDialect` which lacks upsert support. Using `PostgreSQLDialect` correctly maps to the Debezium `PostgresDatabaseDialect`, which generates the `INSERT ... ON CONFLICT ... DO UPDATE` syntax that CockroachDB supports. Adding a `CockroachDBDatabaseDialectProvider` to the Debezium JDBC sink is a natural follow-up enhancement.

## Cleanup

```bash
docker compose down -v
rm -rf connect-plugins
```
