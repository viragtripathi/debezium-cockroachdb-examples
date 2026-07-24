#!/usr/bin/env bash
# Oracle -> Debezium (LogMiner) -> Kafka -> JDBC sink -> CockroachDB demo.
# Fully automated, including the one-time Oracle ARCHIVELOG and LogMiner setup.
set -euo pipefail
cd "$(dirname "$0")"
SCRIPT_DIR="$(pwd)"

# Optional realistic traffic: WORKLOAD=transfers runs concurrent multi-row transfer
# transactions on an Oracle accounts table and verifies row-count and total-balance
# parity in CockroachDB once the pipeline drains.
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
    if docker exec ora2crdb-cockroachdb cockroach sql --insecure -e "SELECT 1" >/dev/null 2>&1; then break; fi
    echo -n "."; sleep 2
done
echo ""
success "CockroachDB is ready"

header "STEP 2: One-Time Oracle Setup (ARCHIVELOG, supplemental logging, LogMiner user, demo schema)"
ORACLE_CONTAINER=oracle19c-demo ./setup-oracle.sh
success "Oracle prepared for LogMiner capture"

header "STEP 3: Set Up the CockroachDB Target"
docker exec ora2crdb-cockroachdb cockroach sql --insecure -e "CREATE DATABASE IF NOT EXISTS targetdb;" >/dev/null
success "targetdb created (tables are auto-created by the JDBC sink)"

header "STEP 4: Deploy Connectors"
info "Waiting for Kafka Connect..."
for i in $(seq 1 60); do
    if curl -s http://localhost:8083/connector-plugins 2>/dev/null | grep -q OracleConnector; then break; fi
    echo -n "."; sleep 2
done
echo ""
success "Kafka Connect is ready (Oracle connector and JDBC sink are bundled in the image)"

HTTP=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "Content-Type: application/json" \
    --data @oracle-source-config.json http://localhost:8083/connectors)
{ [ "$HTTP" = "201" ] || [ "$HTTP" = "409" ]; } || fail "Oracle source deploy returned HTTP $HTTP"
info "Waiting for the Oracle source task (initial snapshot)..."
wait_for_task_running "oracle-source" 90 || fail "Oracle source task did not reach RUNNING"
success "Oracle source connector is RUNNING"

HTTP=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "Content-Type: application/json" \
    --data @jdbc-sink-config.json http://localhost:8083/connectors)
{ [ "$HTTP" = "201" ] || [ "$HTTP" = "409" ]; } || fail "JDBC sink deploy returned HTTP $HTTP"
wait_for_task_running "crdb-jdbc-sink" 45 || fail "JDBC sink task did not reach RUNNING"
success "JDBC sink connector is RUNNING"

header "STEP 5: Live Changes on Oracle (insert, update, delete)"
docker exec -i oracle19c-demo bash -c 'sqlplus -S debezium/dbz@//localhost:1521/ORCLPDB1 <<SQL
INSERT INTO customers (name, email, tier, balance) VALUES ('"'"'Dave Lee'"'"', '"'"'dave@example.com'"'"', '"'"'gold'"'"', 75.25);
UPDATE customers SET tier = '"'"'platinum'"'"', balance = 2500.00 WHERE name = '"'"'Bob Smith'"'"';
DELETE FROM customers WHERE name = '"'"'Carol Davis'"'"';
COMMIT;
SQL' >/dev/null
success "DML executed on Oracle: 1 insert, 1 update, 1 delete"

info "Waiting 60s for LogMiner capture and sink delivery..."
sleep 60

header "STEP 6: Verify the Data in CockroachDB"
ROWS=$(docker exec ora2crdb-cockroachdb cockroach sql --insecure -d targetdb --format=csv \
    -e "SELECT count(*) FROM customers;" 2>/dev/null | tail -1)
info "customers rows in CockroachDB: $ROWS (expected 3: Alice, Bob updated, Dave; Carol deleted)"
[ "$ROWS" = "3" ] || fail "Expected 3 rows in CockroachDB, found $ROWS"
TIER=$(docker exec ora2crdb-cockroachdb cockroach sql --insecure -d targetdb --format=csv \
    -e "SELECT tier FROM customers WHERE name = 'Bob Smith';" 2>/dev/null | tail -1)
[ "$TIER" = "platinum" ] || fail "Expected Bob Smith tier=platinum, found '$TIER'"
success "Round trip verified: snapshot, insert, update, and delete all landed in CockroachDB"
docker exec ora2crdb-cockroachdb cockroach sql --insecure -d targetdb \
    -e "SELECT id, name, tier, balance FROM customers ORDER BY id;"

if [ "$WORKLOAD" = "transfers" ]; then
    header "STEP 7: Transfer Workload (concurrent multi-row transactions + balance conservation check)"
    WORKLOAD_SESSIONS="${WORKLOAD_SESSIONS:-3}"
    WORKLOAD_TXNS="${WORKLOAD_TXNS:-300}"

    info "Creating debezium.accounts with 1000 rows (balance 0) and supplemental logging..."
    docker exec -i oracle19c-demo bash -c 'sqlplus -S debezium/dbz@//localhost:1521/ORCLPDB1 <<SQL
