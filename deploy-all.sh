#!/bin/bash
# ============================================================
# TravelHub — Deploy completo de infraestructura GCP
# ============================================================
# Crea TODA la infraestructura en orden correcto.
# Idempotente: puede ejecutarse multiples veces sin errores.
#
# Uso:
#   source config/environments/dev.env && bash deploy-all.sh
#   source config/environments/prod.env && bash deploy-all.sh
# ============================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

source "${SCRIPT_DIR}/scripts/lib/common.sh"
require_env

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║    TravelHub — Deploy Infraestructura GCP           ║"
echo "╠══════════════════════════════════════════════════════╣"
printf "║  Ambiente: %-42s ║\n" "${ENV}"
printf "║  Proyecto: %-42s ║\n" "${GCP_PROJECT_ID}"
printf "║  Region:   %-42s ║\n" "${GCP_REGION}"
echo "╚══════════════════════════════════════════════════════╝"
echo ""

STEPS=(
  "01-enable-apis.sh:Habilitar APIs de GCP"
  "02-vpc-setup.sh:Crear VPC y subnets"
  "03-firewall-rules.sh:Configurar reglas de firewall"
  "04-private-access.sh:Configurar acceso privado"
  "05-cloud-armor.sh:Crear politica Cloud Armor"
  "06-database.sh:Configurar Cloud SQL PostgreSQL"
  "07-kafka.sh:Desplegar Kafka VM (Compute Engine)"
  "08-gateway.sh:Desplegar API Gateway"
  "09-load-balancer.sh:Configurar Load Balancer"
  "10-tests.sh:Ejecutar tests de validacion"
)

TOTAL=${#STEPS[@]}
CURRENT=0
START_TIME=$(date +%s)

for step in "${STEPS[@]}"; do
  IFS=':' read -r script desc <<< "${step}"
  CURRENT=$((CURRENT + 1))
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  [${CURRENT}/${TOTAL}] ${desc}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  bash "${SCRIPT_DIR}/scripts/${script}"
done

END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║    Deploy completado exitosamente                   ║"
printf "║    Tiempo total: %-35s ║\n" "${ELAPSED}s"
echo "╚══════════════════════════════════════════════════════╝"
echo ""

# Mostrar estado final
bash "${SCRIPT_DIR}/status.sh"
