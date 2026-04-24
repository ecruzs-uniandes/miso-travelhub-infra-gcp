#!/bin/bash
# ============================================================
# TravelHub — Step 07: API Gateway
# ============================================================
# Genera la OpenAPI spec dinamicamente desde el template y
# despliega el API Gateway con validacion JWT.
# Idempotente: crea o actualiza segun corresponda.
#
# Prerequisitos:
#   - user-services desplegado (para JWKS endpoint)
#   - USER_SERVICES_URL definida en el .env
#
# Uso:
#   source config/environments/dev.env && bash scripts/07-gateway.sh
# ============================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
require_env

TEMPLATE_FILE="${REPO_DIR}/gateway/openapi-spec.template.yaml"
SPEC_FILE="/tmp/${PREFIX}-openapi-spec.yaml"
CONFIG_ID="${PREFIX}-config-$(date +%Y%m%d-%H%M%S)"

log_step "Generando OpenAPI spec desde template"

if [[ ! -f "${TEMPLATE_FILE}" ]]; then
  log_error "Template no encontrado: ${TEMPLATE_FILE}"
  exit 1
fi

# Si una URL esta vacia, usar un placeholder que retorna 503
# (evita que el gateway falle por URLs invalidas)
EFFECTIVE_USER_SERVICES_URL="${USER_SERVICES_URL:-https://placeholder-user-services.example.com}"
EFFECTIVE_SEARCH_SERVICES_URL="${SEARCH_SERVICES_URL:-https://placeholder-search-services.example.com}"
EFFECTIVE_BOOKING_SERVICES_URL="${BOOKING_SERVICES_URL:-https://placeholder-booking-services.example.com}"
EFFECTIVE_PAYMENTS_SERVICES_URL="${PAYMENTS_SERVICES_URL:-https://placeholder-payments-services.example.com}"
EFFECTIVE_INVENTORY_SERVICES_URL="${INVENTORY_SERVICES_URL:-https://placeholder-inventory-services.example.com}"
EFFECTIVE_NOTIFICATION_SERVICES_URL="${NOTIFICATION_SERVICES_URL:-https://placeholder-notification-services.example.com}"
EFFECTIVE_PMS_SERVICES_URL="${PMS_SERVICES_URL:-https://placeholder-pms-services.example.com}"
EFFECTIVE_CART_SERVICES_URL="${CART_SERVICES_URL:-https://placeholder-cart-services.example.com}"

# JWKS URI: si no esta definido, usar el endpoint de user-services
if [[ -z "${JWKS_URI:-}" ]]; then
  EFFECTIVE_JWKS_URI="${EFFECTIVE_USER_SERVICES_URL}/.well-known/jwks.json"
else
  EFFECTIVE_JWKS_URI="${JWKS_URI}"
fi

# Reemplazar placeholders con envsubst
log_info "Reemplazando placeholders en template..."
export USER_SERVICES_URL="${EFFECTIVE_USER_SERVICES_URL}"
export SEARCH_SERVICES_URL="${EFFECTIVE_SEARCH_SERVICES_URL}"
export BOOKING_SERVICES_URL="${EFFECTIVE_BOOKING_SERVICES_URL}"
export PAYMENTS_SERVICES_URL="${EFFECTIVE_PAYMENTS_SERVICES_URL}"
export INVENTORY_SERVICES_URL="${EFFECTIVE_INVENTORY_SERVICES_URL}"
export NOTIFICATION_SERVICES_URL="${EFFECTIVE_NOTIFICATION_SERVICES_URL}"
export PMS_SERVICES_URL="${EFFECTIVE_PMS_SERVICES_URL}"
export CART_SERVICES_URL="${EFFECTIVE_CART_SERVICES_URL}"
export JWKS_URI="${EFFECTIVE_JWKS_URI}"

