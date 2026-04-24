#!/bin/bash
# =============================================================================
# Deploy API Gateway con validacion JWT en GCP
# =============================================================================
# Prerequisitos:
#   - user-services desplegado con endpoint JWKS
#   - URLs de Cloud Run actualizadas en gateway/openapi-spec.yaml
# =============================================================================
set -euo pipefail

PROJECT_ID="${GCP_PROJECT_ID:-gen-lang-client-0930444414}"
REGION="${GCP_REGION:-us-central1}"
API_ID="${API_GATEWAY_ID:-travelhub-api}"
CONFIG_ID="travelhub-config-$(date +%Y%m%d-%H%M%S)"
GATEWAY_ID="${API_GATEWAY_NAME:-travelhub-gateway}"

echo "=== Step 1: Habilitar APIs necesarias ==="
gcloud services enable apigateway.googleapis.com --project="${PROJECT_ID}"
gcloud services enable servicemanagement.googleapis.com --project="${PROJECT_ID}"
gcloud services enable servicecontrol.googleapis.com --project="${PROJECT_ID}"

echo "=== Step 2: Crear la API (si no existe) ==="
gcloud api-gateway apis create "${API_ID}" \
  --project="${PROJECT_ID}" \
  2>/dev/null || echo "API '${API_ID}' already exists, continuing..."

echo "=== Step 3: Crear la configuracion del API con OpenAPI spec ==="
gcloud api-gateway api-configs create "${CONFIG_ID}" \
  --api="${API_ID}" \
  --openapi-spec=gateway/openapi-spec.yaml \
  --project="${PROJECT_ID}"

echo "=== Step 4: Desplegar el Gateway ==="
gcloud api-gateway gateways create "${GATEWAY_ID}" \
  --api="${API_ID}" \
  --api-config="${CONFIG_ID}" \
  --location="${REGION}" \
  --project="${PROJECT_ID}" \
  2>/dev/null || \
gcloud api-gateway gateways update "${GATEWAY_ID}" \
  --api="${API_ID}" \
  --api-config="${CONFIG_ID}" \
  --location="${REGION}" \
  --project="${PROJECT_ID}"

echo "=== Step 5: Obtener URL del Gateway ==="
GATEWAY_URL=$(gcloud api-gateway gateways describe "${GATEWAY_ID}" \
  --location="${REGION}" \
  --project="${PROJECT_ID}" \
  --format 'value(defaultHostname)')

echo ""
echo "============================================"
echo "API Gateway deployed successfully!"
echo "============================================"
echo "Project:     ${PROJECT_ID}"
echo "Region:      ${REGION}"
echo "Gateway URL: https://${GATEWAY_URL}"
echo "API Config:  ${CONFIG_ID}"
echo ""
echo "Test commands:"
echo "  # Sin JWT (debe retornar 401 en rutas protegidas):"
echo "  curl -s https://${GATEWAY_URL}/api/v1/bookings/list"
echo ""
echo "  # Con JWT valido:"
echo "  curl -s -H 'Authorization: Bearer <TOKEN>' https://${GATEWAY_URL}/api/v1/bookings/list"
echo ""
echo "  # Ruta publica (no requiere JWT):"
echo "  curl -s https://${GATEWAY_URL}/api/v1/auth/login"
echo "============================================"
