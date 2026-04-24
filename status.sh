#!/bin/bash
# ============================================================
# TravelHub — Estado de infraestructura GCP
# ============================================================
# Muestra el estado actual de todos los componentes.
# Usa simbolos ✓ / ✗ por componente.
#
# Uso:
#   source config/environments/dev.env && bash status.sh
# ============================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

source "${SCRIPT_DIR}/scripts/lib/common.sh"
require_env

# ── Helper: mostrar estado ──
check_status() {
  local label="$1"
  local value="$2"
  local ok_icon="✓"
  local fail_icon="✗"

  if [[ -n "${value}" && "${value}" != "NOT_FOUND" && "${value}" != "false" ]]; then
    printf "  ${GREEN}${ok_icon}${NC}  %-35s %s\n" "${label}:" "${value}"
  else
    printf "  ${RED}${fail_icon}${NC}  %-35s %s\n" "${label}:" "NO EXISTE"
  fi
}

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║    TravelHub — Estado de Infraestructura            ║"
echo "╠══════════════════════════════════════════════════════╣"
printf "║  Ambiente: %-42s ║\n" "${ENV}"
printf "║  Proyecto: %-42s ║\n" "${GCP_PROJECT_ID}"
echo "╚══════════════════════════════════════════════════════╝"

# ── VPC ──
echo ""
echo "  VPC & Networking"
echo "  ─────────────────────────────────────────────────"

VPC_NAME_FOUND=$(gcloud compute networks describe "${VPC_NAME}" \
  --format="value(name)" \
  --project="${GCP_PROJECT_ID}" 2>/dev/null || echo "NOT_FOUND")
check_status "VPC" "${VPC_NAME_FOUND}"

for SUBNET in "${SUBNET_PUBLIC_NAME}" "${SUBNET_SERVICES_NAME}" "${SUBNET_DATA_NAME}"; do
  SUBNET_FOUND=$(gcloud compute networks subnets describe "${SUBNET}" \
    --region="${GCP_REGION}" \
    --format="value(ipCidrRange)" \
    --project="${GCP_PROJECT_ID}" 2>/dev/null || echo "NOT_FOUND")
  check_status "  ${SUBNET}" "${SUBNET_FOUND}"
done

CONNECTOR_FOUND=$(gcloud compute networks vpc-access connectors describe "${VPC_CONNECTOR_NAME}" \
  --region="${GCP_REGION}" \
  --format="value(state)" \
  --project="${GCP_PROJECT_ID}" 2>/dev/null || echo "NOT_FOUND")
check_status "VPC Connector" "${CONNECTOR_FOUND}"

# ── Firewall Rules ──
echo ""
echo "  Firewall Rules"
echo "  ─────────────────────────────────────────────────"

FW_RULES=(
  "${PREFIX}-fw-deny-ssh"
  "${PREFIX}-fw-allow-https-lb"
  "${PREFIX}-fw-allow-health-checks"
  "${PREFIX}-fw-allow-gw-to-svc"
  "${PREFIX}-fw-allow-svc-to-data"
  "${PREFIX}-fw-allow-inter-svc"
  "${PREFIX}-fw-deny-all-ingress"
  "${PREFIX}-fw-allow-egress-ext"
  "${PREFIX}-fw-deny-data-egress"
)

FW_COUNT=0
for rule in "${FW_RULES[@]}"; do
  FOUND=$(gcloud compute firewall-rules describe "${rule}" \
    --format="value(name)" \
    --project="${GCP_PROJECT_ID}" 2>/dev/null || echo "NOT_FOUND")
  if [[ "${FOUND}" != "NOT_FOUND" ]]; then
    FW_COUNT=$((FW_COUNT + 1))
  fi
done
check_status "Reglas de firewall" "${FW_COUNT}/9 activas"

# ── Cloud Armor ──
echo ""
echo "  Cloud Armor"
echo "  ─────────────────────────────────────────────────"

ARMOR_FOUND=$(gcloud compute security-policies describe "${CLOUD_ARMOR_POLICY}" \
  --format="value(name)" \
  --project="${GCP_PROJECT_ID}" 2>/dev/null || echo "NOT_FOUND")
check_status "Security Policy" "${ARMOR_FOUND}"

if [[ "${ARMOR_FOUND}" != "NOT_FOUND" ]]; then
  RULE_COUNT=$(gcloud compute security-policies rules list "${CLOUD_ARMOR_POLICY}" \
    --format="value(priority)" \
    --project="${GCP_PROJECT_ID}" 2>/dev/null | wc -l | tr -d ' ')
  check_status "  Reglas en policy" "${RULE_COUNT} reglas"

  ADAPTIVE=$(gcloud compute security-policies describe "${CLOUD_ARMOR_POLICY}" \
    --format="value(adaptiveProtectionConfig.layer7DdosDefenseConfig.enable)" \
    --project="${GCP_PROJECT_ID}" 2>/dev/null || echo "false")
  check_status "  Adaptive Protection" "${ADAPTIVE}"
