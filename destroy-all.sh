#!/bin/bash
# ============================================================
# TravelHub — Destruir TODA la infraestructura GCP
# ============================================================
# PELIGRO: Elimina todos los recursos del ambiente especificado.
# Idempotente: puede ejecutarse multiples veces sin errores.
# Requiere confirmacion interactiva.
#
# Uso:
#   source config/environments/dev.env && bash destroy-all.sh
# ============================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

source "${SCRIPT_DIR}/scripts/lib/common.sh"
require_env

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║    DESTRUCCION DE INFRAESTRUCTURA                   ║"
echo "╠══════════════════════════════════════════════════════╣"
printf "║  Ambiente: %-42s ║\n" "${ENV}"
printf "║  Proyecto: %-42s ║\n" "${GCP_PROJECT_ID}"
printf "║  Region:   %-42s ║\n" "${GCP_REGION}"
echo "╚══════════════════════════════════════════════════════╝"
echo ""
echo "ADVERTENCIA: Este script eliminara TODOS los recursos"
echo "del ambiente '${ENV}' en el proyecto '${GCP_PROJECT_ID}'."
echo ""
echo "Recursos a eliminar:"
echo "  - Load Balancer (forwarding rule, proxy, cert, url-map, backend, NEG, IP)"
echo "  - API Gateway (gateway, api-config, api)"
echo "  - Cloud SQL + Secret Manager (db-password, kafka-bootstrap-servers)"
echo "  - Cloud Armor security policy"
echo "  - Kafka VM (Compute Engine)"
echo "  - Private Service Connection"
echo "  - Reglas de Firewall"
echo "  - VPC (connector, subnets, VPC)"
echo ""
read -p "Para confirmar, escribe el nombre del ambiente ('${ENV}'): " CONFIRM
if [[ "${CONFIRM}" != "${ENV}" ]]; then
  echo ""
  echo "Confirmacion incorrecta. Operacion cancelada."
  exit 0
fi

echo ""
log_warn "Iniciando destruccion de infraestructura del ambiente '${ENV}'..."
echo ""

# ================================================================
# ORDEN INVERSO DE CREACION (dependencias invertidas)
# ================================================================

# ── 1. Load Balancer — Forwarding Rule ──
log_step "1/17 Eliminando Forwarding Rule"
if resource_exists "forwarding-rules" "${LB_FWD_RULE_NAME}" "--global"; then
  log_info "Eliminando forwarding rule '${LB_FWD_RULE_NAME}'..."
  gcloud compute forwarding-rules delete "${LB_FWD_RULE_NAME}" \
    --global \
    --quiet \
    --project="${GCP_PROJECT_ID}"
  log_success "Forwarding rule eliminada"
else
  log_warn "Forwarding rule '${LB_FWD_RULE_NAME}' no existe — omitiendo"
fi

# ── 2. HTTPS Proxy ──
log_step "2/17 Eliminando HTTPS Proxy"
if resource_exists "target-https-proxies" "${LB_PROXY_NAME}" "--global"; then
  log_info "Eliminando HTTPS proxy '${LB_PROXY_NAME}'..."
  gcloud compute target-https-proxies delete "${LB_PROXY_NAME}" \
    --global \
    --quiet \
    --project="${GCP_PROJECT_ID}"
  log_success "HTTPS proxy eliminado"
else
  log_warn "HTTPS proxy '${LB_PROXY_NAME}' no existe — omitiendo"
fi

# ── 3. SSL Certificate ──
log_step "3/17 Eliminando SSL Certificate"
if resource_exists "ssl-certificates" "${LB_CERT_NAME}" "--global"; then
  log_info "Eliminando certificado SSL '${LB_CERT_NAME}'..."
  gcloud compute ssl-certificates delete "${LB_CERT_NAME}" \
    --global \
    --quiet \
    --project="${GCP_PROJECT_ID}"
  log_success "Certificado SSL eliminado"
