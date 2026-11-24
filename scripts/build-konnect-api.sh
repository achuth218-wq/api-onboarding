#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

export DECK_ANALYTICS=false
export DECK_ORDERS_UPSTREAM_HOST="${DECK_ORDERS_UPSTREAM_HOST:-orders.internal.example.com}"
export DECK_KONNECT_CONTROL_PLANE_NAME="${DECK_KONNECT_CONTROL_PLANE_NAME:-offline-validation}"
mkdir -p build

python3 -m openapi_spec_validator apis/orders/openapi.yaml

# Authentication is supplied by the separate key-auth plugin file. Do not use
# --generate-security, which generates OIDC plugins from supported OAS schemes.
deck file openapi2kong \
  --spec apis/orders/openapi.yaml \
  --uuid-base orders-api \
  --output-file build/orders-api.base.yaml

deck file patch \
  --state build/orders-api.base.yaml \
  --output-file build/orders-api.patched.yaml \
  apis/orders/gateway-patches.yaml

deck file add-plugins \
  --state build/orders-api.patched.yaml \
  --output-file build/orders-api.plugins.yaml \
  apis/orders/plugins/*.yaml

# Tag after adding plugins so services, routes AND plugins share ownership.
deck file add-tags \
  --state build/orders-api.plugins.yaml \
  --output-file build/orders-api.template.yaml \
  api:orders-api managed-by:github-actions

deck file render build/orders-api.template.yaml \
  --populate-env-vars --output-file build/orders-api.yaml
# Validate and deploy the template directly: render produces an inspection copy
# and removes entity IDs. Gateway commands resolve the template at runtime.
deck file validate build/orders-api.template.yaml --konnect-compatibility

echo "Validated API configuration: build/orders-api.yaml"
echo "Deployment template: build/orders-api.template.yaml"
