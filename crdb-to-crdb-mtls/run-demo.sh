#!/bin/bash
# End-to-end fully-secure demo for the Debezium CockroachDB connector.
#
# Proves two things at once:
#   1. The connector can reach a secure (TLS) CockroachDB cluster using a
#      client cert (database.sslmode=verify-full + sslcert + sslkey).
#   2. The connector can ship inline TLS material (CA + client cert + client
#      key) to a CockroachDB enriched changefeed so the changefeed itself can
#      authenticate to a Kafka broker that requires mutual TLS — the
#      cockroachdb.changefeed.sink.tls.* feature added in debezium/dbz#1974.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONNECTOR_PROJECT="${SCRIPT_DIR}/../../debezium-connector-cockroachdb"
CONNECTOR_VERSION="${CONNECTOR_VERSION:-3.6.0-SNAPSHOT}"
SKIP_BUILD="${SKIP_BUILD:-false}"
BUILD_FROM_SOURCE="${BUILD_FROM_SOURCE:-true}"

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

# Helper: run `cockroach sql` against the secure CRDB container, authenticated
# with the root client cert. SQL is read from stdin if a file is piped.
crdb_sql() {
    docker exec -i mtls-demo-cockroachdb cockroach sql \
        --certs-dir=/cockroach/cockroach-certs \
        --host=cockroachdb:26257 \
        --user=root \
        "$@"
}

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

# ── Step 1: Generate TLS material ───────────────────────────────────────────
header "STEP 1: Generate TLS Material (Kafka mTLS + CRDB secure-mode certs)"
if [ -f "$SCRIPT_DIR/certs/kafka/ca.crt" ] \
    && [ -f "$SCRIPT_DIR/certs/crdb/ca.crt" ] \
    && [ -f "$SCRIPT_DIR/certs/crdb/client.demo.key.pk8" ] \
    && [ "${REGENERATE_CERTS:-false}" != "true" ]; then
    success "Existing certs found in certs/kafka/ and certs/crdb/ (set REGENERATE_CERTS=true to rebuild)"
else
    bash "$SCRIPT_DIR/generate-certs.sh"
fi

# ── Step 2: Obtain connector plugin ─────────────────────────────────────────
header "STEP 2: Obtain Connector Plugin"
if [ "$SKIP_BUILD" = "true" ] && [ -d "$SCRIPT_DIR/connect-plugins/debezium-connector-cockroachdb" ] \
    && [ -n "$(ls "$SCRIPT_DIR/connect-plugins/debezium-connector-cockroachdb/"*.jar 2>/dev/null)" ]; then
    success "Using existing plugin in connect-plugins/ (SKIP_BUILD=true)"
elif [ "$BUILD_FROM_SOURCE" = "true" ]; then
    [ -d "$CONNECTOR_PROJECT" ] || fail "BUILD_FROM_SOURCE=true but connector project not found at $CONNECTOR_PROJECT"
    cd "$CONNECTOR_PROJECT"
    SOURCE_VERSION=$(./mvnw -q help:evaluate -Dexpression=project.version -DforceStdout 2>/dev/null || echo "unknown")
    if [ -n "${CONNECTOR_VERSION_OVERRIDE:-}" ] || \
       { [ "$CONNECTOR_VERSION" != "3.6.0-SNAPSHOT" ] && [ "$CONNECTOR_VERSION" != "$SOURCE_VERSION" ]; }; then
        warn "CONNECTOR_VERSION=${CONNECTOR_VERSION} is ignored when BUILD_FROM_SOURCE=true."
        warn "  Maven will build whatever is checked out at ${CONNECTOR_PROJECT} (project.version=${SOURCE_VERSION})."
        warn "  To build a specific tag: git -C ${CONNECTOR_PROJECT} checkout v${CONNECTOR_VERSION} first."
        warn "  To download a released version instead: BUILD_FROM_SOURCE=false CONNECTOR_VERSION=${CONNECTOR_VERSION} ./run-demo.sh"
    fi
    info "Building connector ${SOURCE_VERSION} from source (mTLS feature requires 3.6.0-SNAPSHOT or later)..."
    ./mvnw clean package -DskipTests -DskipITs -Passembly -q
    PLUGIN_ARCHIVE=$(ls target/debezium-connector-cockroachdb-*-plugin.tar.gz 2>/dev/null | head -1)
    [ -z "$PLUGIN_ARCHIVE" ] && PLUGIN_ARCHIVE=$(ls target/debezium-connector-cockroachdb-*-plugin.zip 2>/dev/null | head -1)
    [ -z "$PLUGIN_ARCHIVE" ] && fail "Plugin archive not found after build"
    success "Connector built: $(basename "$PLUGIN_ARCHIVE")"

    cd "$SCRIPT_DIR"
    rm -rf connect-plugins
    mkdir -p connect-plugins
    case "$PLUGIN_ARCHIVE" in
        *.zip)      unzip  -q -o "$CONNECTOR_PROJECT/$PLUGIN_ARCHIVE" -d connect-plugins/ ;;
        *.tar.gz)   tar    -xzf "$CONNECTOR_PROJECT/$PLUGIN_ARCHIVE" -C connect-plugins/ ;;
    esac
    success "Plugin extracted to connect-plugins/"
