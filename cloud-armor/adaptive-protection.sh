#!/bin/bash
# =============================================================================
# TravelHub — Cloud Armor Adaptive Protection
# =============================================================================
# Activa proteccion adaptativa que usa ML para detectar ataques DDoS L7.
# Genera alertas automaticas y puede sugerir reglas de bloqueo.
# =============================================================================
set -euo pipefail

PROJECT_ID="${GCP_PROJECT_ID:-gen-lang-client-0930444414}"
POLICY_NAME="${CLOUD_ARMOR_POLICY:-travelhub-security-policy}"

echo "=== Habilitando Adaptive Protection ==="
gcloud compute security-policies update "${POLICY_NAME}" \
  --enable-layer7-ddos-defense \
  --project="${PROJECT_ID}"

echo "=== Configurando logging detallado ==="
gcloud compute security-policies update "${POLICY_NAME}" \
  --log-level=VERBOSE \
  --project="${PROJECT_ID}"

echo ""
echo "============================================"
echo "Adaptive Protection habilitada"
echo "============================================"
echo "Policy: ${POLICY_NAME}"
echo "Project: ${PROJECT_ID}"
echo ""
echo "  - Deteccion de anomalias L7 con ML"
echo "  - Alertas automaticas en Cloud Monitoring"
echo "  - Logging verbose para auditoria"
echo "============================================"
