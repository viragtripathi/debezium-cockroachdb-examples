# CockroachDB to Neo4j

Streams CockroachDB changes into a Neo4j graph using the Debezium CockroachDB source
connector and the official [Neo4j Connector for Kafka](https://github.com/neo4j/neo4j-kafka-connector)
(Apache 2.0). Rows become nodes, the foreign key becomes a relationship, and the graph
stays continuously synced from the operational database. Everything runs locally in
containers.

```
CockroachDB changefeed
        |
        v
Debezium CockroachDB source connector (Kafka Connect)
        |
        v
Kafka topics (crdb.public.customers, crdb.public.orders)
        |
        v
Neo4j Kafka Connect sink (Cypher strategy)
        |
        v
Neo4j graph: (:Customer)-[:PLACED]->(:Order)
```

## Run it

Prerequisites: docker with compose, curl, python3.

```bash
./run-demo.sh
```

The script downloads the released CockroachDB connector plugin from Maven Central and the
Neo4j connector jar from GitHub releases by default; set `BUILD_FROM_SOURCE=true` to build
the CockroachDB connector from the sibling checkout instead.

| Variable                  | Default        | Description                              |
|---------------------------|----------------|------------------------------------------|
| `CONNECTOR_VERSION`       | `3.7.0.Alpha1` | CockroachDB connector version from Maven |
| `NEO4J_CONNECTOR_VERSION` | `5.5.2`        | Neo4j Kafka connector release            |
| `COCKROACHDB_VERSION`     | `v25.4.14`     | CockroachDB image tag                    |
| `NEO4J_VERSION`           | `5.26-community` | Neo4j image tag                        |
| `DEBEZIUM_VERSION`        | `3.6.0.Final`  | Debezium Connect image tag               |

Tear down:

```bash
docker compose down -v
```

## How the mapping works

The Neo4j sink offers several ingestion strategies (Cypher, node/relationship patterns,
CUD). This demo uses the **Cypher strategy**: one Cypher template per topic, with the
Debezium change event bound as `__value` and the record key as `__key`.

- `customers` events `MERGE` a `(:Customer {id})` node and set its properties from
  `__value.after`.
- `orders` events `MERGE` an `(:Order {id})` node, `MERGE` the customer it references,
  and `MERGE` the `(:Customer)-[:PLACED]->(:Order)` relationship from
  `after.customer_id`. Out-of-order arrival is safe: if an order arrives before its
  customer event, `MERGE` creates a placeholder node that the customer event later
  fills in.
- Deletes (`op = 'd'`) `DETACH DELETE` the node by the record key. Identity always
  comes from `__key`, which is present on every event including deletes, so the
  templates work regardless of whether before-images are enabled. Debezium tombstones
  are dropped with the standard `RecordIsTombstone` predicate.

The `[IMPORTANT]` bits for production use:

- The sink applies events in Kafka partition order; the demo uses single-partition
  topics and one sink task. Neo4j locks both incident nodes when writing a
  relationship, so parallel loading of relationship-heavy streams can deadlock; scale
  with care.
- The sink's CDC ingestion strategy expects Neo4j-shaped change events (nodes and
  relationships), not relational Debezium envelopes; for relational CDC the Cypher and
  pattern strategies are the right tools, as used here.
- CockroachDB `DECIMAL` values arrive as strings to preserve precision and land as
  string properties (`o.amount`); cast in Cypher (`toFloat()`) if you need numeric
  graph properties and can accept the precision trade-off.

## What the demo verifies

1. Initial load: 3 customer nodes, 4 order nodes, 4 `PLACED` relationships, and
   per-customer cardinality (Alice has exactly 2 orders).
2. UPDATE propagation: an order status change and a customer tier change appear as
   property updates on the existing nodes.
3. DELETE propagation: deleting an order removes the order node and its relationship;
   deleting a customer removes the customer node.

## Explore

Neo4j Browser at http://localhost:7474 (`neo4j` / `demopassword`):

```cypher
MATCH (c:Customer)-[r:PLACED]->(o:Order)
RETURN c, r, o;
```
