#!/bin/bash
# ============================================================
# TravelHub — Step 09: Tests de validacion post-deploy
# ============================================================
# Consolida test_cloud_armor.sh y test_firewall_rules.sh.
# Obtiene la URL del gateway dinamicamente.
# Exit code 0 si todo pasa, 1 si hay fallos.
#
# Uso:
#   source config/environments/dev.env && bash scripts/09-tests.sh
# ============================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
require_env

PASS=0
FAIL=0

run_test() {
  local name="$1"
  local expected="$2"
  local actual="$3"
  if [[ "${actual}" == "${expected}" ]]; then
    echo "  PASS: ${name} (got ${actual})"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: ${name} (expected ${expected}, got ${actual})"
    FAIL=$((FAIL + 1))
  fi
}

log_step "Obteniendo URL del gateway para tests"

# Obtener URL del gateway dinamicamente
if ! gateway_exists "${API_GATEWAY_NAME}" "${GCP_REGION}"; then
  log_error "Gateway '${API_GATEWAY_NAME}' no existe. Ejecuta primero los scripts de deploy."
  exit 1
fi

GATEWAY_HOSTNAME=$(gcloud api-gateway gateways describe "${API_GATEWAY_NAME}" \
  --location="${GCP_REGION}" \
  --project="${GCP_PROJECT_ID}" \
  --format="value(defaultHostname)")
GATEWAY_URL="https://${GATEWAY_HOSTNAME}"
log_info "Testing Gateway: ${GATEWAY_URL}"

# ── Tests de infraestructura (gcloud) ──
log_step "Tests de infraestructura VPC"

echo ""
echo "--- Verificando VPC ---"
VPC_EXISTS=$(gcloud compute networks describe "${VPC_NAME}" \
  --format="value(name)" \
  --project="${GCP_PROJECT_ID}" 2>/dev/null || echo "NOT_FOUND")
run_test "VPC '${VPC_NAME}' existe" "${VPC_NAME}" "${VPC_EXISTS}"

echo "--- Verificando subnets ---"
for SUBNET in "${SUBNET_PUBLIC_NAME}" "${SUBNET_SERVICES_NAME}" "${SUBNET_DATA_NAME}"; do
  SUBNET_EXISTS=$(gcloud compute networks subnets describe "${SUBNET}" \
    --region="${GCP_REGION}" \
    --format="value(name)" \
    --project="${GCP_PROJECT_ID}" 2>/dev/null || echo "NOT_FOUND")
  run_test "Subnet '${SUBNET}' existe" "${SUBNET}" "${SUBNET_EXISTS}"
done

echo "--- Verificando reglas de firewall ---"
SSH_RULE=$(gcloud compute firewall-rules describe "${PREFIX}-fw-deny-ssh" \
  --format="value(disabled)" \
  --project="${GCP_PROJECT_ID}" 2>/dev/null || echo "NOT_FOUND")
if [[ "${SSH_RULE}" != "True" ]] && [[ "${SSH_RULE}" != "NOT_FOUND" ]]; then
  run_test "Regla deny-SSH activa" "active" "active"
else
  run_test "Regla deny-SSH activa" "active" "missing_or_disabled"
fi

DENY_ALL=$(gcloud compute firewall-rules describe "${PREFIX}-fw-deny-all-ingress" \
  --format="value(priority)" \
  --project="${GCP_PROJECT_ID}" 2>/dev/null || echo "NOT_FOUND")
run_test "Regla deny-all-ingress en prioridad 65534" "65534" "${DENY_ALL}"

DATA_EGRESS=$(gcloud compute firewall-rules describe "${PREFIX}-fw-deny-data-egress" \
  --format="value(direction)" \
  --project="${GCP_PROJECT_ID}" 2>/dev/null || echo "NOT_FOUND")
run_test "Regla deny-data-egress es EGRESS" "EGRESS" "${DATA_EGRESS}"

