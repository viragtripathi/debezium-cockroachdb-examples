# CockroachDB to CockroachDB Replication (Embedded, fully Kafka-free)

End-to-end **CockroachDB-to-CockroachDB replication with no Kafka and no Kafka Connect at all.**
The Debezium CockroachDB connector runs in [sinkless](../crdb-to-sinkless/) mode inside the
[Debezium embedded engine](https://debezium.io/documentation/reference/stable/development/engine.html),
in a single Java process, and an in-process consumer applies each change to the target over JDBC.

This is the counterpart to [`crdb-to-crdb`](../crdb-to-crdb/) and [`crdb-to-sinkless`](../crdb-to-sinkless/),
both of which still run on Kafka Connect and therefore still use Kafka for their output topics. This
demo removes Kafka entirely.

## Architecture

```
Source CockroachDB (demodb.orders)
       |
       v  Core changefeed streamed over the SQL connection (sinkless)  -- NO Kafka
Debezium embedded engine  (DebeziumEngine, in this JVM)                -- NO Kafka Connect
       |
       v  in-process consumer: JDBC UPSERT / DELETE
Target CockroachDB (targetdb.orders)
```

There is no Kafka broker, no Zookeeper, and no Kafka Connect worker. `docker-compose.yml` starts only
the two CockroachDB clusters. The connector cursor is checkpointed **into CockroachDB itself** (a
`debezium_offsets` table on the target) by a small self-contained offset store
([`CockroachDBOffsetBackingStore`](src/main/java/io/debezium/examples/embedded/CockroachDBOffsetBackingStore.java)),
so restarts resume from the last committed position with no Kafka and no local state file.

## How it works

- The connector is configured exactly as in the `crdb-to-sinkless` demo
  (`cockroachdb.changefeed.sink.type=sinkless`), so CockroachDB streams the changefeed back over the
  SQL connection instead of pushing to a Kafka sink.
- Instead of Kafka Connect, the connector is hosted by `DebeziumEngine`. Each change event is handed
  to [`EmbeddedSinklessReplicator`](src/main/java/io/debezium/examples/embedded/EmbeddedSinklessReplicator.java),
  which reads the Debezium envelope (`op`, `after`, `before`) and issues an `UPSERT` (for
  create/update/read) or `DELETE` (for delete) against the target CockroachDB.
- Offsets (the changefeed cursor) are stored in CockroachDB via a small self-contained
  `CockroachDBOffsetBackingStore` (it extends Kafka's in-memory store and persists to a CRDB table), so the
  whole pipeline needs no Kafka, no local state file, and no extra Debezium storage artifact.
- The apply is **idempotent** (`UPSERT`/`DELETE` keyed by primary key). Because the offset commit and
  the JDBC apply are not one transaction, delivery is at-least-once; idempotent apply makes a
  redelivery after a restart harmless.
- The demo replicates a single table (`orders(id, name, amount)`) to keep the apply logic small and
  readable; the same pattern extends to more tables.

## Prerequisites

- Docker and Docker Compose (or Podman)
- Java 17+ to run, and Maven 3.9+ (`mvn` on your `PATH`). The connector and this app are compiled to
  Java 17; building the connector from source (the current path until sinkless is released) requires
  JDK 21, which is the Debezium build requirement.
- The connector source at `../../debezium-connector-cockroachdb` is needed **only** until the
  sinkless feature is in a published connector release (see below)

## Run

```bash
./run-demo.sh
```

This is an ordinary Maven app: it **resolves the connector from Maven by default** (no clone needed).
Because the sinkless feature is not in a published release yet, the requested version
(`3.6.0-SNAPSHOT`) is not on Maven, so the script automatically falls back to building it from the
local connector clone. Once a release includes sinkless, point the demo at it and it runs purely from
Maven:

```bash
CONNECTOR_VERSION=<released-version> ./run-demo.sh   # resolves from Maven, no clone
```

| Variable              | Default          | Description                                                            |
|-----------------------|------------------|------------------------------------------------------------------------|
| `CONNECTOR_VERSION`   | `3.6.0-SNAPSHOT` | Connector artifact version to resolve from Maven                       |
| `BUILD_FROM_SOURCE`   | `auto`           | `auto` = Maven first, source fallback; `true` = always build from clone; `false` = Maven only (fail if absent) |
| `COCKROACHDB_VERSION` | `v25.4.10`       | CockroachDB image tag                                                  |
| `MVN`                 | `mvn`            | Maven command to use                                                   |

The script starts the two CockroachDB clusters, runs the embedded replicator, performs live DML on
the source, and verifies that the inserts, updates, and deletes all land in the target -- with no
Kafka anywhere.

## When to use this

- You want change-data-capture from CockroachDB into another system with **no Kafka infrastructure**
  to run or secure.
- A single-process replicator (or your own application embedding the engine) is sufficient.

Keep the Kafka Connect demos (`crdb-to-crdb`, `crdb-to-sinkless`) when you want the operational
features of Connect: a cluster of workers, the Debezium JDBC sink connector, REST management, and
Kafka topics as a durable buffer between source and sink.

### Durability tradeoff

As with `crdb-to-sinkless`, the sinkless source has no intermediate buffer. If the replicator is
stopped, the changefeed stops; it resumes from the persisted offset (the `debezium_offsets` table in
the target CockroachDB), bounded by CockroachDB's
[`gc.ttlseconds`](https://www.cockroachlabs.com/docs/stable/configure-replication-zones#gc-ttlseconds)
garbage-collection window (whose default varies by version and deployment). Size it for your
worst-case downtime if you rely on resume.

## Endpoints

| Component   | Address                                       |
|-------------|-----------------------------------------------|
| Source CRDB | `localhost:26257` (UI: http://localhost:8080) |
| Target CRDB | `localhost:26258` (UI: http://localhost:8081) |

## Stop

The script tears everything down at the end. To stop manually:

```bash
docker compose down -v
```
