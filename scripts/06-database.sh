#!/bin/bash
# ============================================================
# TravelHub — Step 06: Cloud SQL PostgreSQL
# ============================================================
# Crea instancia PostgreSQL con IP privada y almacena la
# password en Secret Manager (nunca en texto plano).
# Idempotente: si ya existe, obtiene password de Secret Manager.
#
# Prerequisitos:
#   - VPC creada (script 02)
#   - Private Service Connection creada (script 04)
#
# Uso:
#   source config/environments/dev.env && bash scripts/06-database.sh
# ============================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
require_env

SECRET_NAME="${PREFIX}-db-password"

log_step "Configurando Cloud SQL: ${DB_INSTANCE_NAME}"

# ── Gestionar password en Secret Manager ──
if secret_exists "${SECRET_NAME}"; then
  log_warn "Secret '${SECRET_NAME}' ya existe — usando password existente"
  DB_PASSWORD=$(gcloud secrets versions access latest \
    --secret="${SECRET_NAME}" \
    --project="${GCP_PROJECT_ID}")
  log_success "Password obtenida de Secret Manager"
else
  log_info "Generando nueva password para '${DB_USER}'..."
  DB_PASSWORD=$(openssl rand -base64 24)
  log_info "Almacenando password en Secret Manager como '${SECRET_NAME}'..."
  echo -n "${DB_PASSWORD}" | gcloud secrets create "${SECRET_NAME}" \
    --data-file=- \
    --project="${GCP_PROJECT_ID}"
  log_success "Password almacenada en Secret Manager"
fi

# ── Crear instancia Cloud SQL ──
if sql_instance_exists "${DB_INSTANCE_NAME}"; then
  log_warn "Instancia Cloud SQL '${DB_INSTANCE_NAME}' ya existe — omitiendo"
else
  log_info "Creando instancia Cloud SQL '${DB_INSTANCE_NAME}' (${DB_TIER})..."

  # Flags condicionales segun ambiente
  BACKUP_FLAG="--no-backup"
  HA_FLAG="--availability-type=zonal"
  if [[ "${DB_BACKUP}" == "true" ]]; then
    BACKUP_FLAG="--backup"
  fi
  if [[ "${DB_HA}" == "regional" ]]; then
    HA_FLAG="--availability-type=regional"
  fi

  gcloud sql instances create "${DB_INSTANCE_NAME}" \
    --database-version=POSTGRES_15 \
    --tier="${DB_TIER}" \
    --region="${GCP_REGION}" \
    --network="projects/${GCP_PROJECT_ID}/global/networks/${VPC_NAME}" \
    --no-assign-ip \
    --storage-type=SSD \
    --storage-size="${DB_STORAGE}" \
    --storage-auto-increase \
    ${BACKUP_FLAG} \
    ${HA_FLAG} \
    --project="${GCP_PROJECT_ID}"
  log_success "Instancia Cloud SQL '${DB_INSTANCE_NAME}' creada"
fi

# ── Crear base de datos ──
if sql_database_exists "${DB_INSTANCE_NAME}" "${DB_NAME}"; then
  log_warn "Base de datos '${DB_NAME}' ya existe — omitiendo"
else
  log_info "Creando base de datos '${DB_NAME}'..."
  gcloud sql databases create "${DB_NAME}" \
    --instance="${DB_INSTANCE_NAME}" \
    --project="${GCP_PROJECT_ID}"
  log_success "Base de datos '${DB_NAME}' creada"
fi

# ── Crear usuario ──
if sql_user_exists "${DB_INSTANCE_NAME}" "${DB_USER}"; then
  log_warn "Usuario '${DB_USER}' ya existe — actualizando password..."
  gcloud sql users set-password "${DB_USER}" \
    --instance="${DB_INSTANCE_NAME}" \
    --password="${DB_PASSWORD}" \
    --project="${GCP_PROJECT_ID}"
  log_success "Password del usuario '${DB_USER}' actualizada"
else
  log_info "Creando usuario '${DB_USER}'..."
  gcloud sql users create "${DB_USER}" \
    --instance="${DB_INSTANCE_NAME}" \
    --password="${DB_PASSWORD}" \
    --project="${GCP_PROJECT_ID}"
  log_success "Usuario '${DB_USER}' creado"
fi

# ── Obtener IP privada ──
PRIVATE_IP=$(gcloud sql instances describe "${DB_INSTANCE_NAME}" \
  --format="value(ipAddresses[0].ipAddress)" \
  --project="${GCP_PROJECT_ID}")

echo ""
log_success "Cloud SQL configurado"
echo ""
echo "Resumen:"
echo "  Instancia:   ${DB_INSTANCE_NAME}"
echo "  Base datos:  ${DB_NAME}"
echo "  Usuario:     ${DB_USER}"
echo "  Password:    (almacenada en Secret Manager: ${SECRET_NAME})"
echo "  IP privada:  ${PRIVATE_IP}"
echo "  Tier:        ${DB_TIER}"
echo ""
echo "Variables para Cloud Run:"
echo "  DATABASE_HOST=${PRIVATE_IP}"
echo "  DATABASE_PORT=5432"
echo "  DATABASE_NAME=${DB_NAME}"
echo "  DATABASE_USER=${DB_USER}"
echo "  DATABASE_PASSWORD=\$(gcloud secrets versions access latest --secret=${SECRET_NAME} --project=${GCP_PROJECT_ID})"
