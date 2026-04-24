#!/bin/bash
# ============================================================
# TravelHub — Funciones comunes de infraestructura
# ============================================================
# Importar con: source "$(dirname "$0")/lib/common.sh"
# O desde scripts/ con: source "${SCRIPT_DIR}/lib/common.sh"
# ============================================================

set -euo pipefail

# ── Colores para output ──
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ── Logging ──
log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()    { echo -e "\n${BLUE}━━━ Step: $1 ━━━${NC}"; }

# ── Validacion de ambiente ──
require_env() {
  if [[ -z "${ENV:-}" || -z "${GCP_PROJECT_ID:-}" ]]; then
    log_error "Variables de ambiente no cargadas."
    log_error "Uso: source config/environments/dev.env && bash $0"
    exit 1
  fi
  log_info "Ambiente: ${ENV} | Proyecto: ${GCP_PROJECT_ID} | Region: ${GCP_REGION}"
}

# ── Funciones de idempotencia ──

# Verifica si un recurso de compute existe (VPC, firewall rule, address, etc.)
resource_exists() {
  local resource_type="$1"  # ej: "networks", "firewall-rules", "addresses"
  local resource_name="$2"
  local extra_flags="${3:-}"  # ej: "--global" o "--region=${GCP_REGION}"

  gcloud compute ${resource_type} describe "${resource_name}" \
    ${extra_flags} \
    --project="${GCP_PROJECT_ID}" \
    --format="value(name)" &>/dev/null
}

# Verifica si una subnet existe
subnet_exists() {
  local subnet_name="$1"
  local region="${2:-${GCP_REGION}}"
  gcloud compute networks subnets describe "${subnet_name}" \
    --region="${region}" \
    --project="${GCP_PROJECT_ID}" \
    --format="value(name)" &>/dev/null
}

# Verifica si un VPC Access Connector existe
connector_exists() {
  local connector_name="$1"
  local region="${2:-${GCP_REGION}}"
  gcloud compute networks vpc-access connectors describe "${connector_name}" \
    --region="${region}" \
    --project="${GCP_PROJECT_ID}" \
    --format="value(name)" &>/dev/null
}

# Verifica si una regla de Cloud Armor existe
armor_rule_exists() {
  local policy="$1"
  local priority="$2"
  gcloud compute security-policies rules describe "${priority}" \
    --security-policy="${policy}" \
    --project="${GCP_PROJECT_ID}" &>/dev/null
}

# Verifica si una security policy de Cloud Armor existe
armor_policy_exists() {
  local policy="$1"
  gcloud compute security-policies describe "${policy}" \
    --project="${GCP_PROJECT_ID}" &>/dev/null
}

# Verifica si una instancia de Cloud SQL existe
sql_instance_exists() {
  local instance="$1"
  gcloud sql instances describe "${instance}" \
    --project="${GCP_PROJECT_ID}" &>/dev/null
}

# Verifica si una base de datos SQL existe
sql_database_exists() {
  local instance="$1"
  local database="$2"
  gcloud sql databases describe "${database}" \
    --instance="${instance}" \
    --project="${GCP_PROJECT_ID}" &>/dev/null
}

# Verifica si un usuario SQL existe
sql_user_exists() {
  local instance="$1"
  local user="$2"
  gcloud sql users list \
    --instance="${instance}" \
    --project="${GCP_PROJECT_ID}" \
    --format="value(name)" 2>/dev/null | grep -q "^${user}$"
}

# Verifica si un secret existe en Secret Manager
secret_exists() {
  local secret_name="$1"
  gcloud secrets describe "${secret_name}" \
    --project="${GCP_PROJECT_ID}" &>/dev/null
}

# Verifica si una API de Gateway existe
gateway_api_exists() {
  local api_id="$1"
  gcloud api-gateway apis describe "${api_id}" \
    --project="${GCP_PROJECT_ID}" &>/dev/null
}

# Verifica si un gateway existe
gateway_exists() {
  local gateway_id="$1"
  local location="${2:-${GCP_REGION}}"
  gcloud api-gateway gateways describe "${gateway_id}" \
    --location="${location}" \
    --project="${GCP_PROJECT_ID}" &>/dev/null
}

# Verifica si una API está habilitada
api_enabled() {
  local api="$1"
  gcloud services list --enabled \
    --filter="config.name:${api}" \
    --format="value(config.name)" \
    --project="${GCP_PROJECT_ID}" 2>/dev/null | grep -q "${api}"
}

# Habilitar API si no está habilitada
enable_api() {
  local api="$1"
  if api_enabled "${api}"; then
    log_warn "API ${api} ya habilitada"
  else
    log_info "Habilitando API ${api}..."
    gcloud services enable "${api}" --project="${GCP_PROJECT_ID}"
    log_success "API ${api} habilitada"
  fi
}

# ── Funciones de destruccion ──

# Elimina un recurso de compute si existe
delete_if_exists() {
  local resource_type="$1"
  local resource_name="$2"
  local check_flags="$3"
  local description="$4"
  shift 4

  if ! resource_exists "${resource_type}" "${resource_name}" "${check_flags}"; then
    log_warn "${description} no existe — omitiendo"
    return 0
  fi

  log_info "Eliminando ${description}..."
  "$@"
  log_success "${description} eliminado"
}

# Elimina una subnet si existe
delete_subnet_if_exists() {
  local subnet_name="$1"
  local region="${2:-${GCP_REGION}}"
  local description="$3"
  shift 3

  if ! subnet_exists "${subnet_name}" "${region}"; then
    log_warn "${description} no existe — omitiendo"
    return 0
  fi

  log_info "Eliminando ${description}..."
  "$@"
  log_success "${description} eliminado"
}
