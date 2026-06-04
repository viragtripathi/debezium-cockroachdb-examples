# CockroachDB to CockroachDB Replication (Sinkless Changefeed)

End-to-end example of **CockroachDB-to-CockroachDB replication** using the connector's
**sinkless** changefeed delivery mode (`cockroachdb.changefeed.sink.type=sinkless`), the
[Debezium CockroachDB source connector](https://github.com/debezium/debezium-connector-cockroachdb)
and the [Debezium JDBC sink connector](https://debezium.io/documentation/reference/stable/connectors/jdbc.html).

This is the counterpart to the `crdb-to-crdb` demo. The pipeline and end result are identical;
the difference is **how the source connector ingests change events**.

## What "sinkless" means

CockroachDB can run a changefeed two ways:

- **Kafka sink** (`sink.type=kafka`, the default): `CREATE CHANGEFEED ... INTO 'kafka://...'`.
  CockroachDB pushes change events to an intermediate Kafka cluster, and the connector runs its own
  `KafkaConsumer` to read them back. That second Kafka client is a separate moving part to secure
  (TLS/SASL) and operate.
- **Sinkless / core** (`sink.type=sinkless`): `CREATE CHANGEFEED FOR TABLE ...` **without** an
  `INTO` clause. CockroachDB streams the change events back **over the connector's own SQL
  connection**. There is no intermediate Kafka, no changefeed job, and no consumer to secure.

A sinkless (core) changefeed is tied to the SQL session, so it does **not** appear in
`SHOW CHANGEFEED JOBS`. The connector consumes it by streaming the `CREATE CHANGEFEED` result set.

The Debezium envelope the connector emits downstream is **identical** in both modes, so this demo
produces the same output topics and the same replicated rows in the target as `crdb-to-crdb`.

## Architecture

```
Source CockroachDB (demodb: orders + customers + inventory.warehouse_items)
       |
       v  Core changefeed streamed over the SQL connection (NO Kafka sink, NO changefeed job)
Debezium CockroachDB Source Connector
       |
       v  Connect produces Debezium output topics
Kafka  (output topics: crdb.public.orders, crdb.public.customers, crdb.inventory.warehouse_items)
       |
       v  Debezium JDBC Sink Connector
Target CockroachDB (targetdb)
```

Kafka is still used for the connector's **output** topics (and Connect's own bookkeeping). The
point of sinkless mode is that **CockroachDB never connects to Kafka** -- there are no intermediate
changefeed topics and no Kafka sink to configure or secure.

## When to use sinkless

Use **sinkless** when:

- You want to avoid operating/securing a separate Kafka client between CockroachDB and the connector
  (the TLS/SASL surface collapses onto the single JDBC connection the connector already uses).
- You do not have, or do not want, intermediate Kafka changefeed topics.

Stay on the default **kafka** mode when:

- You need the intermediate Kafka topics to durably buffer change events independently of the
  connector (see the durability tradeoff below).

### Durability tradeoff (important)

With the Kafka sink, change events are buffered in Kafka, so the connector can be down for a long
time and still resume from the intermediate topics.

With sinkless, there is no intermediate buffer. If the connector stops, the changefeed stops, and
resume is bounded by CockroachDB's **garbage-collection (GC) TTL** on the watched tables
([`gc.ttlseconds`](https://www.cockroachlabs.com/docs/stable/configure-replication-zones#gc-ttlseconds),
whose default varies by version and deployment): the connector resumes from the persisted resolved
timestamp (`cursor`), but CockroachDB can only serve changes newer than the GC window. If the
connector is down longer than the GC TTL, the cursor is no longer valid and a new snapshot is
required. Size `gc.ttlseconds` for your worst-case connector downtime if you rely on sinkless resume.

In this demo Phase, recovery on connection drop relies on Kafka Connect restarting the task, which
resumes from the persisted cursor.

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

To build from source instead (required until a release including sinkless mode is published):
```bash
BUILD_FROM_SOURCE=true ./run-demo.sh
```

Override component versions via environment variables:
```bash
CONNECTOR_VERSION=3.5.0.Final COCKROACHDB_VERSION=v25.4.10 DEBEZIUM_VERSION=3.5.0.Final ./run-demo.sh
```

| Variable              | Default       | Description                                                  |
|-----------------------|---------------|--------------------------------------------------------------|
| `CONNECTOR_VERSION`   | `3.5.0.Final` | Connector plugin version to download from Maven Central      |
| `COCKROACHDB_VERSION` | `v25.4.10`    | CockroachDB image tag                                        |
| `DEBEZIUM_VERSION`    | `3.5.0.Final` | Debezium Connect image tag                                   |
| `CONFLUENT_VERSION`   | `7.4.0`       | Confluent Platform (Kafka/ZK) image tag                      |
| `BUILD_FROM_SOURCE`   | `false`       | Build connector from local source instead of downloading     |
| `SKIP_BUILD`          | `false`       | Skip download/build, use existing jars in `connect-plugins/` |

## How the demo proves it is sinkless

Step 11b makes the sinkless behavior explicit:

1. **`SHOW CHANGEFEED JOBS` returns zero running jobs** -- a core/sinkless changefeed is tied to the
   SQL session and is not a changefeed job. (In the `crdb-to-crdb` kafka-mode demo, this is non-zero.)
2. **The `CREATE CHANGEFEED FOR TABLE ...` query is actively running** in
   `crdb_internal.cluster_queries` -- the changefeed is streaming over the SQL connection and never
   returns.
3. **No intermediate changefeed topics exist on Kafka** -- the only `crdb.*` topics are the Debezium
   output topics; CockroachDB created none, because it never connected to Kafka.

The rest of the demo (initial snapshot, live DML, schema evolution, incremental snapshot, multi-schema
table, and the round-trip into the target CockroachDB) runs exactly as in `crdb-to-crdb`, showing the
downstream behavior is unchanged.

## Connector configuration

The only differences from the kafka-mode `connector-config.json` are:

```jsonc
// sinkless mode: stream the changefeed over the SQL connection
"cockroachdb.changefeed.sink.type": "sinkless",
// no "cockroachdb.changefeed.sink.uri"  -- not used in sinkless mode
// no "cockroachdb.changefeed.max.tables.per.changefeed" -- a core changefeed streams all tables
//    over a single SQL connection
```

Everything else (`table.include.list`, `snapshot.mode`, `enriched.properties`, `include.updated`,
`include.diff`, `resolved.interval`, the JDBC sink) is identical to the `crdb-to-crdb` demo.

## Endpoints

| Component        | Address                                                        |
|------------------|---------------------------------------------------------------|
| Source CRDB      | `localhost:26257` (UI: http://localhost:8080)                 |
| Target CRDB      | `localhost:26258` (UI: http://localhost:8081)                 |
| Kafka            | `localhost:29092`                                             |
| Kafka Connect    | `http://localhost:8083`                                       |
| Source connector | `http://localhost:8083/connectors/cockroachdb-sinkless-connector/status` |
| Sink connector   | `http://localhost:8083/connectors/cockroachdb-jdbc-sink/status` |

## Stop the demo

```bash
docker compose down -v
```

## See also

- `../crdb-to-crdb` -- the same pipeline using the default Kafka-sink changefeed mode.
- `../crdb-to-crdb-mtls` -- Kafka-sink mode with mutual TLS on the intermediate Kafka.
