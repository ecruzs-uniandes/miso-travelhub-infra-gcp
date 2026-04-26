#!/bin/bash
# ============================================================
# TravelHub — Step 08: Load Balancer
# ============================================================
# Crea el flujo completo de LB:
#   IP Estatica -> LB (HTTPS) -> Cloud Armor -> API Gateway -> Cloud Run
#
# El hostname del gateway se obtiene dinamicamente (no hardcodeado).
# Idempotente: verifica existencia antes de crear cada recurso.
#
# Uso:
#   source config/environments/dev.env && bash scripts/08-load-balancer.sh
# ============================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
require_env

log_step "Configurando Load Balancer para ambiente: ${ENV}"

# ── Obtener hostname del gateway dinamicamente ──
log_info "Obteniendo hostname del gateway '${API_GATEWAY_NAME}'..."
if ! gateway_exists "${API_GATEWAY_NAME}" "${GCP_REGION}"; then
  log_error "Gateway '${API_GATEWAY_NAME}' no existe. Ejecuta primero el script 07-gateway.sh"
  exit 1
fi

GATEWAY_HOSTNAME=$(gcloud api-gateway gateways describe "${API_GATEWAY_NAME}" \
  --location="${GCP_REGION}" \
  --project="${GCP_PROJECT_ID}" \
  --format="value(defaultHostname)")
log_info "Gateway hostname: ${GATEWAY_HOSTNAME}"

# ── Step 1: Reservar IP estatica global ──
log_step "Step 1: IP estatica global"

if resource_exists "addresses" "${LB_IP_NAME}" "--global"; then
  log_warn "IP '${LB_IP_NAME}' ya existe — omitiendo"
else
  log_info "Reservando IP estatica '${LB_IP_NAME}'..."
  gcloud compute addresses create "${LB_IP_NAME}" \
    --global \
    --ip-version=IPV4 \
    --project="${GCP_PROJECT_ID}"
  log_success "IP '${LB_IP_NAME}' reservada"
fi

STATIC_IP=$(gcloud compute addresses describe "${LB_IP_NAME}" \
  --global \
  --project="${GCP_PROJECT_ID}" \
  --format="value(address)")
log_info "IP estatica: ${STATIC_IP}"

# ── Step 2: Crear Internet NEG apuntando al API Gateway ──
log_step "Step 2: Internet NEG"

if resource_exists "network-endpoint-groups" "${LB_NEG_NAME}" "--global"; then
  log_warn "NEG '${LB_NEG_NAME}' ya existe — omitiendo creacion"
else
  log_info "Creando Internet NEG '${LB_NEG_NAME}'..."
  gcloud compute network-endpoint-groups create "${LB_NEG_NAME}" \
    --network-endpoint-type=INTERNET_FQDN_PORT \
    --global \
    --project="${GCP_PROJECT_ID}"
  log_success "NEG '${LB_NEG_NAME}' creado"

  log_info "Agregando endpoint del gateway al NEG..."
  gcloud compute network-endpoint-groups update "${LB_NEG_NAME}" \
    --add-endpoint="fqdn=${GATEWAY_HOSTNAME},port=443" \
    --global \
    --project="${GCP_PROJECT_ID}"
  log_success "Endpoint del gateway agregado al NEG"
fi

# ── Step 3: Backend Service con Cloud Armor ──
log_step "Step 3: Backend Service"

if resource_exists "backend-services" "${LB_BACKEND_NAME}" "--global"; then
  log_warn "Backend service '${LB_BACKEND_NAME}' ya existe — actualizando configuracion"
  # Actualizar host header (puede haber cambiado el gateway hostname)
  gcloud compute backend-services update "${LB_BACKEND_NAME}" \
    --custom-request-header="Host: ${GATEWAY_HOSTNAME}" \
    --global \
    --project="${GCP_PROJECT_ID}"
else
  log_info "Creando Backend Service '${LB_BACKEND_NAME}'..."
  gcloud compute backend-services create "${LB_BACKEND_NAME}" \
    --global \
    --protocol=HTTPS \
    --port-name=https \
    --project="${GCP_PROJECT_ID}"
  log_success "Backend Service '${LB_BACKEND_NAME}' creado"

  log_info "Agregando NEG al backend service..."
  gcloud compute backend-services add-backend "${LB_BACKEND_NAME}" \
    --global \
    --network-endpoint-group="${LB_NEG_NAME}" \
    --global-network-endpoint-group \
    --project="${GCP_PROJECT_ID}"
  log_success "NEG agregado al backend service"

  log_info "Configurando Host header para API Gateway..."
  gcloud compute backend-services update "${LB_BACKEND_NAME}" \
    --custom-request-header="Host: ${GATEWAY_HOSTNAME}" \
    --global \
    --project="${GCP_PROJECT_ID}"
fi

CLOUD_ARMOR_ENABLED="${CLOUD_ARMOR_ENABLED:-true}"
if [[ "${CLOUD_ARMOR_ENABLED}" == "true" ]]; then
  log_info "Asociando Cloud Armor '${CLOUD_ARMOR_POLICY}' al backend..."
  gcloud compute backend-services update "${LB_BACKEND_NAME}" \
    --security-policy="${CLOUD_ARMOR_POLICY}" \
    --global \
    --project="${GCP_PROJECT_ID}"
  log_success "Cloud Armor asociado al backend"
