#!/bin/bash
# ============================================================
# TravelHub — Step 02: VPC y Subnets
# ============================================================
# Crea la VPC, las 3 subnets y el VPC Access Connector.
# Idempotente: verifica existencia antes de crear.
#
# Arquitectura de red:
#   subnet-public:    Load Balancer, API Gateway
#   subnet-services:  Cloud Run microservicios
#   subnet-data:      PostgreSQL, Redis, Elasticsearch, Kafka
#   connector:        Cloud Run -> VPC (10.10.8.0/28)
#
# Uso:
#   source config/environments/dev.env && bash scripts/02-vpc-setup.sh
# ============================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
require_env

log_step "Creando VPC: ${VPC_NAME}"

# ── VPC ──
if resource_exists "networks" "${VPC_NAME}"; then
  log_warn "VPC '${VPC_NAME}' ya existe — omitiendo"
else
  log_info "Creando VPC '${VPC_NAME}'..."
  gcloud compute networks create "${VPC_NAME}" \
    --subnet-mode=custom \
    --bgp-routing-mode=global \
    --project="${GCP_PROJECT_ID}"
  log_success "VPC '${VPC_NAME}' creada"
fi

# ── Subnet publica (LB + API Gateway) ──
log_step "Creando subnets"

if subnet_exists "${SUBNET_PUBLIC_NAME}" "${GCP_REGION}"; then
  log_warn "Subnet '${SUBNET_PUBLIC_NAME}' ya existe — omitiendo"
else
  log_info "Creando subnet publica '${SUBNET_PUBLIC_NAME}' (${SUBNET_PUBLIC_CIDR})..."
  gcloud compute networks subnets create "${SUBNET_PUBLIC_NAME}" \
    --network="${VPC_NAME}" \
    --region="${GCP_REGION}" \
    --range="${SUBNET_PUBLIC_CIDR}" \
    --purpose=PRIVATE \
    --project="${GCP_PROJECT_ID}"
  log_success "Subnet '${SUBNET_PUBLIC_NAME}' creada"
fi

# ── Subnet de servicios (Cloud Run) ──
if subnet_exists "${SUBNET_SERVICES_NAME}" "${GCP_REGION}"; then
  log_warn "Subnet '${SUBNET_SERVICES_NAME}' ya existe — omitiendo"
else
  log_info "Creando subnet de servicios '${SUBNET_SERVICES_NAME}' (${SUBNET_SERVICES_CIDR})..."
  gcloud compute networks subnets create "${SUBNET_SERVICES_NAME}" \
    --network="${VPC_NAME}" \
    --region="${GCP_REGION}" \
    --range="${SUBNET_SERVICES_CIDR}" \
    --purpose=PRIVATE \
    --enable-private-ip-google-access \
    --project="${GCP_PROJECT_ID}"
  log_success "Subnet '${SUBNET_SERVICES_NAME}' creada"
fi

# ── Subnet de datos (PostgreSQL, Redis, etc.) ──
if subnet_exists "${SUBNET_DATA_NAME}" "${GCP_REGION}"; then
  log_warn "Subnet '${SUBNET_DATA_NAME}' ya existe — omitiendo"
else
  log_info "Creando subnet de datos '${SUBNET_DATA_NAME}' (${SUBNET_DATA_CIDR})..."
  gcloud compute networks subnets create "${SUBNET_DATA_NAME}" \
    --network="${VPC_NAME}" \
    --region="${GCP_REGION}" \
    --range="${SUBNET_DATA_CIDR}" \
    --purpose=PRIVATE \
    --enable-private-ip-google-access \
    --project="${GCP_PROJECT_ID}"
  log_success "Subnet '${SUBNET_DATA_NAME}' creada"
fi

# ── VPC Access Connector (Cloud Run -> VPC) ──
log_step "Creando VPC Access Connector: ${VPC_CONNECTOR_NAME}"

if connector_exists "${VPC_CONNECTOR_NAME}" "${GCP_REGION}"; then
  log_warn "Connector '${VPC_CONNECTOR_NAME}' ya existe — omitiendo"
else
  # f1-micro es mas confiable que e2-micro en proyectos nuevos
  # (e2-micro da "internal error" code 13 en algunos proyectos)
  VPC_CONNECTOR_MACHINE_TYPE="${VPC_CONNECTOR_MACHINE_TYPE:-f1-micro}"
  VPC_CONNECTOR_MIN_INSTANCES="${VPC_CONNECTOR_MIN_INSTANCES:-2}"
  VPC_CONNECTOR_MAX_INSTANCES="${VPC_CONNECTOR_MAX_INSTANCES:-3}"

  log_info "Creando VPC Access Connector '${VPC_CONNECTOR_NAME}' (${VPC_CONNECTOR_CIDR}, ${VPC_CONNECTOR_MACHINE_TYPE})..."
  gcloud compute networks vpc-access connectors create "${VPC_CONNECTOR_NAME}" \
    --region="${GCP_REGION}" \
    --network="${VPC_NAME}" \
    --range="${VPC_CONNECTOR_CIDR}" \
    --machine-type="${VPC_CONNECTOR_MACHINE_TYPE}" \
    --min-instances="${VPC_CONNECTOR_MIN_INSTANCES}" \
    --max-instances="${VPC_CONNECTOR_MAX_INSTANCES}" \
    --project="${GCP_PROJECT_ID}"
  log_success "Connector '${VPC_CONNECTOR_NAME}' creado"
fi

echo ""
log_success "VPC setup completo"
echo ""
echo "Resumen:"
echo "  VPC:              ${VPC_NAME}"
echo "  Subnet public:    ${SUBNET_PUBLIC_NAME} (${SUBNET_PUBLIC_CIDR})"
echo "  Subnet services:  ${SUBNET_SERVICES_NAME} (${SUBNET_SERVICES_CIDR})"
echo "  Subnet data:      ${SUBNET_DATA_NAME} (${SUBNET_DATA_CIDR})"
echo "  VPC Connector:    ${VPC_CONNECTOR_NAME} (${VPC_CONNECTOR_CIDR})"
