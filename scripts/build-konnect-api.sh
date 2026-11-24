#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

SERVICE="${1:-orders}"
TARGET_ENVIRONMENT="${2:-development}"
if [[ ! "$SERVICE" =~ ^[a-z][a-z0-9]*(-[a-z0-9]+)*$ || "$SERVICE" == all ]]; then
  echo "Use a service folder name such as orders or inventory." >&2
  exit 1
fi
API_NAME="${SERVICE}-api"
API_DIR="apis/$SERVICE"
case "$TARGET_ENVIRONMENT" in
  development) GATEWAY_FILE="$API_DIR/gateway-patches.yaml" ;;
  staging|production) GATEWAY_FILE="$API_DIR/environments/$TARGET_ENVIRONMENT/gateway-patches.yaml" ;;
  *) echo "Environment must be development, staging, or production." >&2; exit 1 ;;
esac
if [[ ! -f "$GATEWAY_FILE" ]]; then
  echo "Create $GATEWAY_FILE with static settings for $TARGET_ENVIRONMENT." >&2
  exit 1
fi
OUTPUT_DIR="build/$TARGET_ENVIRONMENT/$SERVICE"

export DECK_ANALYTICS=false
mkdir -p "$OUTPUT_DIR"

# Catch a copied spec that still has another service's identity before deploying.
python3 - "$API_DIR/openapi.yaml" "$API_NAME" <<'PY'
import sys
import yaml
with open(sys.argv[1]) as source:
    spec = yaml.safe_load(source)
if spec.get('x-kong-name') != sys.argv[2]:
    raise SystemExit(f"Set x-kong-name to {sys.argv[2]} in {sys.argv[1]}")
PY

python3 -m openapi_spec_validator "$API_DIR/openapi.yaml"

# Authentication is supplied by the separate key-auth plugin file. Do not use
# --generate-security, which generates OIDC plugins from supported OAS schemes.
deck file openapi2kong \
  --spec "$API_DIR/openapi.yaml" \
  --uuid-base "$API_NAME" \
  --output-file "$OUTPUT_DIR/base.yaml"

deck file patch \
  --state "$OUTPUT_DIR/base.yaml" \
  --output-file "$OUTPUT_DIR/patched.yaml" \
  "$GATEWAY_FILE"

deck file add-plugins \
  --state "$OUTPUT_DIR/patched.yaml" \
  --output-file "$OUTPUT_DIR/plugins.yaml" \
  "$API_DIR"/plugins/*.yaml

# Tag after adding plugins so services, routes AND plugins share ownership.
deck file add-tags \
  --state "$OUTPUT_DIR/plugins.yaml" \
  --output-file "$OUTPUT_DIR/kong.yaml" \
  "api:$API_NAME" managed-by:github-actions

# Deploy this state directly to retain stable Service and Route IDs.
deck file validate "$OUTPUT_DIR/kong.yaml" --konnect-compatibility

echo "Validated API configuration: $OUTPUT_DIR/kong.yaml"
