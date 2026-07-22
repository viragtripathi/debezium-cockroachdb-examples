#!/usr/bin/env bash
# CockroachDB -> Debezium -> Kafka -> Apache Iceberg demo.
# Runs the whole pipeline and verifies the data lands in Iceberg tables.
set -euo pipefail
cd "$(dirname "$0")"
SCRIPT_DIR="$(pwd)"

CONNECTOR_VERSION="${CONNECTOR_VERSION:-3.6.0.Final}"
ICEBERG_SINK_VERSION="${ICEBERG_SINK_VERSION:-1.9.2}"
# The delete step needs the fix from debezium/dbz#2267, which is newer than 3.6.0.Final.
# Until a release carries it, build the connector from the sibling repo when available.
BUILD_FROM_SOURCE="${BUILD_FROM_SOURCE:-auto}"
CONNECTOR_PROJECT="${CONNECTOR_PROJECT:-$SCRIPT_DIR/../../debezium-connector-cockroachdb}"

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[0;33m'; BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
fail()    { echo -e "${RED}[FAIL]${NC} $1"; exit 1; }
header()  { echo -e "\n${BOLD}=== $1 ===${NC}\n"; }

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
                | python3 -c "import sys,json; t=json.load(sys.stdin).get('tasks',[]); print(t[0].get('trace','')[:800] if t else '')" 2>/dev/null)
            echo ""
            fail "Task FAILED: $trace"
        fi
        echo -n "."
        sleep 2
    done
    echo ""
    return 1
}

# ── Step 1: Obtain connector plugins ─────────────────────────────────────────
header "STEP 1: Obtain Connector Plugins"

CRDB_PLUGIN_DIR="$SCRIPT_DIR/connect-plugins/debezium-connector-cockroachdb"
if [ -n "$(ls "$CRDB_PLUGIN_DIR"/*.jar 2>/dev/null)" ]; then
    success "CockroachDB connector already present in connect-plugins/"
elif [ "$BUILD_FROM_SOURCE" != "false" ] && [ -d "$CONNECTOR_PROJECT" ]; then
    info "Building the CockroachDB connector from source ($CONNECTOR_PROJECT)..."
    (cd "$CONNECTOR_PROJECT" && ./mvnw clean package -Passembly -DskipTests -DskipITs -q)
    PLUGIN_ZIP=$(ls "$CONNECTOR_PROJECT"/target/debezium-connector-cockroachdb-*-plugin.zip | head -1)
    [ -n "$PLUGIN_ZIP" ] || fail "Build produced no plugin zip"
    mkdir -p "$SCRIPT_DIR/connect-plugins"
    unzip -q -o "$PLUGIN_ZIP" -d "$SCRIPT_DIR/connect-plugins/"
    success "CockroachDB connector built from source"
else
    MAVEN_BASE="https://repo1.maven.org/maven2/io/debezium/debezium-connector-cockroachdb"
    PLUGIN_ZIP_NAME="debezium-connector-cockroachdb-${CONNECTOR_VERSION}-plugin.zip"
    info "Downloading ${PLUGIN_ZIP_NAME} from Maven Central..."
    curl -fSL -o "/tmp/${PLUGIN_ZIP_NAME}" "${MAVEN_BASE}/${CONNECTOR_VERSION}/${PLUGIN_ZIP_NAME}" \
        || fail "Download failed. Build from source or set CONNECTOR_VERSION."
    mkdir -p "$SCRIPT_DIR/connect-plugins"
    unzip -q -o "/tmp/${PLUGIN_ZIP_NAME}" -d "$SCRIPT_DIR/connect-plugins/"
    success "CockroachDB connector ${CONNECTOR_VERSION} extracted"
    warn "Releases up to 3.6.0.Final do not carry the delete fix (debezium/dbz#2267);"
    warn "the delete step below needs a newer build. See the README's Requirements note."
fi

ICEBERG_PLUGIN_DIR="$SCRIPT_DIR/connect-plugins/iceberg-kafka-connect"
if [ -n "$(ls "$ICEBERG_PLUGIN_DIR"/*.jar 2>/dev/null)" ]; then
    success "Iceberg sink already present in connect-plugins/"