else
  log_warn "Certificado SSL '${LB_CERT_NAME}' no existe — omitiendo"
fi

# ── 4. URL Map ──
log_step "4/17 Eliminando URL Map"
if resource_exists "url-maps" "${LB_URL_MAP_NAME}" "--global"; then
  log_info "Eliminando URL map '${LB_URL_MAP_NAME}'..."
  gcloud compute url-maps delete "${LB_URL_MAP_NAME}" \
    --global \
    --quiet \
    --project="${GCP_PROJECT_ID}"
  log_success "URL map eliminado"
else
  log_warn "URL map '${LB_URL_MAP_NAME}' no existe — omitiendo"
fi

# ── 5. Backend Service (primero remover Cloud Armor) ──
log_step "5/17 Eliminando Backend Service"
if resource_exists "backend-services" "${LB_BACKEND_NAME}" "--global"; then
  log_info "Removiendo Cloud Armor del backend service..."
  gcloud compute backend-services update "${LB_BACKEND_NAME}" \
    --no-security-policy \
    --global \
    --project="${GCP_PROJECT_ID}" 2>/dev/null || true

  log_info "Eliminando backend service '${LB_BACKEND_NAME}'..."
  gcloud compute backend-services delete "${LB_BACKEND_NAME}" \
    --global \
    --quiet \
    --project="${GCP_PROJECT_ID}"
  log_success "Backend service eliminado"
else
  log_warn "Backend service '${LB_BACKEND_NAME}' no existe — omitiendo"
fi

# ── 6. NEG ──
log_step "6/17 Eliminando Network Endpoint Group"
if resource_exists "network-endpoint-groups" "${LB_NEG_NAME}" "--global"; then
  log_info "Eliminando NEG '${LB_NEG_NAME}'..."
  gcloud compute network-endpoint-groups delete "${LB_NEG_NAME}" \
    --global \
    --quiet \
    --project="${GCP_PROJECT_ID}"
  log_success "NEG eliminado"
else
  log_warn "NEG '${LB_NEG_NAME}' no existe — omitiendo"
fi

# ── 7. IP Estatica ──
log_step "7/17 Eliminando IP estatica"
if resource_exists "addresses" "${LB_IP_NAME}" "--global"; then
  log_info "Eliminando IP estatica '${LB_IP_NAME}'..."
  gcloud compute addresses delete "${LB_IP_NAME}" \
    --global \
    --quiet \
    --project="${GCP_PROJECT_ID}"
  log_success "IP estatica eliminada"
else
  log_warn "IP estatica '${LB_IP_NAME}' no existe — omitiendo"
fi

# ── 8. API Gateway ──
log_step "8/17 Eliminando API Gateway"

if gateway_exists "${API_GATEWAY_NAME}" "${GCP_REGION}"; then
  log_info "Eliminando gateway '${API_GATEWAY_NAME}'..."
  gcloud api-gateway gateways delete "${API_GATEWAY_NAME}" \
    --location="${GCP_REGION}" \
    --quiet \
    --project="${GCP_PROJECT_ID}"
  log_success "Gateway eliminado"
else
  log_warn "Gateway '${API_GATEWAY_NAME}' no existe — omitiendo"
fi

# Eliminar todas las api-configs de esta API
if gateway_api_exists "${API_GATEWAY_ID}"; then
  log_info "Eliminando api-configs de '${API_GATEWAY_ID}'..."
  CONFIGS=$(gcloud api-gateway api-configs list \
    --api="${API_GATEWAY_ID}" \
    --project="${GCP_PROJECT_ID}" \
    --format="value(name)" 2>/dev/null || true)
  if [[ -n "${CONFIGS}" ]]; then
    while IFS= read -r config; do
      CONFIG_SHORT=$(basename "${config}")
      log_info "Eliminando api-config '${CONFIG_SHORT}'..."
      gcloud api-gateway api-configs delete "${CONFIG_SHORT}" \
        --api="${API_GATEWAY_ID}" \
        --quiet \
        --project="${GCP_PROJECT_ID}" 2>/dev/null || true
    done <<< "${CONFIGS}"
    log_success "Api-configs eliminadas"
  fi

  log_info "Eliminando API '${API_GATEWAY_ID}'..."
  gcloud api-gateway apis delete "${API_GATEWAY_ID}" \
    --quiet \
    --project="${GCP_PROJECT_ID}"
  log_success "API eliminada"
