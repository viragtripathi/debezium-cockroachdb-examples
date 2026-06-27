#!/usr/bin/env bash
#
# Continuous change-event generator for the crdb-to-crdb demo. Drives a steady mix of inserts,
# updates, and deletes against the source CockroachDB so the Grafana dashboard
# (observability/) shows sustained, live data flow.
#
# Usage:
#   observability/continuous-writer.sh                 # defaults: a batch every 2s, forever
#   INTERVAL=1 BATCH=10 observability/continuous-writer.sh
#   DURATION=120 observability/continuous-writer.sh     # stop after ~120s
#
# Stop with Ctrl-C.
#
# Tunables (environment variables):
#   INTERVAL   seconds between batches            (default 2)
#   BATCH      new orders inserted per batch       (default 5)
#   DURATION   total run time in seconds, 0=forever (default 0)
#   CONTAINER  source CockroachDB container name   (default demo-cockroachdb)
#   DB         source database                     (default demodb)
set -euo pipefail

INTERVAL="${INTERVAL:-2}"
BATCH="${BATCH:-5}"
DURATION="${DURATION:-0}"
CONTAINER="${CONTAINER:-demo-cockroachdb}"
DB="${DB:-demodb}"

tick=0
created=0
updated=0
deleted=0
start=$(date +%s)

cleanup() {
  echo ""
  echo "Stopped after ${tick} batches: ~${created} inserts, ~${updated} updates, ~${deleted} deletes."
  exit 0
}
trap cleanup INT TERM

echo "Continuous writer -> ${CONTAINER}/${DB} (batch=${BATCH} every ${INTERVAL}s, duration=${DURATION:-0}s). Ctrl-C to stop."

while true; do
  tick=$((tick + 1))

  # Insert a batch of orders and a few customers, update the just-created orders, and delete a couple
  # of the oldest open orders. Keeps create/update/delete all moving without unbounded table growth.
  docker exec -i "$CONTAINER" cockroach sql --insecure -d "$DB" >/dev/null 2>&1 <<SQL || true
INSERT INTO orders (order_number, customer_name, email, amount, status)
SELECT 'CW-${tick}-'||i, 'cust_'||((i % 7) + 1), 'cw${tick}_'||i||'@example.com', (i * 3.5)::DECIMAL(12,2), 'pending'
FROM generate_series(1, ${BATCH}) AS g(i);

INSERT INTO customers (name, email)
SELECT 'cw_cust_${tick}_'||i, 'cwcust${tick}_'||i||'@example.com'
FROM generate_series(1, GREATEST(1, ${BATCH} / 3)) AS g(i);

UPDATE orders SET status = 'shipped', updated_at = now() WHERE order_number LIKE 'CW-${tick}-%';

DELETE FROM orders WHERE id IN (
  SELECT id FROM orders WHERE status = 'shipped' ORDER BY created_at ASC LIMIT GREATEST(1, ${BATCH} / 3)
);
SQL

  created=$((created + BATCH))
  updated=$((updated + BATCH))
  deleted=$((deleted + (BATCH / 3 > 0 ? BATCH / 3 : 1)))

  printf "\rbatch %-5d  inserts~%-7d updates~%-7d deletes~%-7d" "$tick" "$created" "$updated" "$deleted"

  if [ "$DURATION" -ne 0 ]; then
    now=$(date +%s)
    [ $((now - start)) -ge "$DURATION" ] && cleanup
  fi
  sleep "$INTERVAL"
done
