#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONNECTOR_PROJECT="${SCRIPT_DIR}/../../debezium-connector-cockroachdb"
CONNECTOR_VERSION="${CONNECTOR_VERSION:-3.7.0.Alpha2}"
JDBC_SINK_VERSION="${JDBC_SINK_VERSION:-3.7.0.Alpha2}"
SKIP_BUILD="${SKIP_BUILD:-false}"
BUILD_FROM_SOURCE="${BUILD_FROM_SOURCE:-false}"

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

target_sql() {
    docker exec demo-cockroachdb-target cockroach sql --insecure -d targetdb --format=csv -e "$1" 2>/dev/null | tail -1
}

# Polls a single-value SQL query on the target until it returns the expected value.
wait_for_target() {
    local query="$1" expected="$2" max="$3" label="$4"
    for i in $(seq 1 "$max"); do
        local actual=$(target_sql "$query")
        if [ "$actual" = "$expected" ]; then
            success "$label: $actual"
            return 0
        fi
        echo -n "."
        sleep 2
    done
    echo ""
    fail "$label: expected $expected, got $(target_sql "$query")"
}

# ── Step 1: Obtain CockroachDB connector plugin ─────────────────────────────
header "STEP 1: Obtain CockroachDB Connector Plugin"
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
    cd "$SCRIPT_DIR"
    rm -rf connect-plugins
    mkdir -p connect-plugins
    unzip -q -o "$CONNECTOR_PROJECT/$PLUGIN_ZIP" -d connect-plugins/
    success "Plugin built from source and extracted to connect-plugins/"
else
    MAVEN_BASE="https://repo1.maven.org/maven2/io/debezium/debezium-connector-cockroachdb"
    PLUGIN_ZIP_NAME="debezium-connector-cockroachdb-${CONNECTOR_VERSION}-plugin.zip"
    if [ -d "$SCRIPT_DIR/connect-plugins/debezium-connector-cockroachdb" ] \
        && [ -n "$(ls "$SCRIPT_DIR/connect-plugins/debezium-connector-cockroachdb/"*.jar 2>/dev/null)" ]; then
        success "Plugin already present in connect-plugins/"
    else
        info "Downloading connector plugin ${CONNECTOR_VERSION} from Maven Central..."
        cd "$SCRIPT_DIR"
        rm -rf connect-plugins
        mkdir -p connect-plugins
        curl -fSL -o "/tmp/${PLUGIN_ZIP_NAME}" "${MAVEN_BASE}/${CONNECTOR_VERSION}/${PLUGIN_ZIP_NAME}" \
            || fail "Download failed; try BUILD_FROM_SOURCE=true"
        unzip -q -o "/tmp/${PLUGIN_ZIP_NAME}" -d connect-plugins/
        rm -f "/tmp/${PLUGIN_ZIP_NAME}"
        success "Plugin ${CONNECTOR_VERSION} extracted to connect-plugins/"
    fi
fi
cd "$SCRIPT_DIR"

# ── Step 2: Obtain JDBC sink plugin ─────────────────────────────────────────
header "STEP 2: Obtain JDBC Sink Plugin (${JDBC_SINK_VERSION})"
if [ -d "$SCRIPT_DIR/connect-plugins-jdbc/debezium-connector-jdbc" ] \
    && [ -n "$(ls "$SCRIPT_DIR/connect-plugins-jdbc/debezium-connector-jdbc/"*.jar 2>/dev/null)" ]; then
    success "JDBC sink plugin already present in connect-plugins-jdbc/"
else
    JDBC_MAVEN_BASE="https://repo1.maven.org/maven2/io/debezium/debezium-connector-jdbc"
    JDBC_ZIP_NAME="debezium-connector-jdbc-${JDBC_SINK_VERSION}-plugin.zip"
    info "Downloading JDBC sink plugin ${JDBC_SINK_VERSION} from Maven Central..."
    rm -rf connect-plugins-jdbc
    mkdir -p connect-plugins-jdbc
    curl -fSL -o "/tmp/${JDBC_ZIP_NAME}" "${JDBC_MAVEN_BASE}/${JDBC_SINK_VERSION}/${JDBC_ZIP_NAME}" \
        || fail "JDBC sink plugin download failed"
    unzip -q -o "/tmp/${JDBC_ZIP_NAME}" -d connect-plugins-jdbc/
    rm -f "/tmp/${JDBC_ZIP_NAME}"
    success "JDBC sink plugin ${JDBC_SINK_VERSION} extracted to connect-plugins-jdbc/"
