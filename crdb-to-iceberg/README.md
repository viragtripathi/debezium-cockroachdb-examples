# CockroachDB to Apache Iceberg

Streams CockroachDB changes into Apache Iceberg tables using the Debezium CockroachDB source
connector and the Apache Iceberg Kafka Connect sink. Everything runs locally in containers and
the demo verifies the data by reading the Iceberg tables back through the catalog.

```
CockroachDB changefeed
        |
        v
Debezium CockroachDB source connector (Kafka Connect)
        |
        v
Kafka topics (crdb.public.orders, crdb.public.customers)
        |
        v
Apache Iceberg sink connector (Kafka Connect)
        |
        v
Iceberg tables (REST catalog + MinIO object storage)
```

Any engine that speaks Iceberg can then query the tables: Spark, Trino, DuckDB, ClickHouse
(Iceberg table engine), Snowflake, and others. No engine is bundled here; the demo verifies the
data with pyiceberg, which talks straight to the catalog.

## What the demo does

1. Downloads the two connector plugins: the Debezium CockroachDB connector from Maven Central
   and the Apache Iceberg sink from Confluent Hub.
2. Starts CockroachDB, Kafka, Kafka Connect, MinIO, and an Iceberg REST catalog.
3. Creates `orders` and `customers` tables with seed rows, including a `JSONB NOT NULL` column
   and a `DECIMAL(28,18)` column carrying 19 significant digits.
4. Deploys the source connector, which creates the changefeed, and the Iceberg sink, which
   auto-creates one Iceberg table per source table (`demo.orders`, `demo.customers`).
5. Runs an insert, an update, and a delete while the pipeline is live.
6. Reads the Iceberg tables back and checks row counts, CDC metadata, and that the
   `DECIMAL(28,18)` value arrived with every digit intact.

## Run it

Prerequisites: docker with compose, curl, python3 on the host. About 4 GB of free memory for
the containers.

One version note: the delete step exercises a connector fix (debezium/dbz#2267) that is newer
than the 3.6.0.Final release. The script builds the connector from the sibling
debezium-connector-cockroachdb checkout automatically when one is present next to this repo;
without one, it downloads the latest release and the delete step will stop the source task
until the next release ships. JDK 21 and Maven are only needed for the build-from-source path.

```bash
./run-demo.sh
```

Tear down:

```bash
docker-compose down -v
```

## What lands in Iceberg

The sink appends one row per change event. The Debezium `ExtractNewRecordState` transform
flattens the change event, so each Iceberg row holds the after-image columns plus `__op`
(`c`, `u`, `d`, or `r` for snapshot reads), `__ts_ms`, and `__deleted`. Delete events arrive as
rows with `__op = 'd'` and `__deleted = 'true'`, carrying the primary key of the deleted row.

This means the Iceberg table is the full history of changes, not a mirror of the current table
state. That is the behavior of the Apache Iceberg sink today: it writes append-only. If you
need a latest-row view, derive it at query time or with a scheduled merge. For example, with
engines that support window functions:

```sql
SELECT * FROM (
  SELECT *, row_number() OVER (PARTITION BY id ORDER BY __ts_ms DESC) AS rn
  FROM demo.orders
) WHERE rn = 1 AND __deleted <> 'true';
```

The older Tabular version of this sink had an upsert mode, but it was deprecated with the
donation to Apache Iceberg and the current releases do not include it. If you want CDC applied
as upserts directly, look at the community project
[debezium-server-iceberg](https://github.com/memiiso/debezium-server-iceberg), which runs
Debezium sources under Debezium Server and writes Iceberg with update and delete semantics.
Note that with CockroachDB the changefeed still needs Kafka as its transport, so that path does
not remove Kafka from the picture.

## Configuration notes

The interesting parts of `iceberg-sink-config.json`:

| Property | Value | Why |
|---|---|---|
| `transforms.unwrap.type` | `io.debezium.transforms.ExtractNewRecordState` | Flattens the Debezium envelope; `delete.tombstone.handling.mode=rewrite` keeps delete rows with `__deleted` and consumes tombstones |
| `transforms.addTopic.type` | `InsertField$Value` with `topic.field=_topic` | Stamps each record with its source topic for routing |
| `iceberg.tables` + `iceberg.table.<t>.route-regex` | route on `_topic` | One sink connector writes each source table to its own Iceberg table |
| `iceberg.tables.auto-create-enabled` | `true` | The sink creates Iceberg tables from the record schema |
| `iceberg.tables.evolve-schema-enabled` | `true` | Source schema changes add columns to the Iceberg table |
| `iceberg.control.commit.interval-ms` / `commit.timeout-ms` | `20000` / `15000` | Commit every 20 seconds so the demo shows data quickly; the default interval is 5 minutes |
| `consumer.override.auto.offset.reset` | `earliest` | The sink reads the topics from the beginning even if it subscribes after the snapshot events were produced |
| `iceberg.catalog.*` | REST catalog + S3 settings | Points at the local REST catalog and MinIO; swap these for your real catalog and object store |

The sink also bundles its own `DebeziumTransform` SMT; this example uses Debezium's
`ExtractNewRecordState` instead because the sink transform reads `source.table` from the
envelope, which this connector does not populate yet.

Kafka runs as a single KRaft node (`apache/kafka:3.9.0`). The sink coordinates its Iceberg
commits over an internal Kafka control topic with transactions, and that coordination did not
complete reliably on older zookeeper-based single-broker images during testing.

Type mapping notes: the connector emits CockroachDB `DECIMAL` columns as strings to preserve
precision, so they land as Iceberg `string` columns; cast them in queries or in a derived
table. `JSONB` columns also arrive as strings holding the JSON text.

## Swapping in a real environment

- Point `iceberg.catalog.uri` and the `iceberg.catalog.s3.*` settings at your catalog and
  object store. The sink bundles support for REST, Glue, Nessie, Hive, and JDBC catalogs.
- Raise `iceberg.control.commit.interval-ms` back toward the default; every commit creates an
  Iceberg snapshot, and committing too often creates many small files.
- Size `tasks.max` to the topic partition count.
