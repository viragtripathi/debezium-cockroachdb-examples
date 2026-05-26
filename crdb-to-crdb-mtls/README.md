# Fully-Secure CockroachDB → mTLS Kafka via the Debezium Connector

End-to-end demo that exercises the **`cockroachdb.changefeed.sink.tls.*`
properties** ([debezium/dbz#1974](https://issues.redhat.com/browse/DBZ-1974))
on the [Debezium CockroachDB source connector](https://github.com/debezium/debezium-connector-cockroachdb)
against:

- a **secure (TLS) CockroachDB** cluster authenticated with a client cert via pgjdbc, AND
- a **Kafka broker that requires mutual TLS** for the CockroachDB changefeed sink.

Two independent trust chains are involved — they share no CA — and both layers
must succeed for events to flow.

## Architecture

```
                            ┌────────────────────────────────────────────────────┐
                            │ Secure CockroachDB (start-single-node --certs-dir) │
                            │   demodb.orders                                    │
                            └────────────────────────┬───────────────────────────┘
                                                     │
                pgjdbc verify-full                   │   CREATE CHANGEFEED ... INTO
                ssl{rootcert,cert,key} =             │     'kafka://kafka:9093?
                /etc/crdb-tls/{ca,client.demo}.*     │        tls_enabled=true&
                                                     │        ca_cert=<base64 PEM>&
                                                     │        client_cert=<base64 PEM>&
                                                     │        client_key=<base64 PEM>'
                                                     ▼
   ┌──────────────────────────────┐         ┌──────────────────────────────┐
   │ Debezium connector           │────────▶│ Kafka SSL listener           │
   │   (Kafka Connect worker)     │         │   kafka:9093                 │
   │   reads PEM files from disk, │         │   SSL_CLIENT_AUTH=required   │
   │   base64-inlines into the    │         └──────────────┬───────────────┘
   │   CockroachDB sink URI       │                        │
   └──────────────┬───────────────┘                        │
                  │ reads intermediate topic from          │
                  │ kafka:9092 (PLAINTEXT — same broker,   │
                  │ same data, different listener)         │
                  ▼                                        │
   Kafka topic: crdb.public.orders   ◀────────────────────┘
   (Debezium output, JSON)              CRDB writes to: crdb.demodb.public.orders
```

Both Kafka listeners point at the same broker, so the in-network Kafka Connect
worker uses the PLAINTEXT listener for its own bookkeeping topics and for
reading the intermediate changefeed topic, while CockroachDB pushes the
changefeed over mTLS to the SSL listener. That matches the most common
production topology, where Connect runs on a trusted network alongside Kafka
and only external CockroachDB clusters speak mTLS to the broker.

## Prerequisites

- Docker / Docker Compose (or Podman)
- A JDK (used only for `keytool` while generating the broker JKS stores)
- `openssl`
- `docker` (also used to run `cockroach cert` in a one-shot container — no local CockroachDB install required)

To build the connector from source (required while `3.6.0-SNAPSHOT` is the only
version that ships the `cockroachdb.changefeed.sink.tls.*` properties):

- JDK 21+
- Maven 3.9.8+
- Connector source at `../../debezium-connector-cockroachdb`

## Quick Start

```bash
./run-demo.sh
```

The default is `BUILD_FROM_SOURCE=true` because the mTLS feature requires
`3.6.0-SNAPSHOT` or later. Once `3.6.0.Final` is published:

```bash
BUILD_FROM_SOURCE=false CONNECTOR_VERSION=3.6.0.Final ./run-demo.sh
```

| Variable              | Default            | Description                                                  |
|-----------------------|--------------------|--------------------------------------------------------------|
| `CONNECTOR_VERSION`   | `3.6.0-SNAPSHOT`   | Connector plugin version                                     |
| `COCKROACHDB_VERSION` | `v25.4.10`         | CockroachDB image tag (and the image used for `cockroach cert`) |
| `DEBEZIUM_VERSION`    | `3.5.0.Final`      | Debezium Connect image tag                                   |
| `CONFLUENT_VERSION`   | `7.4.0`            | Confluent Platform (Kafka/ZK) image tag                      |
| `BUILD_FROM_SOURCE`   | `true`             | Build connector from local source instead of downloading     |
| `SKIP_BUILD`          | `false`            | Skip download/build, use existing jars in `connect-plugins/` |
| `REGENERATE_CERTS`    | `false`            | Force `generate-certs.sh` to rebuild material in `certs/`    |

## TLS Material

`generate-certs.sh` produces two independent trust chains:

```
certs/
├── kafka/                      ← openssl (Kafka mTLS)
│   ├── ca.crt, ca.key
│   ├── broker.crt, broker.key
│   ├── broker.keystore.jks, broker.truststore.jks
│   ├── client.crt, client.key, client.keystore.jks
│   └── keystore_creds, key_creds, truststore_creds
│
├── crdb/                       ← cockroach cert (secure-mode CRDB)
│   ├── ca.crt
│   ├── node.crt, node.key                 # CRDB node identity
│   ├── client.root.crt, client.root.key   # `cockroach sql` tooling
│   ├── client.demo.crt, client.demo.key   # Used by the connector (PEM)
│   └── client.demo.key.pk8                # PKCS#8 DER — pgjdbc reads this
│
└── crdb-ca-key/
    └── ca.key                  # CRDB CA private key, kept out of /certs by cockroach cert
```

The connector container mounts:

- `certs/kafka/` → `/etc/kafka-tls/` (read-only) — for `cockroachdb.changefeed.sink.tls.*`
- `certs/crdb/`  → `/etc/crdb-tls/`  (read-only) — for `database.sslrootcert` / `sslcert` / `sslkey`

The Kafka broker mounts `certs/kafka/` → `/etc/kafka/secrets/`. The CockroachDB
container mounts `certs/crdb/` → `/cockroach/cockroach-certs/`.

## Connector Configuration

The two security layers — pgjdbc to secure CRDB, and mTLS to Kafka — are
controlled by two disjoint sets of properties:

```json
"database.sslmode":     "verify-full",
"database.sslrootcert": "/etc/crdb-tls/ca.crt",
"database.sslcert":     "/etc/crdb-tls/client.demo.crt",
"database.sslkey":      "/etc/crdb-tls/client.demo.key.pk8",
"database.user":        "demo",

"cockroachdb.changefeed.sink.type":               "kafka",
"cockroachdb.changefeed.sink.uri":                "kafka://kafka:9093",
"cockroachdb.changefeed.sink.tls.ca.cert.file":     "/etc/kafka-tls/ca.crt",
"cockroachdb.changefeed.sink.tls.client.cert.file": "/etc/kafka-tls/client.crt",
"cockroachdb.changefeed.sink.tls.client.key.file":  "/etc/kafka-tls/client.key",
"cockroachdb.changefeed.kafka.bootstrap.servers":   "kafka:9092"
```

The connector resolves each `cockroachdb.changefeed.sink.tls.*.file` at task
start, base64-encodes the contents, and appends them to the sink URI as
`ca_cert=…`, `client_cert=…`, `client_key=…`, plus `tls_enabled=true`. See
CockroachDB's [Kafka sink documentation](https://www.cockroachlabs.com/docs/stable/changefeed-sinks#kafka)
for the inline query parameter format.

The `cockroachdb.changefeed.kafka.bootstrap.servers` override points the
connector's own consumer at the PLAINTEXT listener on the same broker —
otherwise the consumer would derive its bootstrap from the sink URI
(`kafka:9093`) and try PLAINTEXT against the SSL listener.

## What the Demo Proves

| Capability                                          | How                                                                                |
|-----------------------------------------------------|------------------------------------------------------------------------------------|
| pgjdbc verify-full to secure CockroachDB            | Step 10 (connector reaches RUNNING). CRDB only accepts cert-authenticated clients. |
| Connector reads PEM files from the worker's disk    | `cockroachdb.changefeed.sink.tls.{ca,client.cert,client.key}.file`                 |
| Connector base64-encodes and inlines TLS material   | Step 11 verifies `ca_cert=`, `client_cert=`, `client_key=`, `tls_enabled=true`     |
| CockroachDB changefeed actually publishes over mTLS | Step 12 consumes events from `kafka:9093` with `SSL_CLIENT_AUTH=required`         |
| Sink-type gate (kafka only)                         | Connector skips TLS injection if `cockroachdb.changefeed.sink.type != kafka`       |
| No cert files written on the CockroachDB node       | All Kafka TLS material is inlined into the changefeed URI                          |

## Inspect Live State

Interactive SQL on the secure CRDB (via the bundled `root` client cert):

```bash
docker exec -it mtls-demo-cockroachdb cockroach sql \
  --certs-dir=/cockroach/cockroach-certs --host=cockroachdb:26257 --user=root -d demodb
```

Look at the changefeed URI (CRDB redacts the base64 blobs in `SHOW CHANGEFEED JOBS`,
so you'll see `ca_cert=redacted&client_cert=redacted&client_key=redacted&tls_enabled=true`
— that confirms the material was injected and accepted):

```bash
docker exec -it mtls-demo-cockroachdb cockroach sql \
  --certs-dir=/cockroach/cockroach-certs --host=cockroachdb:26257 --user=root \
  -e "SELECT description FROM [SHOW CHANGEFEED JOBS] WHERE description LIKE '%kafka%'"
```

Consume events through the mTLS listener using the bundled client keystore:

```bash
docker exec mtls-demo-kafka kafka-console-consumer \
  --bootstrap-server kafka:9093 \
  --consumer.config /tmp/ssl-consumer.properties \
  --topic crdb.demodb.public.orders --from-beginning
```

## Files

| File                    | Description                                                                  |
|-------------------------|------------------------------------------------------------------------------|
| `run-demo.sh`           | Fully automated 13-step demo script                                          |
| `generate-certs.sh`     | Builds both cert chains in `certs/kafka/` and `certs/crdb/`                  |
| `docker-compose.yml`    | 4-service stack: Zookeeper, mTLS Kafka, secure CRDB, Kafka Connect           |
| `connector-config.json` | Connector config with both layers (pgjdbc verify-full + sink TLS injection)  |
| `setup-cockroachdb.sql` | DB setup: `demodb`, `orders`, `demo` user, `CHANGEFEED` grant, seed rows     |

## Cleanup

```bash
docker compose down -v
rm -rf connect-plugins certs
```

## See Also

- [`../crdb-to-crdb`](../crdb-to-crdb) — insecure CRDB → Kafka → CRDB round-trip with the JDBC sink (no TLS)
- [`../pg-to-crdb`](../pg-to-crdb) — Postgres → Kafka → CRDB round-trip
