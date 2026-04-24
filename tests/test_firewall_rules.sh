#!/bin/bash
# =============================================================================
# Tests de validacion de reglas de Firewall VPC
# =============================================================================
set -euo pipefail

PROJECT_ID="${GCP_PROJECT_ID:-gen-lang-client-0930444414}"
VPC_NAME="${VPC_NAME:-travelhub-vpc}"
PASS=0
FAIL=0

run_test() {
  local name="$1"
  local expected="$2"
  local actual="$3"
  if [ "$actual" == "$expected" ]; then
    echo "  PASS: ${name}"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: ${name} (expected '${expected}', got '${actual}')"
    FAIL=$((FAIL + 1))
  fi
}

echo "=== Verificando reglas de firewall ==="
echo "Project: ${PROJECT_ID}"
echo "VPC:     ${VPC_NAME}"
echo ""

# Listar todas las reglas
echo "--- Reglas configuradas ---"
gcloud compute firewall-rules list \
  --filter="network=${VPC_NAME}" \
  --format="table(name, direction, priority, allowed[].map().firewall_rule().list():label=ALLOWED, denied[].map().firewall_rule().list():label=DENIED)" \
  --project="${PROJECT_ID}"

echo ""

# Verificar que SSH esta bloqueado
echo "--- Verificando SSH bloqueado ---"
SSH_RULE=$(gcloud compute firewall-rules describe fw-deny-ssh-internet \
  --format="value(disabled)" \
  --project="${PROJECT_ID}" 2>/dev/null || echo "NOT_FOUND")
if [ "$SSH_RULE" != "True" ] && [ "$SSH_RULE" != "NOT_FOUND" ]; then
  run_test "SSH deny rule is active" "active" "active"
else
  run_test "SSH deny rule is active" "active" "missing_or_disabled"
fi

# Verificar deny-all-ingress
echo "--- Verificando deny-all-ingress ---"
DENY_ALL=$(gcloud compute firewall-rules describe fw-deny-all-ingress \
  --format="value(priority)" \
  --project="${PROJECT_ID}" 2>/dev/null || echo "NOT_FOUND")
run_test "Deny-all-ingress at priority 65534" "65534" "${DENY_ALL}"

# Verificar data layer egress bloqueado
echo "--- Verificando data layer egress blocked ---"
DATA_EGRESS=$(gcloud compute firewall-rules describe fw-deny-data-egress \
  --format="value(direction)" \
  --project="${PROJECT_ID}" 2>/dev/null || echo "NOT_FOUND")
run_test "Data layer egress blocked" "EGRESS" "${DATA_EGRESS}"

# Verificar gateway -> services existe
echo "--- Verificando gateway to services ---"
GW_SVC=$(gcloud compute firewall-rules describe fw-allow-gateway-to-services \
  --format="value(direction)" \
  --project="${PROJECT_ID}" 2>/dev/null || echo "NOT_FOUND")
run_test "Gateway to services rule exists" "INGRESS" "${GW_SVC}"

# Verificar services -> data existe
echo "--- Verificando services to data ---"
SVC_DATA=$(gcloud compute firewall-rules describe fw-allow-services-to-data \
  --format="value(direction)" \
  --project="${PROJECT_ID}" 2>/dev/null || echo "NOT_FOUND")
run_test "Services to data rule exists" "INGRESS" "${SVC_DATA}"

echo ""
echo "============================================"
echo "Results: ${PASS} passed, ${FAIL} failed"
echo "============================================"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