else
  log_warn "API '${API_GATEWAY_ID}' no existe — omitiendo"
fi

# ── 9. Cloud SQL ──
log_step "9/17 Eliminando Cloud SQL"
if sql_instance_exists "${DB_INSTANCE_NAME}"; then
  log_info "Eliminando instancia Cloud SQL '${DB_INSTANCE_NAME}' (puede tardar varios minutos)..."
  gcloud sql instances delete "${DB_INSTANCE_NAME}" \
    --quiet \
    --project="${GCP_PROJECT_ID}"
  log_success "Instancia Cloud SQL eliminada"
else
  log_warn "Instancia Cloud SQL '${DB_INSTANCE_NAME}' no existe — omitiendo"
fi

# ── 10. Secret Manager ──
log_step "10/17 Eliminando secrets de Secret Manager"
for SECRET_NAME in "${PREFIX}-db-password" "${PREFIX}-kafka-bootstrap-servers"; do
  if secret_exists "${SECRET_NAME}"; then
    log_info "Eliminando secret '${SECRET_NAME}'..."
    gcloud secrets delete "${SECRET_NAME}" \
      --quiet \
      --project="${GCP_PROJECT_ID}"
    log_success "Secret '${SECRET_NAME}' eliminado"
  else
    log_warn "Secret '${SECRET_NAME}' no existe — omitiendo"
  fi
done

# ── 11. Cloud Armor — Reglas y Policy ──
log_step "11/17 Eliminando Cloud Armor"
if armor_policy_exists "${CLOUD_ARMOR_POLICY}"; then
  log_info "Eliminando reglas de Cloud Armor (1000-3000)..."
  for priority in 1000 1100 1200 1300 1400 1500 2000 2100 2200 3000; do
    if armor_rule_exists "${CLOUD_ARMOR_POLICY}" "${priority}"; then
      gcloud compute security-policies rules delete "${priority}" \
        --security-policy="${CLOUD_ARMOR_POLICY}" \
        --quiet \
        --project="${GCP_PROJECT_ID}" 2>/dev/null || true
    fi
  done

  log_info "Eliminando security policy '${CLOUD_ARMOR_POLICY}'..."
  gcloud compute security-policies delete "${CLOUD_ARMOR_POLICY}" \
    --quiet \
    --project="${GCP_PROJECT_ID}"
  log_success "Cloud Armor eliminado"
else
  log_warn "Security policy '${CLOUD_ARMOR_POLICY}' no existe — omitiendo"
fi

# ── 12. Kafka VM ──
log_step "12/17 Eliminando Kafka VM"
if gcloud compute instances describe "${KAFKA_VM_NAME}" \
    --zone="${KAFKA_VM_ZONE}" \
    --project="${GCP_PROJECT_ID}" &>/dev/null; then
  log_info "Eliminando VM '${KAFKA_VM_NAME}' en ${KAFKA_VM_ZONE}..."
  gcloud compute instances delete "${KAFKA_VM_NAME}" \
    --zone="${KAFKA_VM_ZONE}" \
    --quiet \
    --project="${GCP_PROJECT_ID}"
  log_success "VM '${KAFKA_VM_NAME}' eliminada"
else
  log_warn "VM '${KAFKA_VM_NAME}' no existe — omitiendo"
fi

# ── 13. Private Service Connection ──
log_step "13/17 Eliminando Private Service Connection"