else
  log_warn "Cloud Armor DESHABILITADO — desasociando policy del backend si existia..."
  gcloud compute backend-services update "${LB_BACKEND_NAME}" \
    --no-security-policy \
    --global \
    --project="${GCP_PROJECT_ID}" 2>/dev/null || true
  log_warn "Backend sin security policy. Activar con CLOUD_ARMOR_ENABLED=true."
fi

# ── Step 4: URL Map ──
log_step "Step 4: URL Map"

if resource_exists "url-maps" "${LB_URL_MAP_NAME}" "--global"; then
  log_warn "URL map '${LB_URL_MAP_NAME}' ya existe — omitiendo"
else
  log_info "Creando URL map '${LB_URL_MAP_NAME}'..."
  gcloud compute url-maps create "${LB_URL_MAP_NAME}" \
    --default-service="${LB_BACKEND_NAME}" \
    --global \
    --project="${GCP_PROJECT_ID}"
  log_success "URL map '${LB_URL_MAP_NAME}' creado"
fi

# ── Step 5: Certificado SSL ──
log_step "Step 5: Certificado SSL"

SSL_MODE="${SSL_MODE:-self-signed}"

if resource_exists "ssl-certificates" "${LB_CERT_NAME}" "--global"; then
  log_warn "Certificado SSL '${LB_CERT_NAME}' ya existe — omitiendo"
else
  if [[ "${SSL_MODE}" == "managed" ]]; then
    # Certificado managed con dominio (el DNS debe apuntar a la IP del LB)
    log_info "Creando certificado SSL managed para dominio '${DOMAIN}'..."
    gcloud compute ssl-certificates create "${LB_CERT_NAME}" \
      --domains="${DOMAIN}" \
      --global \
      --project="${GCP_PROJECT_ID}"
    log_success "Certificado SSL managed creado para ${DOMAIN}"
    log_warn "El cert puede tardar hasta 60 min en provisionarse. Verifica que el DNS ${DOMAIN} apunte a la IP del LB."
  else
    # Certificado self-signed (dev o prod-de-prueba)
    log_info "Generando certificado SSL self-signed (SSL_MODE=${SSL_MODE})..."
    CERT_DIR="/tmp/${PREFIX}-ssl"
    mkdir -p "${CERT_DIR}"

    openssl req -x509 -nodes -days 365 \
      -newkey rsa:2048 \
      -keyout "${CERT_DIR}/private.key" \
      -out "${CERT_DIR}/certificate.crt" \
      -subj "/C=CO/ST=Bogota/L=Bogota/O=TravelHub/CN=${STATIC_IP}" \
      2>/dev/null

    gcloud compute ssl-certificates create "${LB_CERT_NAME}" \
      --certificate="${CERT_DIR}/certificate.crt" \
      --private-key="${CERT_DIR}/private.key" \
      --global \
      --project="${GCP_PROJECT_ID}"

    rm -rf "${CERT_DIR}"
    log_success "Certificado SSL self-signed creado"
  fi
fi

# ── Step 6: Target HTTPS Proxy ──
log_step "Step 6: HTTPS Proxy"

if resource_exists "target-https-proxies" "${LB_PROXY_NAME}" "--global"; then
  log_warn "HTTPS proxy '${LB_PROXY_NAME}' ya existe — omitiendo"
else
  log_info "Creando Target HTTPS Proxy '${LB_PROXY_NAME}'..."
  gcloud compute target-https-proxies create "${LB_PROXY_NAME}" \
    --url-map="${LB_URL_MAP_NAME}" \
    --ssl-certificates="${LB_CERT_NAME}" \
    --global \
    --project="${GCP_PROJECT_ID}"
  log_success "HTTPS proxy '${LB_PROXY_NAME}' creado"
fi

# ── Step 7: Forwarding Rule ──
log_step "Step 7: Forwarding Rule"

if resource_exists "forwarding-rules" "${LB_FWD_RULE_NAME}" "--global"; then
  log_warn "Forwarding rule '${LB_FWD_RULE_NAME}' ya existe — omitiendo"
else
  log_info "Creando Forwarding Rule '${LB_FWD_RULE_NAME}'..."
  gcloud compute forwarding-rules create "${LB_FWD_RULE_NAME}" \
    --global \
    --address="${LB_IP_NAME}" \
    --target-https-proxy="${LB_PROXY_NAME}" \
    --ports=443 \
    --project="${GCP_PROJECT_ID}"
  log_success "Forwarding Rule '${LB_FWD_RULE_NAME}' creada"
fi

echo ""
log_success "Load Balancer configurado"
echo ""
echo "Resumen:"
echo "  IP estatica:   ${STATIC_IP} (${LB_IP_NAME})"
echo "  Gateway FQDN:  ${GATEWAY_HOSTNAME}"
echo "  Cloud Armor:   $([ "${CLOUD_ARMOR_ENABLED}" == "true" ] && echo "${CLOUD_ARMOR_POLICY}" || echo "DESHABILITADO")"
echo "  SSL:           $([ "${SSL_MODE}" == "managed" ] && echo "Managed (${DOMAIN})" || echo "Self-signed")"
echo ""
echo "Flujo:"
echo "  Internet -> ${STATIC_IP} -> LB -> Cloud Armor -> API Gateway -> Cloud Run"
echo ""
echo "Test:"
echo "  curl -k https://${STATIC_IP}/health"
echo "  curl -k https://${STATIC_IP}/.well-known/jwks.json"
echo "  curl -k https://${STATIC_IP}/api/v1/bookings/list  (esperado: 401)"
