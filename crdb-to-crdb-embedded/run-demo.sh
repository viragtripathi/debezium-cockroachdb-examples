#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
CONNECTOR_PROJECT="${SCRIPT_DIR}/../../debezium-connector-cockroachdb"
APP_LOG="/tmp/crdb-embedded-app.log"

# This is an ordinary Maven app: it resolves the connector from Maven by default. Only when the
# requested version is not published (e.g. the unreleased sinkless snapshot) does it fall back to
# building from a local connector clone. Uses system Maven (mvn); no connector wrapper required.
MVN="${MVN:-mvn}"
CONNECTOR_VERSION="${CONNECTOR_VERSION:-3.6.0-SNAPSHOT}"
BUILD_FROM_SOURCE="${BUILD_FROM_SOURCE:-auto}"   # auto | true | false

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
fail()    { echo -e "${RED}[FAIL]${NC} $1"; cleanup; exit 1; }
header()  { echo -e "\n${BOLD}=== $1 ===${NC}\n"; }

APP_PID=""
cleanup() {
    [ -n "$APP_PID" ] && kill "$APP_PID" >/dev/null 2>&1 || true
    docker compose down -v --remove-orphans >/dev/null 2>&1 || true
}

src_count() { docker exec embedded-cockroachdb cockroach sql --insecure -d demodb --format=csv -e "SELECT count(*) FROM orders" 2>/dev/null | tail -1 | tr -d '[:space:]'; }
tgt_count() { docker exec embedded-cockroachdb-target cockroach sql --insecure -d targetdb --format=csv -e "SELECT count(*) FROM orders" 2>/dev/null | tail -1 | tr -d '[:space:]'; }
# Skip the CSV header (line 1) and take the first data row, so a deleted/absent row yields an empty
# string rather than the literal header "amount".
tgt_amount() { docker exec embedded-cockroachdb-target cockroach sql --insecure -d targetdb --format=csv -e "SELECT amount FROM orders WHERE id=$1" 2>/dev/null | tail -n +2 | head -1 | tr -d '[:space:]'; }

# ── Step 1: Obtain the connector (Maven first, source fallback) ─────────────
header "STEP 1: Resolve the CockroachDB connector ${CONNECTOR_VERSION}"
command -v "$MVN" >/dev/null 2>&1 || fail "Maven ('$MVN') not found on PATH. Install Maven 3.9+ or set MVN=..."
build_connector_from_source() {
    [ -d "$CONNECTOR_PROJECT" ] || fail "Need to build the connector from source, but the clone was not found at $CONNECTOR_PROJECT. Either clone it there, or set CONNECTOR_VERSION to a published release."
    info "Building connector ${CONNECTOR_VERSION} from source and installing to the local Maven repo..."
    ( cd "$CONNECTOR_PROJECT" && ./mvnw -q -DskipTests -DskipITs -Dcheckstyle.skip=true -Drevapi.skip=true install )
}
ARTIFACT="io.debezium:debezium-connector-cockroachdb:${CONNECTOR_VERSION}"
if [ "$BUILD_FROM_SOURCE" = "true" ]; then
    build_connector_from_source
    success "Connector built from source"
elif "$MVN" -q dependency:get -Dartifact="$ARTIFACT" -Dtransitive=false >/dev/null 2>&1; then
    success "Connector ${CONNECTOR_VERSION} resolved from Maven (no clone needed)"
elif [ "$BUILD_FROM_SOURCE" = "false" ]; then
    fail "Connector ${CONNECTOR_VERSION} is not available from Maven and BUILD_FROM_SOURCE=false. Set CONNECTOR_VERSION to a published release, or allow source build."
else
    warn "Connector ${CONNECTOR_VERSION} not published to Maven yet (expected for the unreleased sinkless build); falling back to source"
    build_connector_from_source
    success "Connector built from source (set CONNECTOR_VERSION to a release to skip this once sinkless ships)"
fi

# ── Step 2: Start the two CockroachDB clusters (no Kafka, no Connect) ────────
header "STEP 2: Start Docker Compose (Source CRDB + Target CRDB only)"
docker compose down -v --remove-orphans 2>/dev/null || true
docker compose up -d
success "Containers starting (no Kafka, Zookeeper, or Kafka Connect)"

