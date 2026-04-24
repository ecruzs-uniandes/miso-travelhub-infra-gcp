#!/bin/bash
# ============================================================
# TravelHub — Step 04: Private Service Connection
# ============================================================
# Configura el acceso privado para que Cloud SQL y MemoryStore
# sean accesibles solo por IP privada, sin pasar por internet.
# Idempotente: verifica existencia antes de crear.
#
# Uso:
#   source config/environments/dev.env && bash scripts/04-private-access.sh
# ============================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
require_env

log_step "Configurando Private Google Access en subnet de datos"

# ── Habilitar Private Google Access en subnet-data ──
# Siempre actualizar (operacion idempotente en si misma)
log_info "Habilitando Private Google Access en '${SUBNET_DATA_NAME}'..."
gcloud compute networks subnets update "${SUBNET_DATA_NAME}" \
  --region="${GCP_REGION}" \
  --enable-private-ip-google-access \
  --project="${GCP_PROJECT_ID}"
log_success "Private Google Access habilitado en '${SUBNET_DATA_NAME}'"

# ── Reservar rango de IP para Private Service Connection ──
log_step "Reservando rango IP para Private Service Connection"

if resource_exists "addresses" "${PRIVATE_RANGE_NAME}" "--global"; then
  log_warn "Rango '${PRIVATE_RANGE_NAME}' ya existe — omitiendo"
else
  log_info "Reservando rango '${PRIVATE_RANGE_NAME}' (${PRIVATE_RANGE_CIDR}/${PRIVATE_RANGE_PREFIX})..."
  gcloud compute addresses create "${PRIVATE_RANGE_NAME}" \
    --global \
    --purpose=VPC_PEERING \
    --addresses="${PRIVATE_RANGE_CIDR}" \
    --prefix-length="${PRIVATE_RANGE_PREFIX}" \
    --network="${VPC_NAME}" \
    --project="${GCP_PROJECT_ID}"
  log_success "Rango '${PRIVATE_RANGE_NAME}' reservado"
fi

# ── Crear Private Service Connection (peering) ──
log_step "Configurando Private Service Connection"

# Verificar si el peering ya existe
PEERING_EXISTS=$(gcloud services vpc-peerings list \
  --service=servicenetworking.googleapis.com \
  --network="${VPC_NAME}" \
  --project="${GCP_PROJECT_ID}" \
  --format="value(service)" 2>/dev/null | grep -c "servicenetworking" || true)

if [[ "${PEERING_EXISTS}" -gt 0 ]]; then
  log_warn "Private Service Connection ya existe — omitiendo"
else
  log_info "Creando Private Service Connection..."
  gcloud services vpc-peerings connect \
    --service=servicenetworking.googleapis.com \
    --ranges="${PRIVATE_RANGE_NAME}" \
    --network="${VPC_NAME}" \
    --project="${GCP_PROJECT_ID}"
  log_success "Private Service Connection creada"
fi

echo ""
log_success "Private access configurado"
echo ""
echo "Resumen:"
echo "  VPC:          ${VPC_NAME}"
echo "  Rango IP:     ${PRIVATE_RANGE_NAME} (${PRIVATE_RANGE_CIDR}/${PRIVATE_RANGE_PREFIX})"
echo "  Cloud SQL:    accesible solo por IP privada"
echo "  MemoryStore:  accesible solo por IP privada"