# El host del gateway se obtendra despues de crearlo; usar placeholder temporal
# si ya existe el gateway, obtener el hostname real
if gateway_exists "${API_GATEWAY_NAME}" "${GCP_REGION}"; then
  GATEWAY_HOST=$(gcloud api-gateway gateways describe "${API_GATEWAY_NAME}" \
    --location="${GCP_REGION}" \
    --project="${GCP_PROJECT_ID}" \
    --format="value(defaultHostname)")
  export GATEWAY_HOST="${GATEWAY_HOST}"
  log_info "Gateway existente, hostname: ${GATEWAY_HOST}"
else
  # Primer deploy: usar placeholder; se actualizara con redeploy
  export GATEWAY_HOST="${PREFIX}-gateway.apigateway.${GCP_PROJECT_ID}.cloud.goog"
  log_warn "Gateway no existe aun. Usando hostname tentativo: ${GATEWAY_HOST}"
fi

envsubst < "${TEMPLATE_FILE}" > "${SPEC_FILE}"
log_success "Spec generada en ${SPEC_FILE}"

# ── Crear API si no existe ──
log_step "Configurando API Gateway: ${API_GATEWAY_ID}"

if gateway_api_exists "${API_GATEWAY_ID}"; then
  log_warn "API '${API_GATEWAY_ID}' ya existe — omitiendo"
else
  log_info "Creando API '${API_GATEWAY_ID}'..."
  gcloud api-gateway apis create "${API_GATEWAY_ID}" \
    --project="${GCP_PROJECT_ID}"
  log_success "API '${API_GATEWAY_ID}' creada"
fi

# ── Crear nueva API config (siempre nueva para actualizar la spec) ──
log_info "Creando API config '${CONFIG_ID}'..."
gcloud api-gateway api-configs create "${CONFIG_ID}" \
  --api="${API_GATEWAY_ID}" \
  --openapi-spec="${SPEC_FILE}" \
  --project="${GCP_PROJECT_ID}"
log_success "API config '${CONFIG_ID}' creada"

# ── Crear o actualizar gateway ──
log_step "Desplegando gateway: ${API_GATEWAY_NAME}"

if gateway_exists "${API_GATEWAY_NAME}" "${GCP_REGION}"; then
  log_info "Actualizando gateway '${API_GATEWAY_NAME}' con nueva config..."
  gcloud api-gateway gateways update "${API_GATEWAY_NAME}" \
    --api="${API_GATEWAY_ID}" \
    --api-config="${CONFIG_ID}" \
    --location="${GCP_REGION}" \
    --project="${GCP_PROJECT_ID}"
  log_success "Gateway '${API_GATEWAY_NAME}' actualizado"
else
  log_info "Creando gateway '${API_GATEWAY_NAME}'..."
  gcloud api-gateway gateways create "${API_GATEWAY_NAME}" \
    --api="${API_GATEWAY_ID}" \
    --api-config="${CONFIG_ID}" \
    --location="${GCP_REGION}" \
    --project="${GCP_PROJECT_ID}"
  log_success "Gateway '${API_GATEWAY_NAME}' creado"
fi

# ── Obtener URL del gateway ──
GATEWAY_URL=$(gcloud api-gateway gateways describe "${API_GATEWAY_NAME}" \
  --location="${GCP_REGION}" \
  --project="${GCP_PROJECT_ID}" \
  --format="value(defaultHostname)")

# Limpiar spec temporal
rm -f "${SPEC_FILE}"

echo ""
log_success "API Gateway desplegado"
echo ""
echo "Resumen:"
echo "  API ID:      ${API_GATEWAY_ID}"
echo "  Config ID:   ${CONFIG_ID}"
echo "  Gateway URL: https://${GATEWAY_URL}"
echo ""
echo "Test commands:"
echo "  curl -s https://${GATEWAY_URL}/.well-known/jwks.json"
echo "  curl -s https://${GATEWAY_URL}/api/v1/auth/login  (publico)"
echo "  curl -s https://${GATEWAY_URL}/api/v1/bookings/list  (esperado: 401 sin JWT)"
