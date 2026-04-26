#!/bin/bash
# ============================================================
# TravelHub — Step 07: Kafka VM (Compute Engine)
# ============================================================
# Levanta una VM con Docker en la subnet-data, IP privada estatica,
# y corre via docker compose: Zookeeper + Kafka + Kafka UI + topics.
#
# Topics creados automaticamente por kafka-init:
#   - pms-sync-queue (3 particiones, replication 1)
#   - pms-sync-dlq   (1 particion,  replication 1)
#
# Acceso:
#   - Brokers (privado, via VPC connector desde Cloud Run):
#       ${SUBNET_DATA_CIDR%.*}.3:9092
#   - Kafka UI (admin, via IAP tunnel):
#       gcloud compute start-iap-tunnel <vm> 8080 ...
#
# Prerequisitos:
#   - VPC + subnet-data creadas (script 02)
#   - Reglas de firewall: fw-allow-svc-to-data + fw-allow-iap-kafka (script 03)
#
# Uso:
#   source config/environments/dev.env && bash scripts/07-kafka.sh
# ============================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
require_env

STARTUP_SCRIPT="${SCRIPT_DIR}/lib/kafka-startup.sh"
KAFKA_INTERNAL_IP="${SUBNET_DATA_CIDR%.*}.3"   # 10.10.3.3 (dev) | 10.20.3.3 (prod)
KAFKA_SECRET_NAME="${PREFIX}-kafka-bootstrap-servers"

log_step "Desplegando Kafka VM: ${KAFKA_VM_NAME}"

# ── 1. Crear VM ──
if gcloud compute instances describe "${KAFKA_VM_NAME}" \
    --zone="${KAFKA_VM_ZONE}" \
    --project="${GCP_PROJECT_ID}" &>/dev/null; then
  log_warn "VM '${KAFKA_VM_NAME}' ya existe en zona ${KAFKA_VM_ZONE} — omitiendo"
  KAFKA_BROKER_IP=$(gcloud compute instances describe "${KAFKA_VM_NAME}" \
    --zone="${KAFKA_VM_ZONE}" \
    --project="${GCP_PROJECT_ID}" \
    --format="value(networkInterfaces[0].networkIP)")
else
  if [[ ! -f "${STARTUP_SCRIPT}" ]]; then
    log_error "No se encontro el startup script: ${STARTUP_SCRIPT}"
    exit 1
  fi
  log_info "Creando VM '${KAFKA_VM_NAME}' (${KAFKA_VM_MACHINE_TYPE}) en ${KAFKA_VM_ZONE}..."
  gcloud compute instances create "${KAFKA_VM_NAME}" \
    --zone="${KAFKA_VM_ZONE}" \
    --machine-type="${KAFKA_VM_MACHINE_TYPE}" \
    --image-family="${KAFKA_VM_IMAGE_FAMILY}" \
    --image-project="${KAFKA_VM_IMAGE_PROJECT}" \
    --boot-disk-size="${KAFKA_VM_DISK_SIZE}" \
    --boot-disk-type="${KAFKA_VM_DISK_TYPE}" \
    --subnet="${SUBNET_DATA_NAME}" \
    --private-network-ip="${KAFKA_INTERNAL_IP}" \
    --tags="data-layer,${KAFKA_VM_NAME}" \
    --metadata-from-file=startup-script="${STARTUP_SCRIPT}" \
    --project="${GCP_PROJECT_ID}"
  KAFKA_BROKER_IP="${KAFKA_INTERNAL_IP}"
  log_success "VM '${KAFKA_VM_NAME}' creada con IP privada ${KAFKA_BROKER_IP}"
  log_info "El startup-script tarda ~3 min en levantar Kafka."
  log_info "Para verificar:"
  log_info "  gcloud compute ssh ${KAFKA_VM_NAME} --zone=${KAFKA_VM_ZONE} \\"
  log_info "    --tunnel-through-iap --project=${GCP_PROJECT_ID} \\"
  log_info "    --command='sudo tail -n 50 /var/log/kafka-startup.log'"
fi

# ── 2. Almacenar bootstrap servers en Secret Manager ──
KAFKA_BOOTSTRAP="${KAFKA_BROKER_IP}:9092"

if secret_exists "${KAFKA_SECRET_NAME}"; then
  EXISTING=$(gcloud secrets versions access latest \
    --secret="${KAFKA_SECRET_NAME}" \
    --project="${GCP_PROJECT_ID}")
  if [[ "${EXISTING}" != "${KAFKA_BOOTSTRAP}" ]]; then
    log_info "Actualizando '${KAFKA_SECRET_NAME}' (de ${EXISTING} a ${KAFKA_BOOTSTRAP})..."
    echo -n "${KAFKA_BOOTSTRAP}" | gcloud secrets versions add "${KAFKA_SECRET_NAME}" \
      --data-file=- \
      --project="${GCP_PROJECT_ID}"
    log_success "Nueva version del secret creada"
  else
    log_warn "Secret '${KAFKA_SECRET_NAME}' ya tiene el valor correcto — omitiendo"
  fi
else
  log_info "Creando secret '${KAFKA_SECRET_NAME}'..."
  echo -n "${KAFKA_BOOTSTRAP}" | gcloud secrets create "${KAFKA_SECRET_NAME}" \
    --data-file=- \
    --project="${GCP_PROJECT_ID}"
  log_success "Secret '${KAFKA_SECRET_NAME}' creado"
fi

echo ""
log_success "Kafka VM desplegada"
echo ""
echo "Resumen:"
echo "  VM:                ${KAFKA_VM_NAME} (${KAFKA_VM_MACHINE_TYPE}, ${KAFKA_VM_DISK_SIZE} ${KAFKA_VM_DISK_TYPE})"
echo "  Zona:              ${KAFKA_VM_ZONE}"
echo "  Subnet:            ${SUBNET_DATA_NAME}"
echo "  IP privada:        ${KAFKA_BROKER_IP}"
echo "  Bootstrap servers: ${KAFKA_BOOTSTRAP}"
echo "  Topics:            pms-sync-queue (3 part.), pms-sync-dlq (1 part.)"
echo "  Secret Manager:    ${KAFKA_SECRET_NAME}"
echo ""
echo "Acceso a Kafka UI (admin) via IAP tunnel:"
echo "  gcloud compute start-iap-tunnel ${KAFKA_VM_NAME} 8080 \\"
echo "    --local-host-port=localhost:8080 \\"
echo "    --zone=${KAFKA_VM_ZONE} --project=${GCP_PROJECT_ID}"
echo "  -> http://localhost:8080"
echo ""
echo "Variable para Cloud Run (pms-integration-services y pms-sync-worker):"
echo "  KAFKA_BOOTSTRAP_SERVERS=\$(gcloud secrets versions access latest \\"
echo "    --secret=${KAFKA_SECRET_NAME} --project=${GCP_PROJECT_ID})"