fi

# ── Step 3: Start infrastructure ────────────────────────────────────────────
header "STEP 3: Start Docker Compose (CockroachDB x2 + Redpanda + Connect)"
docker compose down -v --remove-orphans 2>/dev/null || true
docker compose up -d
success "Containers starting..."

# ── Step 4: Wait for CockroachDB and Redpanda ───────────────────────────────
header "STEP 4: Wait for CockroachDB (source + target) and Redpanda"
for c in demo-cockroachdb demo-cockroachdb-target; do
    for i in $(seq 1 30); do
        if docker exec $c cockroach sql --insecure -e "SELECT 1" >/dev/null 2>&1; then
            success "$c is ready"
            break
        fi
        echo -n "."
        sleep 2
    done
    docker exec $c cockroach sql --insecure -e "SELECT 1" >/dev/null 2>&1 || fail "$c did not start"
done

for i in $(seq 1 30); do
    if docker exec demo-redpanda rpk cluster health 2>/dev/null | grep -q "Healthy:.*true"; then
        success "Redpanda is healthy ($(docker exec demo-redpanda rpk version 2>/dev/null | head -1))"
        break
    fi
    echo -n "."
    sleep 2
done
docker exec demo-redpanda rpk cluster health 2>/dev/null | grep -q "Healthy:.*true" || fail "Redpanda did not become healthy"

# ── Step 5: Setup databases ─────────────────────────────────────────────────
header "STEP 5: Setup Databases"
docker exec -i demo-cockroachdb cockroach sql --insecure < setup-cockroachdb.sql
docker exec -i demo-cockroachdb-target cockroach sql --insecure < setup-target-cockroachdb.sql
success "Source demodb (customers + orders) and target targetdb configured"

# ── Step 6: Wait for Kafka Connect and plugins ──────────────────────────────
header "STEP 6: Wait for Kafka Connect (running against Redpanda)"
wait_for_url "http://localhost:8083/" 60 || fail "Kafka Connect did not start within 120s"
if ! wait_for_plugin "CockroachDBConnector" 60 || ! wait_for_plugin "JdbcSinkConnector" 60; then
    fail "Connector plugins did not register within 120s"
fi
echo ""
success "Kafka Connect is up with Redpanda as its backing broker (storage topics live in Redpanda)"