else
    MAVEN_BASE="https://repo1.maven.org/maven2/io/debezium/debezium-connector-cockroachdb"
    PLUGIN_ZIP_NAME="debezium-connector-cockroachdb-${CONNECTOR_VERSION}-plugin.zip"
    PLUGIN_URL="${MAVEN_BASE}/${CONNECTOR_VERSION}/${PLUGIN_ZIP_NAME}"
    if [ -d "$SCRIPT_DIR/connect-plugins/debezium-connector-cockroachdb" ] \
        && [ -n "$(ls "$SCRIPT_DIR/connect-plugins/debezium-connector-cockroachdb/"*.jar 2>/dev/null)" ]; then
        success "Plugin already present in connect-plugins/"
    else
        info "Downloading connector ${CONNECTOR_VERSION} from Maven Central..."
        cd "$SCRIPT_DIR"
        rm -rf connect-plugins
        mkdir -p connect-plugins
        if curl -fSL -o "/tmp/${PLUGIN_ZIP_NAME}" "$PLUGIN_URL"; then
            unzip -q -o "/tmp/${PLUGIN_ZIP_NAME}" -d connect-plugins/
            rm -f "/tmp/${PLUGIN_ZIP_NAME}"
            success "Plugin ${CONNECTOR_VERSION} downloaded"
        else
            warn "Download failed. The version ${CONNECTOR_VERSION} may not be published yet."
            info "  Use BUILD_FROM_SOURCE=true ./run-demo.sh while 3.6.0 is in development."
            fail "Cannot proceed without connector plugin"
        fi
    fi
fi

# ── Step 3: Start infrastructure ────────────────────────────────────────────
header "STEP 3: Start Docker Compose (secure CRDB + mTLS Kafka + Zookeeper + Connect)"
cd "$SCRIPT_DIR"
docker compose down -v --remove-orphans 2>/dev/null || true
docker compose up -d
success "Containers starting..."

# ── Step 4: Wait for secure CockroachDB ─────────────────────────────────────
header "STEP 4: Wait for Secure CockroachDB"
for i in $(seq 1 30); do
    if crdb_sql -e "SELECT 1" >/dev/null 2>&1; then
        success "Secure CockroachDB is ready (port 26257, certs-dir=/cockroach/cockroach-certs)"
        break
    fi
    echo -n "."
    sleep 2
done
crdb_sql -e "SELECT 1" >/dev/null 2>&1 || fail "Secure CockroachDB did not start"

# ── Step 5: Setup database ──────────────────────────────────────────────────
header "STEP 5: Setup Database (demodb.orders, demo user, rangefeed)"
crdb_sql < setup-cockroachdb.sql
success "demodb.orders ready with 3 seed rows; demo SQL user mapped to client.demo cert"

# ── Step 6: Wait for Kafka SSL listener ─────────────────────────────────────
header "STEP 6: Wait for Kafka mTLS Listener (port 9093)"
for i in $(seq 1 30); do
    if docker exec mtls-demo-kafka bash -c \
        "kafka-broker-api-versions --bootstrap-server kafka:9092" >/dev/null 2>&1; then
        success "Kafka broker is up (internal PLAINTEXT listener 9092 ready)"
        break
    fi
    echo -n "."
    sleep 2
done

