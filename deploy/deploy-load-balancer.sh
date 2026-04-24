#!/bin/bash
# =============================================================================
# TravelHub — Load Balancer + IP Estatica + Cloud Armor
# =============================================================================
# Crea el flujo completo:
#   IP Estatica → LB (HTTPS) → Cloud Armor → API Gateway → Cloud Run
#
# Recursos creados:
#   1. IP estatica global
#   2. Internet NEG apuntando al API Gateway
#   3. Backend service con Cloud Armor
#   4. URL map
#   5. Certificado SSL self-signed (dev)
#   6. Target HTTPS proxy
#   7. Forwarding rule
# =============================================================================
set -euo pipefail

PROJECT_ID="${GCP_PROJECT_ID:-gen-lang-client-0930444414}"
REGION="${GCP_REGION:-us-central1}"
POLICY_NAME="${CLOUD_ARMOR_POLICY:-travelhub-security-policy}"
GATEWAY_HOSTNAME="${GATEWAY_HOSTNAME:-travelhub-gateway-1yvtqj7r.uc.gateway.dev}"

IP_NAME="travelhub-lb-ip"
NEG_NAME="travelhub-gateway-neg"
BACKEND_NAME="travelhub-backend-service"
URL_MAP_NAME="travelhub-url-map"
CERT_NAME="travelhub-ssl-cert"
PROXY_NAME="travelhub-https-proxy"
FWD_RULE_NAME="travelhub-forwarding-rule"

# ─────────────────────────────────────────────────────────────────────────────
# Step 1: Reservar IP estatica global
# ─────────────────────────────────────────────────────────────────────────────
echo "=== Step 1: Reservando IP estatica global ==="
gcloud compute addresses create "${IP_NAME}" \
  --global \
  --ip-version=IPV4 \
  --project="${PROJECT_ID}" \
  2>/dev/null || echo "IP '${IP_NAME}' already exists, continuing..."

STATIC_IP=$(gcloud compute addresses describe "${IP_NAME}" \
  --global \
  --project="${PROJECT_ID}" \
  --format="value(address)")
echo "IP reservada: ${STATIC_IP}"

# ─────────────────────────────────────────────────────────────────────────────
# Step 2: Crear Internet NEG apuntando al API Gateway
# El NEG usa INTERNET_FQDN_PORT para apuntar al hostname del gateway
# ─────────────────────────────────────────────────────────────────────────────
echo "=== Step 2: Creando Internet NEG ==="
gcloud compute network-endpoint-groups create "${NEG_NAME}" \
  --network-endpoint-type=INTERNET_FQDN_PORT \
  --global \
  --project="${PROJECT_ID}" \
  2>/dev/null || echo "NEG '${NEG_NAME}' already exists, continuing..."

echo "=== Agregando endpoint del API Gateway al NEG ==="
gcloud compute network-endpoint-groups update "${NEG_NAME}" \
  --add-endpoint="fqdn=${GATEWAY_HOSTNAME},port=443" \
  --global \
  --project="${PROJECT_ID}" \
  2>/dev/null || echo "Endpoint already exists in NEG, continuing..."

# ─────────────────────────────────────────────────────────────────────────────
# Step 3: Crear Backend Service y asociar NEG + Cloud Armor
# ─────────────────────────────────────────────────────────────────────────────
echo "=== Step 3: Creando Backend Service ==="
gcloud compute backend-services create "${BACKEND_NAME}" \
  --global \
  --protocol=HTTPS \
  --port-name=https \
  --project="${PROJECT_ID}" \
  2>/dev/null || echo "Backend service '${BACKEND_NAME}' already exists, continuing..."

echo "=== Agregando NEG al Backend Service ==="
gcloud compute backend-services add-backend "${BACKEND_NAME}" \
  --global \
  --network-endpoint-group="${NEG_NAME}" \
  --global-network-endpoint-group \
  --project="${PROJECT_ID}" \
  2>/dev/null || echo "Backend already has NEG, continuing..."

echo "=== Configurando Host header para API Gateway ==="
gcloud compute backend-services update "${BACKEND_NAME}" \
  --custom-request-header="Host: ${GATEWAY_HOSTNAME}" \
  --global \
  --project="${PROJECT_ID}"

