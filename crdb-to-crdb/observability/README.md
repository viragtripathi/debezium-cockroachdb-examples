# Metrics: Prometheus and Grafana

This overlay exposes the Debezium CockroachDB connector's JMX metrics with the Prometheus JMX
exporter java agent, stores them in Prometheus, and visualizes them in Grafana. It works with the
`crdb-to-crdb` demo and mirrors the canonical Debezium monitoring example
(https://github.com/debezium/debezium-examples/tree/main/monitoring).

## What it shows

The connector exposes the standard Debezium MBeans:

- `debezium.cockroachdb:type=connector-metrics,context=snapshot,server=<topic.prefix>`
- `debezium.cockroachdb:type=connector-metrics,context=streaming,server=<topic.prefix>`

The provided dashboard surfaces a Connectors table (name, version, type, status), a live data-flow
view (records/sec at each hop: CRDB -> connector -> Kafka -> JDBC sink -> CRDB target), snapshot
running/completed, lag (`MilliSecondsBehindSource`), event throughput, create/update/delete counts,
and the change-event queue capacity.

## Run

The simplest path is the demo script with the overlay enabled:

```bash
cd crdb-to-crdb
OBSERVABILITY=true ./run-demo.sh
```

To pull in the latest connector from source, combine it with `BUILD_FROM_SOURCE=true`:

```bash
OBSERVABILITY=true BUILD_FROM_SOURCE=true ./run-demo.sh
```

Or bring the overlay up manually alongside an already-running demo:

```bash
docker compose -f docker-compose.yml -f observability/docker-compose.observability.yml up -d --build
```

### Drive continuous change events

To see sustained movement on the dashboard, run the continuous writer (steady mix of inserts,
updates, and deletes against the source). Ctrl-C to stop:

```bash
./observability/continuous-writer.sh
# tunables: INTERVAL (s between batches), BATCH (orders per batch), DURATION (0=forever)
INTERVAL=1 BATCH=10 ./observability/continuous-writer.sh
```

## Access

- Grafana: http://localhost:3000 (admin / admin) -> dashboard "Debezium CockroachDB"
- Prometheus: http://localhost:9090
- Raw metrics: http://localhost:9404/metrics (the agent serves `:8080` inside the container, mapped
  to host `9404`; look for `debezium_metrics_*`)

## How it is wired

- The `connect` service is rebuilt from `Dockerfile.connect`, which bakes the
  `jmx_prometheus_javaagent` jar and `config.yml` into the image (same as the canonical Debezium
  monitoring example's `debezium-jmx-exporter`).
- The agent is started in-process via `KAFKA_OPTS=-javaagent:.../jmx_prometheus_javaagent.jar=8080:.../config.yml`
  and serves the connector's MBeans on `:8080/metrics`. `config.yml` maps the Debezium connector
  MBeans to `debezium_metrics_<Attribute>` series with `plugin`, `name`, and `context` labels, plus
  the Kafka Connect worker/client metrics.
- `prometheus` scrapes `connect:8080`; `grafana` is provisioned with the Prometheus datasource and
  the dashboard.

## Teardown

```bash
docker compose -f docker-compose.yml -f observability/docker-compose.observability.yml down -v
```
