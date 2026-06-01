#!/usr/bin/env bash
#
# Mint a realm-signed service-principal cert for hecate-mpong-bot from the
# deployed realm (macula-realm). Run once per bot instance at install time,
# on the infra node that will host the container.
#
# The realm endpoint is POST /api/v1/services/provision
# (ServicePrincipalIssuanceController): we generate the bot's Ed25519
# keypair locally (the realm only ever signs the PUBLIC half), present the
# host node's refresh token, and the realm returns the signed cert. hecate_om
# loads the cert at boot (held for v2 realm-membership enforcement; v1
# connect/publish does not require it — see config/sys.config).
#
# Usage:
#   MACULA_REALM_REFRESH_TOKEN=<node refresh token> \
#     scripts/provision-service-cert.sh [node-name]
#
# Env:
#   MACULA_REALM_REFRESH_TOKEN  (required) the host node's realm refresh token
#   REALM_URL                   (default https://macula.io)
#   SECRETS_DIR                 (default /etc/hecate/secrets/hecate-mpong-bot)
set -euo pipefail

SERVICE_NAME="hecate-mpong-bot"
REALM_URL="${REALM_URL:-https://macula.io}"
NODE_NAME="${1:-$(hostname -s)}"
SECRETS_DIR="${SECRETS_DIR:-/etc/hecate/secrets/${SERVICE_NAME}}"
: "${MACULA_REALM_REFRESH_TOKEN:?set MACULA_REALM_REFRESH_TOKEN (the host node's realm refresh token)}"

command -v openssl >/dev/null || { echo "openssl required" >&2; exit 1; }
command -v jq      >/dev/null || { echo "jq required" >&2; exit 1; }

mkdir -p "$SECRETS_DIR"; chmod 0700 "$SECRETS_DIR"
KEY="$SECRETS_DIR/identity.pem"

# 1. Ed25519 keypair — the service keeps the private half forever.
[ -f "$KEY" ] || openssl genpkey -algorithm ed25519 -out "$KEY"
chmod 0600 "$KEY"

# 2. Raw 32-byte public key, base64. (Ed25519 SPKI DER is 44 bytes; the raw
#    key is the trailing 32 — which is exactly what the realm expects.)
PUBKEY_B64=$(openssl pkey -in "$KEY" -pubout -outform DER | tail -c 32 | base64 -w0)

# 3. Provision. The refresh token rides only in the Authorization header,
#    never echoed.
RESP=$(curl -fsS -X POST "${REALM_URL}/api/v1/services/provision" \
    -H "Authorization: Bearer ${MACULA_REALM_REFRESH_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"public_key\":\"${PUBKEY_B64}\",\"service_name\":\"${SERVICE_NAME}\",\"node_name\":\"${NODE_NAME}\"}")

# 4. Write the realm-signed cert + CA chain.
printf '%s' "$RESP" | jq -er '.cert_pem'     > "$SECRETS_DIR/service-cert.pem"
printf '%s' "$RESP" | jq -er '.ca_chain_pem' > "$SECRETS_DIR/ca-chain.pem"
chmod 0644 "$SECRETS_DIR/service-cert.pem" "$SECRETS_DIR/ca-chain.pem"

echo "provisioned: $(printf '%s' "$RESP" | jq -r '.service_mri')  (node ${NODE_NAME})"
echo "  key   -> ${KEY}            (0600, private — never leaves this host)"
echo "  cert  -> ${SECRETS_DIR}/service-cert.pem"
echo
echo "Container mount: ${SECRETS_DIR}/service-cert.pem -> /etc/hecate/secrets/service-cert.pem (ro)"
