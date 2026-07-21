#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONNECTOR_PROJECT="${SCRIPT_DIR}/../../debezium-connector-cockroachdb"
CONNECTOR_VERSION="${CONNECTOR_VERSION:-3.6.0.Final}"
SKIP_BUILD="${SKIP_BUILD:-false}"
BUILD_FROM_SOURCE="${BUILD_FROM_SOURCE:-false}"

# Optional Prometheus + Grafana observability overlay (observability/). When OBSERVABILITY=true the
# demo also starts the JMX-exporter-enabled Connect image, Prometheus, and Grafana.
OBSERVABILITY="${OBSERVABILITY:-false}"
COMPOSE_FILES="-f docker-compose.yml"
if [ "$OBSERVABILITY" = "true" ]; then
    COMPOSE_FILES="$COMPOSE_FILES -f observability/docker-compose.observability.yml"
fi

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
        if curl -s -o /dev/null -w '' "$url" 2>/dev/null; then
            return 0
        fi
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
        if curl -s http://localhost:8083/connector-plugins 2>/dev/null | grep -q "$plugin"; then
            return 0
        fi
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
        if [ "$state" = "RUNNING" ]; then
            return 0
        elif [ "$state" = "FAILED" ]; then
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

# ── Step 1: Obtain connector plugin ─────────────────────────────────────────
header "STEP 1: Obtain Connector Plugin"
if [ "$SKIP_BUILD" = "true" ] && [ -d "$SCRIPT_DIR/connect-plugins/debezium-connector-cockroachdb" ] \
    && [ -n "$(ls "$SCRIPT_DIR/connect-plugins/debezium-connector-cockroachdb/"*.jar 2>/dev/null)" ]; then
    success "Using existing plugin in connect-plugins/ (SKIP_BUILD=true)"
elif [ "$BUILD_FROM_SOURCE" = "true" ]; then
    if [ ! -d "$CONNECTOR_PROJECT" ]; then
        fail "BUILD_FROM_SOURCE=true but connector project not found at $CONNECTOR_PROJECT"
    fi
    cd "$CONNECTOR_PROJECT"
    info "Building connector from source..."
    ./mvnw clean package -DskipTests -DskipITs -Passembly -q
    PLUGIN_ZIP=$(ls target/debezium-connector-cockroachdb-*-plugin.zip 2>/dev/null | head -1)
    [ -z "$PLUGIN_ZIP" ] && fail "Plugin zip not found after build"
    success "Connector built: $(basename "$PLUGIN_ZIP")"

    header "STEP 2: Prepare Plugin Directory"
    cd "$SCRIPT_DIR"
    rm -rf connect-plugins
    mkdir -p connect-plugins
    unzip -q -o "$CONNECTOR_PROJECT/$PLUGIN_ZIP" -d connect-plugins/
    success "Plugin extracted to connect-plugins/"
else
    MAVEN_BASE="https://repo1.maven.org/maven2/io/debezium/debezium-connector-cockroachdb"
    PLUGIN_ZIP_NAME="debezium-connector-cockroachdb-${CONNECTOR_VERSION}-plugin.zip"
    PLUGIN_URL="${MAVEN_BASE}/${CONNECTOR_VERSION}/${PLUGIN_ZIP_NAME}"

    if [ -d "$SCRIPT_DIR/connect-plugins/debezium-connector-cockroachdb" ] \
        && [ -n "$(ls "$SCRIPT_DIR/connect-plugins/debezium-connector-cockroachdb/"*.jar 2>/dev/null)" ]; then
        success "Plugin already present in connect-plugins/"
        info "To re-download, run: rm -rf connect-plugins && ./run-demo.sh"
    else
        info "Downloading connector plugin ${CONNECTOR_VERSION} from Maven Central..."
        cd "$SCRIPT_DIR"
        rm -rf connect-plugins
        mkdir -p connect-plugins
        if curl -fSL -o "/tmp/${PLUGIN_ZIP_NAME}" "$PLUGIN_URL"; then
            unzip -q -o "/tmp/${PLUGIN_ZIP_NAME}" -d connect-plugins/
            rm -f "/tmp/${PLUGIN_ZIP_NAME}"
            success "Plugin ${CONNECTOR_VERSION} downloaded and extracted to connect-plugins/"
        else
            echo ""
            warn "Download failed. The version ${CONNECTOR_VERSION} may not be published yet."
            info "Options:"
            info "  1. Build from source:  BUILD_FROM_SOURCE=true ./run-demo.sh"
            info "  2. Specify a version:  CONNECTOR_VERSION=3.6.0.Final ./run-demo.sh"
            info "  3. Place jars manually in connect-plugins/debezium-connector-cockroachdb/ and run with SKIP_BUILD=true"
            fail "Cannot proceed without connector plugin"
        fi
    fi