fi

# ── Cloud SQL ──
echo ""
echo "  Cloud SQL"
echo "  ─────────────────────────────────────────────────"

SQL_STATE=$(gcloud sql instances describe "${DB_INSTANCE_NAME}" \
  --format="value(state)" \
  --project="${GCP_PROJECT_ID}" 2>/dev/null || echo "NOT_FOUND")
check_status "Instancia Cloud SQL" "${SQL_STATE}"

if [[ "${SQL_STATE}" != "NOT_FOUND" ]]; then
  SQL_IP=$(gcloud sql instances describe "${DB_INSTANCE_NAME}" \
    --format="value(ipAddresses[0].ipAddress)" \
    --project="${GCP_PROJECT_ID}" 2>/dev/null || echo "NOT_FOUND")
  check_status "  IP privada" "${SQL_IP}"

  SECRET_NAME="${PREFIX}-db-password"
  SECRET_FOUND=$(gcloud secrets describe "${SECRET_NAME}" \
    --format="value(name)" \
    --project="${GCP_PROJECT_ID}" 2>/dev/null || echo "NOT_FOUND")
  check_status "  Secret Manager (password)" "$(basename "${SECRET_FOUND}" 2>/dev/null || echo "NOT_FOUND")"
fi

# ── API Gateway ──
echo ""
echo "  API Gateway"
echo "  ─────────────────────────────────────────────────"

GW_URL=$(gcloud api-gateway gateways describe "${API_GATEWAY_NAME}" \
  --location="${GCP_REGION}" \
  --format="value(defaultHostname)" \
  --project="${GCP_PROJECT_ID}" 2>/dev/null || echo "NOT_FOUND")
check_status "Gateway URL" "${GW_URL}"

if [[ "${GW_URL}" != "NOT_FOUND" ]]; then
  GW_STATE=$(gcloud api-gateway gateways describe "${API_GATEWAY_NAME}" \
    --location="${GCP_REGION}" \
    --format="value(state)" \
    --project="${GCP_PROJECT_ID}" 2>/dev/null || echo "NOT_FOUND")
  check_status "  Estado gateway" "${GW_STATE}"
fi

# ── Load Balancer ──
echo ""
echo "  Load Balancer"
echo "  ─────────────────────────────────────────────────"

LB_IP=$(gcloud compute addresses describe "${LB_IP_NAME}" \
  --global \
  --format="value(address)" \
  --project="${GCP_PROJECT_ID}" 2>/dev/null || echo "NOT_FOUND")
check_status "IP estatica" "${LB_IP}"

BACKEND_FOUND=$(gcloud compute backend-services describe "${LB_BACKEND_NAME}" \
  --global \
  --format="value(name)" \
  --project="${GCP_PROJECT_ID}" 2>/dev/null || echo "NOT_FOUND")
check_status "Backend Service" "${BACKEND_FOUND}"

FWD_FOUND=$(gcloud compute forwarding-rules describe "${LB_FWD_RULE_NAME}" \
  --global \
  --format="value(name)" \
  --project="${GCP_PROJECT_ID}" 2>/dev/null || echo "NOT_FOUND")
check_status "Forwarding Rule" "${FWD_FOUND}"

# ── Microservicios Cloud Run ──
echo ""
echo "  Microservicios Cloud Run"
echo "  ─────────────────────────────────────────────────"

SERVICES=(
  "user-services"
  "search-services"
  "booking-services"
  "payments-services"
  "inventory-services"
  "notification-services"
  "pms-integration-services"
  "shopping-cart-services"
)

for svc in "${SERVICES[@]}"; do
  SVC_URL=$(gcloud run services describe "${svc}" \
    --region="${GCP_REGION}" \
    --format="value(status.url)" \
    --project="${GCP_PROJECT_ID}" 2>/dev/null || echo "NOT_FOUND")
  check_status "${svc}" "${SVC_URL}"
done

# ── Resumen ──
echo ""
echo "  ─────────────────────────────────────────────────"
if [[ "${LB_IP}" != "NOT_FOUND" && "${GW_URL}" != "NOT_FOUND" ]]; then
  echo ""
  log_success "Infraestructura activa"
  echo ""
  echo "  Entrada: https://${LB_IP} (${LB_IP_NAME})"
  echo "  Gateway: https://${GW_URL}"
  if [[ -n "${DOMAIN:-}" ]]; then
    echo "  Dominio: https://${DOMAIN}"
  fi
else
  echo ""
  log_warn "Infraestructura parcial o no desplegada"
  echo ""
  echo "  Para desplegar: source config/environments/${ENV}.env && bash deploy-all.sh"
fi
echo ""
