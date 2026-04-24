#!/bin/bash
# =============================================================================
# TravelHub — Cloud Armor Security Policy
# =============================================================================
# Crea la política de seguridad WAF para el Load Balancer.
# Cloud Armor opera en el borde de red (edge) de GCP.
#
# Reglas:
#   1000-1500  WAF OWASP Top 10
#   2000-2200  Rate limiting (global, login, pagos)
#   3000       Geo-blocking
#   default    Allow
# =============================================================================
set -euo pipefail

PROJECT_ID="${GCP_PROJECT_ID:-gen-lang-client-0930444414}"
POLICY_NAME="${CLOUD_ARMOR_POLICY:-travelhub-security-policy}"

echo "=== Habilitando Cloud Armor API ==="
gcloud services enable compute.googleapis.com --project="${PROJECT_ID}"

echo "=== Creando política de seguridad ==="
gcloud compute security-policies create "${POLICY_NAME}" \
  --project="${PROJECT_ID}" \
  --description="TravelHub WAF + DDoS protection policy"

# ─────────────────────────────────────────────────────────────────────────────
# REGLA 1: Bloquear SQL Injection (OWASP CRS)
# Mitiga: STRIDE Tampering, AH007
# ─────────────────────────────────────────────────────────────────────────────
echo "=== Regla 1000: Bloquear SQL Injection ==="
gcloud compute security-policies rules create 1000 \
  --security-policy="${POLICY_NAME}" \
  --expression="evaluatePreconfiguredExpr('sqli-v33-stable')" \
  --action=deny-403 \
  --description="Block SQL injection attempts (OWASP CRS)" \
  --project="${PROJECT_ID}"

# ─────────────────────────────────────────────────────────────────────────────
# REGLA 2: Bloquear Cross-Site Scripting (XSS)
# Mitiga: STRIDE Tampering + Information Disclosure
# ─────────────────────────────────────────────────────────────────────────────
echo "=== Regla 1100: Bloquear XSS ==="
gcloud compute security-policies rules create 1100 \
  --security-policy="${POLICY_NAME}" \
  --expression="evaluatePreconfiguredExpr('xss-v33-stable')" \
  --action=deny-403 \
  --description="Block cross-site scripting attacks (OWASP CRS)" \
  --project="${PROJECT_ID}"

# ─────────────────────────────────────────────────────────────────────────────
# REGLA 3: Bloquear Local File Inclusion (LFI)
# Mitiga: STRIDE Information Disclosure
# ─────────────────────────────────────────────────────────────────────────────
echo "=== Regla 1200: Bloquear LFI ==="
gcloud compute security-policies rules create 1200 \
  --security-policy="${POLICY_NAME}" \
  --expression="evaluatePreconfiguredExpr('lfi-v33-stable')" \
  --action=deny-403 \
  --description="Block local file inclusion attacks" \
  --project="${PROJECT_ID}"

# ─────────────────────────────────────────────────────────────────────────────
# REGLA 4: Bloquear Remote File Inclusion (RFI)
# Mitiga: STRIDE Elevation of Privilege
# ─────────────────────────────────────────────────────────────────────────────
echo "=== Regla 1300: Bloquear RFI ==="
gcloud compute security-policies rules create 1300 \
  --security-policy="${POLICY_NAME}" \
  --expression="evaluatePreconfiguredExpr('rfi-v33-stable')" \
  --action=deny-403 \
  --description="Block remote file inclusion attacks" \
  --project="${PROJECT_ID}"

# ─────────────────────────────────────────────────────────────────────────────
# REGLA 5: Bloquear Remote Code Execution / Protocol Attacks
# Mitiga: STRIDE Elevation of Privilege
# ─────────────────────────────────────────────────────────────────────────────
echo "=== Regla 1400: Bloquear Protocol Attacks ==="
gcloud compute security-policies rules create 1400 \
  --security-policy="${POLICY_NAME}" \
  --expression="evaluatePreconfiguredExpr('protocolattack-v33-stable')" \
  --action=deny-403 \
  --description="Block protocol-level attacks" \
  --project="${PROJECT_ID}"

# ─────────────────────────────────────────────────────────────────────────────
# REGLA 6: Bloquear Session Fixation
# Mitiga: STRIDE Spoofing
# ─────────────────────────────────────────────────────────────────────────────
echo "=== Regla 1500: Bloquear Session Fixation ==="
gcloud compute security-policies rules create 1500 \
  --security-policy="${POLICY_NAME}" \
  --expression="evaluatePreconfiguredExpr('sessionfixation-v33-stable')" \
  --action=deny-403 \
  --description="Block session fixation attacks" \
  --project="${PROJECT_ID}"

