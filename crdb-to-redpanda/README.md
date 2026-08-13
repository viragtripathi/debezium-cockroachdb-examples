# CockroachDB to CockroachDB over Redpanda

The same CDC pipeline as [crdb-to-crdb](../crdb-to-crdb/), with **Redpanda** in place of
Apache Kafka. Nothing else changes: the configs point at a different bootstrap address and
that is the entire delta, which is the point of the demo.

This validates both Kafka-protocol touchpoints against Redpanda:

1. **CockroachDB's changefeed produces into Redpanda** (the `kafka://` sink URI of the
   changefeed is just a Kafka-protocol endpoint).
2. **Kafka Connect runs against Redpanda** (worker storage topics, the Debezium
   CockroachDB source connector, and the Debezium JDBC sink all speak the Kafka protocol
   to Redpanda).

```
CockroachDB changefeed  --kafka://redpanda:9092-->  Redpanda (intermediate topics)
        Debezium CockroachDB source connector (Kafka Connect on Redpanda)
                          |
                          v
              Redpanda (crdb.public.* topics)
                          |
                          v
        Debezium JDBC sink (CockroachDB dialect, UNNEST batch writes)
                          |
                          v
                  CockroachDB (target)
```

## Run it

Prerequisites: docker with compose, curl, python3.

```bash
./run-demo.sh
```

| Variable              | Default        | Description                              |
|-----------------------|----------------|------------------------------------------|
| `CONNECTOR_VERSION`   | `3.7.0.Alpha2` | CockroachDB connector version from Maven |
| `JDBC_SINK_VERSION`   | `3.7.0.Alpha2` | Debezium JDBC sink version from Maven    |
| `REDPANDA_VERSION`    | `v26.2.1`      | Redpanda image tag                       |
| `COCKROACHDB_VERSION` | `v25.4.14`     | CockroachDB image tag                    |
| `DEBEZIUM_VERSION`    | `3.6.0.Final`  | Debezium Connect image tag               |

Tear down:

```bash
docker compose down -v
```

## What the demo verifies

1. Kafka Connect starts with Redpanda as its backing broker (worker storage topics in
   Redpanda), and both connector plugins register.
2. The changefeed's intermediate topics and the connector's output topics are created in
   Redpanda (asserted via `rpk topic list`).
3. Insert, update, and delete propagation from source to target CockroachDB, verified by
   SQL on the target: row counts, an order status change, a customer tier change, and
   row removal after deletes.
4. The JDBC sink resolves the CockroachDB dialect automatically and engages set-based
   UNNEST batch writes.

## Notes

- Kafka Connect is a process you run yourself next to the brokers; Redpanda replaces the
  brokers, not Connect. This demo runs Connect via the `quay.io/debezium/connect` image
  with `BOOTSTRAP_SERVERS` pointed at Redpanda.
- The connector plugins are plain jars: the demo downloads the released plugin zips from
  Maven Central and mounts them onto the worker's plugin path. No build required.
- Redpanda ships `rpk` instead of the Kafka shell tools, so topic inspection here uses
  `rpk topic list` / `rpk topic consume`.
