#!/bin/bash
# ============================================================
# TravelHub — Step 03: Reglas de Firewall VPC
# ============================================================
# Principio: DENY ALL por defecto, permitir solo lo necesario.
# Idempotente: verifica existencia antes de crear cada regla.
#
# Capas:
#   subnet-public    -> Solo HTTPS (443) desde internet
#   subnet-services  -> Solo trafico desde subnet-public (gateway)
#   subnet-data      -> Solo trafico desde subnet-services
#
# Uso:
#   source config/environments/dev.env && bash scripts/03-firewall-rules.sh
# ============================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
require_env

log_step "Configurando reglas de firewall para VPC: ${VPC_NAME}"

# ── Helper: crear firewall rule si no existe ──
create_fw_rule() {
  local rule_name="$1"
  local description="$2"
  shift 2

  if resource_exists "firewall-rules" "${rule_name}"; then
    log_warn "Regla '${rule_name}' ya existe — omitiendo"
    return 0
  fi

  log_info "Creando regla '${rule_name}'..."
  gcloud compute firewall-rules create "${rule_name}" \
    --network="${VPC_NAME}" \
    --project="${GCP_PROJECT_ID}" \
    --description="${description}" \
    "$@"
  log_success "Regla '${rule_name}' creada"
}

# ── REGLA -1: Permitir IAP (SSH + Kafka UI) hacia la VM de Kafka ──
# Prioridad 50 < 100 (deny-ssh) → tiene precedencia. Solo aplica al tag de la VM.
create_fw_rule "${PREFIX}-fw-allow-iap-kafka" \
  "Allow IAP tunnel to Kafka VM (SSH:22 and Kafka UI:8080)" \
  --direction=INGRESS \
  --priority=50 \
  --action=ALLOW \
  --rules=tcp:22,tcp:8080 \
  --source-ranges=35.235.240.0/20 \
  --target-tags="${KAFKA_VM_NAME}"

# ── REGLA 0: Bloquear SSH desde internet ──
create_fw_rule "${PREFIX}-fw-deny-ssh" \
  "Block SSH access from internet" \
  --direction=INGRESS \
  --priority=100 \
  --action=DENY \
  --rules=tcp:22 \
  --source-ranges=0.0.0.0/0

# ── REGLA 1: Permitir HTTPS (443) hacia el Load Balancer ──
create_fw_rule "${PREFIX}-fw-allow-https-lb" \
  "Allow HTTPS from internet to Load Balancer" \
  --direction=INGRESS \
  --priority=1000 \
  --action=ALLOW \
  --rules=tcp:443 \
  --source-ranges=0.0.0.0/0 \
  --target-tags=load-balancer

# ── REGLA 2: Permitir Health Checks de GCP ──
create_fw_rule "${PREFIX}-fw-allow-health-checks" \
  "Allow GCP health check probes" \
  --direction=INGRESS \
  --priority=1100 \
  --action=ALLOW \
  --rules=tcp:8000,tcp:8080 \
  --source-ranges=130.211.0.0/22,35.191.0.0/16 \
  --target-tags=cloud-run-service

# ── REGLA 3: Permitir trafico del Gateway -> Microservicios ──
create_fw_rule "${PREFIX}-fw-allow-gw-to-svc" \
  "Allow API Gateway to reach Cloud Run services on port 8000" \
  --direction=INGRESS \
  --priority=1200 \
  --action=ALLOW \
  --rules=tcp:8000 \
  --source-ranges="${SUBNET_PUBLIC_CIDR}" \
  --target-tags=cloud-run-service

# ── REGLA 4: Permitir Microservicios -> Capa de Datos ──
create_fw_rule "${PREFIX}-fw-allow-svc-to-data" \
  "Allow microservices to reach PostgreSQL(5432), Redis(6379), Elasticsearch(9200), Kafka(9092)" \
  --direction=INGRESS \
  --priority=1300 \
  --action=ALLOW \
  --rules=tcp:5432,tcp:6379,tcp:9200,tcp:9092 \
  --source-ranges="${SUBNET_SERVICES_CIDR}" \
  --target-tags=data-layer

# ── REGLA 5: Permitir comunicacion inter-microservicios ──
create_fw_rule "${PREFIX}-fw-allow-inter-svc" \
  "Allow Cloud Run services to communicate with each other" \
  --direction=INGRESS \
  --priority=1400 \
  --action=ALLOW \
  --rules=tcp:8000 \
  --source-tags=cloud-run-service \
  --target-tags=cloud-run-service

# ── REGLA 6: DENY ALL — Bloquear cualquier otro trafico ingress ──
create_fw_rule "${PREFIX}-fw-deny-all-ingress" \
  "Default deny: block all ingress not explicitly allowed" \
  --direction=INGRESS \
  --priority=65534 \
  --action=DENY \
  --rules=all \
  --source-ranges=0.0.0.0/0

# ── REGLA 7: Egress — Permitir salida HTTPS a servicios externos ──
create_fw_rule "${PREFIX}-fw-allow-egress-ext" \
  "Allow HTTPS egress to external services (Stripe, PMS, Email)" \
  --direction=EGRESS \
  --priority=1000 \
  --action=ALLOW \
  --rules=tcp:443 \
  --destination-ranges=0.0.0.0/0 \
  --target-tags=cloud-run-service

# ── REGLA 8: Egress — Bloquear salida desde capa de datos ──
create_fw_rule "${PREFIX}-fw-deny-data-egress" \
  "Block all egress from data layer to internet" \
  --direction=EGRESS \
  --priority=1000 \
  --action=DENY \
  --rules=all \
  --destination-ranges=0.0.0.0/0 \
  --target-tags=data-layer

echo ""
log_success "Reglas de firewall configuradas"
echo ""
echo "Ingress rules:"
echo "  [P50]    ALLOW IAP -> Kafka VM (22,8080)       ${PREFIX}-fw-allow-iap-kafka"
echo "  [P100]   DENY  SSH desde internet              ${PREFIX}-fw-deny-ssh"
echo "  [P1000]  ALLOW HTTPS (443) -> Load Balancer    ${PREFIX}-fw-allow-https-lb"
echo "  [P1100]  ALLOW GCP Health Checks               ${PREFIX}-fw-allow-health-checks"
echo "  [P1200]  ALLOW Gateway -> Microservicios(8000) ${PREFIX}-fw-allow-gw-to-svc"
echo "  [P1300]  ALLOW Services -> Data(5432+)         ${PREFIX}-fw-allow-svc-to-data"
echo "  [P1400]  ALLOW Inter-service (8000)            ${PREFIX}-fw-allow-inter-svc"
echo "  [P65534] DENY  Todo el resto                   ${PREFIX}-fw-deny-all-ingress"
echo ""
echo "Egress rules:"
echo "  [P1000]  ALLOW Services -> External HTTPS(443) ${PREFIX}-fw-allow-egress-ext"
echo "  [P1000]  DENY  Data layer -> Internet          ${PREFIX}-fw-deny-data-egress"
