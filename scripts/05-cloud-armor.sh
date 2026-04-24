#!/bin/bash
# ============================================================
# TravelHub — Step 05: Cloud Armor Security Policy
# ============================================================
# Crea la politica WAF + rate limiting + geo-blocking.
# Consolida security-policy.sh y adaptive-protection.sh.
# Idempotente: verifica existencia antes de crear.
#
# Reglas:
#   1000-1500  WAF OWASP Top 10
#   2000-2200  Rate limiting (global, login, pagos)
#   3000       Geo-blocking
#   default    Allow
#
# Uso:
#   source config/environments/dev.env && bash scripts/05-cloud-armor.sh
# ============================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
require_env

CLOUD_ARMOR_ENABLED="${CLOUD_ARMOR_ENABLED:-true}"
if [[ "${CLOUD_ARMOR_ENABLED}" == "false" ]]; then
  log_warn "Cloud Armor DESHABILITADO (CLOUD_ARMOR_ENABLED=false)"
  log_warn "Saltando script 05. Para activar:"
  log_warn "  1. Pedir aumento de quota SECURITY_POLICIES en Console"
  log_warn "  2. Cambiar CLOUD_ARMOR_ENABLED=\"true\" en el .env"
  log_warn "  3. Reejecutar: bash scripts/05-cloud-armor.sh && bash scripts/08-load-balancer.sh"
  exit 0
fi

log_step "Configurando Cloud Armor: ${CLOUD_ARMOR_POLICY}"

# ── Crear security policy si no existe ──
if armor_policy_exists "${CLOUD_ARMOR_POLICY}"; then
  log_warn "Security policy '${CLOUD_ARMOR_POLICY}' ya existe — omitiendo creacion"
else
  log_info "Creando security policy '${CLOUD_ARMOR_POLICY}'..."
  gcloud compute security-policies create "${CLOUD_ARMOR_POLICY}" \
    --project="${GCP_PROJECT_ID}" \
    --description="TravelHub WAF + DDoS protection policy (${ENV})"
  log_success "Security policy '${CLOUD_ARMOR_POLICY}' creada"
fi

# ── Helper: crear regla de armor si no existe ──
create_armor_rule() {
  local priority="$1"
  local description="$2"
  shift 2

  if armor_rule_exists "${CLOUD_ARMOR_POLICY}" "${priority}"; then
    log_warn "Regla ${priority} ya existe en '${CLOUD_ARMOR_POLICY}' — omitiendo"
    return 0
  fi

  log_info "Creando regla ${priority}: ${description}..."
  gcloud compute security-policies rules create "${priority}" \
    --security-policy="${CLOUD_ARMOR_POLICY}" \
    --project="${GCP_PROJECT_ID}" \
    --description="${description}" \
    "$@"
  log_success "Regla ${priority} creada"
}

ARMOR_WAF_ENABLED="${ARMOR_WAF_ENABLED:-true}"
ARMOR_GEO_BLOCK_ENABLED="${ARMOR_GEO_BLOCK_ENABLED:-true}"

if [[ "${ARMOR_WAF_ENABLED}" == "true" ]]; then
  log_step "Creando reglas WAF OWASP (ARMOR_WAF_ENABLED=true)"

  # REGLA 1000: SQL Injection
  create_armor_rule 1000 "Block SQL injection (OWASP CRS)" \
    --expression="evaluatePreconfiguredExpr('sqli-v33-stable')" \
    --action=deny-403

  # REGLA 1100: XSS
  create_armor_rule 1100 "Block cross-site scripting (OWASP CRS)" \
    --expression="evaluatePreconfiguredExpr('xss-v33-stable')" \
    --action=deny-403

  # REGLA 1200: LFI
  create_armor_rule 1200 "Block local file inclusion" \
    --expression="evaluatePreconfiguredExpr('lfi-v33-stable')" \
    --action=deny-403

  # REGLA 1300: RFI
  create_armor_rule 1300 "Block remote file inclusion" \
    --expression="evaluatePreconfiguredExpr('rfi-v33-stable')" \
    --action=deny-403

  # REGLA 1400: Protocol Attacks
  create_armor_rule 1400 "Block protocol-level attacks" \
    --expression="evaluatePreconfiguredExpr('protocolattack-v33-stable')" \
    --action=deny-403

  # REGLA 1500: Session Fixation
  create_armor_rule 1500 "Block session fixation attacks" \
    --expression="evaluatePreconfiguredExpr('sessionfixation-v33-stable')" \
    --action=deny-403
else
  log_step "WAF OMITIDO (ARMOR_WAF_ENABLED=false)"
  log_warn "Reglas OWASP 1000-1500 no se crean. Activar con ARMOR_WAF_ENABLED=true."

  # Limpieza: si existen reglas WAF de una ejecucion previa, eliminarlas
  for priority in 1000 1100 1200 1300 1400 1500; do
    if armor_rule_exists "${CLOUD_ARMOR_POLICY}" "${priority}"; then
      log_info "Eliminando regla WAF previa ${priority}..."
      gcloud compute security-policies rules delete "${priority}" \
        --security-policy="${CLOUD_ARMOR_POLICY}" \
        --quiet \
        --project="${GCP_PROJECT_ID}" 2>/dev/null || true
      log_success "Regla ${priority} eliminada"
    fi
  done
