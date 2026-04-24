#!/bin/bash
# =============================================================================
# Asociar la politica Cloud Armor al backend service del Load Balancer
# =============================================================================
# Prerequisito: Tener un Load Balancer con backend service configurado.
# Cloud Armor se aplica al backend service, no al API Gateway directamente.
# =============================================================================
set -euo pipefail

PROJECT_ID="${GCP_PROJECT_ID:-gen-lang-client-0930444414}"
POLICY_NAME="${CLOUD_ARMOR_POLICY:-travelhub-security-policy}"
BACKEND_SERVICE="${BACKEND_SERVICE_NAME:-travelhub-backend-service}"

echo "=== Asociando Cloud Armor al Backend Service ==="
gcloud compute backend-services update "${BACKEND_SERVICE}" \
  --security-policy="${POLICY_NAME}" \
  --global \
  --project="${PROJECT_ID}"

echo ""
echo "============================================"
echo "Cloud Armor '${POLICY_NAME}' asociado a '${BACKEND_SERVICE}'"
echo "============================================"
echo "Project: ${PROJECT_ID}"
echo ""
echo "Verificar con:"
echo "  gcloud compute backend-services describe ${BACKEND_SERVICE} --global --format='value(securityPolicy)' --project=${PROJECT_ID}"
echo "============================================"