info "Probing SSL listener with the client cert..."
SSL_OUT=$(docker exec mtls-demo-kafka bash -c "
    openssl s_client -connect kafka:9093 \
        -CAfile /etc/kafka/secrets/ca.crt \
        -cert  /etc/kafka/secrets/client.crt \
        -key   /etc/kafka/secrets/client.key \
        -verify_return_error -brief </dev/null
" 2>&1 || true)
if echo "$SSL_OUT" | grep -qi "verification:\? *OK\|Verification: OK"; then
    success "mTLS handshake succeeded against kafka:9093"
else
    echo "$SSL_OUT" | tail -20
    fail "mTLS handshake against kafka:9093 failed"
fi

# ── Step 7: Wait for Kafka Connect ──────────────────────────────────────────
header "STEP 7: Wait for Kafka Connect"
if ! wait_for_url "http://localhost:8083/" 60; then
    echo ""
    fail "Kafka Connect did not start within 120s"
fi
echo ""
success "Kafka Connect is ready"

# ── Step 8: Verify plugin ───────────────────────────────────────────────────
header "STEP 8: Verify CockroachDB Connector Plugin"
PLUGINS=""
for i in $(seq 1 30); do
    PLUGINS=$(curl -s http://localhost:8083/connector-plugins 2>/dev/null || echo "")
    if echo "$PLUGINS" | grep -q "CockroachDBConnector"; then
        break
    fi
    echo -n "."
    sleep 2
done
echo ""
echo "$PLUGINS" | grep -q "CockroachDBConnector" || fail "CockroachDBConnector plugin not found"
success "CockroachDBConnector plugin discovered"

# ── Step 9: Verify both PEM mounts are visible inside the Connect container ─
header "STEP 9: Verify Cert Mounts Visible Inside Connect Container"
docker exec mtls-demo-connect ls -la \
    /etc/kafka-tls/ca.crt /etc/kafka-tls/client.crt /etc/kafka-tls/client.key \
    /etc/crdb-tls/ca.crt  /etc/crdb-tls/client.demo.crt /etc/crdb-tls/client.demo.key.pk8 \
    || fail "Expected cert files not mounted into the connect container"
success "Kafka mTLS PEMs + CRDB sslcert/sslkey visible to the connector"

# ── Step 10: Deploy connector ───────────────────────────────────────────────
header "STEP 10: Deploy Connector (secure CRDB + mTLS Kafka changefeed sink)"
RESPONSE=$(curl -s -o /tmp/mtls-demo-response.json -w "%{http_code}" -X POST \
    -H "Content-Type: application/json" \
    --data @connector-config.json \
    http://localhost:8083/connectors)
BODY=$(cat /tmp/mtls-demo-response.json)
if [ "$RESPONSE" -ge 200 ] && [ "$RESPONSE" -lt 300 ]; then
    success "Connector deployed (HTTP $RESPONSE)"
elif echo "$BODY" | grep -q "already exists"; then
    warn "Connector already exists"
else
    echo "$BODY" | python3 -m json.tool 2>/dev/null || echo "$BODY"
    fail "Connector deploy failed (HTTP $RESPONSE)"
fi

info "Waiting for connector task to reach RUNNING..."
if ! wait_for_task_running "cockroachdb-mtls-demo-connector" 30; then
    fail "Connector task did not reach RUNNING"
fi
success "Connector task is RUNNING (proves: pgjdbc verify-full to CRDB works AND changefeed -> mTLS Kafka works)"

# ── Step 11: Confirm CRDB changefeed has the TLS material inlined ──────────
header "STEP 11: Inspect CockroachDB Changefeed Job"
info "Looking for the changefeed job created by the connector..."
JOB_ROW=$(crdb_sql --format=tsv \
    -e "SELECT job_id, status, description FROM [SHOW CHANGEFEED JOBS] WHERE description LIKE '%kafka://kafka:9093%' ORDER BY created DESC LIMIT 1" \
    2>/dev/null | tail -1)
if [ -z "$JOB_ROW" ] || [ "$JOB_ROW" = "job_id	status	description" ]; then
    warn "No matching changefeed job found yet (it may still be starting)"
else
    echo "$JOB_ROW"
    DESC=$(echo "$JOB_ROW" | cut -f3-)
    for PARAM in tls_enabled=true ca_cert= client_cert= client_key=; do
        if echo "$DESC" | grep -q "$PARAM"; then
            success "Changefeed URI carries $PARAM"
        else
            warn "Changefeed URI is missing $PARAM"
        fi
    done
fi

# ── Step 12: Insert live data and verify events arrive over mTLS ────────────
header "STEP 12: Insert Live Rows + Consume Events from mTLS Kafka"
crdb_sql -d demodb -e "
INSERT INTO orders (order_number, customer_name, amount, status) VALUES
    ('ORD-MTLS-LIVE-001', 'Dana Live',  99.00, 'new'),
    ('ORD-MTLS-LIVE-002', 'Evan Live', 175.25, 'pending');
" 2>&1
success "2 rows inserted into the secure CRDB"
info "Waiting 15s for changefeed -> Kafka -> connector pipeline..."
sleep 15

docker exec mtls-demo-kafka bash -c "cat > /tmp/ssl-consumer.properties <<EOF
security.protocol=SSL
ssl.truststore.location=/etc/kafka/secrets/broker.truststore.jks
ssl.truststore.password=changeit
ssl.keystore.location=/etc/kafka/secrets/client.keystore.jks
ssl.keystore.password=changeit
ssl.key.password=changeit
ssl.endpoint.identification.algorithm=
EOF" >/dev/null

# The CockroachDB changefeed writes to topic `<topic_prefix><full_table_name>`,
# which with topic_prefix=crdb. and full_table_name is `crdb.demodb.public.orders`.
INTERMEDIATE_TOPIC="crdb.demodb.public.orders"
info "Consuming directly from CRDB's intermediate topic '$INTERMEDIATE_TOPIC' via the mTLS listener..."
EVENTS=$(docker exec mtls-demo-kafka kafka-console-consumer \
    --bootstrap-server kafka:9093 \
    --consumer.config /tmp/ssl-consumer.properties \
    --topic "$INTERMEDIATE_TOPIC" \
    --from-beginning \
    --max-messages 10 \
    --timeout-ms 15000 2>/dev/null || true)

EVENT_COUNT=$(echo "$EVENTS" | grep -c '^{' || true)
if [ "$EVENT_COUNT" -gt 0 ]; then
    success "Consumed $EVENT_COUNT events from the mTLS listener (proves CRDB -> mTLS Kafka works)"
    echo "$EVENTS" | python3 -c "
import sys,json
for line in sys.stdin:
    line=line.strip()
    if not line: continue
    try:
        d=json.loads(line)
        p = d.get('payload', d)
        a = p.get('after') or {}
        op = p.get('op','?')
        print(f'    op={op}  order={a.get(\"order_number\",\"\")}  amount={a.get(\"amount\",\"\")}  status={a.get(\"status\",\"\")}')
    except: pass
" 2>/dev/null
else
    warn "No events consumed from $INTERMEDIATE_TOPIC -- check connector logs (docker logs mtls-demo-connect)"
fi

OUTPUT_TOPIC="crdb.public.orders"
info "Consuming from connector's output topic '$OUTPUT_TOPIC' (PLAINTEXT)..."
DZ_EVENTS=$(docker exec mtls-demo-kafka kafka-console-consumer \
    --bootstrap-server kafka:9092 \
    --topic "$OUTPUT_TOPIC" \
    --from-beginning \
    --max-messages 10 \
    --timeout-ms 15000 2>/dev/null || true)

DZ_COUNT=$(echo "$DZ_EVENTS" | grep -c '^{' || true)
if [ "$DZ_COUNT" -gt 0 ]; then
    success "Consumed $DZ_COUNT Debezium events from $OUTPUT_TOPIC"
else
    warn "No Debezium events on $OUTPUT_TOPIC yet"
fi

# ── Step 13: Error check ────────────────────────────────────────────────────
header "STEP 13: Error Check"
ERRORS=$(docker logs mtls-demo-connect 2>&1 \
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
echo "  Fully-secure pipeline:"
echo "  Secure CockroachDB (demodb.orders, --certs-dir, root-CA-signed node cert)"
echo "       ^"
echo "       |  pgjdbc verify-full with client.demo cert (database.sslmode=verify-full)"
echo "       |"
echo "  Debezium connector (CockroachDB)"
echo "       |"
echo "       |  CREATE CHANGEFEED with inline TLS material:"
echo "       |     ca_cert + client_cert + client_key (base64) + tls_enabled=true"
echo "       v"
echo "  Kafka mTLS listener (kafka:9093, SSL_CLIENT_AUTH=required)"
echo ""
success "Secure CockroachDB : localhost:26257  (UI: https://localhost:8080)"
success "Kafka mTLS listener: kafka:9093 (in-network) — host plaintext: localhost:29092"
success "Kafka Connect REST : http://localhost:8083"
success "Connector status   : http://localhost:8083/connectors/cockroachdb-mtls-demo-connector/status"
echo ""
info "Interactive SQL on secure CRDB:"
echo "  docker exec -it mtls-demo-cockroachdb cockroach sql \\"
echo "    --certs-dir=/cockroach/cockroach-certs --host=cockroachdb:26257 --user=root -d demodb"
echo ""
info "Inspect the changefeed URI (will show ca_cert=..., client_cert=..., client_key=...):"
echo "  docker exec -it mtls-demo-cockroachdb cockroach sql \\"
echo "    --certs-dir=/cockroach/cockroach-certs --host=cockroachdb:26257 --user=root \\"
echo "    -e \"SELECT description FROM [SHOW CHANGEFEED JOBS] WHERE description LIKE '%kafka%'\""
echo ""
info "Consume events via the mTLS listener:"
echo "  docker exec mtls-demo-kafka kafka-console-consumer \\"
echo "    --bootstrap-server kafka:9093 --consumer.config /tmp/ssl-consumer.properties \\"
echo "    --topic crdb.demodb.public.orders --from-beginning"
echo ""
info "To stop the demo:"
echo "  cd $(pwd) && docker compose down -v"
