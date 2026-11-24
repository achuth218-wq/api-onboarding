#!/usr/bin/env sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
CERTS_DIR="$ROOT_DIR/certs"
ROOT_CA_DIR="$CERTS_DIR/root-ca"
INTERMEDIATE_DIR="$CERTS_DIR/intermediate"
DATA_PLANE_DIR="$CERTS_DIR/data-plane"

ROOT_CA_CN=${ROOT_CA_CN:-konnect-root-ca}
INTERMEDIATE_CA_CN=${INTERMEDIATE_CA_CN:-konnect-intermediate-ca}
DP_CERT_CN=${DP_CERT_CN:-kong-dp.internal}
DP_CERT_SAN=${DP_CERT_SAN:-DNS:kong-dp.internal}

mkdir -p "$ROOT_CA_DIR" "$INTERMEDIATE_DIR" "$DATA_PLANE_DIR"

INTERMEDIATE_EXT="$INTERMEDIATE_DIR/intermediate.ext"
LEAF_EXT="$DATA_PLANE_DIR/leaf.ext"

cat > "$INTERMEDIATE_EXT" <<EOF
basicConstraints=critical,CA:TRUE,pathlen:0
keyUsage=critical,keyCertSign,cRLSign
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid,issuer
EOF

cat > "$LEAF_EXT" <<EOF
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=clientAuth
subjectAltName=$DP_CERT_SAN
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid,issuer
EOF

openssl req -x509 -new -nodes -newkey rsa:4096 \
  -sha256 -days 3650 \
  -subj "/CN=$ROOT_CA_CN" \
  -keyout "$ROOT_CA_DIR/rootCA.key" \
  -out "$ROOT_CA_DIR/rootCA.crt"

openssl req -new -nodes -newkey rsa:4096 \
  -sha256 \
  -subj "/CN=$INTERMEDIATE_CA_CN" \
  -keyout "$INTERMEDIATE_DIR/intermediate.key" \
  -out "$INTERMEDIATE_DIR/intermediate.csr"

openssl x509 -req \
  -in "$INTERMEDIATE_DIR/intermediate.csr" \
  -CA "$ROOT_CA_DIR/rootCA.crt" \
  -CAkey "$ROOT_CA_DIR/rootCA.key" \
  -CAcreateserial \
  -days 1825 \
  -sha256 \
  -extfile "$INTERMEDIATE_EXT" \
  -out "$INTERMEDIATE_DIR/intermediate.crt"

openssl req -new -nodes -newkey rsa:4096 \
  -sha256 \
  -subj "/CN=$DP_CERT_CN" \
  -keyout "$DATA_PLANE_DIR/tls.key" \
  -out "$DATA_PLANE_DIR/tls.csr"

openssl x509 -req \
  -in "$DATA_PLANE_DIR/tls.csr" \
  -CA "$INTERMEDIATE_DIR/intermediate.crt" \
  -CAkey "$INTERMEDIATE_DIR/intermediate.key" \
  -CAcreateserial \
  -days 825 \
  -sha256 \
  -extfile "$LEAF_EXT" \
  -out "$DATA_PLANE_DIR/tls.crt"

cat "$DATA_PLANE_DIR/tls.crt" "$INTERMEDIATE_DIR/intermediate.crt" > "$DATA_PLANE_DIR/tls-chain.crt"

rm -f \
  "$INTERMEDIATE_DIR/intermediate.csr" \
  "$DATA_PLANE_DIR/tls.csr" \
  "$INTERMEDIATE_EXT" \
  "$LEAF_EXT"

echo "Generated certificates under $CERTS_DIR"
echo "Upload $ROOT_CA_DIR/rootCA.crt to Konnect as the trust anchor."
echo "Use $DATA_PLANE_DIR/tls-chain.crt and $DATA_PLANE_DIR/tls.key on the Kong data plane."
