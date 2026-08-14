# Oracle to CockroachDB

Streams Oracle changes into CockroachDB using the Debezium Oracle connector (LogMiner) and the
Debezium JDBC sink. Everything runs locally in containers, and the demo automates the Oracle
side completely, including the one-time ARCHIVELOG and LogMiner preparation that Oracle CDC
normally requires by hand.

```
Oracle 19c (LogMiner)
        |
        v
Debezium Oracle source connector (Kafka Connect)
        |
        v
Kafka topic (oracle.DEBEZIUM.CUSTOMERS)
        |
        v
Debezium JDBC sink connector
        |
        v
CockroachDB (targetdb.customers)
```

## Run it

Prerequisites: docker with compose, curl, python3. The Oracle image is about 2.8 GB and the
first boot creates the database, which takes 10 minutes or more; later runs on the same
containers start much faster.

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

## What the automated Oracle setup does

`setup-oracle.sh` runs the standard Debezium LogMiner preparation and is safe to re-run:

1. Enables ARCHIVELOG mode. This is the only step that restarts the database, and it is
   skipped when the database is already in ARCHIVELOG mode. The recovery area directory is
   created before the restart; the restart fails without it.
2. Enables minimal supplemental logging at the database level.
3. Creates the `logminer_tbs` tablespace in the CDB and the PDB, and the common LogMiner user
   `c##dbzuser` with the grants the Debezium Oracle connector documents.
4. Creates the demo schema: user `debezium` in `ORCLPDB1` with a `customers` table, three seed
   rows, and `SUPPLEMENTAL LOG DATA (ALL) COLUMNS` on the table so update and delete events
   carry complete row images.

## No LogMiner tuning

The source connector config carries no mining tuning at all. Debezium 3.6 replaced the old
adaptive batch sizing (`log.mining.batch.size.*` and the sleep time settings) with log
count based mining, so a new deployment starts with the defaults and adjusts only if redo log
sizing calls for it. See the Debezium post
[No More Tuning: Oracle Log Mining Simplified in Debezium 3.6](https://debezium.io/blog/2026/07/06/oracle-logminer-no-more-tuning/).
The demo uses `log.mining.strategy=online_catalog`, which is the right choice when the
captured schema does not change while the connector is running.

## What the demo verifies

1. The initial snapshot lands the three seed customers in CockroachDB.
2. A live insert, update, and delete on Oracle flow through LogMiner to Kafka and are applied
   to CockroachDB by the JDBC sink with upsert and delete semantics.
3. The final state in `targetdb.customers` matches Oracle: three rows, with the updated tier
   visible and the deleted row gone.

## Realistic traffic (`WORKLOAD=transfers`)

The scripted DML above is deterministic on purpose: it makes the assertions exact. For traffic
that looks like a real Oracle application, run:

```bash
WORKLOAD=transfers ./run-demo.sh
```

After the core demo, the script creates a `debezium.accounts` table with 1000 rows (balance
0), deploys a second source and sink connector pair for it, and runs `WORKLOAD_SESSIONS`
(default 3) concurrent sqlplus sessions, each executing `WORKLOAD_TXNS` (default 300) transfer
transactions. Every transfer updates two rows in one transaction, with locks taken in id order
so sessions cannot deadlock.

The verification uses the workload's own invariant: transfers only move money between
accounts, so once the pipeline drains, both the row count and the total balance must match
exactly between Oracle and CockroachDB. A mismatch means an event was lost, duplicated in a
non-idempotent way, or applied with wrong values. This exercises LogMiner under concurrent
multi-row transactions, the traffic shape a real Oracle migration produces.

## Notes

- The JDBC sink writes to CockroachDB through the PostgreSQL wire protocol. From Debezium
  3.7 the sink ships a first class CockroachDB dialect that resolves automatically from the
  connection URL, so the old `hibernate.dialect=PostgreSQLDialect` pin is gone from these
  configs; on a 3.6.x sink, add it back.
- Oracle `NUMBER(p,s)` columns arrive as Kafka Connect decimals and land in CockroachDB as
  `DECIMAL`; `VARCHAR2` lands as `STRING`; `TIMESTAMP` columns arrive as epoch values with
  Debezium temporal logical types, the same encoding every Debezium relational connector uses.