fi

log_step "Creando reglas de rate limiting"

# REGLA 2000: Rate Limiting Global
create_armor_rule 2000 "Global rate limiting: ${RATE_LIMIT_GLOBAL} req/min per IP" \
  --src-ip-ranges="*" \
  --action=throttle \
  --rate-limit-threshold-count="${RATE_LIMIT_GLOBAL}" \
  --rate-limit-threshold-interval-sec=60 \
  --conform-action=allow \
  --exceed-action=deny-429 \
  --enforce-on-key=IP

# REGLA 2100: Rate Limiting Login (anti brute-force)
create_armor_rule 2100 "Login rate limit: ${RATE_LIMIT_LOGIN} req/min per IP (AH008)" \
  --expression="request.path.matches('/api/v1/auth/login')" \
  --action=throttle \
  --rate-limit-threshold-count="${RATE_LIMIT_LOGIN}" \
  --rate-limit-threshold-interval-sec=60 \
  --conform-action=allow \
  --exceed-action=deny-429 \
  --enforce-on-key=IP

# REGLA 2200: Rate Limiting Pagos
create_armor_rule 2200 "Payments rate limit: ${RATE_LIMIT_PAYMENTS} req/min per IP (PCI-DSS)" \
  --expression="request.path.matches('/api/v1/payments/.*')" \
  --action=throttle \
  --rate-limit-threshold-count="${RATE_LIMIT_PAYMENTS}" \
  --rate-limit-threshold-interval-sec=60 \
  --conform-action=allow \
  --exceed-action=deny-429 \
  --enforce-on-key=IP

if [[ "${ARMOR_GEO_BLOCK_ENABLED}" == "true" ]]; then
  log_step "Creando regla de geo-blocking (ARMOR_GEO_BLOCK_ENABLED=true)"

  # REGLA 3000: Geo-blocking (LATAM + regiones de negocio)
  create_armor_rule 3000 "Block traffic from non-operational regions" \
    --expression="!origin.region_code.matches('CO|PE|EC|MX|CL|AR|US|BR|ES|FR|DE|GB|IT')" \
    --action=deny-403
else
  log_step "Geo-blocking OMITIDO (ARMOR_GEO_BLOCK_ENABLED=false)"
  log_warn "Regla 3000 no se crea. Activar con ARMOR_GEO_BLOCK_ENABLED=true."

  if armor_rule_exists "${CLOUD_ARMOR_POLICY}" 3000; then
    log_info "Eliminando regla 3000 previa de geo-blocking..."
    gcloud compute security-policies rules delete 3000 \
      --security-policy="${CLOUD_ARMOR_POLICY}" \
      --quiet \
      --project="${GCP_PROJECT_ID}" 2>/dev/null || true
    log_success "Regla 3000 eliminada"
  fi
fi

# ── Regla DEFAULT: Allow ──
log_step "Configurando regla default"
log_info "Actualizando regla default (allow)..."
gcloud compute security-policies rules update 2147483647 \
  --security-policy="${CLOUD_ARMOR_POLICY}" \
  --action=allow \
  --description="Default: allow legitimate traffic" \
  --project="${GCP_PROJECT_ID}"
log_success "Regla default configurada"

# ── Adaptive Protection (DDoS L7 con ML) ──
log_step "Habilitando Adaptive Protection"
log_info "Habilitando Adaptive Protection (DDoS L7)..."
gcloud compute security-policies update "${CLOUD_ARMOR_POLICY}" \
  --enable-layer7-ddos-defense \
  --project="${GCP_PROJECT_ID}"
log_success "Adaptive Protection habilitada"

log_info "Configurando logging verbose..."
gcloud compute security-policies update "${CLOUD_ARMOR_POLICY}" \
  --log-level=VERBOSE \
  --project="${GCP_PROJECT_ID}"
log_success "Logging verbose configurado"

echo ""
log_success "Cloud Armor configurado"
echo ""
echo "Policy: ${CLOUD_ARMOR_POLICY}"
echo ""
if [[ "${ARMOR_WAF_ENABLED}" == "true" ]]; then
  echo "WAF rules (OWASP):     ACTIVAS"
  echo "  1000 - Block SQLi"
  echo "  1100 - Block XSS"
  echo "  1200 - Block LFI"
  echo "  1300 - Block RFI"
  echo "  1400 - Block Protocol Attacks"
  echo "  1500 - Block Session Fixation"
else
  echo "WAF rules (OWASP):     DESHABILITADAS (ARMOR_WAF_ENABLED=false)"
fi
echo ""
echo "Rate limiting:         ACTIVO"
echo "  2000 - Global:   ${RATE_LIMIT_GLOBAL} req/min/IP"
echo "  2100 - Login:    ${RATE_LIMIT_LOGIN} req/min/IP"
echo "  2200 - Payments: ${RATE_LIMIT_PAYMENTS} req/min/IP"
echo ""
if [[ "${ARMOR_GEO_BLOCK_ENABLED}" == "true" ]]; then
  echo "Geo-blocking:          ACTIVO"
  echo "  3000 - Solo LATAM + regiones de negocio"
else
  echo "Geo-blocking:          DESHABILITADO (ARMOR_GEO_BLOCK_ENABLED=false)"
fi
echo ""
echo "Adaptive Protection: habilitada (DDoS L7 con ML)"
