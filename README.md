# Debezium CockroachDB Examples

End-to-end CDC replication examples using [Debezium](https://debezium.io/) connectors with CockroachDB.

## Demos

| Demo                                    | Source            | Target       | Description                                                                                                                                                                                                                         |
|-----------------------------------------|-------------------|--------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| [crdb-to-crdb](crdb-to-crdb/)           | CockroachDB       | CockroachDB  | Full CDC replication using the Debezium CockroachDB source connector with enriched changefeeds. Includes multi-table, multi-schema, schema evolution, and incremental snapshot demos.                                               |
| [crdb-to-sinkless](crdb-to-sinkless/)   | CockroachDB       | CockroachDB  | Same pipeline as `crdb-to-crdb` but using the **sinkless** changefeed mode (`cockroachdb.changefeed.sink.type=sinkless`): the changefeed streams over the connector's SQL connection with no intermediate Kafka ([debezium/dbz#2024](https://issues.redhat.com/browse/DBZ-2024)). |
| [crdb-to-crdb-embedded](crdb-to-crdb-embedded/) | CockroachDB | CockroachDB | **Fully Kafka-free.** The connector runs in sinkless mode inside the Debezium **embedded engine** (no Kafka, no Kafka Connect); an in-process consumer applies changes to the target over JDBC ([debezium/dbz#2024](https://issues.redhat.com/browse/DBZ-2024)). |
| [crdb-to-crdb-mtls](crdb-to-crdb-mtls/) | CockroachDB (TLS) | Kafka (mTLS) | Fully-secure pipeline: pgjdbc `verify-full` to a secure CockroachDB cluster + `cockroachdb.changefeed.sink.tls.*` ([debezium/dbz#1974](https://issues.redhat.com/browse/DBZ-1974)) to push the changefeed over mutual TLS to Kafka. |
| [crdb-to-iceberg](crdb-to-iceberg/)     | CockroachDB       | Apache Iceberg | CDC into Apache Iceberg tables using the official Apache Iceberg Kafka Connect sink, with MinIO object storage and an Iceberg REST catalog. Any Iceberg-capable engine (Spark, Trino, DuckDB, ClickHouse) can query the result. |
| [pg-to-crdb](pg-to-crdb/)               | PostgreSQL        | CockroachDB  | PostgreSQL partitioned table migration using the Debezium PostgreSQL source connector with `ByLogicalTableRouter` SMT to merge partition topics.                                                                                    |

## Quick Start

Each demo is self-contained. Navigate to the demo folder and run:

```bash
cd crdb-to-crdb && ./run-demo.sh
```

or

```bash
cd crdb-to-sinkless && ./run-demo.sh
```

or

```bash
cd crdb-to-crdb-embedded && ./run-demo.sh
```

or

```bash
cd crdb-to-crdb-mtls && ./run-demo.sh
```

or

```bash
cd crdb-to-iceberg && ./run-demo.sh
```

or

```bash
cd pg-to-crdb && ./run-demo.sh
```

## Prerequisites

- Docker and Docker Compose (or Podman)

See individual demo READMEs for additional details.
