#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONNECTOR_PROJECT="${SCRIPT_DIR}/../../debezium-connector-cockroachdb"
CONNECTOR_VERSION="${CONNECTOR_VERSION:-3.7.0.Alpha1}"
NEO4J_CONNECTOR_VERSION="${NEO4J_CONNECTOR_VERSION:-5.5.2}"
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

cypher() {
    docker exec demo-neo4j cypher-shell -u neo4j -p demopassword --format plain "$1" 2>/dev/null | tail -1
}

# Polls a single-value cypher query until it returns the expected value.
wait_for_cypher() {
    local query="$1" expected="$2" max="$3" label="$4"
    for i in $(seq 1 "$max"); do
        local actual=$(cypher "$query")
        if [ "$actual" = "$expected" ]; then
            success "$label: $actual"
            return 0
        fi
        echo -n "."
        sleep 2
    done
    echo ""
    fail "$label: expected $expected, got $(cypher "$query")"
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

# ── Step 2: Obtain Neo4j connector plugin ───────────────────────────────────
header "STEP 2: Obtain Neo4j Connector Plugin (${NEO4J_CONNECTOR_VERSION})"
NEO4J_JAR="neo4j-kafka-connect-neo4j-${NEO4J_CONNECTOR_VERSION}.jar"
if [ -f "$SCRIPT_DIR/connect-plugins-neo4j/${NEO4J_JAR}" ]; then
    success "Neo4j connector plugin already present in connect-plugins-neo4j/"
else
    mkdir -p connect-plugins-neo4j
    info "Downloading ${NEO4J_JAR} from GitHub releases..."
    curl -fSL -o "connect-plugins-neo4j/${NEO4J_JAR}" \
        "https://github.com/neo4j/neo4j-kafka-connector/releases/download/${NEO4J_CONNECTOR_VERSION}/${NEO4J_JAR}" \
        || fail "Neo4j connector download failed"
    success "Neo4j connector plugin downloaded"
fi

# ── Step 3: Start infrastructure ────────────────────────────────────────────
header "STEP 3: Start Docker Compose (CockroachDB + Kafka + Connect + Neo4j)"
docker compose down -v --remove-orphans 2>/dev/null || true
docker compose up -d
success "Containers starting..."

# ── Step 4: Wait for CockroachDB and Neo4j ──────────────────────────────────
header "STEP 4: Wait for CockroachDB and Neo4j"
for i in $(seq 1 30); do
    if docker exec demo-cockroachdb cockroach sql --insecure -e "SELECT 1" >/dev/null 2>&1; then
        success "CockroachDB is ready (port 26257)"
        break
    fi
    echo -n "."
    sleep 2
done
docker exec demo-cockroachdb cockroach sql --insecure -e "SELECT 1" >/dev/null 2>&1 || fail "CockroachDB did not start"

for i in $(seq 1 45); do
    if docker exec demo-neo4j cypher-shell -u neo4j -p demopassword "RETURN 1" >/dev/null 2>&1; then
        success "Neo4j is ready (bolt 7687, browser http://localhost:7474)"
        break
    fi
    echo -n "."
    sleep 2
done
docker exec demo-neo4j cypher-shell -u neo4j -p demopassword "RETURN 1" >/dev/null 2>&1 || fail "Neo4j did not start"

# ── Step 5: Setup source database ───────────────────────────────────────────
header "STEP 5: Setup Source Database (demodb: customers + orders)"
docker exec -i demo-cockroachdb cockroach sql --insecure < setup-cockroachdb.sql
success "demodb configured with public.customers and public.orders"

# ── Step 6: Wait for Kafka Connect and plugins ──────────────────────────────
header "STEP 6: Wait for Kafka Connect and Plugin Discovery"
wait_for_url "http://localhost:8083/" 60 || fail "Kafka Connect did not start within 120s"
if ! wait_for_plugin "CockroachDBConnector" 60 || ! wait_for_plugin "Neo4jConnector" 60; then
    fail "Connector plugins did not register within 120s"
fi
echo ""
success "CockroachDB source and Neo4j sink plugins discovered"

# ── Step 7: Deploy source connector ─────────────────────────────────────────
header "STEP 7: Deploy Debezium CockroachDB Source Connector"
HTTP=$(curl -s -o /tmp/neo4j-demo-src.json -w '%{http_code}' -X POST -H "Content-Type: application/json" \
    --data @connector-config.json http://localhost:8083/connectors)
{ [ "$HTTP" = "201" ] || [ "$HTTP" = "409" ]; } || { cat /tmp/neo4j-demo-src.json; fail "Source deploy returned HTTP $HTTP"; }
wait_for_task_running "debezium-cockroachdb-source" 30 || fail "Source connector task did not start"
success "Source connector task is RUNNING"

# ── Step 8: Insert graph data ───────────────────────────────────────────────
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

# ── Step 9: Deploy Neo4j sink connector ─────────────────────────────────────
header "STEP 9: Deploy Neo4j Sink Connector (Cypher strategy per topic)"
HTTP=$(curl -s -o /tmp/neo4j-demo-sink.json -w '%{http_code}' -X POST -H "Content-Type: application/json" \
    --data @neo4j-sink-config.json http://localhost:8083/connectors)
{ [ "$HTTP" = "201" ] || [ "$HTTP" = "409" ]; } || { cat /tmp/neo4j-demo-sink.json; fail "Sink deploy returned HTTP $HTTP"; }
wait_for_task_running "neo4j-sink" 30 || fail "Neo4j sink task did not start"
success "Neo4j sink task is RUNNING"

# ── Step 10: Verify initial graph ───────────────────────────────────────────
header "STEP 10: Verify Initial Graph (nodes + relationships)"
wait_for_cypher "MATCH (c:Customer) RETURN count(c);" "3" 45 "Customer nodes"
wait_for_cypher "MATCH (o:Order) RETURN count(o);" "4" 30 "Order nodes"
wait_for_cypher "MATCH (:Customer)-[r:PLACED]->(:Order) RETURN count(r);" "4" 30 "PLACED relationships"
wait_for_cypher "MATCH (c:Customer {id: 1})-[:PLACED]->(o:Order) RETURN count(o);" "2" 30 "Alice's orders"

# ── Step 11: Verify UPDATE propagation ──────────────────────────────────────
header "STEP 11: UPDATE Propagation (row update becomes property update)"
docker exec -i demo-cockroachdb cockroach sql --insecure -d demodb -e "
UPDATE orders SET status = 'shipped' WHERE id = 101;
UPDATE customers SET tier = 'gold' WHERE id = 2;
"
wait_for_cypher "MATCH (o:Order {id: 101}) RETURN o.status;" "\"shipped\"" 30 "Order 101 status"
wait_for_cypher "MATCH (c:Customer {id: 2}) RETURN c.tier;" "\"gold\"" 30 "Bob's tier"

# ── Step 12: Verify DELETE propagation ──────────────────────────────────────
header "STEP 12: DELETE Propagation (row delete removes node + relationship)"
docker exec -i demo-cockroachdb cockroach sql --insecure -d demodb -e "
DELETE FROM orders WHERE id = 104;
DELETE FROM customers WHERE id = 3;
"
wait_for_cypher "MATCH (o:Order) RETURN count(o);" "3" 30 "Order nodes after delete"
wait_for_cypher "MATCH (:Customer)-[r:PLACED]->(:Order) RETURN count(r);" "3" 30 "PLACED relationships after delete"
wait_for_cypher "MATCH (c:Customer) RETURN count(c);" "2" 30 "Customer nodes after delete"

# ── Step 13: Error check ────────────────────────────────────────────────────
header "STEP 13: Error Check"
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

# ── Step 14: Summary ────────────────────────────────────────────────────────
header "DEMO COMPLETE"
echo ""
echo "  CockroachDB (customers + orders tables)"
echo "       |"
echo "       v  [CockroachDB enriched changefeed]"
echo "  Kafka (per-table intermediate topics)"
echo "       |"
echo "       v  [Debezium CockroachDB Source Connector]"
echo "  Kafka (crdb.public.customers + crdb.public.orders)"
echo "       |"
echo "       v  [Neo4j Kafka Connect Sink, Cypher strategy]"
echo "  Neo4j graph: (:Customer)-[:PLACED]->(:Order)"
echo ""
success "CockroachDB     : localhost:26257  (UI: http://localhost:8080)"
success "Neo4j Browser   : http://localhost:7474  (neo4j/demopassword)"
success "Kafka Connect   : http://localhost:8083"
echo ""
info "Explore the graph:"
echo "  docker exec -it demo-neo4j cypher-shell -u neo4j -p demopassword"
echo "  MATCH (c:Customer)-[r:PLACED]->(o:Order) RETURN c.name, o.id, o.amount, o.status;"
echo ""
info "To stop the demo:"
echo "  cd $(pwd) && docker compose down -v"