if [[ "${CLOUD_ARMOR_ENABLED:-true}" == "true" ]]; then
  echo "--- Verificando Cloud Armor ---"
  ARMOR_EXISTS=$(gcloud compute security-policies describe "${CLOUD_ARMOR_POLICY}" \
    --format="value(name)" \
    --project="${GCP_PROJECT_ID}" 2>/dev/null || echo "NOT_FOUND")
  run_test "Cloud Armor policy '${CLOUD_ARMOR_POLICY}' existe" "${CLOUD_ARMOR_POLICY}" "${ARMOR_EXISTS}"
else
  log_warn "Cloud Armor check OMITIDO (CLOUD_ARMOR_ENABLED=false)"
fi

echo "--- Verificando Cloud SQL ---"
SQL_EXISTS=$(gcloud sql instances describe "${DB_INSTANCE_NAME}" \
  --format="value(name)" \
  --project="${GCP_PROJECT_ID}" 2>/dev/null || echo "NOT_FOUND")
run_test "Cloud SQL '${DB_INSTANCE_NAME}' existe" "${DB_INSTANCE_NAME}" "${SQL_EXISTS}"

# ── Tests de conectividad HTTP ──
log_step "Tests de conectividad HTTP (Cloud Armor + Gateway)"

echo ""
echo "--- Test conectividad basica ---"
STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
  --max-time 15 \
  "${GATEWAY_URL}/.well-known/jwks.json" 2>/dev/null || echo "000")
run_test "JWKS endpoint accesible (200)" "200" "${STATUS}"

echo "--- Test rutas protegidas requieren JWT ---"
STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
  --max-time 15 \
  "${GATEWAY_URL}/api/v1/bookings/list" 2>/dev/null || echo "000")
run_test "Ruta protegida sin JWT retorna 401" "401" "${STATUS}"

if [[ "${ARMOR_WAF_ENABLED:-true}" == "true" ]]; then
  echo "--- Test Cloud Armor: SQLi bloqueado ---"
  STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
    --max-time 15 \
    "${GATEWAY_URL}/api/v1/search/hotels?q=1'%20OR%201=1--" 2>/dev/null || echo "000")
  run_test "SQLi bloqueado por Cloud Armor (403)" "403" "${STATUS}"

  echo "--- Test Cloud Armor: XSS bloqueado ---"
  STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
    --max-time 15 \
    "${GATEWAY_URL}/api/v1/search/hotels?q=<script>alert(1)</script>" 2>/dev/null || echo "000")
  run_test "XSS bloqueado por Cloud Armor (403)" "403" "${STATUS}"

  echo "--- Test Cloud Armor: LFI bloqueado ---"
  STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
    --max-time 15 \
    "${GATEWAY_URL}/api/v1/search/../../etc/passwd" 2>/dev/null || echo "000")
  run_test "LFI bloqueado por Cloud Armor (403)" "403" "${STATUS}"
else
  log_warn "Tests WAF OMITIDOS (ARMOR_WAF_ENABLED=false)"
fi

if [[ "${CLOUD_ARMOR_ENABLED:-true}" == "true" ]]; then
  echo "--- Test rate limiting login ---"
  RATE_LIMITED=false
  for i in $(seq 1 13); do
    STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
      --max-time 10 \
      -X POST "${GATEWAY_URL}/api/v1/auth/login" \
      -H "Content-Type: application/json" \
      -d '{"email":"test@test.com","password":"wrong"}' 2>/dev/null || echo "000")
    if [[ "${STATUS}" == "429" ]]; then
      run_test "Rate limit login activado en request ${i}" "429" "${STATUS}"
      RATE_LIMITED=true
      break
    fi
  done
  if [[ "${RATE_LIMITED}" == "false" ]]; then
    run_test "Rate limit login activado dentro de 13 requests" "429" "${STATUS}"
  fi
else
  log_warn "Test rate limiting OMITIDO (CLOUD_ARMOR_ENABLED=false)"
fi

# ── Resumen ──
echo ""
echo "============================================"
echo "  Resultados: ${PASS} pasados, ${FAIL} fallados"
echo "============================================"
echo ""

if [[ "${FAIL}" -gt 0 ]]; then
  log_error "${FAIL} test(s) fallaron"
  exit 1
fi

log_success "Todos los tests pasaron"