fi

# ── Step 3: Start infrastructure ────────────────────────────────────────────
header "STEP 3: Start Docker Compose (Source CRDB + Target CRDB + Kafka + Connect)"
docker compose $COMPOSE_FILES down -v --remove-orphans 2>/dev/null || true
docker compose $COMPOSE_FILES up -d --build
success "Containers starting..."
if [ "$OBSERVABILITY" = "true" ]; then
    success "Observability overlay enabled (Prometheus + Grafana + JMX exporter)"
fi

# ── Step 4: Wait for Source CockroachDB ─────────────────────────────────────
header "STEP 4: Wait for Source CockroachDB"
for i in $(seq 1 30); do
    if docker exec demo-cockroachdb cockroach sql --insecure -e "SELECT 1" >/dev/null 2>&1; then
        success "Source CockroachDB is ready (port 26257)"
        break
    fi
    echo -n "."
    sleep 2
done
docker exec demo-cockroachdb cockroach sql --insecure -e "SELECT 1" >/dev/null 2>&1 || fail "Source CockroachDB did not start"

# ── Step 5: Wait for Target CockroachDB ────────────────────────────────────
header "STEP 5: Wait for Target CockroachDB"
for i in $(seq 1 30); do
    if docker exec demo-cockroachdb-target cockroach sql --insecure -e "SELECT 1" >/dev/null 2>&1; then
        success "Target CockroachDB is ready (port 26258)"
        break
    fi
    echo -n "."
    sleep 2
done
docker exec demo-cockroachdb-target cockroach sql --insecure -e "SELECT 1" >/dev/null 2>&1 || fail "Target CockroachDB did not start"

# ── Step 6: Setup source database ──────────────────────────────────────────
header "STEP 6: Setup Source Database (demodb: orders + customers + inventory.warehouse_items)"
docker exec -i demo-cockroachdb cockroach sql --insecure < setup-cockroachdb.sql
success "Source DB configured: demodb with public.orders, public.customers, and inventory.warehouse_items (3 rows each)"

# ── Step 7: Setup target database ──────────────────────────────────────────
header "STEP 7: Setup Target Database (targetdb)"
docker exec -i demo-cockroachdb-target cockroach sql --insecure < setup-target-cockroachdb.sql
success "Target DB configured: targetdb (empty, table will be auto-created by sink)"

# ── Step 8: Wait for Kafka Connect ─────────────────────────────────────────
header "STEP 8: Wait for Kafka Connect"
if ! wait_for_url "http://localhost:8083/" 60; then
    echo ""
    fail "Kafka Connect did not start within 120s"
fi
# Wait for plugin discovery to finish, not just the REST port to open.
if ! wait_for_plugin "CockroachDBConnector" 60 || ! wait_for_plugin "JdbcSinkConnector" 60; then
    echo ""
    fail "Connector plugins did not register within 120s"
fi
echo ""
success "Kafka Connect is ready"

