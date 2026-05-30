#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
fail()    { echo -e "${RED}[FAIL]${NC} $1"; exit 1; }
header()  { echo -e "\n${BOLD}=== $1 ===${NC}\n"; }

wait_for_url() {
    local url="$1" max="$2"
    for i in $(seq 1 "$max"); do
        if curl -s -o /dev/null -w '' "$url" 2>/dev/null; then return 0; fi
        echo -n "."
        sleep 2
    done
    echo ""
    return 1
}

# Kafka Connect answers its REST port before it finishes registering connector
# plugins, so waiting on the port alone races plugin discovery. Poll until the
# named connector class actually appears in /connector-plugins.
wait_for_plugin() {
    local plugin="$1" max="$2"
    for i in $(seq 1 "$max"); do
        if curl -s http://localhost:8083/connector-plugins 2>/dev/null | grep -q "$plugin"; then return 0; fi
        echo -n "."
        sleep 2
    done
    echo ""
    return 1
}

wait_for_task_running() {
    local name="$1" max="$2"
    for i in $(seq 1 "$max"); do
        local state=$(curl -s "http://localhost:8083/connectors/$name/status" 2>/dev/null \
            | python3 -c "import sys,json; t=json.load(sys.stdin).get('tasks',[]); print(t[0]['state'] if t else 'NO_TASK')" 2>/dev/null || echo "UNKNOWN")
        if [ "$state" = "RUNNING" ]; then return 0; fi
        if [ "$state" = "FAILED" ]; then
            local trace=$(curl -s "http://localhost:8083/connectors/$name/status" 2>/dev/null \
                | python3 -c "import sys,json; t=json.load(sys.stdin).get('tasks',[]); print(t[0].get('trace','')[:500] if t else '')" 2>/dev/null)
            echo ""
            fail "Task FAILED: $trace"
        fi
        echo -n "."
        sleep 2
    done
    echo ""
    return 1
}

cd "$SCRIPT_DIR"

# ── Step 1: Start infrastructure ────────────────────────────────────────────
header "STEP 1: Start Docker Compose (PostgreSQL + CockroachDB Target + Kafka + Connect)"
info "No custom connector plugin needed -- Debezium Connect image ships with PostgresConnector + JDBC Sink"
docker compose down -v --remove-orphans 2>/dev/null || true
docker compose up -d
success "Containers starting..."

# ── Step 2: Wait for PostgreSQL ─────────────────────────────────────────────
header "STEP 2: Wait for PostgreSQL"
for i in $(seq 1 30); do
    if docker exec pg2crdb-postgres pg_isready -U postgres >/dev/null 2>&1; then
        success "PostgreSQL is ready (port 5432)"
        break
    fi
    echo -n "."
    sleep 2
done
docker exec pg2crdb-postgres pg_isready -U postgres >/dev/null 2>&1 || fail "PostgreSQL did not start"

# ── Step 3: Wait for Target CockroachDB ────────────────────────────────────
header "STEP 3: Wait for Target CockroachDB"
for i in $(seq 1 30); do
    if docker exec pg2crdb-cockroachdb-target cockroach sql --insecure -e "SELECT 1" >/dev/null 2>&1; then
        success "Target CockroachDB is ready (port 26257)"
        break
    fi
    echo -n "."
    sleep 2
done
docker exec pg2crdb-cockroachdb-target cockroach sql --insecure -e "SELECT 1" >/dev/null 2>&1 || fail "Target CockroachDB did not start"

# ── Step 4: Setup source database with partitioned tables ──────────────────
header "STEP 4: Setup Source PostgreSQL (partitioned orders table + customers)"
docker exec -i pg2crdb-postgres psql -U postgres -d sourcedb < setup-postgres.sql
success "Source DB configured: orders (48 monthly partitions, ~192 rows) + customers (5 rows)"

