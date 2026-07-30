#!/usr/bin/env bash
# CockroachDB -> Debezium CockroachDB connector -> Kafka -> JDBC sink -> Oracle demo.
set -euo pipefail
cd "$(dirname "$0")"
SCRIPT_DIR="$(pwd)"

# Optional scale test: WORKLOAD=tpcc loads the built-in cockroach TPC-C workload (9 tables,
# about 600k rows at 1 warehouse), streams it into Oracle, runs live TPC-C transactions on
# top, and verifies per-table row-count parity once the pipeline drains.
WORKLOAD="${WORKLOAD:-}"

# Pick the Oracle image for the host architecture.
if [ "$(uname -m)" = "arm64" ] || [ "$(uname -m)" = "aarch64" ]; then
    export ORACLE_IMAGE="${ORACLE_IMAGE:-virag/oracle-19.3.0-ee-arm64:latest}"
else
    export ORACLE_IMAGE="${ORACLE_IMAGE:-virag/oracle-19.3.0-ee:latest}"
fi

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[0;33m'; BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
fail()    { echo -e "${RED}[FAIL]${NC} $1"; exit 1; }
header()  { echo -e "\n${BOLD}=== $1 ===${NC}\n"; }

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

# The delete step needs fixes that ship in 3.7.0.Alpha1 and later; the script downloads
# that release from Maven Central by default, or builds from the sibling repo with
# BUILD_FROM_SOURCE=true.
CONNECTOR_VERSION="${CONNECTOR_VERSION:-3.7.0.Alpha1}"
BUILD_FROM_SOURCE="${BUILD_FROM_SOURCE:-false}"
CONNECTOR_PROJECT="${CONNECTOR_PROJECT:-$SCRIPT_DIR/../../debezium-connector-cockroachdb}"

header "STEP 0: Obtain the CockroachDB Connector"
CRDB_PLUGIN_DIR="$SCRIPT_DIR/connect-plugins/debezium-connector-cockroachdb"
if [ -n "$(ls "$CRDB_PLUGIN_DIR"/*.jar 2>/dev/null)" ]; then
    success "CockroachDB connector already present in connect-plugins/"
elif [ "$BUILD_FROM_SOURCE" = "true" ] && [ -d "$CONNECTOR_PROJECT" ]; then
    info "Building the CockroachDB connector from source ($CONNECTOR_PROJECT)..."
    (cd "$CONNECTOR_PROJECT" && ./mvnw clean package -Passembly -DskipTests -DskipITs -q)
    PLUGIN_ZIP=$(ls "$CONNECTOR_PROJECT"/target/debezium-connector-cockroachdb-*-plugin.zip | head -1)
    [ -n "$PLUGIN_ZIP" ] || fail "Build produced no plugin zip"
    mkdir -p "$SCRIPT_DIR/connect-plugins"
    unzip -q -o "$PLUGIN_ZIP" -d "$SCRIPT_DIR/connect-plugins/"
    success "CockroachDB connector built from source"
else
    info "Downloading connector plugin ${CONNECTOR_VERSION} from Maven Central..."
    mkdir -p "$SCRIPT_DIR/connect-plugins"
    PLUGIN_URL="https://repo1.maven.org/maven2/io/debezium/debezium-connector-cockroachdb/${CONNECTOR_VERSION}/debezium-connector-cockroachdb-${CONNECTOR_VERSION}-plugin.zip"
    if curl -fSL -o /tmp/crdb-plugin.zip "$PLUGIN_URL" 2>/dev/null; then
        unzip -q -o /tmp/crdb-plugin.zip -d "$SCRIPT_DIR/connect-plugins/"
        rm -f /tmp/crdb-plugin.zip
        success "CockroachDB connector ${CONNECTOR_VERSION} downloaded"
    else
        fail "Download failed; retry or use BUILD_FROM_SOURCE=true"
    fi
fi

header "STEP 1: Start Containers"
info "Oracle image: $ORACLE_IMAGE"
docker-compose up -d 2>/dev/null || docker compose up -d
success "Containers starting..."

info "Waiting for Oracle (first boot creates the database and can take 10 minutes or more)..."
for i in $(seq 1 150); do
    if docker logs oracle19c-demo 2>/dev/null | grep "DATABASE IS READY TO USE" >/dev/null; then break; fi
    echo -n "."; sleep 10
done
echo ""
docker logs oracle19c-demo 2>/dev/null | grep "DATABASE IS READY TO USE" >/dev/null || fail "Oracle did not become ready"
success "Oracle is ready"

info "Waiting for CockroachDB..."
for i in $(seq 1 30); do
    if docker exec crdb2ora-cockroachdb cockroach sql --insecure -e "SELECT 1" >/dev/null 2>&1; then break; fi
    echo -n "."; sleep 2
done
echo ""
success "CockroachDB is ready"

header "STEP 2: Set Up Source and Target"
docker exec -i crdb2ora-cockroachdb cockroach sql --insecure < setup-cockroachdb.sql >/dev/null
success "CockroachDB source: demodb.orders with 3 rows"

# Oracle is a plain JDBC target here: no ARCHIVELOG or LogMiner setup needed, just a schema
# user with quota; the JDBC sink auto-creates the table.
docker exec -i oracle19c-demo bash -c 'sqlplus -S / as sysdba <<SQL
WHENEVER SQLERROR CONTINUE
ALTER SESSION SET CONTAINER = ORCLPDB1;
CREATE USER debezium IDENTIFIED BY dbz DEFAULT TABLESPACE users QUOTA UNLIMITED ON users;
GRANT CREATE SESSION, CREATE TABLE, CREATE SEQUENCE TO debezium;
SQL' >/dev/null
success "Oracle target: user debezium ready in ORCLPDB1"

header "STEP 3: Deploy Connectors"
info "Waiting for Kafka Connect..."
for i in $(seq 1 60); do
    if curl -s http://localhost:8083/connector-plugins 2>/dev/null | grep -q CockroachDBConnector; then break; fi
    echo -n "."; sleep 2
done
echo ""
success "Kafka Connect is ready (CockroachDB connector and JDBC sink are bundled in the image)"

HTTP=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "Content-Type: application/json" \
    --data @connector-config.json http://localhost:8083/connectors)
{ [ "$HTTP" = "201" ] || [ "$HTTP" = "409" ]; } || fail "CockroachDB source deploy returned HTTP $HTTP"
wait_for_task_running "cockroachdb-source" 45 || fail "CockroachDB source task did not reach RUNNING"
success "CockroachDB source connector is RUNNING"

HTTP=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "Content-Type: application/json" \
    --data @oracle-sink-config.json http://localhost:8083/connectors)
{ [ "$HTTP" = "201" ] || [ "$HTTP" = "409" ]; } || fail "Oracle sink deploy returned HTTP $HTTP"
wait_for_task_running "oracle-jdbc-sink" 45 || fail "Oracle sink task did not reach RUNNING"
success "Oracle JDBC sink connector is RUNNING"

header "STEP 4: Live Changes on CockroachDB (insert, update, delete)"
docker exec crdb2ora-cockroachdb cockroach sql --insecure -d demodb -e "
INSERT INTO orders (order_number, customer_name, amount, status) VALUES ('ORD-LIVE-001', 'Dave Lee', 75.25, 'new');
UPDATE orders SET status = 'shipped' WHERE order_number = 'ORD-1002';
DELETE FROM orders WHERE order_number = 'ORD-1003';" >/dev/null
success "DML executed on CockroachDB: 1 insert, 1 update, 1 delete"

info "Waiting 45s for the changefeed and sink delivery..."
sleep 45

header "STEP 5: Verify the Data in Oracle"
RESULT=$(docker exec -i oracle19c-demo bash -c 'sqlplus -S debezium/dbz@//localhost:1521/ORCLPDB1 <<SQL
SET HEADING OFF FEEDBACK OFF
SELECT COUNT(*) FROM orders;
SQL' 2>/dev/null | tr -d "[:space:]")
info "orders rows in Oracle: $RESULT (expected 3: ORD-1001, ORD-1002 updated, ORD-LIVE-001; ORD-1003 deleted)"
[ "$RESULT" = "3" ] || fail "Expected 3 rows in Oracle, found '$RESULT'"
STATUS=$(docker exec -i oracle19c-demo bash -c 'sqlplus -S debezium/dbz@//localhost:1521/ORCLPDB1 <<SQL
SET HEADING OFF FEEDBACK OFF
SELECT TO_CHAR(status) FROM orders WHERE TO_CHAR(order_number) = '"'"'ORD-1002'"'"';
SQL' 2>/dev/null | tr -d "[:space:]")
[ "$STATUS" = "shipped" ] || fail "Expected ORD-1002 status=shipped in Oracle, found '$STATUS'"
success "Round trip verified: snapshot, insert, update, and delete all landed in Oracle"

if [ "$WORKLOAD" = "tpcc" ]; then
    header "STEP 6: TPC-C Scale Test (WORKLOAD=tpcc)"
    WAREHOUSES="${WAREHOUSES:-1}"
    WORKLOAD_DURATION="${WORKLOAD_DURATION:-60s}"
    WORKLOAD_MAX_RATE="${WORKLOAD_MAX_RATE:-20}"
    DRAIN_TIMEOUT="${DRAIN_TIMEOUT:-1800}"
    PGURL='postgresql://root@localhost:26257?sslmode=disable'
    # Fixed table order used for both parity strings.
    TPCC_CRDB_COUNTS="SELECT (SELECT count(*) FROM warehouse) || '|' || (SELECT count(*) FROM district) || '|' || (SELECT count(*) FROM customer) || '|' || (SELECT count(*) FROM history) || '|' || (SELECT count(*) FROM \"order\") || '|' || (SELECT count(*) FROM new_order) || '|' || (SELECT count(*) FROM item) || '|' || (SELECT count(*) FROM stock) || '|' || (SELECT count(*) FROM order_line);"

    info "Loading TPC-C with ${WAREHOUSES} warehouse(s) (about 600k rows per warehouse)..."
    docker exec crdb2ora-cockroachdb cockroach workload init tpcc \
        --warehouses="$WAREHOUSES" "$PGURL" >/dev/null 2>&1
    success "tpcc database loaded"

    HTTP=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "Content-Type: application/json" \
        --data @tpcc-source-config.json http://localhost:8083/connectors)
    { [ "$HTTP" = "201" ] || [ "$HTTP" = "409" ]; } || fail "tpcc source deploy returned HTTP $HTTP"
    wait_for_task_running "tpcc-source" 90 || fail "tpcc source task did not reach RUNNING"
    success "tpcc source connector is RUNNING (initial scan backfills all 9 tables)"

    HTTP=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "Content-Type: application/json" \
        --data @tpcc-oracle-sink-config.json http://localhost:8083/connectors)
    { [ "$HTTP" = "201" ] || [ "$HTTP" = "409" ]; } || fail "tpcc sink deploy returned HTTP $HTTP"
    wait_for_task_running "tpcc-oracle-sink" 45 || fail "tpcc sink task did not reach RUNNING"
    success "tpcc Oracle sink connector is RUNNING"

    info "Running TPC-C transactions for ${WORKLOAD_DURATION} (max ${WORKLOAD_MAX_RATE} txns/s) while the backfill streams..."
    docker exec crdb2ora-cockroachdb cockroach workload run tpcc --warehouses="$WAREHOUSES" \
        --duration="$WORKLOAD_DURATION" --wait=false --max-rate="$WORKLOAD_MAX_RATE" "$PGURL" >/dev/null 2>&1
    success "TPC-C run finished; source is now static"

    SRC_COUNTS=$(docker exec crdb2ora-cockroachdb cockroach sql --insecure -d tpcc --format=csv \
        -e "$TPCC_CRDB_COUNTS" 2>/dev/null | tail -1)
    info "Source counts (warehouse|district|customer|history|order|new_order|item|stock|order_line):"
    info "  $SRC_COUNTS"

    info "Waiting for the pipeline to drain into Oracle (timeout ${DRAIN_TIMEOUT}s)..."
    TGT_COUNTS=""
    ELAPSED=0
    while [ "$ELAPSED" -lt "$DRAIN_TIMEOUT" ]; do
        TGT_COUNTS=$(docker exec -i oracle19c-demo bash -c 'sqlplus -S debezium/dbz@//localhost:1521/ORCLPDB1 <<SQL
SET HEADING OFF FEEDBACK OFF
SELECT (SELECT COUNT(*) FROM "tpcc_public_warehouse") || '"'"'|'"'"' || (SELECT COUNT(*) FROM "tpcc_public_district") || '"'"'|'"'"' || (SELECT COUNT(*) FROM "tpcc_public_customer") || '"'"'|'"'"' || (SELECT COUNT(*) FROM "tpcc_public_history") || '"'"'|'"'"' || (SELECT COUNT(*) FROM "tpcc_public_order") || '"'"'|'"'"' || (SELECT COUNT(*) FROM "tpcc_public_new_order") || '"'"'|'"'"' || (SELECT COUNT(*) FROM "tpcc_public_item") || '"'"'|'"'"' || (SELECT COUNT(*) FROM "tpcc_public_stock") || '"'"'|'"'"' || (SELECT COUNT(*) FROM "tpcc_public_order_line") FROM dual;
SQL' 2>/dev/null | tr -d "[:space:]")
        if [ "$TGT_COUNTS" = "$SRC_COUNTS" ]; then break; fi
        echo "  ${ELAPSED}s: oracle counts = ${TGT_COUNTS:-tables not created yet}"
        sleep 30
        ELAPSED=$((ELAPSED + 30))
    done
    info "Target counts: $TGT_COUNTS"
    [ "$TGT_COUNTS" = "$SRC_COUNTS" ] || fail "TPC-C parity check failed after ${DRAIN_TIMEOUT}s: source '$SRC_COUNTS' vs oracle '$TGT_COUNTS'"
    success "TPC-C parity verified: all 9 tables match row for row in Oracle after backfill plus live transactions"
fi

header "Demo Complete"
success "CockroachDB        : localhost:26257  (UI: http://localhost:8080)"
success "Oracle             : localhost:1521 (ORCLPDB1, user debezium/dbz)"
success "Kafka Connect      : http://localhost:8083"
echo ""
info "Tear down with: docker-compose down -v"
