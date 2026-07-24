# CockroachDB to Oracle

Streams CockroachDB changes into Oracle using the Debezium CockroachDB source connector and
the Debezium JDBC sink. Everything runs locally in containers.

```
CockroachDB changefeed
        |
        v
Debezium CockroachDB source connector (Kafka Connect)
        |
        v
Kafka topic (crdb.public.orders)
        |
        v
Debezium JDBC sink connector (Oracle dialect)
        |
        v
Oracle 19c (ORCLPDB1, debezium.orders)
```

## Run it

Prerequisites: docker with compose, curl, python3. The Oracle image is about 2.8 GB and the
first boot creates the database, which takes 10 minutes or more; later runs on the same
containers start much faster.

One version note: the delete step exercises a connector fix (debezium/dbz#2267) that is newer
than the 3.6.0.Final release. The script builds the connector from the sibling
debezium-connector-cockroachdb checkout automatically when one is present next to this repo;
without one, it falls back to the bundled release and the delete step will stop the source
task until the next release ships.

```bash
./run-demo.sh
```

The script picks the Oracle image for your architecture automatically:
`virag/oracle-19.3.0-ee-arm64` on Apple Silicon, `virag/oracle-19.3.0-ee` on x86. Override
with `ORACLE_IMAGE=...` if needed.

Tear down:

```bash
docker-compose down -v
```

## How it works

- The CockroachDB connector creates an enriched changefeed and emits standard Debezium change
  events, so the JDBC sink consumes them like events from any other Debezium source.
- Oracle is a plain JDBC target here: no ARCHIVELOG mode, supplemental logging, or LogMiner
  user is needed. The demo creates only a schema user (`debezium/dbz` in `ORCLPDB1`) and the
  sink auto-creates the `orders` table from the event schema with
  `schema.evolution=basic`.
- The sink resolves the Oracle dialect from the `jdbc:oracle:thin` connection automatically;
  the Oracle JDBC driver ships inside the Debezium Connect image.
- Upserts use the primary key from the record key, and deletes are propagated, so the Oracle
  table converges to the same state as the CockroachDB source.

## What the demo verifies

1. The initial changefeed scan lands the three seed orders in Oracle.
2. A live insert, update, and delete on CockroachDB flow through the changefeed to Kafka and
   are applied to Oracle by the JDBC sink.
3. The final state in `debezium.orders` matches CockroachDB: three rows, the updated status
   visible, and the deleted row gone.

## Scale test (`WORKLOAD=tpcc`)

For volume beyond the scripted rows, run:

```bash
WORKLOAD=tpcc ./run-demo.sh
```

After the core demo, the script loads the built-in
[`cockroach workload tpcc`](https://www.cockroachlabs.com/docs/stable/cockroach-workload)
dataset (9 tables, about 500k rows at the default 1 warehouse), deploys a second source and
sink connector pair for the `tpcc` database, and runs live TPC-C transactions while the
changefeed initial scan backfills into Oracle. Once the run finishes and the pipeline
drains, the script asserts per-table row-count parity across all 9 tables, which exercises
inserts, updates, and deletes (the delivery transaction deletes from `new_order`) at volume.

Tunables: `WAREHOUSES` (default `1`), `WORKLOAD_DURATION` (default `60s`),
`WORKLOAD_MAX_RATE` (default `20` transactions per second), and `DRAIN_TIMEOUT` (default
`1800` seconds; the backfill into Oracle is the slow part, on the order of a few thousand
rows per second).

TPC-C notes: the sink runs with `quote.identifiers=true` because the `history` table has a
column named `rowid`, which collides with Oracle's reserved `ROWID` in unquoted DDL. The
resulting Oracle tables are case-sensitive lowercase (query them as `"tpcc_public_order"`).
The `order` table name itself is accepted unquoted by `CREATE CHANGEFEED`, and TPC-C's
composite primary keys are used as is from the record key.

## Notes

- CockroachDB `DECIMAL` columns arrive as strings to preserve precision and land in Oracle as
  `VARCHAR2`; cast in queries or add a generated column if you need Oracle `NUMBER` semantics.
  `UUID` keys land as `VARCHAR2`, and `TIMESTAMPTZ` columns arrive as ISO offset strings.
- The mirror demo, [`oracle-to-crdb`](../oracle-to-crdb/), runs the same pipeline in the other
  direction with Oracle as the CDC source via LogMiner.