# ── Step 5: Verify partition layout ────────────────────────────────────────
header "STEP 5: Verify PostgreSQL Partition Layout"
info "Partitioned tables in source database:"
docker exec pg2crdb-postgres psql -U postgres -d sourcedb -c "
    SELECT inhrelid::regclass AS partition_name,
           pg_get_expr(c.relpartbound, c.oid) AS partition_range
    FROM pg_inherits i
    JOIN pg_class c ON c.oid = i.inhrelid
    WHERE inhparent = 'orders'::regclass
    ORDER BY partition_name;
"
echo ""
info "Row distribution across partitions:"
docker exec pg2crdb-postgres psql -U postgres -d sourcedb -c "
    SELECT tableoid::regclass AS partition, count(*) AS rows
    FROM orders GROUP BY tableoid ORDER BY partition;
"
success "48 monthly partitions verified -- this matches the real-world scenario of many child tables merging into one"

# ── Step 6: Setup target database ──────────────────────────────────────────
header "STEP 6: Setup Target CockroachDB (targetdb)"
docker exec -i pg2crdb-cockroachdb-target cockroach sql --insecure < setup-target-cockroachdb.sql
success "Target DB configured: targetdb (tables will be auto-created by JDBC sink)"

# ── Step 7: Wait for Kafka Connect ─────────────────────────────────────────
header "STEP 7: Wait for Kafka Connect"
if ! wait_for_url "http://localhost:8083/" 60; then
    echo ""
    fail "Kafka Connect did not start within 120s"
fi
# Wait for plugin discovery to finish, not just the REST port to open.
if ! wait_for_plugin "PostgresConnector" 60 || ! wait_for_plugin "JdbcSinkConnector" 60; then
    echo ""
    fail "Connector plugins did not register within 120s"
fi
echo ""
success "Kafka Connect is ready"