PEERING_EXISTS=$(gcloud services vpc-peerings list \
  --service=servicenetworking.googleapis.com \
  --network="${VPC_NAME}" \
  --project="${GCP_PROJECT_ID}" \
  --format="value(service)" 2>/dev/null | grep -c "servicenetworking" || true)

if [[ "${PEERING_EXISTS}" -gt 0 ]]; then
  log_info "Desconectando VPC peering de servicenetworking..."
  gcloud services vpc-peerings delete \
    --service=servicenetworking.googleapis.com \
    --network="${VPC_NAME}" \
    --quiet \
    --project="${GCP_PROJECT_ID}" 2>/dev/null || true
  log_success "VPC peering desconectado"
else
  log_warn "VPC peering no existe — omitiendo"
fi

if resource_exists "addresses" "${PRIVATE_RANGE_NAME}" "--global"; then
  log_info "Eliminando rango IP privado '${PRIVATE_RANGE_NAME}'..."
  gcloud compute addresses delete "${PRIVATE_RANGE_NAME}" \
    --global \
    --quiet \
    --project="${GCP_PROJECT_ID}"
  log_success "Rango IP privado eliminado"
else
  log_warn "Rango IP privado '${PRIVATE_RANGE_NAME}' no existe — omitiendo"
fi

# ── 14. Firewall Rules ──
log_step "14/17 Eliminando reglas de Firewall"

FW_RULES=(
  "${PREFIX}-fw-allow-iap-kafka"
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

for rule in "${FW_RULES[@]}"; do
  if resource_exists "firewall-rules" "${rule}"; then
    log_info "Eliminando regla '${rule}'..."
    gcloud compute firewall-rules delete "${rule}" \
      --quiet \
      --project="${GCP_PROJECT_ID}"
    log_success "Regla '${rule}' eliminada"
  else
    log_warn "Regla '${rule}' no existe — omitiendo"
  fi
done

# ── 15. VPC Connector ──
log_step "15/17 Eliminando VPC Connector"
if connector_exists "${VPC_CONNECTOR_NAME}" "${GCP_REGION}"; then
  log_info "Eliminando VPC connector '${VPC_CONNECTOR_NAME}'..."
  gcloud compute networks vpc-access connectors delete "${VPC_CONNECTOR_NAME}" \
    --region="${GCP_REGION}" \
    --quiet \
    --project="${GCP_PROJECT_ID}"
  log_success "VPC connector eliminado"
else
  log_warn "VPC connector '${VPC_CONNECTOR_NAME}' no existe — omitiendo"
fi

# ── 16. Subnets ──
log_step "16/17 Eliminando Subnets"

for subnet in "${SUBNET_DATA_NAME}" "${SUBNET_SERVICES_NAME}" "${SUBNET_PUBLIC_NAME}"; do
  if subnet_exists "${subnet}" "${GCP_REGION}"; then
    log_info "Eliminando subnet '${subnet}'..."
    gcloud compute networks subnets delete "${subnet}" \
      --region="${GCP_REGION}" \
      --quiet \
      --project="${GCP_PROJECT_ID}"
    log_success "Subnet '${subnet}' eliminada"
  else
    log_warn "Subnet '${subnet}' no existe — omitiendo"
  fi
done

# ── 17. VPC ──
log_step "17/17 Eliminando VPC"
if resource_exists "networks" "${VPC_NAME}"; then
  log_info "Eliminando VPC '${VPC_NAME}'..."
  gcloud compute networks delete "${VPC_NAME}" \
    --quiet \
    --project="${GCP_PROJECT_ID}"
  log_success "VPC '${VPC_NAME}' eliminada"
else
  log_warn "VPC '${VPC_NAME}' no existe — omitiendo"
fi

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║    Destruccion completada                           ║"
printf "║    Ambiente '%-39s' ║\n" "${ENV}"
echo "╚══════════════════════════════════════════════════════╝"
echo ""
log_success "Todos los recursos del ambiente '${ENV}' han sido eliminados"