# ── Step 9: Verify plugins ─────────────────────────────────────────────────
header "STEP 9: Verify Connector Plugins"
info "Waiting for connector plugins to be discovered (Connect REST API can respond before scan completes)..."
PLUGINS=""
for i in $(seq 1 30); do
    PLUGINS=$(curl -s http://localhost:8083/connector-plugins 2>/dev/null || echo "")
    if echo "$PLUGINS" | grep -q "CockroachDBConnector" && echo "$PLUGINS" | grep -q "JdbcSinkConnector"; then
        break
    fi
    echo -n "."
    sleep 2
done
echo ""
echo "$PLUGINS" | python3 -c "
import sys,json
try:
    for p in json.load(sys.stdin):
        c = p['class']
        if 'cockroachdb' in c.lower() or 'jdbc' in c.lower():
            print(f'  {p[\"type\"]:6s}  {c}')
except Exception:
    pass
" 2>/dev/null || true
echo "$PLUGINS" | grep -q "CockroachDBConnector" || fail "CockroachDB source connector not found after waiting 60s"
echo "$PLUGINS" | grep -q "JdbcSinkConnector" || fail "JDBC sink connector not found after waiting 60s"
success "Both source and sink connector plugins discovered"

# ── Step 10: Deploy source connector ───────────────────────────────────────
header "STEP 10: Deploy Debezium CockroachDB Source Connector"
RESPONSE=$(curl -s -o /tmp/demo-src-response.json -w "%{http_code}" -X POST \
    -H "Content-Type: application/json" \
    --data @connector-config.json \
    http://localhost:8083/connectors)
BODY=$(cat /tmp/demo-src-response.json)
if [ "$RESPONSE" -ge 200 ] && [ "$RESPONSE" -lt 300 ]; then
    success "Source connector deployed (HTTP $RESPONSE)"
elif echo "$BODY" | grep -q "already exists"; then
    warn "Source connector already exists"
else
    echo "$BODY" | python3 -m json.tool 2>/dev/null || echo "$BODY"
    fail "Source connector deploy failed (HTTP $RESPONSE)"
fi

info "Waiting for source connector task to start..."
if ! wait_for_task_running "debezium-cockroachdb-source" 30; then
    fail "Source connector task did not start"
fi
success "Source connector task is RUNNING"

# ── Step 11: Wait for changefeed + insert initial data ─────────────────────
header "STEP 11: Insert Initial Data and Wait for Changefeed Events"
info "Inserting initial data (changefeed uses cursor=now, so we insert after changefeed creation)..."
docker exec -i demo-cockroachdb cockroach sql --insecure -d demodb -e "
INSERT INTO orders (id, order_number, customer_name, email, amount, status, created_at) VALUES
(gen_random_uuid(), 'ORD-LIVE-001', 'Alice Johnson', 'alice@example.com', 199.99, 'new', now()),
(gen_random_uuid(), 'ORD-LIVE-002', 'Bob Smith', 'bob@example.com', 75.50, 'pending', now()),
(gen_random_uuid(), 'ORD-LIVE-003', 'Carol Williams', 'carol@example.com', 320.00, 'confirmed', now());
" 2>&1
success "3 rows inserted after changefeed creation"
info "Waiting 15s for events to flow through source connector..."
sleep 15

# ── Step 11b: Changefeed splitting demo (debezium/dbz#2014) ──────────────────
header "STEP 11b: Changefeed Splitting (debezium/dbz#2014)"
info "connector-config.json sets cockroachdb.changefeed.max.tables.per.changefeed=2,"
info "so the 4 captured tables are split across 2 changefeeds to avoid per-table coupling."
CHANGEFEED_COUNT=$(docker exec demo-cockroachdb cockroach sql --insecure -d demodb \
    --format=csv -e "SELECT count(*) FROM [SHOW CHANGEFEED JOBS] WHERE status = 'running'" 2>/dev/null | tail -1 | tr -d '[:space:]')
info "Running changefeed jobs: ${CHANGEFEED_COUNT}"
if [ "$CHANGEFEED_COUNT" = "2" ]; then
    success "Tables split into 2 changefeeds (max 2 tables each) -- coupling avoided"
else
    warn "Expected 2 running changefeeds, found ${CHANGEFEED_COUNT} (set max.tables.per.changefeed=0 for a single changefeed)"
fi

# ── Step 12: Deploy JDBC sink connector ────────────────────────────────────
header "STEP 12: Deploy Debezium JDBC Sink Connector (target CRDB)"
RESPONSE=$(curl -s -o /tmp/demo-sink-response.json -w "%{http_code}" -X POST \
    -H "Content-Type: application/json" \
    --data @sink-connector-config.json \
    http://localhost:8083/connectors)
BODY=$(cat /tmp/demo-sink-response.json)
if [ "$RESPONSE" -ge 200 ] && [ "$RESPONSE" -lt 300 ]; then
    success "Sink connector deployed (HTTP $RESPONSE)"
elif echo "$BODY" | grep -q "already exists"; then
    warn "Sink connector already exists"
else
    echo "$BODY" | python3 -m json.tool 2>/dev/null || echo "$BODY"
    fail "Sink connector deploy failed (HTTP $RESPONSE)"
fi

info "Waiting for sink connector task to start..."
if ! wait_for_task_running "debezium-jdbc-sink" 30; then
    warn "Sink connector task did not reach RUNNING state -- check logs below"
fi

# ── Step 13: Run DML operations ────────────────────────────────────────────
header "STEP 13: Run DML Operations on Source CRDB"
info "Executing INSERT, UPDATE, DELETE on source..."
docker exec -i demo-cockroachdb cockroach sql --insecure < demo-operations.sql
success "DML operations executed: 2 order UPDATEs, 1 order DELETE, 1 customer UPDATE, 1 customer INSERT"

info "Waiting 15s for events to propagate through the full pipeline..."
sleep 15

# ── Step 14: Schema Evolution Demo ─────────────────────────────────────────
header "STEP 14: Schema Evolution Demo (ALTER TABLE ADD COLUMN -- no restart)"
info "Adding 'priority' column to orders table..."
docker exec -i demo-cockroachdb cockroach sql --insecure < demo-schema-evolution.sql
success "Schema evolution SQL executed: ADD COLUMN, INSERT with new column, UPDATE existing row"

info "Waiting 20s for CockroachDB backfill and connector schema detection..."
sleep 20

info "Checking if new 'priority' field appears in Kafka events..."
SCHEMA_EVENTS=$(docker exec demo-kafka kafka-console-consumer \
    --bootstrap-server localhost:9092 \
    --topic crdb.public.orders \
    --from-beginning \
    --max-messages 30 \
    --timeout-ms 15000 2>/dev/null || true)

if echo "$SCHEMA_EVENTS" | grep -q '"priority"'; then
    success "Schema evolution detected: 'priority' field present in change events"
    echo "$SCHEMA_EVENTS" | python3 -c "
import sys,json
for line in sys.stdin:
    line=line.strip()
    if not line: continue
    try:
        d=json.loads(line)
        after = d.get('payload',{}).get('after',{})
        if after and 'priority' in after:
            op = d['payload']['op']
            print(f'    op={op}  order={after.get(\"order_number\",\"\")}  priority={after.get(\"priority\",\"\")}')
    except: pass
" 2>/dev/null
else
    warn "Priority field not yet visible (backfill may still be in progress)"
fi

info "Checking if the NOT NULL JSONB 'audit' field appears in Kafka events (debezium/dbz#2253)..."
if echo "$SCHEMA_EVENTS" | grep -q '"audit"'; then
    success "NOT NULL JSONB column detected: 'audit' field present in change events"
else
    warn "Audit field not yet visible (backfill may still be in progress)"
fi

info "Checking DECIMAL(28,18) precision passthrough (debezium/dbz#2256)..."
if echo "$SCHEMA_EVENTS" | grep -q '9999999999.999999999'; then
    success "High-precision DECIMAL preserved: precise_qty carries all 19 significant digits"
else
    warn "Full-precision decimal not found in sampled events"
fi
echo ""

# ── Step 15: Incremental Snapshot Demo ──────────────────────────────────────
header "STEP 15: Incremental Snapshot Demo (signal-based re-snapshot -- no restart)"
info "Triggering incremental snapshot of orders table via signaling table..."
docker exec -i demo-cockroachdb cockroach sql --insecure < demo-incremental-snapshot.sql
success "Incremental snapshot signal inserted into debezium_signal table"

info "Waiting 20s for incremental snapshot to complete..."
sleep 20

info "Checking for snapshot records (op=r) in Kafka events..."
SNAP_EVENTS=$(docker exec demo-kafka kafka-console-consumer \
    --bootstrap-server localhost:9092 \
    --topic crdb.public.orders \
    --from-beginning \
    --max-messages 50 \
    --timeout-ms 15000 2>/dev/null || true)

SNAP_COUNT=$(echo "$SNAP_EVENTS" | python3 -c "
import sys,json
count=0
for line in sys.stdin:
    line=line.strip()
    if not line: continue
    try:
        d=json.loads(line)
        payload = d.get('payload', d)
        if payload.get('op') == 'r':
            count += 1
    except: pass
print(count)
" 2>/dev/null || echo "0")

if [ "$SNAP_COUNT" -gt 0 ]; then
    success "Incremental snapshot complete: $SNAP_COUNT snapshot records (op=r) emitted"
    echo "$SNAP_EVENTS" | python3 -c "
import sys,json
for line in sys.stdin:
    line=line.strip()
    if not line: continue
    try:
        d=json.loads(line)
        payload = d.get('payload', d)
        if payload.get('op') == 'r':
            after = payload.get('after',{})
            print(f'    op=r  order={after.get(\"order_number\",\"\")}  amount={after.get(\"amount\",\"\")}  status={after.get(\"status\",\"\")}')
    except: pass
" 2>/dev/null
else
    warn "No snapshot records found yet (incremental snapshot may still be running)"
fi
echo ""

# ── Step 16: Show debug logs from source connector ─────────────────────────
header "STEP 16: Source Connector Debug Logs (event processing + schema evolution)"
echo ""
docker logs demo-connect 2>&1 \
    | grep -E "CockroachDB.*Registered table|CockroachDB.*Consuming from|CockroachDB.*changefeed|CockroachDB.*Dispatching|CockroachDB.*offset|CockroachDB.*Snapshot|CockroachDB.*dispatch|Schema change detected|Schema refreshed" \
    | tail -20
echo ""

# ── Step 17: Show debug logs from sink connector ───────────────────────────
header "STEP 17: JDBC Sink Connector Debug Logs (writing to target)"
echo ""
docker logs demo-connect 2>&1 \
    | grep -iE "Flushing records|CREATE TABLE|ALTER TABLE|upsert|Skipping tombstone|Using dialect|Database version|orders|customers" \
    | tail -15
echo ""

# ── Step 18: Check for errors ──────────────────────────────────────────────
header "STEP 18: Error Check"
ERRORS=$(docker logs demo-connect 2>&1 \
    | grep -E "^[0-9]{4}-.*ERROR" \
    | grep -v "errors\.\|error_code\|config_mismatch" \
    | tail -5)
if [ -z "$ERRORS" ]; then
    success "No errors in connector logs"
else
    warn "Errors found:"
    echo "$ERRORS"
fi

# ── Step 19: Kafka topics ──────────────────────────────────────────────────
header "STEP 19: Kafka Topics"
docker exec demo-kafka kafka-topics --bootstrap-server localhost:9092 --list 2>/dev/null \
    | grep -v "^_\|connect-\|demo-connect" | sort

# ── Step 20: Consume Debezium events from output topic ─────────────────────
header "STEP 20: Debezium Change Events (orders + customers topics)"
for TOPIC in crdb.public.orders crdb.public.customers; do
    info "Topic: $TOPIC"
    EVENTS=$(docker exec demo-kafka kafka-console-consumer \
        --bootstrap-server localhost:9092 \
        --topic "$TOPIC" \
        --from-beginning \
        --max-messages 20 \
        --timeout-ms 10000 2>/dev/null || true)

    if [ -n "$EVENTS" ]; then
        EVENT_COUNT=$(echo "$EVENTS" | wc -l | tr -d ' ')
        success "  $EVENT_COUNT events on $TOPIC"
        echo "$EVENTS" | python3 -c "
import sys,json
for line in sys.stdin:
    line=line.strip()
    if not line: continue
    try:
        d=json.loads(line)
        payload = d.get('payload', d)
        op = payload.get('op','?')
        after = payload.get('after',{})
        if after:
            name = after.get('order_number', after.get('name',''))
            print(f'    op={op}  name={name}')
    except: pass
" 2>/dev/null
    else
        warn "  No events on $TOPIC"
    fi
    echo ""
done

# ── Step 20b: Multi-schema regression (debezium/dbz#1973) ──────────────────
header "STEP 20b: Multi-Schema Regression (debezium/dbz#1973)"
info "Verifying that inventory.warehouse_items (non-public schema) is streamed end-to-end..."
docker exec -i demo-cockroachdb cockroach sql --insecure -d demodb -e "
INSERT INTO inventory.warehouse_items (sku, description, quantity) VALUES
    (2001, 'noise-cancelling earbuds', 25),
    (2002, 'portable monitor', 9);
UPDATE inventory.warehouse_items SET quantity = 50 WHERE sku = 1001;
" 2>&1
sleep 10

INV_TOPIC="crdb.inventory.warehouse_items"
INV_EVENTS=$(docker exec demo-kafka kafka-console-consumer \
    --bootstrap-server localhost:9092 \
    --topic "$INV_TOPIC" \
    --from-beginning \
    --max-messages 20 \
    --timeout-ms 10000 2>/dev/null || true)

if [ -z "$INV_EVENTS" ]; then
    fail "No events on $INV_TOPIC -- non-public schema table was dropped by discovery (dbz#1973 regression)"
fi

INV_COUNT=$(echo "$INV_EVENTS" | grep -c '^{' || true)
success "$INV_TOPIC streamed $INV_COUNT events -- non-public schema is honored"
echo "$INV_EVENTS" | python3 -c "
import sys,json
for line in sys.stdin:
    line=line.strip()
    if not line: continue
    try:
        d=json.loads(line)
        payload = d.get('payload', d)
        op = payload.get('op','?')
        after = payload.get('after') or {}
        sku = after.get('sku','?')
        desc = after.get('description','')
        qty = after.get('quantity','')
        print(f'    op={op}  sku={sku}  description={desc}  quantity={qty}')
    except: pass
" 2>/dev/null
echo ""

# ── Step 21: Verify data in target CockroachDB ────────────────────────────
header "STEP 21: Verify Data in Target CockroachDB (CRDB->Kafka->CRDB round-trip)"
echo ""
info "Querying target CRDB -- orders (crdb_public_orders):"
echo ""
TARGET_ORDERS=$(docker exec demo-cockroachdb-target cockroach sql --insecure -d targetdb \
    -e "SELECT id, order_number, customer_name, amount, status FROM crdb_public_orders ORDER BY order_number LIMIT 10" 2>&1 || echo "TABLE_NOT_FOUND")

if echo "$TARGET_ORDERS" | grep -q "does not exist\|TABLE_NOT_FOUND"; then
    warn "Orders table not yet created in target -- sink may need more time"
else
    echo "$TARGET_ORDERS"
fi

echo ""
info "Querying target CRDB -- customers (crdb_public_customers):"
echo ""
TARGET_CUSTOMERS=$(docker exec demo-cockroachdb-target cockroach sql --insecure -d targetdb \
    -e "SELECT id, name, email, tier FROM crdb_public_customers ORDER BY name LIMIT 10" 2>&1 || echo "TABLE_NOT_FOUND")

if echo "$TARGET_CUSTOMERS" | grep -q "does not exist\|TABLE_NOT_FOUND"; then
    warn "Customers table not yet created in target -- sink may need more time"
else
    echo "$TARGET_CUSTOMERS"
fi

echo ""
info "Comparing source vs target row counts:"
SRC_ORD=$(docker exec demo-cockroachdb cockroach sql --insecure -d demodb \
    -e "SELECT count(*) FROM orders" --format=csv 2>/dev/null | tail -1)
SRC_CUST=$(docker exec demo-cockroachdb cockroach sql --insecure -d demodb \
    -e "SELECT count(*) FROM customers" --format=csv 2>/dev/null | tail -1)
TGT_ORD=$(docker exec demo-cockroachdb-target cockroach sql --insecure -d targetdb \
    -e "SELECT count(*) FROM crdb_public_orders" --format=csv 2>/dev/null | tail -1 || echo "0")
TGT_CUST=$(docker exec demo-cockroachdb-target cockroach sql --insecure -d targetdb \
    -e "SELECT count(*) FROM crdb_public_customers" --format=csv 2>/dev/null | tail -1 || echo "0")
echo "  Source orders:    $SRC_ORD rows   |  Target orders:    $TGT_ORD rows"
echo "  Source customers: $SRC_CUST rows   |  Target customers: $TGT_CUST rows"

# ── Step 21c: Restart resume (debezium/dbz#2154) ─────────────────────────────
header "STEP 21c: Restart Resume (debezium/dbz#2154 -- no replay on restart)"

get_end_offset() {
    docker exec demo-kafka kafka-run-class kafka.tools.GetOffsetShell \
        --broker-list localhost:9092 --topic "$1" 2>/dev/null | awk -F: '{s+=$3} END{print s+0}'
}

OUTPUT_TOPIC="crdb.public.orders"
RESUME_BEFORE=$(get_end_offset "$OUTPUT_TOPIC")
info "Output topic $OUTPUT_TOPIC end offset before restart: $RESUME_BEFORE"
info "Restarting the source connector with no new data..."
curl -s -X POST "http://localhost:8083/connectors/debezium-cockroachdb-source/restart?includeTasks=true&onlyFailed=false" -o /dev/null
sleep 45
RESUME_AFTER=$(get_end_offset "$OUTPUT_TOPIC")
info "Output topic $OUTPUT_TOPIC end offset after restart:  $RESUME_AFTER"
# With no new data, a connector that resumes from its persisted offset does not re-emit the backlog,
# so the output topic offset is unchanged. The small slack tolerates an occasional heartbeat record.
if [ "$RESUME_AFTER" -le "$((RESUME_BEFORE + 2))" ]; then
    success "Restart did not replay: output offset stayed at ~$RESUME_BEFORE (connector resumed from its persisted position)"
else
    warn "Output topic grew from $RESUME_BEFORE to $RESUME_AFTER after a restart with no new data -- possible replay"
fi

# ── Step 22: Summary ───────────────────────────────────────────────────────
header "DEMO COMPLETE"
echo ""
echo "  Architecture (multi-table changefeed):"
echo "  Source CRDB (demodb: orders + customers)"
echo "       |"
echo "       v  [Single CockroachDB enriched changefeed for ALL tables]"
echo "  Kafka (per-table intermediate topics)"
echo "       |"
echo "       v  [Debezium CockroachDB Source Connector]"
echo "  Kafka (crdb.public.orders + crdb.public.customers)"
echo "       |"
echo "       v  [Debezium JDBC Sink Connector]"
echo "  Target CRDB (targetdb: orders + customers)"
echo ""
success "Source CRDB       : localhost:26257  (UI: http://localhost:8080)"
success "Target CRDB       : localhost:26258  (UI: http://localhost:8081)"
success "Kafka             : localhost:29092"
success "Kafka Connect     : http://localhost:8083"
success "Source connector  : http://localhost:8083/connectors/debezium-cockroachdb-source/status"
success "Sink connector    : http://localhost:8083/connectors/debezium-jdbc-sink/status"
if [ "$OBSERVABILITY" = "true" ]; then
    success "Grafana           : http://localhost:3000  (admin/admin) -> dashboard 'Debezium CockroachDB'"
    success "Prometheus        : http://localhost:9090"
    success "Connector metrics : http://localhost:9404/metrics  (debezium_metrics_*)"
fi
echo ""
if [ "$OBSERVABILITY" = "true" ]; then
    info "Drive continuous change events for the dashboard:"
    echo "  ./observability/continuous-writer.sh"
    echo ""
fi
info "Interactive SQL on source:"
echo "  docker exec -it demo-cockroachdb cockroach sql --insecure -d demodb"
echo ""
info "Interactive SQL on target:"
echo "  docker exec -it demo-cockroachdb-target cockroach sql --insecure -d targetdb"
echo ""
info "Watch events in real-time:"
echo "  docker exec demo-kafka kafka-console-consumer --bootstrap-server localhost:9092 --topic crdb.public.orders"
echo "  docker exec demo-kafka kafka-console-consumer --bootstrap-server localhost:9092 --topic crdb.public.customers"
echo ""
info "View connector debug logs:"
echo "  docker compose logs -f connect 2>&1 | grep -E 'DEBUG|INFO' | grep -iE 'cockroachdb|jdbc'"
echo ""
info "To stop the demo:"
echo "  cd $(pwd) && docker compose $COMPOSE_FILES down -v"