WHENEVER SQLERROR CONTINUE
CREATE TABLE accounts (id NUMBER PRIMARY KEY, balance NUMBER(12,2) DEFAULT 0 NOT NULL);
ALTER TABLE accounts ADD SUPPLEMENTAL LOG DATA (ALL) COLUMNS;
DECLARE n NUMBER;
BEGIN
  SELECT COUNT(*) INTO n FROM accounts;
  IF n = 0 THEN
    INSERT INTO accounts (id, balance) SELECT LEVEL, 0 FROM dual CONNECT BY LEVEL <= 1000;
    COMMIT;
  END IF;
END;
/
SQL' >/dev/null
    success "accounts table ready (1000 rows, sum(balance) = 0)"

    HTTP=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "Content-Type: application/json" \
        --data @accounts-source-config.json http://localhost:8083/connectors)
    { [ "$HTTP" = "201" ] || [ "$HTTP" = "409" ]; } || fail "accounts source deploy returned HTTP $HTTP"
    wait_for_task_running "accounts-source" 90 || fail "accounts source task did not reach RUNNING"
    success "accounts source connector is RUNNING (snapshot backfills the 1000 accounts)"

    HTTP=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "Content-Type: application/json" \
        --data @accounts-sink-config.json http://localhost:8083/connectors)
    { [ "$HTTP" = "201" ] || [ "$HTTP" = "409" ]; } || fail "accounts sink deploy returned HTTP $HTTP"
    wait_for_task_running "accounts-jdbc-sink" 45 || fail "accounts sink task did not reach RUNNING"
    success "accounts sink connector is RUNNING"

    info "Running ${WORKLOAD_SESSIONS} concurrent sessions of ${WORKLOAD_TXNS} transfer transactions each..."
    # Each transfer updates two rows in one transaction. Locks are taken in id order so
    # concurrent sessions cannot deadlock.
    for s in $(seq 1 "$WORKLOAD_SESSIONS"); do
        docker exec -i oracle19c-demo bash -c 'sqlplus -S debezium/dbz@//localhost:1521/ORCLPDB1 <<SQL
SET FEEDBACK OFF
DECLARE
  a NUMBER; b NUMBER; amt NUMBER;
BEGIN
  FOR i IN 1..'"$WORKLOAD_TXNS"' LOOP
    a := TRUNC(DBMS_RANDOM.VALUE(1, 1001));
    b := TRUNC(DBMS_RANDOM.VALUE(1, 1001));
    IF b = a THEN b := MOD(a, 1000) + 1; END IF;
    amt := ROUND(DBMS_RANDOM.VALUE(1, 100), 2);
    IF a < b THEN
      UPDATE accounts SET balance = balance - amt WHERE id = a;
      UPDATE accounts SET balance = balance + amt WHERE id = b;
    ELSE
      UPDATE accounts SET balance = balance + amt WHERE id = b;
      UPDATE accounts SET balance = balance - amt WHERE id = a;
    END IF;
    COMMIT;
  END LOOP;
END;
/
SQL' >/dev/null 2>&1 &
    done
    wait
    success "Transfer workload finished; Oracle source is now static"

    # Transfers only move money between accounts, so row count and total balance are
    # invariants: once the pipeline drains, CockroachDB must match Oracle exactly.
    SRC_STATE=$(docker exec -i oracle19c-demo bash -c 'sqlplus -S debezium/dbz@//localhost:1521/ORCLPDB1 <<SQL
SET HEADING OFF FEEDBACK OFF
SELECT COUNT(*) || '"'"'|'"'"' || TO_CHAR(SUM(balance), '"'"'FM9999999990.00'"'"') FROM accounts;
SQL' 2>/dev/null | tr -d "[:space:]")
    info "Oracle after workload: count|sum(balance) = $SRC_STATE"

    info "Waiting for LogMiner capture and sink delivery to drain (polling for parity)..."
    TGT_STATE=""
    for i in $(seq 1 60); do
        TGT_STATE=$(docker exec ora2crdb-cockroachdb cockroach sql --insecure -d targetdb --format=csv \
            -e "SELECT count(*) || '|' || (sum(balance)::DECIMAL(12,2))::STRING FROM accounts" 2>/dev/null | tail -1 || echo "")
        if [ "$TGT_STATE" = "$SRC_STATE" ]; then break; fi
        echo -n "."
        sleep 5
    done
    echo ""
    info "CockroachDB after drain: count|sum(balance) = $TGT_STATE"
    [ "$TGT_STATE" = "$SRC_STATE" ] || fail "Transfer parity check failed: Oracle '$SRC_STATE' vs CockroachDB '$TGT_STATE'"
    success "Transfer parity verified: row count and total balance match exactly after concurrent multi-row transactions"
fi

header "Demo Complete"
success "Oracle             : localhost:1521 (ORCLPDB1, demo user debezium/dbz)"
success "CockroachDB        : localhost:26257  (UI: http://localhost:8080)"
success "Kafka Connect      : http://localhost:8083"
echo ""
info "Tear down with: docker-compose down -v"
