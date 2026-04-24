#!/bin/bash
# =============================================================================
# Tests de validacion de reglas Cloud Armor
# Ejecutar despues del despliegue para verificar que las reglas funcionan.
#
# Uso:
#   GATEWAY_URL=https://tu-gateway-url bash tests/test_cloud_armor.sh
# =============================================================================
set -euo pipefail

GATEWAY_URL="${GATEWAY_URL:?ERROR: Debes definir GATEWAY_URL}"
PASS=0
FAIL=0

run_test() {
  local name="$1"
  local expected="$2"
  local actual="$3"
  if [ "$actual" == "$expected" ]; then
    echo "  PASS: ${name} (got ${actual})"
    ((PASS++))
  else
    echo "  FAIL: ${name} (expected ${expected}, got ${actual})"
    ((FAIL++))
  fi
}

echo "=== Testing Cloud Armor Rules ==="
echo "Gateway: ${GATEWAY_URL}"
echo ""

# Test 1: SQL Injection debe ser bloqueado (403)
echo "--- Test SQLi Protection ---"
STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
  "${GATEWAY_URL}/api/v1/search/hotels?q=1'%20OR%201=1--")
run_test "SQLi blocked" "403" "${STATUS}"

# Test 2: XSS debe ser bloqueado (403)
echo "--- Test XSS Protection ---"
STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
  "${GATEWAY_URL}/api/v1/search/hotels?q=<script>alert(1)</script>")
run_test "XSS blocked" "403" "${STATUS}"

# Test 3: LFI debe ser bloqueado (403)
echo "--- Test LFI Protection ---"
STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
  "${GATEWAY_URL}/api/v1/search/../../etc/passwd")
run_test "LFI blocked" "403" "${STATUS}"

# Test 4: Rate limiting en login (>10 req/min -> 429)
echo "--- Test Login Rate Limiting ---"
RATE_LIMITED=false
for i in $(seq 1 12); do
  STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST "${GATEWAY_URL}/api/v1/auth/login" \
    -H "Content-Type: application/json" \
    -d '{"email":"test@test.com","password":"wrong"}')
  if [ "$STATUS" == "429" ]; then
    run_test "Login rate limit triggered at request ${i}" "429" "${STATUS}"
    RATE_LIMITED=true
    break
  fi
done
if [ "$RATE_LIMITED" == "false" ]; then
  run_test "Login rate limit triggered within 12 requests" "429" "${STATUS}"
fi

# Test 5: Trafico normal al endpoint publico JWKS
echo "--- Test Normal Traffic ---"
STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
  "${GATEWAY_URL}/.well-known/jwks.json")
run_test "JWKS public endpoint accessible" "200" "${STATUS}"

echo ""
echo "============================================"
echo "Results: ${PASS} passed, ${FAIL} failed"
echo "============================================"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