# ─────────────────────────────────────────────────────────────────────────────
# REGLA 7: Rate Limiting GLOBAL (resuelve debilidad PF1)
# 100 requests por IP por minuto
# ─────────────────────────────────────────────────────────────────────────────
echo "=== Regla 2000: Rate Limiting Global por IP ==="
gcloud compute security-policies rules create 2000 \
  --security-policy="${POLICY_NAME}" \
  --src-ip-ranges="*" \
  --action=throttle \
  --rate-limit-threshold-count=100 \
  --rate-limit-threshold-interval-sec=60 \
  --conform-action=allow \
  --exceed-action=deny-429 \
  --enforce-on-key=IP \
  --description="Global rate limiting: 100 req/min per IP (fixes PF1 gap)" \
  --project="${PROJECT_ID}"

# ─────────────────────────────────────────────────────────────────────────────
# REGLA 8: Rate Limiting estricto para login (anti brute-force)
# 10 requests por IP por minuto — mitiga AH008
# ─────────────────────────────────────────────────────────────────────────────
echo "=== Regla 2100: Rate Limiting Login (anti brute-force) ==="
gcloud compute security-policies rules create 2100 \
  --security-policy="${POLICY_NAME}" \
  --expression="request.path.matches('/api/v1/auth/login')" \
  --action=throttle \
  --rate-limit-threshold-count=10 \
  --rate-limit-threshold-interval-sec=60 \
  --conform-action=allow \
  --exceed-action=deny-429 \
  --enforce-on-key=IP \
  --description="Strict rate limit on login: 10 req/min per IP (AH008)" \
  --project="${PROJECT_ID}"

# ─────────────────────────────────────────────────────────────────────────────
# REGLA 9: Rate Limiting para pagos
# 20 requests por IP por minuto — proteccion adicional PCI-DSS
# ─────────────────────────────────────────────────────────────────────────────
echo "=== Regla 2200: Rate Limiting Pagos ==="
gcloud compute security-policies rules create 2200 \
  --security-policy="${POLICY_NAME}" \
  --expression="request.path.matches('/api/v1/payments/.*')" \
  --action=throttle \
  --rate-limit-threshold-count=20 \
  --rate-limit-threshold-interval-sec=60 \
  --conform-action=allow \
  --exceed-action=deny-429 \
  --enforce-on-key=IP \
  --description="Rate limit on payments: 20 req/min per IP (PCI-DSS)" \
  --project="${PROJECT_ID}"

# ─────────────────────────────────────────────────────────────────────────────
# REGLA 10: Geo-blocking — Permitir solo LATAM + regiones de negocio
# TravelHub opera en: CO, PE, EC, MX, CL, AR + US/EU para turismo
# ─────────────────────────────────────────────────────────────────────────────
echo "=== Regla 3000: Geo-blocking ==="
gcloud compute security-policies rules create 3000 \
  --security-policy="${POLICY_NAME}" \
  --expression="!origin.region_code.matches('CO|PE|EC|MX|CL|AR|US|BR|ES|FR|DE|GB|IT')" \
  --action=deny-403 \
  --description="Block traffic from non-operational regions" \
  --project="${PROJECT_ID}"

# ─────────────────────────────────────────────────────────────────────────────
# REGLA DEFAULT: Permitir trafico legitimo
# ─────────────────────────────────────────────────────────────────────────────
echo "=== Actualizando regla default (allow) ==="
gcloud compute security-policies rules update 2147483647 \
  --security-policy="${POLICY_NAME}" \
  --action=allow \
  --description="Default: allow legitimate traffic" \
  --project="${PROJECT_ID}"

echo ""
echo "============================================"
echo "Cloud Armor policy '${POLICY_NAME}' created"
echo "============================================"
echo "Project: ${PROJECT_ID}"
echo ""
echo "WAF rules:"
echo "  1000 - Block SQLi"
echo "  1100 - Block XSS"
echo "  1200 - Block LFI"
echo "  1300 - Block RFI"
echo "  1400 - Block Protocol Attacks"
echo "  1500 - Block Session Fixation"
echo ""
echo "Rate limiting rules:"
echo "  2000 - Global: 100 req/min/IP"
echo "  2100 - Login:  10 req/min/IP"
echo "  2200 - Payments: 20 req/min/IP"
echo ""
echo "Geo-blocking:"
echo "  3000 - Only LATAM + business regions"
echo "============================================"
