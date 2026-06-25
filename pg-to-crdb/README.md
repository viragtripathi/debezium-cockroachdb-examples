# PostgreSQL to CockroachDB: Partitioned Table Migration

End-to-end demo of **PostgreSQL partitioned table replication to CockroachDB** via Kafka Connect, using the
[Debezium PostgreSQL source connector](https://debezium.io/documentation/reference/stable/connectors/postgresql.html)
with the [ByLogicalTableRouter](https://debezium.io/documentation/reference/stable/transformations/topic-routing.html) SMT
and the [Debezium JDBC sink connector](https://debezium.io/documentation/reference/stable/connectors/jdbc.html).

## The Problem

PostgreSQL tables partitioned by range (e.g., by date) create many child tables.
Debezium captures each child partition as a separate topic. For a table with hundreds of partitions,
this means hundreds of Kafka topics that all represent the same logical table.

On the target side, CockroachDB doesn't need (or benefit from) the same partitioning scheme.
You want all partition data merged into a single target table.

## The Solution

The `ByLogicalTableRouter` SMT uses a regex to match all partition topics and routes them
to a single merged topic:

```
pgdemo.public.orders_2023_01 ─┐
pgdemo.public.orders_2023_02 ─┤
...                            ├──> pgdemo.public.orders (single merged topic)
pgdemo.public.orders_2026_11 ─┤
pgdemo.public.orders_2026_12 ─┘
```

The JDBC Sink connector then writes the merged topic to a single CockroachDB table
with `schema.evolution=basic` (auto-creates the table) and `insert.mode=upsert`.

## Architecture

```
PostgreSQL (sourcedb)
  orders (partitioned by range on created_at)
    ├── orders_2023_01
    ├── orders_2023_02
    ├── ...  (48 monthly partitions, Jan 2023 - Dec 2026)
    ├── orders_2026_11
    └── orders_2026_12
       |
       v  Debezium PG Source + ByLogicalTableRouter SMT
Kafka  (pgdemo.public.orders)  -- single merged topic
       |
       v  Debezium JDBC Sink Connector (upsert mode)
CockroachDB (targetdb.pgdemo_public_orders)  -- single table, no partitions
```

## Prerequisites

- Docker and Docker Compose (or Podman)

No custom connector plugins needed -- the Debezium Connect image ships with both
the PostgreSQL source connector and the JDBC sink connector.

## Quick Start

```bash
./run-demo.sh
```

Override component versions:
```bash
POSTGRES_VERSION=16 COCKROACHDB_VERSION=v25.4.11 DEBEZIUM_VERSION=3.5.0.Final ./run-demo.sh
```

| Variable              | Default       | Description                             |
|-----------------------|---------------|-----------------------------------------|
| `POSTGRES_VERSION`    | `16`          | PostgreSQL image tag                    |
| `COCKROACHDB_VERSION` | `v25.4.11`    | CockroachDB target image tag            |
| `DEBEZIUM_VERSION`    | `3.5.0.Final` | Debezium Connect image tag              |
| `CONFLUENT_VERSION`   | `7.4.0`       | Confluent Platform (Kafka/ZK) image tag |

## What the Demo Shows

1. **Start** PostgreSQL, CockroachDB, Kafka, and Kafka Connect
2. **Create** a partitioned `orders` table with 48 monthly partitions (Jan 2023 - Dec 2026) + ~192 rows
3. **Verify** the PostgreSQL partition layout and row distribution across all 48 partitions
4. **Deploy** the Debezium PG source connector with `ByLogicalTableRouter` SMT
5. **Verify** that all partition data appears on a single merged Kafka topic
6. **Deploy** the JDBC sink connector writing to CockroachDB
7. **Verify** initial snapshot: all rows from all partitions land in one CockroachDB table
8. **Run DML** across different partitions (UPDATE, INSERT, DELETE)
9. **Verify** that DML changes replicate correctly with matching row counts

## Key Configuration: ByLogicalTableRouter SMT

```json
"transforms": "route_partitions",
"transforms.route_partitions.type": "io.debezium.transforms.ByLogicalTableRouter",
"transforms.route_partitions.topic.regex": "pgdemo\\.public\\.orders_.*",
"transforms.route_partitions.topic.replacement": "pgdemo.public.orders",
"transforms.route_partitions.key.enforce.uniqueness": "false"
```

This routes all topics matching `pgdemo.public.orders_*` (the child partitions)
to a single `pgdemo.public.orders` topic. The sink connector then writes this
merged stream to one CockroachDB table.

## Files

| File                           | Description                                           |
|--------------------------------|-------------------------------------------------------|
| `docker-compose.yml`           | PostgreSQL + CockroachDB + Kafka + Connect            |
| `setup-postgres.sql`           | Source DB: partitioned orders table with 48 monthly partitions |
| `setup-target-cockroachdb.sql` | Target DB: just creates the database                  |
| `source-connector-config.json` | Debezium PG source with ByLogicalTableRouter SMT      |
| `sink-connector-config.json`   | Debezium JDBC sink writing to CockroachDB             |
| `demo-operations.sql`          | DML across partitions (UPDATE, INSERT, DELETE)        |
| `run-demo.sh`                  | Automated end-to-end demo script                      |

## Cleanup

```bash
docker compose down -v
```
