#!/bin/bash
# Generate two cert chains for the fully-secure mTLS demo:
#
#   certs/kafka/ — Kafka mTLS material (openssl)
#     CA + broker cert (SAN: kafka,localhost) + client cert; JKS stores for cp-kafka
#     PEM files for the Debezium connector to inline into the CRDB sink URI
#
#   certs/crdb/  — CockroachDB secure-mode material (cockroach cert)
#     CA, node cert, client.root (for tooling), client.demo (for the connector)
#     plus client.demo.key.pk8 (PKCS#8 DER) so pgjdbc can load the key
#
# Re-running this script is idempotent: certs/ is rebuilt from scratch.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CERTS_DIR="${SCRIPT_DIR}/certs"
KAFKA_DIR="${CERTS_DIR}/kafka"
CRDB_DIR="${CERTS_DIR}/crdb"
CRDB_CA_KEY_DIR="${CERTS_DIR}/crdb-ca-key"
COCKROACHDB_IMAGE="cockroachdb/cockroach:${COCKROACHDB_VERSION:-v25.4.10}"
DAYS=3650
STORE_PASS="changeit"
KEY_PASS="changeit"

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

command -v openssl >/dev/null 2>&1 || fail "openssl is required"
command -v keytool >/dev/null 2>&1 || fail "keytool (from a JDK) is required"
command -v docker  >/dev/null 2>&1 || fail "docker is required (used to run 'cockroach cert' in a one-shot container)"

rm -rf "$CERTS_DIR"
mkdir -p "$KAFKA_DIR" "$CRDB_DIR" "$CRDB_CA_KEY_DIR"

# ────────────────────────────────────────────────────────────────────────────
# KAFKA mTLS chain
# ────────────────────────────────────────────────────────────────────────────
header "Generating Kafka mTLS chain (CA + broker + client) -> certs/kafka/"
cd "$KAFKA_DIR"

info "Self-signed CA (Debezium CRDB Demo Kafka CA)"
openssl genrsa -out ca.key 4096 2>/dev/null
openssl req -x509 -new -nodes -key ca.key -sha256 -days "$DAYS" \
    -subj "/C=US/ST=CA/L=SF/O=DebeziumDemo/OU=Kafka/CN=Debezium CRDB Demo Kafka CA" \
    -out ca.crt 2>/dev/null

info "Broker key + CSR (CN=kafka, SAN=DNS:kafka,DNS:localhost)"
cat > broker.cnf <<'EOF'
[req]
default_bits = 2048
prompt = no
default_md = sha256
distinguished_name = dn
req_extensions = req_ext

[dn]
C  = US
ST = CA
L  = SF
O  = DebeziumDemo
OU = Kafka
CN = kafka

[req_ext]
subjectAltName = @alt_names

[alt_names]
DNS.1 = kafka
DNS.2 = localhost
EOF
openssl genrsa -out broker.key 2048 2>/dev/null
openssl req -new -key broker.key -out broker.csr -config broker.cnf 2>/dev/null
cat > broker-ext.cnf <<'EOF'
subjectAltName = @alt_names
extendedKeyUsage = serverAuth

[alt_names]
DNS.1 = kafka
DNS.2 = localhost
EOF
openssl x509 -req -in broker.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
    -out broker.crt -days "$DAYS" -sha256 -extfile broker-ext.cnf 2>/dev/null

info "Client key + CSR (CN=kafka-client)"
openssl genrsa -out client.key 2048 2>/dev/null
openssl req -new -key client.key -out client.csr \
    -subj "/C=US/ST=CA/L=SF/O=DebeziumDemo/OU=KafkaClient/CN=kafka-client" 2>/dev/null
cat > client-ext.cnf <<'EOF'
extendedKeyUsage = clientAuth
EOF
openssl x509 -req -in client.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
    -out client.crt -days "$DAYS" -sha256 -extfile client-ext.cnf 2>/dev/null

info "Normalize client.key to PKCS#8 PEM (CockroachDB enriched changefeed reads PKCS#8)"
openssl pkcs8 -topk8 -nocrypt -in client.key -out client.pk8.key 2>/dev/null
mv client.pk8.key client.key

info "Broker keystore (PKCS#12 -> JKS)"
openssl pkcs12 -export -in broker.crt -inkey broker.key -name kafka \
    -CAfile ca.crt -caname rootCA \
    -out broker.p12 -password "pass:$STORE_PASS" 2>/dev/null
keytool -importkeystore -srckeystore broker.p12 -srcstoretype PKCS12 \
    -srcstorepass "$STORE_PASS" \
    -destkeystore broker.keystore.jks -deststoretype JKS \
    -deststorepass "$STORE_PASS" -destkeypass "$KEY_PASS" \
    -noprompt >/dev/null 2>&1