else
    ICEBERG_ZIP="iceberg-iceberg-kafka-connect-${ICEBERG_SINK_VERSION}.zip"
    ICEBERG_URL="https://hub-downloads.confluent.io/api/plugins/iceberg/iceberg-kafka-connect/versions/${ICEBERG_SINK_VERSION}/${ICEBERG_ZIP}"
    info "Downloading Apache Iceberg sink ${ICEBERG_SINK_VERSION} from Confluent Hub (about 150 MB)..."
    curl -fSL -o "/tmp/${ICEBERG_ZIP}" "$ICEBERG_URL" \
        || fail "Download failed. See https://www.confluent.io/hub/iceberg/iceberg-kafka-connect"
    mkdir -p "$ICEBERG_PLUGIN_DIR"
    unzip -q -o "/tmp/${ICEBERG_ZIP}" -d /tmp/iceberg-sink-extract
    cp /tmp/iceberg-sink-extract/iceberg-iceberg-kafka-connect-${ICEBERG_SINK_VERSION}/lib/*.jar "$ICEBERG_PLUGIN_DIR/"
    rm -rf /tmp/iceberg-sink-extract
    success "Apache Iceberg sink ${ICEBERG_SINK_VERSION} extracted"
fi

# ── Step 2: Start the stack ──────────────────────────────────────────────────
header "STEP 2: Start Containers"
docker-compose up -d 2>/dev/null || docker compose up -d
success "Containers starting..."

info "Waiting for CockroachDB..."
for i in $(seq 1 30); do
    if docker exec iceberg-demo-cockroachdb cockroach sql --insecure -e "SELECT 1" >/dev/null 2>&1; then break; fi
    echo -n "."; sleep 2
done
echo ""
success "CockroachDB is ready"

info "Waiting for the Iceberg REST catalog..."
for i in $(seq 1 30); do
    if curl -s http://localhost:8181/v1/config >/dev/null 2>&1; then break; fi
    echo -n "."; sleep 2
done
echo ""
success "Iceberg REST catalog is ready (warehouse on MinIO)"

# ── Step 3: Set up the source database ───────────────────────────────────────
header "STEP 3: Set Up CockroachDB"
docker exec -i iceberg-demo-cockroachdb cockroach sql --insecure < setup-cockroachdb.sql >/dev/null
success "demodb created with orders and customers (3 rows each)"

# ── Step 4: Deploy the connectors ────────────────────────────────────────────
header "STEP 4: Deploy Connectors"
info "Waiting for Kafka Connect to discover both plugins..."
wait_for_plugin "CockroachDBConnector" 60 || fail "CockroachDB connector plugin not discovered"
wait_for_plugin "IcebergSinkConnector" 30 || fail "Iceberg sink plugin not discovered"
success "Both connector plugins discovered"

HTTP=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "Content-Type: application/json" \
    --data @connector-config.json http://localhost:8083/connectors)
[ "$HTTP" = "201" ] || fail "Source connector deploy returned HTTP $HTTP"
success "Source connector deployed (HTTP 201)"
info "Waiting for source connector task..."
wait_for_task_running "cockroachdb-source" 45 || fail "Source connector task did not reach RUNNING"
success "Source connector task is RUNNING"

HTTP=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "Content-Type: application/json" \
    --data @iceberg-sink-config.json http://localhost:8083/connectors)
[ "$HTTP" = "201" ] || fail "Iceberg sink deploy returned HTTP $HTTP"
success "Iceberg sink deployed (HTTP 201)"
info "Waiting for Iceberg sink task..."
wait_for_task_running "iceberg-sink" 45 || fail "Iceberg sink task did not reach RUNNING"
success "Iceberg sink task is RUNNING"

# ── Step 5: Live changes ─────────────────────────────────────────────────────
header "STEP 5: Live Changes (insert, update, delete)"
docker exec iceberg-demo-cockroachdb cockroach sql --insecure -d demodb -e "
INSERT INTO orders (order_number, customer_name, email, amount, status, metadata, precise_qty)
VALUES ('ORD-LIVE-001', 'Dave Lee', 'dave@example.com', 75.25, 'new', '{\"channel\": \"api\"}', 1234567890.123456789);
UPDATE orders SET status = 'shipped' WHERE order_number = 'ORD-1002';
DELETE FROM orders WHERE order_number = 'ORD-1003';
INSERT INTO customers (name, email, tier) VALUES ('Eve Adams', 'eve@example.com', 'gold');" >/dev/null
success "DML executed: 1 order insert, 1 update, 1 delete, 1 customer insert"

# The sink coordinator commits to Iceberg on an interval (20s in this demo).
info "Waiting for the changefeed, the sink, and the Iceberg commit cycle..."
sleep 30

# ── Step 6: Verify the data in Iceberg ───────────────────────────────────────
header "STEP 6: Verify Iceberg Tables"
NETWORK=$(docker inspect iceberg-demo-connect --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{end}}')
info "Reading Iceberg tables back through the REST catalog (pyiceberg)..."
VERIFIED=false
for attempt in 1 2 3 4; do
    if docker run --rm --network "$NETWORK" -v "$SCRIPT_DIR/verify-iceberg.py:/verify.py:ro" \
        python:3.12-slim bash -c "pip install -q 'pyiceberg[s3fs,pyarrow]' >/dev/null 2>&1 && python /verify.py" | tee /tmp/iceberg-verify.out \
        && grep -q VERIFY_OK /tmp/iceberg-verify.out; then
        VERIFIED=true
        break
    fi
    warn "Iceberg tables not complete yet (attempt $attempt); waiting for the next commit cycle..."
    sleep 30
done
if [ "$VERIFIED" = "true" ]; then
    success "Iceberg tables verified: rows, CDC metadata, and full DECIMAL(28,18) precision"
else
    fail "Iceberg verification did not pass after 4 attempts; see output above"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
header "Demo Complete"
success "CockroachDB       : localhost:26257  (UI: http://localhost:8080)"
success "Kafka             : localhost:29092"
success "Kafka Connect     : http://localhost:8083"
success "Iceberg REST      : http://localhost:8181"
success "MinIO console     : http://localhost:9001  (admin/password)"
echo ""
info "The Iceberg tables demo.orders and demo.customers hold the CDC event stream."
info "Tear down with: docker-compose down -v"