# ── Step 3: Wait for both clusters ──────────────────────────────────────────
header "STEP 3: Wait for Source and Target CockroachDB"
for i in $(seq 1 30); do docker exec embedded-cockroachdb cockroach sql --insecure -e "SELECT 1" >/dev/null 2>&1 && break; sleep 2; done
docker exec embedded-cockroachdb cockroach sql --insecure -e "SELECT 1" >/dev/null 2>&1 || fail "Source CRDB did not start"
success "Source CRDB ready (localhost:26257)"
for i in $(seq 1 30); do docker exec embedded-cockroachdb-target cockroach sql --insecure -e "SELECT 1" >/dev/null 2>&1 && break; sleep 2; done
docker exec embedded-cockroachdb-target cockroach sql --insecure -e "SELECT 1" >/dev/null 2>&1 || fail "Target CRDB did not start"
success "Target CRDB ready (localhost:26258)"

# ── Step 4: Set up databases ────────────────────────────────────────────────
header "STEP 4: Set up source (demodb.orders, 3 rows) and target (targetdb.orders)"
docker exec -i embedded-cockroachdb cockroach sql --insecure < setup-source.sql
docker exec -i embedded-cockroachdb-target cockroach sql --insecure < setup-target.sql
success "Source seeded with 3 rows; target table created (empty)"

# ── Step 5: Start the embedded replicator (in-process, Kafka-free) ──────────
header "STEP 5: Start the Debezium embedded replicator (sinkless source -> JDBC target)"
nohup "$MVN" -q -Dconnector.version="$CONNECTOR_VERSION" compile exec:java > "$APP_LOG" 2>&1 &
APP_PID=$!
info "Embedded app started (PID $APP_PID), logs at $APP_LOG"

# ── Step 6: Wait for the initial scan to replicate (no cursor race) ─────────
header "STEP 6: Wait for the initial snapshot to replicate to the target"
for i in $(seq 1 60); do
    [ "$(tgt_count)" = "3" ] && break
    if ! kill -0 "$APP_PID" 2>/dev/null; then echo "--- app log ---"; tail -30 "$APP_LOG"; fail "Embedded app exited early"; fi
    echo -n "."; sleep 2
done
echo ""
[ "$(tgt_count)" = "3" ] || { tail -30 "$APP_LOG"; fail "Initial snapshot did not replicate (target has $(tgt_count) rows)"; }
success "Initial snapshot replicated: target has 3 rows (no Kafka involved)"

# ── Step 7: Live DML on the source ──────────────────────────────────────────
header "STEP 7: Run live DML on the source (INSERT, UPDATE, DELETE)"
docker exec -i embedded-cockroachdb cockroach sql --insecure -d demodb -e "
INSERT INTO orders (id, name, amount) VALUES (4, 'Dave', 50.00);
UPDATE orders SET amount = 999.00 WHERE id = 1;
DELETE FROM orders WHERE id = 2;
"
success "DML executed: +1 insert, 1 update, 1 delete"

# ── Step 8: Verify the live changes replicated ──────────────────────────────
header "STEP 8: Verify live changes replicated to the target"
for i in $(seq 1 60); do
    if [ "$(tgt_count)" = "3" ] && [ "$(tgt_amount 4)" = "50.00" ] && [ "$(tgt_amount 1)" = "999.00" ] && [ -z "$(tgt_amount 2)" ]; then
        break
    fi
    echo -n "."; sleep 2
done
echo ""
SRC=$(src_count); TGT=$(tgt_count)
info "Source rows: $SRC   |   Target rows: $TGT"
info "Target id=1 amount: $(tgt_amount 1) (expected 999.00)"
info "Target id=4 amount: $(tgt_amount 4) (expected 50.00, inserted live)"
info "Target id=2 present: $([ -z "$(tgt_amount 2)" ] && echo no || echo yes) (expected no, deleted live)"
if [ "$SRC" = "$TGT" ] && [ "$(tgt_amount 1)" = "999.00" ] && [ "$(tgt_amount 4)" = "50.00" ] && [ -z "$(tgt_amount 2)" ]; then
    success "All changes replicated CRDB -> CRDB with no Kafka and no Kafka Connect"
else
    tail -30 "$APP_LOG"; fail "Replication mismatch"
fi

# ── Step 9: Summary ─────────────────────────────────────────────────────────
header "DEMO COMPLETE (Kafka-free)"
echo "  Source CRDB (demodb.orders)"
echo "       |"
echo "       v  Core changefeed streamed over SQL (sinkless) -- NO Kafka"
echo "  Debezium embedded engine (in this JVM) -- NO Kafka Connect"
echo "       |"
echo "       v  JDBC upsert/delete"
echo "  Target CRDB (targetdb.orders)"
echo ""
success "Source CRDB : localhost:26257 (UI http://localhost:8080)"
success "Target CRDB : localhost:26258 (UI http://localhost:8081)"
info "App log: $APP_LOG"
echo ""
info "Stopping the embedded app and tearing down containers..."
cleanup
success "Done"