echo "=== Asociando Cloud Armor al Backend Service ==="
gcloud compute backend-services update "${BACKEND_NAME}" \
  --security-policy="${POLICY_NAME}" \
  --global \
  --project="${PROJECT_ID}"

# ─────────────────────────────────────────────────────────────────────────────
# Step 4: Crear URL Map
# Rutea todo el trafico al backend service (el gateway maneja el routing)
# ─────────────────────────────────────────────────────────────────────────────
echo "=== Step 4: Creando URL Map ==="
gcloud compute url-maps create "${URL_MAP_NAME}" \
  --default-service="${BACKEND_NAME}" \
  --global \
  --project="${PROJECT_ID}" \
  2>/dev/null || echo "URL map '${URL_MAP_NAME}' already exists, continuing..."

# ─────────────────────────────────────────────────────────────────────────────
# Step 5: Crear certificado SSL self-signed (dev)
# En produccion reemplazar con certificado managed de Google
# ─────────────────────────────────────────────────────────────────────────────
echo "=== Step 5: Generando certificado SSL self-signed (dev) ==="
CERT_DIR="/tmp/travelhub-ssl"
mkdir -p "${CERT_DIR}"

openssl req -x509 -nodes -days 365 \
  -newkey rsa:2048 \
  -keyout "${CERT_DIR}/private.key" \
  -out "${CERT_DIR}/certificate.crt" \
  -subj "/C=CO/ST=Bogota/L=Bogota/O=TravelHub/CN=${STATIC_IP}" \
  2>/dev/null

gcloud compute ssl-certificates create "${CERT_NAME}" \
  --certificate="${CERT_DIR}/certificate.crt" \
  --private-key="${CERT_DIR}/private.key" \
  --global \
  --project="${PROJECT_ID}" \
  2>/dev/null || echo "SSL cert '${CERT_NAME}' already exists, continuing..."

rm -rf "${CERT_DIR}"

# ─────────────────────────────────────────────────────────────────────────────
# Step 6: Crear Target HTTPS Proxy
# ─────────────────────────────────────────────────────────────────────────────
echo "=== Step 6: Creando Target HTTPS Proxy ==="
gcloud compute target-https-proxies create "${PROXY_NAME}" \
  --url-map="${URL_MAP_NAME}" \
  --ssl-certificates="${CERT_NAME}" \
  --global \
  --project="${PROJECT_ID}" \
  2>/dev/null || echo "HTTPS proxy '${PROXY_NAME}' already exists, continuing..."

# ─────────────────────────────────────────────────────────────────────────────
# Step 7: Crear Forwarding Rule (conecta IP con proxy)
# ─────────────────────────────────────────────────────────────────────────────
echo "=== Step 7: Creando Forwarding Rule ==="
gcloud compute forwarding-rules create "${FWD_RULE_NAME}" \
  --global \
  --address="${IP_NAME}" \
  --target-https-proxy="${PROXY_NAME}" \
  --ports=443 \
  --project="${PROJECT_ID}" \
  2>/dev/null || echo "Forwarding rule '${FWD_RULE_NAME}' already exists, continuing..."

echo ""
echo "============================================"
echo "Load Balancer deployed"
echo "============================================"
echo "Project:       ${PROJECT_ID}"
echo "Static IP:     ${STATIC_IP}"
echo "Gateway FQDN:  ${GATEWAY_HOSTNAME}"
echo "Cloud Armor:   ${POLICY_NAME}"
echo "SSL:           Self-signed (dev)"
echo ""
echo "Flujo:"
echo "  Internet -> ${STATIC_IP} -> LB -> Cloud Armor -> API Gateway -> Cloud Run"
echo ""
echo "Test:"
echo "  curl -k https://${STATIC_IP}/health"
echo "  curl -k https://${STATIC_IP}/.well-known/jwks.json"
echo "  curl -k https://${STATIC_IP}/api/v1/bookings/list  (esperado: 401)"
echo ""
echo "Nota: -k ignora el warning del certificado self-signed."
echo "Para produccion, crear certificado managed con dominio:"
echo "  gcloud compute ssl-certificates create travelhub-ssl-managed \\"
echo "    --domains=api.travelhub.app --global"
echo "============================================"
