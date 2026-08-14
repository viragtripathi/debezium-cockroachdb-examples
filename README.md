# Debezium CockroachDB Examples

End-to-end CDC replication examples using [Debezium](https://debezium.io/) connectors with CockroachDB.
Every demo is self-contained, fully automated, and self-verifying: one script starts the
containers, deploys the connectors, drives changes, and asserts the results.

```bash
cd <demo-directory> && ./run-demo.sh
```

New here? Start with [crdb-to-crdb](crdb-to-crdb/), the flagship demo.

## CockroachDB as the CDC source: pipeline and delivery modes

How change events leave CockroachDB, and over what transport.

| Demo | Highlights |
|------|------------|
| [crdb-to-crdb](crdb-to-crdb/) | **The flagship.** Full CDC replication via Kafka into a second CockroachDB: multi-table, multi-schema, schema evolution, incremental snapshots, UNNEST batch writes on the sink. Optional `WORKLOAD=bank` phase verifies row-count and total-balance parity under concurrent traffic. |
| [crdb-to-sinkless](crdb-to-sinkless/) | The same pipeline in **sinkless** mode: the changefeed streams over the connector's SQL connection, no intermediate Kafka topics ([debezium/dbz#2024](https://github.com/debezium/dbz/issues/2024)). |
| [crdb-to-crdb-embedded](crdb-to-crdb-embedded/) | **Fully Kafka-free.** Sinkless mode inside the Debezium embedded engine; an in-process consumer applies changes to the target over JDBC. No Kafka, no Kafka Connect. |
| [crdb-to-crdb-mtls](crdb-to-crdb-mtls/) | Fully-secure pipeline: pgjdbc `verify-full` to a TLS CockroachDB cluster, and the changefeed pushed to Kafka over mutual TLS via `cockroachdb.changefeed.sink.tls.*` ([debezium/dbz#1974](https://github.com/debezium/dbz/issues/1974)). |
| [crdb-to-redpanda](crdb-to-redpanda/) | The pipeline with **Redpanda** replacing Apache Kafka: the changefeed produces into Redpanda and Kafka Connect runs against it. The only configuration delta is the bootstrap address. |

## CockroachDB as the CDC source: destinations

Where the change events land.

| Demo | Target | Highlights |
|------|--------|------------|
| [crdb-to-oracle](crdb-to-oracle/) | Oracle 19c | Via the Debezium JDBC sink (Oracle dialect auto-resolved). Optional `WORKLOAD=tpcc` scale test streams the full TPC-C dataset (9 tables, ~600k rows) and asserts per-table row-count parity. |
| [crdb-to-iceberg](crdb-to-iceberg/) | Apache Iceberg | Via the official Apache Iceberg Kafka Connect sink, with MinIO object storage and an Iceberg REST catalog. Queryable from any Iceberg-capable engine (Spark, Trino, DuckDB, ClickHouse). |
| [crdb-to-neo4j](crdb-to-neo4j/) | Neo4j | Via the official Neo4j Kafka Connect sink (Cypher strategy): rows become nodes, the foreign key becomes a `(:Customer)-[:PLACED]->(:Order)` relationship, with insert, update, and delete propagation verified. |

## CockroachDB as the target

Migrating into CockroachDB from other databases via Debezium CDC.

| Demo | Source | Highlights |
|------|--------|------------|
| [oracle-to-crdb](oracle-to-crdb/) | Oracle 19c | Oracle CDC via LogMiner into CockroachDB through the Debezium JDBC sink (CockroachDB dialect auto-resolved). The one-time ARCHIVELOG and LogMiner preparation is fully automated. |
| [pg-to-crdb](pg-to-crdb/) | PostgreSQL | Partitioned table migration using the Debezium PostgreSQL source connector with the `ByLogicalTableRouter` SMT to merge partition topics. |

## Prerequisites

- Docker and Docker Compose (or Podman)

Each demo README documents its own version knobs (`CONNECTOR_VERSION`,
`DEBEZIUM_VERSION`, `COCKROACHDB_VERSION`, and friends) and any demo-specific options.