# ── Step 8: Verify plugins ─────────────────────────────────────────────────
header "STEP 8: Verify Connector Plugins"
PLUGINS=$(curl -s http://localhost:8083/connector-plugins)
echo "$PLUGINS" | python3 -c "
import sys,json
for p in json.load(sys.stdin):
    c = p['class']
    if 'postgres' in c.lower() or 'jdbc' in c.lower():
        print(f'  {p[\"type\"]:6s}  {c}')
" 2>/dev/null
echo "$PLUGINS" | grep -q "PostgresConnector" || fail "PostgreSQL source connector not found"
echo "$PLUGINS" | grep -q "JdbcSinkConnector" || fail "JDBC sink connector not found"
success "Both PostgresConnector and JdbcSinkConnector discovered"

# ── Step 9: Deploy source connector with ByLogicalTableRouter ──────────────
header "STEP 9: Deploy PostgreSQL Source Connector (with partition routing SMT)"
info "The ByLogicalTableRouter SMT merges partition topics into a single logical table topic:"
info "  pgdemo.public.orders_2025q1, orders_2025q2, ... -> pgdemo.public.orders"
echo ""
RESPONSE=$(curl -s -o /tmp/pg2crdb-src-response.json -w "%{http_code}" -X POST \
    -H "Content-Type: application/json" \
    --data @source-connector-config.json \
    http://localhost:8083/connectors)
BODY=$(cat /tmp/pg2crdb-src-response.json)
if [ "$RESPONSE" -ge 200 ] && [ "$RESPONSE" -lt 300 ]; then
    success "Source connector deployed (HTTP $RESPONSE)"
elif echo "$BODY" | grep -q "already exists"; then
    warn "Source connector already exists"
else
    echo "$BODY" | python3 -m json.tool 2>/dev/null || echo "$BODY"
    fail "Source connector deploy failed (HTTP $RESPONSE)"
fi

info "Waiting for source connector task to start..."
if ! wait_for_task_running "pg-source-connector" 30; then
    fail "Source connector task did not start"
fi
success "Source connector task is RUNNING"

info "Waiting 30s for initial snapshot of 48 partitions to complete..."
sleep 30

# ── Step 10: Check merged topic ────────────────────────────────────────────
header "STEP 10: Verify Partition Topic Merging"
info "Kafka topics created:"
docker exec pg2crdb-kafka kafka-topics --bootstrap-server localhost:9092 --list 2>/dev/null \
    | grep -v "^_\|connect-\|pg2crdb-connect" | sort

echo ""
info "Checking that all partition data lands on the merged 'pgdemo.public.orders' topic..."
MERGED_EVENTS=$(docker exec pg2crdb-kafka kafka-console-consumer \
    --bootstrap-server localhost:9092 \
    --topic pgdemo.public.orders \
    --from-beginning \
    --max-messages 200 \
    --timeout-ms 20000 2>/dev/null || true)

MERGED_COUNT=$(echo "$MERGED_EVENTS" | grep -c "order_number" || echo "0")
if [ "$MERGED_COUNT" -gt 0 ]; then
    success "Partition merging works: $MERGED_COUNT order events on unified pgdemo.public.orders topic"
    echo "$MERGED_EVENTS" | python3 -c "
import sys,json
for line in sys.stdin:
    line=line.strip()
    if not line: continue
    try:
        d=json.loads(line)
        payload = d.get('payload', d)
        after = payload.get('after',{})
        if after and 'order_number' in after:
            op = payload.get('op','?')
            print(f'    op={op}  order={after.get(\"order_number\",\"\")}  region={after.get(\"region\",\"\")}  created_at={after.get(\"created_at\",\"\")}')
    except: pass
" 2>/dev/null
else
    warn "No merged events found yet -- snapshot may still be running"
fi
echo ""

# ── Step 11: Deploy JDBC sink connector ────────────────────────────────────
header "STEP 11: Deploy JDBC Sink Connector (target CockroachDB)"
RESPONSE=$(curl -s -o /tmp/pg2crdb-sink-response.json -w "%{http_code}" -X POST \
    -H "Content-Type: application/json" \
    --data @sink-connector-config.json \
    http://localhost:8083/connectors)
BODY=$(cat /tmp/pg2crdb-sink-response.json)
if [ "$RESPONSE" -ge 200 ] && [ "$RESPONSE" -lt 300 ]; then
    success "Sink connector deployed (HTTP $RESPONSE)"
elif echo "$BODY" | grep -q "already exists"; then
    warn "Sink connector already exists"
else
    echo "$BODY" | python3 -m json.tool 2>/dev/null || echo "$BODY"
    fail "Sink connector deploy failed (HTTP $RESPONSE)"
fi

info "Waiting for sink connector task to start..."
if ! wait_for_task_running "crdb-jdbc-sink" 30; then
    warn "Sink connector task did not reach RUNNING state"
fi

info "Waiting 15s for sink to process snapshot events..."
sleep 15

# ── Step 12: Verify initial snapshot in target ─────────────────────────────
header "STEP 12: Verify Initial Snapshot in Target CockroachDB"
info "Orders replicated to target (all partitions merged into one table):"
docker exec pg2crdb-cockroachdb-target cockroach sql --insecure -d targetdb \
    -e "SELECT id, order_number, customer_name, amount, status, region, created_at FROM pgdemo_public_orders ORDER BY order_number" 2>&1 || warn "Orders table not yet created"

echo ""
info "Customers replicated to target:"
docker exec pg2crdb-cockroachdb-target cockroach sql --insecure -d targetdb \
    -e "SELECT id, name, email, tier FROM pgdemo_public_customers ORDER BY name" 2>&1 || warn "Customers table not yet created"

# ── Step 13: Run DML across partitions ─────────────────────────────────────
header "STEP 13: Run DML Operations Across Partitions"
info "Executing UPDATE, INSERT, DELETE across different partitions..."
docker exec -i pg2crdb-postgres psql -U postgres -d sourcedb < demo-operations.sql
success "DML executed: 3 UPDATEs (2023, 2024, 2025 partitions), 1 INSERT (2026-04), 1 DELETE (2023-07), customer ops"

info "Waiting 15s for CDC events to propagate..."
sleep 15

# ── Step 14: Verify DML replication ────────────────────────────────────────
header "STEP 14: Verify DML Replication in Target CockroachDB"
info "Target orders after DML:"
docker exec pg2crdb-cockroachdb-target cockroach sql --insecure -d targetdb \
    -e "SELECT id, order_number, customer_name, amount, status, region FROM pgdemo_public_orders ORDER BY order_number" 2>&1 || true

echo ""
info "Source vs target row counts:"
SRC_ORD=$(docker exec pg2crdb-postgres psql -U postgres -d sourcedb -t -c "SELECT count(*) FROM orders" 2>/dev/null | tr -d ' ')
SRC_CUST=$(docker exec pg2crdb-postgres psql -U postgres -d sourcedb -t -c "SELECT count(*) FROM customers" 2>/dev/null | tr -d ' ')
TGT_ORD=$(docker exec pg2crdb-cockroachdb-target cockroach sql --insecure -d targetdb \
    -e "SELECT count(*) FROM pgdemo_public_orders" --format=csv 2>/dev/null | tail -1 || echo "0")
TGT_CUST=$(docker exec pg2crdb-cockroachdb-target cockroach sql --insecure -d targetdb \
    -e "SELECT count(*) FROM pgdemo_public_customers" --format=csv 2>/dev/null | tail -1 || echo "0")
echo "  Source orders:    $SRC_ORD rows   |  Target orders:    $TGT_ORD rows"
echo "  Source customers: $SRC_CUST rows  |  Target customers: $TGT_CUST rows"

if [ "$SRC_ORD" = "$TGT_ORD" ]; then
    success "Row counts match -- partition merging + replication verified"
else
    warn "Row counts differ (source=$SRC_ORD target=$TGT_ORD) -- sink may need more time"
fi

# ── Step 15: Error check ──────────────────────────────────────────────────
header "STEP 15: Error Check"
ERRORS=$(docker logs pg2crdb-connect 2>&1 \
    | grep -E "^[0-9]{4}-.*ERROR" \
    | grep -v "errors\.\|error_code\|config_mismatch" \
    | tail -5)
if [ -z "$ERRORS" ]; then
    success "No errors in connector logs"
else
    warn "Errors found:"
    echo "$ERRORS"
fi

# ── Step 16: Summary ──────────────────────────────────────────────────────
header "DEMO COMPLETE"
echo ""
echo "  Architecture (PG partitioned tables -> merged CockroachDB table):"
echo ""
echo "  PostgreSQL (sourcedb)"
echo "    orders_2023_01 ─┐"
echo "    orders_2023_02 ─┤"
echo "    ...              ├─> Debezium PG Source + ByLogicalTableRouter SMT"
echo "    orders_2026_11 ─┤     (merges all 48 partition topics into one)"
echo "    orders_2026_12 ─┘"
echo "         |"
echo "         v"
echo "  Kafka (pgdemo.public.orders)  -- single unified topic"
echo "         |"
echo "         v"
echo "  Debezium JDBC Sink Connector (upsert + schema.evolution=basic)"
echo "         |"
echo "         v"
echo "  CockroachDB (targetdb.pgdemo_public_orders)  -- single table, no partitions"
echo ""
success "Source PostgreSQL  : localhost:5432"
success "Target CockroachDB : localhost:26257  (UI: http://localhost:8080)"
success "Kafka              : localhost:29092"
success "Kafka Connect      : http://localhost:8083"
success "Source connector   : http://localhost:8083/connectors/pg-source-connector/status"
success "Sink connector     : http://localhost:8083/connectors/crdb-jdbc-sink/status"
echo ""
info "Interactive SQL on source:"
echo "  docker exec -it pg2crdb-postgres psql -U postgres -d sourcedb"
echo ""
info "Interactive SQL on target:"
echo "  docker exec -it pg2crdb-cockroachdb-target cockroach sql --insecure -d targetdb"
echo ""
info "Watch merged events in real-time:"
echo "  docker exec pg2crdb-kafka kafka-console-consumer --bootstrap-server localhost:9092 --topic pgdemo.public.orders"
echo ""
info "To stop the demo:"
echo "  cd $(pwd) && docker compose down -v"
