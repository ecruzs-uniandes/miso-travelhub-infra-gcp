#!/bin/bash
# ============================================================
# TravelHub — Step 01: Habilitar APIs de GCP
# ============================================================
# Habilita todas las APIs necesarias de una sola vez antes
# de ejecutar cualquier otro script. Idempotente.
#
# Uso:
#   source config/environments/dev.env && bash scripts/01-enable-apis.sh
# ============================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
require_env

log_step "Habilitando APIs de GCP"

APIS=(
  "compute.googleapis.com"
  "vpcaccess.googleapis.com"
  "servicenetworking.googleapis.com"
  "sqladmin.googleapis.com"
  "apigateway.googleapis.com"
  "servicemanagement.googleapis.com"
  "servicecontrol.googleapis.com"
  "secretmanager.googleapis.com"
  "run.googleapis.com"
  "cloudbuild.googleapis.com"
)

for api in "${APIS[@]}"; do
  enable_api "${api}"
done

echo ""
log_success "Todas las APIs habilitadas correctamente"
echo ""
echo "APIs habilitadas:"
for api in "${APIS[@]}"; do
  echo "  - ${api}"
done