# ── Step 7: Deploy source connector ─────────────────────────────────────────
header "STEP 7: Deploy CockroachDB Source Connector (changefeed INTO Redpanda)"
HTTP=$(curl -s -o /tmp/rp-demo-src.json -w '%{http_code}' -X POST -H "Content-Type: application/json" \
    --data @connector-config.json http://localhost:8083/connectors)
{ [ "$HTTP" = "201" ] || [ "$HTTP" = "409" ]; } || { cat /tmp/rp-demo-src.json; fail "Source deploy returned HTTP $HTTP"; }
wait_for_task_running "debezium-cockroachdb-source" 30 || fail "Source connector task did not start"
success "Source connector task is RUNNING; CockroachDB's changefeed produces into Redpanda"

# ── Step 8: Insert data ─────────────────────────────────────────────────────
header "STEP 8: Insert Customers and Orders"
docker exec -i demo-cockroachdb cockroach sql --insecure -d demodb -e "
INSERT INTO customers (id, name, email, tier) VALUES
    (1, 'Alice Johnson', 'alice@example.com', 'standard'),
    (2, 'Bob Smith', 'bob@example.com', 'standard'),
    (3, 'Carol Williams', 'carol@example.com', 'premium');
INSERT INTO orders (id, customer_id, amount, status) VALUES
    (101, 1, 199.99, 'new'),
    (102, 1, 75.50, 'new'),
    (103, 2, 320.00, 'new'),
    (104, 3, 42.25, 'new');
"
success "3 customers and 4 orders inserted"

# ── Step 9: Deploy JDBC sink ────────────────────────────────────────────────
header "STEP 9: Deploy Debezium JDBC Sink (consumes from Redpanda, writes target CRDB)"
HTTP=$(curl -s -o /tmp/rp-demo-sink.json -w '%{http_code}' -X POST -H "Content-Type: application/json" \
    --data @sink-connector-config.json http://localhost:8083/connectors)
{ [ "$HTTP" = "201" ] || [ "$HTTP" = "409" ]; } || { cat /tmp/rp-demo-sink.json; fail "Sink deploy returned HTTP $HTTP"; }
wait_for_task_running "debezium-jdbc-sink" 30 || fail "JDBC sink task did not start"
success "JDBC sink task is RUNNING"

if docker logs demo-connect 2>&1 | grep -qi "CockroachDBDatabaseDialect"; then
    success "Sink resolved the CockroachDB dialect automatically"
fi
if docker logs demo-connect 2>&1 | grep -q "Using UnnestRecordWriter for UNNEST optimization"; then
    success "Sink engaged set-based UNNEST batch writes"
fi

# ── Step 10: Verify initial replication ─────────────────────────────────────
header "STEP 10: Verify Initial Replication (source -> Redpanda -> target)"
wait_for_target "SELECT count(*) FROM crdb_public_customers" "3" 45 "Target customers"
wait_for_target "SELECT count(*) FROM crdb_public_orders" "4" 30 "Target orders"

# ── Step 11: Verify UPDATE propagation ──────────────────────────────────────
header "STEP 11: UPDATE Propagation"
docker exec -i demo-cockroachdb cockroach sql --insecure -d demodb -e "
UPDATE orders SET status = 'shipped' WHERE id = 101;
UPDATE customers SET tier = 'gold' WHERE id = 2;
"
wait_for_target "SELECT status FROM crdb_public_orders WHERE id = 101" "shipped" 30 "Order 101 status"
wait_for_target "SELECT tier FROM crdb_public_customers WHERE id = 2" "gold" 30 "Bob's tier"

# ── Step 12: Verify DELETE propagation ──────────────────────────────────────
header "STEP 12: DELETE Propagation"
docker exec -i demo-cockroachdb cockroach sql --insecure -d demodb -e "
DELETE FROM orders WHERE id = 104;
DELETE FROM customers WHERE id = 3;
"
wait_for_target "SELECT count(*) FROM crdb_public_orders" "3" 30 "Target orders after delete"
wait_for_target "SELECT count(*) FROM crdb_public_customers" "2" 30 "Target customers after delete"

# ── Step 13: Show the topics in Redpanda ────────────────────────────────────
header "STEP 13: Topics in Redpanda (rpk)"
TOPICS=$(docker exec demo-redpanda rpk topic list 2>/dev/null | awk '{print $1}' | grep -v "^NAME")
echo "$TOPICS" | sed 's/^/  /'
echo "$TOPICS" | grep -q "crdb.public.customers" || fail "Output topic crdb.public.customers not found in Redpanda"
echo "$TOPICS" | grep -q "crdb.demodb.public.customers" || warn "Intermediate topic not visible via rpk (naming may differ)"
success "Both the changefeed's intermediate topics and the connector's output topics live in Redpanda"

# ── Step 14: Error check ────────────────────────────────────────────────────
header "STEP 14: Error Check"
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

# ── Step 15: Summary ────────────────────────────────────────────────────────
header "DEMO COMPLETE"
echo ""
echo "  CockroachDB (source)"
echo "       |"
echo "       v  [CockroachDB enriched changefeed, kafka:// sink pointed at Redpanda]"
echo "  Redpanda (intermediate topics)"
echo "       |"
echo "       v  [Debezium CockroachDB Source Connector on Kafka Connect]"
echo "  Redpanda (crdb.public.customers + crdb.public.orders)"
echo "       |"
echo "       v  [Debezium JDBC Sink, CockroachDB dialect + UNNEST]"
echo "  CockroachDB (target)"
echo ""
success "Source CRDB    : localhost:26257  (UI: http://localhost:8080)"
success "Target CRDB    : localhost:26258  (UI: http://localhost:8081)"
success "Redpanda       : localhost:29092 (external listener)"
success "Kafka Connect  : http://localhost:8083"
echo ""
info "Inspect Redpanda:"
echo "  docker exec demo-redpanda rpk topic list"
echo "  docker exec demo-redpanda rpk topic consume crdb.public.orders --num 5"
echo ""
info "To stop the demo:"
echo "  cd $(pwd) && docker compose down -v"