info "Broker truststore (CA cert only)"
keytool -import -trustcacerts -alias rootCA -file ca.crt \
    -keystore broker.truststore.jks -storepass "$STORE_PASS" \
    -noprompt >/dev/null 2>&1

info "Client keystore (used by kafka-console-consumer for the mTLS sanity check)"
openssl pkcs12 -export -in client.crt -inkey client.key -name client \
    -CAfile ca.crt -caname rootCA \
    -out client.p12 -password "pass:$STORE_PASS" 2>/dev/null
keytool -importkeystore -srckeystore client.p12 -srcstoretype PKCS12 \
    -srcstorepass "$STORE_PASS" \
    -destkeystore client.keystore.jks -deststoretype JKS \
    -deststorepass "$STORE_PASS" -destkeypass "$KEY_PASS" \
    -noprompt >/dev/null 2>&1

echo "$STORE_PASS" > keystore_creds
echo "$KEY_PASS"   > key_creds
echo "$STORE_PASS" > truststore_creds

rm -f broker.csr broker.cnf broker-ext.cnf broker.p12 \
      client.csr client-ext.cnf client.p12 ca.srl

chmod 644 *.crt *.jks keystore_creds key_creds truststore_creds
chmod 600 *.key
success "Kafka mTLS chain ready in $KAFKA_DIR"

# ────────────────────────────────────────────────────────────────────────────
# CockroachDB secure-mode chain (via `cockroach cert` in a one-shot container)
# ────────────────────────────────────────────────────────────────────────────
header "Generating CockroachDB secure-mode chain (CA + node + client.root + client.demo) -> certs/crdb/"
cd "$SCRIPT_DIR"

# Run the cockroach CLI inside a container; mount certs/crdb/ as the certs-dir
# and certs/crdb-ca-key/ as the safe directory for the CA key.
COCKROACH_CERT="docker run --rm \
    --volume ${CRDB_DIR}:/certs \
    --volume ${CRDB_CA_KEY_DIR}:/ca-key \
    ${COCKROACHDB_IMAGE} cert"

info "Creating CA"
$COCKROACH_CERT create-ca --certs-dir=/certs --ca-key=/ca-key/ca.key

info "Creating node cert (SANs: cockroachdb, localhost, 127.0.0.1)"
$COCKROACH_CERT create-node cockroachdb localhost 127.0.0.1 \
    --certs-dir=/certs --ca-key=/ca-key/ca.key

info "Creating client cert for root (used by 'cockroach sql' tooling)"
$COCKROACH_CERT create-client root \
    --certs-dir=/certs --ca-key=/ca-key/ca.key

info "Creating client cert for demo (used by the Debezium connector)"
$COCKROACH_CERT create-client demo \
    --certs-dir=/certs --ca-key=/ca-key/ca.key

info "Converting client.demo.key (PEM) to PKCS#8 DER for pgjdbc (sslkey)"
openssl pkcs8 -topk8 -inform PEM -outform DER \
    -in "${CRDB_DIR}/client.demo.key" \
    -out "${CRDB_DIR}/client.demo.key.pk8" -nocrypt 2>/dev/null

# pgjdbc requires the DER key to be world-readable (0644). Demo only.
chmod 644 "${CRDB_DIR}/client.demo.key.pk8" \
          "${CRDB_DIR}/ca.crt" \
          "${CRDB_DIR}/client.demo.crt"

# `cockroach cert` writes node.key + client.*.key as 0600 owned by uid 0 (root
# inside the one-shot container). Loosen on the host so the demo can read for
# verification. CockroachDB itself will still validate strict perms via its own
# checks because the container re-mounts /certs at runtime.
chmod 644 "${CRDB_DIR}"/*.crt
chmod 600 "${CRDB_DIR}"/*.key 2>/dev/null || true

success "CockroachDB secure-mode chain ready in $CRDB_DIR"

# ────────────────────────────────────────────────────────────────────────────
ls -la "$KAFKA_DIR" "$CRDB_DIR"
echo ""
success "All TLS material generated."
info "Kafka (mounted into cp-kafka /etc/kafka/secrets/):"
info "  broker.keystore.jks, broker.truststore.jks, keystore_creds, key_creds, truststore_creds"
info "Kafka (mounted into Connect /etc/kafka-tls/ for the connector to read):"
info "  ca.crt, client.crt, client.key"
info "CockroachDB (mounted into CRDB /cockroach/cockroach-certs/):"
info "  ca.crt, node.crt, node.key, client.root.crt, client.root.key"
info "CockroachDB (mounted into Connect /etc/crdb-tls/ for pgjdbc):"
info "  ca.crt, client.demo.crt, client.demo.key.pk8"
