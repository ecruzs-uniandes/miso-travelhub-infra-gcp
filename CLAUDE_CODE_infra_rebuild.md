# CLAUDE_CODE — Refactorización Completa de Infraestructura GCP TravelHub

> **Proyecto:** TravelHub — Grupo 9 (MISW4501, Uniandes)
> **Repo:** `uniandes-pf-infra-gcp`
> **Objetivo:** Refactorizar toda la infraestructura GCP con scripts bash idempotentes, multi-ambiente, con scripts centralizados de creación y destrucción.
> **Herramienta IaC:** gcloud CLI (bash scripts). NO usar Terraform para la infra base (el Terraform existente es solo para CI/CD pipeline y se mantiene separado).

---

## 1. DIAGNÓSTICO DEL ESTADO ACTUAL

### 1.1 Problemas Críticos Encontrados

#### P1 — NO ES IDEMPOTENTE
Los scripts usan `gcloud ... create` sin verificar existencia previa. Si se ejecutan dos veces, fallan con error "already exists". Solo algunos comandos en `deploy/deploy-load-balancer.sh` y `deploy/deploy-gateway.sh` tienen `2>/dev/null || echo "already exists"` pero eso **suprime TODOS los errores**, no solo el de existencia. El patrón correcto es verificar antes de crear.

**Archivos afectados:**
- `firewall/vpc-setup.sh` — NINGÚN chequeo de existencia
- `firewall/firewall-rules.sh` — NINGÚN chequeo de existencia (9 reglas)
- `firewall/private-access.sh` — NINGÚN chequeo de existencia
- `cloud-armor/security-policy.sh` — NINGÚN chequeo de existencia (11 reglas)
- `cloud-armor/adaptive-protection.sh` — Sin chequeo
- `database/setup-cloudsql.sh` — Sin chequeo, genera password nuevo cada vez (pierde el anterior)

#### P2 — NO HAY SCRIPT CENTRALIZADO
No existe un `deploy-all.sh` para crear todo en orden, ni un `destroy-all.sh` para eliminar todo. El README documenta el orden manual pero no lo automatiza.

#### P3 — NO SOPORTA MULTI-AMBIENTE
Todo apunta a un solo proyecto GCP (`gen-lang-client-0930444414`). No hay forma de desplegar en dev/qa/prod cambiando solo una variable. Los nombres de recursos son fijos (`travelhub-vpc`, `travelhub-db`, etc.) sin prefijo de ambiente. Si se intentara desplegar en un segundo proyecto con el mismo prefijo, funcionaría, pero no se pueden tener dos ambientes en el mismo proyecto.

#### P4 — DOS PROYECTOS GCP DESALINEADOS
Los bash scripts apuntan a `gen-lang-client-0930444414` (proyecto de Edwin) pero el pipeline CI/CD en Terraform apunta a `secret-lambda-491419-p2` (proyecto de Pablo). No hay un mecanismo para unificar ambos o hacer que el CI/CD trabaje sobre la infra base.

#### P5 — CONTRASEÑA HARDCODEADA EN DOCUMENTACIÓN
El archivo `INFRA_STATUS.md` tiene la contraseña de Cloud SQL en texto plano: `lALk8rAOj1TSltRQzGavZdBCrSu67ZJg`. Mientras tanto, `database/setup-cloudsql.sh` genera una password aleatoria con `openssl rand` pero solo la imprime en consola (se pierde). No hay integración con Secret Manager.

#### P6 — CI/CD TERRAFORM DESPLEGA UN SOLO SERVICIO
El módulo `cloud-run-service` de Terraform crea UN SOLO Cloud Run service (`prod-travelhub-project-app-service`), pero TravelHub tiene 8 microservicios. No hay iteración sobre servicios ni parametrización por servicio.

#### P7 — GATEWAY HOSTNAME HARDCODEADO
`deploy/deploy-load-balancer.sh` tiene `GATEWAY_HOSTNAME` hardcodeado al hostname del gateway de dev. Si se redesplega en otro proyecto, el hostname será diferente y el LB apuntará al gateway equivocado.

#### P8 — CORS POLICY NO ESTÁ INTEGRADA
El archivo `gateway/cors-policy.yaml` existe pero NO está referenciado en ningún script ni en la OpenAPI spec. Es un archivo muerto.

#### P9 — NO HAY TEARDOWN (DESTRUCCIÓN)
No existe ningún script para destruir los recursos creados. Para limpiar hay que hacerlo manualmente en la consola GCP, lo cual es lento y propenso a errores.

#### P10 — OPENAPI SPEC CON URLs HARDCODEADAS
`gateway/openapi-spec.yaml` tiene las URLs de Cloud Run hardcodeadas (con hashes de deploy). Cuando se redespliegue `user-services`, el hash cambiará y habrá que editar manualmente el YAML. Los demás servicios tienen `PLACEHOLDER` literal.

### 1.2 Problemas Menores

- `database/setup-cloudsql.sh` no parametriza el password — genera uno nuevo cada vez, pero no lo almacena en Secret Manager
- Los tests en `tests/` son buenos pero no se ejecutan automáticamente después del deploy
- `cloud-armor/security-policy.sh` crea regla 3000 (geo-blocking) que bloqueará tráfico desde la universidad si no está en los países permitidos (Colombia sí está, pero podría ser un problema para pruebas desde VPN de otros países)
- No hay script para habilitar las APIs de GCP necesarias de forma centralizada (están dispersas en cada script)
- El Terraform usa `google_cloud_run_service` (v1 API, deprecated) en lugar de `google_cloud_run_v2_service`

---

## 2. ARQUITECTURA OBJETIVO

### 2.1 Estructura del Repositorio Refactorizado

```
uniandes-pf-infra-gcp/
├── config/
│   ├── environments/
│   │   ├── dev.env                  # Variables para ambiente dev
│   │   ├── qa.env                   # Variables para ambiente qa (futuro)
│   │   └── prod.env                 # Variables para ambiente prod (futuro)
│   └── services.env                 # Lista de microservicios y sus configs
├── scripts/
│   ├── lib/
│   │   └── common.sh               # Funciones compartidas (logging, idempotencia, validación)
│   ├── 01-enable-apis.sh           # Habilitar todas las APIs de GCP
│   ├── 02-vpc-setup.sh             # VPC + subnets + VPC Access Connector
│   ├── 03-firewall-rules.sh        # Reglas de firewall (DENY ALL base)
│   ├── 04-private-access.sh        # Private Service Connection
│   ├── 05-cloud-armor.sh           # Security policy + adaptive protection (consolidado)
│   ├── 06-database.sh              # Cloud SQL + Secret Manager
│   ├── 07-gateway.sh               # API Gateway (genera spec dinámicamente)
│   ├── 08-load-balancer.sh         # LB + IP estática + SSL + Cloud Armor
│   └── 09-tests.sh                 # Tests de validación post-deploy
├── destroy/
│   ├── destroy-all.sh              # Destruir TODOS los recursos en orden inverso
│   └── destroy-selective.sh        # Destruir componentes individuales
├── gateway/
│   ├── openapi-spec.template.yaml  # Template con placeholders {{SERVICE_URL}}
│   └── cors-policy.yaml            # Política CORS (ahora integrada)
├── deploy-all.sh                   # Script maestro: crea TODO en orden
├── destroy-all.sh                  # Script maestro: destruye TODO en orden inverso
├── status.sh                       # Muestra estado actual de todos los componentes
├── CLAUDE.md                       # Contexto para Claude Code
├── README.md                       # Documentación actualizada
└── cloud-run-services-cicd-pipeline/  # Terraform CI/CD (sin cambios por ahora)
```

### 2.2 Convención de Nombres Multi-Ambiente

Todos los recursos GCP deben tener prefijo de ambiente:

```
{ENV}-travelhub-{recurso}
```

Ejemplos:
- `dev-travelhub-vpc`
- `dev-travelhub-security-policy`
- `dev-travelhub-db`
- `dev-travelhub-lb-ip`
- `qa-travelhub-vpc` (futuro)
- `prod-travelhub-vpc` (futuro)

Esto permite tener múltiples ambientes en el mismo proyecto GCP o en proyectos diferentes.

### 2.3 Archivos de Ambiente

**`config/environments/dev.env`:**
```bash
# ============================================================
# TravelHub — Ambiente: DEV
# ============================================================
export ENV="dev"
export GCP_PROJECT_ID="gen-lang-client-0930444414"
export GCP_REGION="us-central1"
export DOMAIN="apitravelhub.site"

# Naming
export PREFIX="${ENV}-travelhub"
export VPC_NAME="${PREFIX}-vpc"
export CLOUD_ARMOR_POLICY="${PREFIX}-security-policy"
export DB_INSTANCE_NAME="${PREFIX}-db"
export DB_NAME="travelhub"
export DB_USER="travelhub_app"

# Networking
export SUBNET_PUBLIC_CIDR="10.10.1.0/24"
export SUBNET_SERVICES_CIDR="10.10.2.0/24"
export SUBNET_DATA_CIDR="10.10.3.0/24"
export VPC_CONNECTOR_CIDR="10.10.8.0/28"
export PRIVATE_RANGE_CIDR="10.100.0.0"
export PRIVATE_RANGE_PREFIX="20"

# Cloud SQL
export DB_TIER="db-f1-micro"
export DB_HA="zonal"            # zonal para dev, regional para prod
export DB_BACKUP="false"        # false para dev, true para prod
export DB_STORAGE="10GB"

# Cloud Armor
export RATE_LIMIT_GLOBAL="100"
export RATE_LIMIT_LOGIN="10"
export RATE_LIMIT_PAYMENTS="20"

# Gateway
export JWKS_URI=""  # Se completa después del deploy de user-services

# Microservicios Cloud Run (URLs se llenan post-deploy)
export USER_SERVICES_URL=""
export SEARCH_SERVICES_URL=""
export BOOKING_SERVICES_URL=""
export PAYMENTS_SERVICES_URL=""
export INVENTORY_SERVICES_URL=""
export NOTIFICATION_SERVICES_URL=""
export PMS_SERVICES_URL=""
export CART_SERVICES_URL=""
```

**`config/services.env`:**
```bash
# ============================================================
# TravelHub — Definición de Microservicios
# ============================================================
# Formato: NOMBRE:PUERTO:REQUIERE_JWT
# Los que tienen JWT=false son rutas públicas manejadas aparte
SERVICES=(
  "user-services:8000:mixed"
  "search-services:8000:true"
  "booking-services:8000:true"
  "payments-services:8000:true"
  "inventory-services:8000:true"
  "notification-services:8000:true"
  "pms-integration-services:8000:true"
  "shopping-cart-services:8000:true"
)
```

---

## 3. ESPECIFICACIÓN DE CADA SCRIPT

### 3.0 Biblioteca Común — `scripts/lib/common.sh`

Esta biblioteca debe ser importada por TODOS los scripts con `source "$(dirname "$0")/lib/common.sh"`.

Debe proveer:

```bash
#!/bin/bash
# ============================================================
# TravelHub — Funciones comunes de infraestructura
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

# ── Validación de ambiente ──
require_env() {
  # Verifica que el archivo de ambiente fue cargado
  if [[ -z "${ENV:-}" || -z "${GCP_PROJECT_ID:-}" ]]; then
    log_error "Variables de ambiente no cargadas."
    log_error "Uso: source config/environments/dev.env && bash $0"
    exit 1
  fi
  log_info "Ambiente: ${ENV} | Proyecto: ${GCP_PROJECT_ID} | Región: ${GCP_REGION}"
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

# Crea un recurso solo si no existe
create_if_not_exists() {
  local resource_type="$1"
  local resource_name="$2"
  local check_flags="$3"
  local description="$4"
  shift 4
  # Los argumentos restantes ($@) son los flags de creación

  if resource_exists "${resource_type}" "${resource_name}" "${check_flags}"; then
    log_warn "${description} ya existe — omitiendo"
    return 0
  fi

  log_info "Creando ${description}..."
  "$@"
  log_success "${description} creado"
}

# Verifica si una regla de Cloud Armor existe
armor_rule_exists() {
  local policy="$1"
  local priority="$2"
  gcloud compute security-policies rules describe "${priority}" \
    --security-policy="${policy}" \
    --project="${GCP_PROJECT_ID}" &>/dev/null
}

# Verifica si una instancia de Cloud SQL existe
sql_instance_exists() {
  local instance="$1"
  gcloud sql instances describe "${instance}" \
    --project="${GCP_PROJECT_ID}" &>/dev/null
}

# Verifica si un secret existe en Secret Manager
secret_exists() {
  local secret_name="$1"
  gcloud secrets describe "${secret_name}" \
    --project="${GCP_PROJECT_ID}" &>/dev/null
}

# Verifica si una API está habilitada
api_enabled() {
  local api="$1"
  gcloud services list --enabled \
    --filter="config.name:${api}" \
    --format="value(config.name)" \
    --project="${GCP_PROJECT_ID}" | grep -q "${api}"
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

# ── Funciones de destrucción ──

# Elimina un recurso si existe
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
```

### 3.1 Script 01 — Habilitar APIs

**`scripts/01-enable-apis.sh`**

Habilitar todas las APIs necesarias de una sola vez. Esto evita el problema de que cada script habilite la suya (y falle si la API tarda en propagarse).

APIs a habilitar:
- `compute.googleapis.com`
- `vpcaccess.googleapis.com`
- `servicenetworking.googleapis.com`
- `sqladmin.googleapis.com`
- `apigateway.googleapis.com`
- `servicemanagement.googleapis.com`
- `servicecontrol.googleapis.com`
- `secretmanager.googleapis.com`
- `run.googleapis.com`
- `cloudbuild.googleapis.com`

Patrón: iterar sobre la lista, usar `enable_api()` de common.sh.

### 3.2 Script 02 — VPC Setup

**`scripts/02-vpc-setup.sh`**

Misma lógica que el actual `firewall/vpc-setup.sh` pero:
- Usar `create_if_not_exists()` para VPC, cada subnet, y el VPC connector
- Nombres con prefijo: `${PREFIX}-vpc`, `${PREFIX}-subnet-public`, etc.
- CIDRs desde variables de ambiente (no hardcodeados)
- El VPC connector se llama `${PREFIX}-connector`

### 3.3 Script 03 — Firewall Rules

**`scripts/03-firewall-rules.sh`**

Misma lógica que el actual pero:
- Cada regla verificada con `resource_exists "firewall-rules"` antes de crear
- Nombres con prefijo: `${PREFIX}-fw-deny-ssh`, `${PREFIX}-fw-allow-https-lb`, etc.
- Referenciar el VPC por `${VPC_NAME}` (que ya tiene prefijo)

### 3.4 Script 04 — Private Access

**`scripts/04-private-access.sh`**

Igual que el actual pero con chequeos de idempotencia:
- Verificar si el rango de IPs ya está reservado
- Verificar si el peering ya existe
- Nombres: `${PREFIX}-private-range`

### 3.5 Script 05 — Cloud Armor

**`scripts/05-cloud-armor.sh`**

Consolidar `security-policy.sh` + `adaptive-protection.sh` en un solo script:
- Verificar si la policy existe antes de crearla
- Para cada regla, usar `armor_rule_exists()` antes de crear
- Rate limits desde variables de ambiente (`${RATE_LIMIT_GLOBAL}`, etc.)
- Policy name: `${CLOUD_ARMOR_POLICY}` (que ya tiene prefijo)

### 3.6 Script 06 — Database

**`scripts/06-database.sh`**

Cambio más significativo respecto al actual:
- Verificar si la instancia SQL existe con `sql_instance_exists()`
- Si NO existe: crear instancia, DB, usuario, generar password
- **Almacenar password en Secret Manager** como `${PREFIX}-db-password`
- Si YA existe: obtener password de Secret Manager, imprimir connection string
- Tier, HA, backup, storage desde variables de ambiente
- Si el ambiente es prod: `--availability-type=regional --backup`

```bash
# Patrón para Secret Manager:
SECRET_NAME="${PREFIX}-db-password"
if ! secret_exists "${SECRET_NAME}"; then
  DB_PASSWORD=$(openssl rand -base64 24)
  echo -n "${DB_PASSWORD}" | gcloud secrets create "${SECRET_NAME}" \
    --data-file=- \
    --project="${GCP_PROJECT_ID}"
else
  DB_PASSWORD=$(gcloud secrets versions access latest \
    --secret="${SECRET_NAME}" \
    --project="${GCP_PROJECT_ID}")
fi
```

### 3.7 Script 07 — API Gateway

**`scripts/07-gateway.sh`**

Cambio más significativo: generar la OpenAPI spec dinámicamente desde un template.

- Leer `gateway/openapi-spec.template.yaml`
- Reemplazar placeholders `{{USER_SERVICES_URL}}`, `{{SEARCH_SERVICES_URL}}`, etc. con las URLs del ambiente
- Si una URL está vacía (servicio no desplegado), usar un placeholder que retorne 503
- Guardar spec generada en `/tmp/${PREFIX}-openapi-spec.yaml`
- Crear API config con timestamp (ya lo hace el actual)
- Crear o actualizar gateway

**`gateway/openapi-spec.template.yaml`** debe usar estos placeholders:
```yaml
x-google-backend:
  address: "{{USER_SERVICES_URL}}"
```

### 3.8 Script 08 — Load Balancer

**`scripts/08-load-balancer.sh`**

Igual que el actual pero:
- Todos los recursos con prefijo (`${PREFIX}-lb-ip`, `${PREFIX}-gateway-neg`, etc.)
- El hostname del gateway se obtiene dinámicamente (no hardcodeado):
  ```bash
  GATEWAY_HOSTNAME=$(gcloud api-gateway gateways describe "${PREFIX}-gateway" \
    --location="${GCP_REGION}" \
    --project="${GCP_PROJECT_ID}" \
    --format="value(defaultHostname)")
  ```
- Para dev: certificado self-signed
- Para prod: certificado managed con dominio
- Idempotencia en cada paso

### 3.9 Script 09 — Tests

**`scripts/09-tests.sh`**

Consolidar `test_cloud_armor.sh` + `test_firewall_rules.sh`:
- Obtener GATEWAY_URL dinámicamente del gateway desplegado
- Ejecutar todos los tests existentes
- Agregar test de conectividad al health endpoint
- Exit code 0 si todo pasa, 1 si hay fallos

---

## 4. SCRIPTS MAESTROS

### 4.1 `deploy-all.sh`

```bash
#!/bin/bash
# ============================================================
# TravelHub — Deploy completo de infraestructura
# ============================================================
# Uso:
#   source config/environments/dev.env && bash deploy-all.sh
#   source config/environments/prod.env && bash deploy-all.sh
# ============================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

source "${SCRIPT_DIR}/scripts/lib/common.sh"
require_env

echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║  TravelHub — Deploy Infraestructura GCP         ║"
echo "║  Ambiente: ${ENV}                               ║"
echo "║  Proyecto: ${GCP_PROJECT_ID}                    ║"
echo "╚══════════════════════════════════════════════════╝"
echo ""

STEPS=(
  "01-enable-apis.sh:Habilitar APIs de GCP"
  "02-vpc-setup.sh:Crear VPC y subnets"
  "03-firewall-rules.sh:Configurar reglas de firewall"
  "04-private-access.sh:Configurar acceso privado"
  "05-cloud-armor.sh:Crear política Cloud Armor"
  "06-database.sh:Configurar Cloud SQL PostgreSQL"
  "07-gateway.sh:Desplegar API Gateway"
  "08-load-balancer.sh:Configurar Load Balancer"
  "09-tests.sh:Ejecutar tests de validación"
)

TOTAL=${#STEPS[@]}
CURRENT=0

for step in "${STEPS[@]}"; do
  IFS=':' read -r script desc <<< "$step"
  CURRENT=$((CURRENT + 1))
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  [${CURRENT}/${TOTAL}] ${desc}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  bash "${SCRIPT_DIR}/scripts/${script}"
done

echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║  ✓ Deploy completado exitosamente               ║"
echo "╚══════════════════════════════════════════════════╝"

# Imprimir resumen con status.sh
bash "${SCRIPT_DIR}/status.sh"
```

### 4.2 `destroy-all.sh`

```bash
#!/bin/bash
# ============================================================
# TravelHub — Destruir TODA la infraestructura
# ============================================================
# PELIGRO: Este script elimina todos los recursos del ambiente.
# Uso:
#   source config/environments/dev.env && bash destroy-all.sh
# ============================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

source "${SCRIPT_DIR}/scripts/lib/common.sh"
require_env

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║  ⚠  DESTRUCCIÓN DE INFRAESTRUCTURA                 ║"
echo "║  Ambiente: ${ENV}                                   ║"
echo "║  Proyecto: ${GCP_PROJECT_ID}                        ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""
echo "ESTO ELIMINARÁ TODOS LOS RECURSOS DEL AMBIENTE '${ENV}'."
echo ""
read -p "¿Estás seguro? Escribe '${ENV}' para confirmar: " CONFIRM
if [[ "${CONFIRM}" != "${ENV}" ]]; then
  echo "Cancelado."
  exit 0
fi

# Orden inverso de creación (dependencias invertidas)
# 1. Load Balancer (forwarding rule → proxy → cert → url-map → backend → NEG → IP)
# 2. API Gateway
# 3. Cloud SQL
# 4. Cloud Armor
# 5. Private Access
# 6. Firewall rules
# 7. VPC (subnets → connector → VPC)
```

El script `destroy-all.sh` debe eliminar en ORDEN INVERSO estricto:

1. **Forwarding rule** → `gcloud compute forwarding-rules delete`
2. **HTTPS proxy** → `gcloud compute target-https-proxies delete`
3. **SSL certificate** → `gcloud compute ssl-certificates delete`
4. **URL map** → `gcloud compute url-maps delete`
5. **Backend service** (primero quitar Cloud Armor: `--security-policy ""`) → `gcloud compute backend-services delete`
6. **NEG** → `gcloud compute network-endpoint-groups delete`
7. **IP estática** → `gcloud compute addresses delete`
8. **API Gateway** → gateway → api-config → api
9. **Cloud SQL instance** → `gcloud sql instances delete` (esto borra DB y usuario)
10. **Secret Manager secrets** → `gcloud secrets delete`
11. **Cloud Armor policy** → primero borrar todas las reglas (1000-3000), luego la policy
12. **Private Service Connection** → desconectar peering, borrar rango reservado
13. **Firewall rules** → borrar todas las `${PREFIX}-fw-*`
14. **VPC connector** → `gcloud compute networks vpc-access connectors delete`
15. **Subnets** → borrar las 3 subnets
16. **VPC** → `gcloud compute networks delete`

Cada paso debe usar `delete_if_exists()` para ser idempotente en la destrucción.

### 4.3 `status.sh`

Debe consultar y mostrar el estado actual de todos los componentes:
- VPC y subnets (existen? CIDRs?)
- Firewall rules (cuántas? activas?)
- Cloud Armor (policy existe? reglas?)
- Cloud SQL (instancia? IP privada? estado?)
- API Gateway (URL?)
- Load Balancer (IP estática? backend service?)
- Microservicios Cloud Run (cuáles están desplegados?)

Formato: tabla resumen con ✓ / ✗ por componente.

---

## 5. REGLAS DE IMPLEMENTACIÓN

### 5.1 Idempotencia
- **NUNCA** usar `2>/dev/null || echo "already exists"` — esto suprime errores reales
- **SIEMPRE** verificar existencia antes de crear con `gcloud describe` + chequeo de exit code
- Cada script debe poder ejecutarse N veces con resultado idéntico

### 5.2 Naming
- Todo recurso: `${PREFIX}-{nombre}` donde `PREFIX="${ENV}-travelhub"`
- Firewall rules: `${PREFIX}-fw-{acción}` (ej: `dev-travelhub-fw-deny-ssh`)
- Cloud Armor rules: se crean dentro de la policy `${PREFIX}-security-policy`

### 5.3 Variables
- CERO valores hardcodeados en scripts (todo viene del archivo `.env`)
- Las URLs de Cloud Run se pasan como variables de ambiente
- Passwords en Secret Manager, nunca en archivos ni en output

### 5.4 Error Handling
- Todos los scripts: `set -euo pipefail`
- Cada paso con logging claro (log_info, log_success, log_error)
- El `deploy-all.sh` debe detenerse si un paso falla (set -e lo garantiza)

### 5.5 Seguridad
- Password de DB en Secret Manager (no en consola, no en archivos)
- El `destroy-all.sh` requiere confirmación interactiva escribiendo el nombre del ambiente
- No imprimir passwords en output (solo referencia al secret)

---

## 6. OPENAPI SPEC TEMPLATE

Crear `gateway/openapi-spec.template.yaml` basado en el actual pero con estos cambios:

1. Reemplazar todas las URLs hardcodeadas de Cloud Run por placeholders:
   - `https://user-services-ridyy4wz4q-uc.a.run.app` → `{{USER_SERVICES_URL}}`
   - `https://search-services-PLACEHOLDER.a.run.app` → `{{SEARCH_SERVICES_URL}}`
   - etc.
2. El JWKS URI también debe ser placeholder: `{{JWKS_URI}}`
3. El host del gateway: `{{GATEWAY_HOST}}`

El script `07-gateway.sh` usará `envsubst` o `sed` para reemplazar los placeholders con las URLs reales del ambiente.

---

## 7. QUÉ NO TOCAR

- **`cloud-run-services-cicd-pipeline/`** — El Terraform CI/CD de Pablo se mantiene separado. No refactorizarlo en esta tarea.
- **`INSTRUCTIONS_API_Gateway_JWT_Hibrido_GCP.md`** — Documento de referencia, mantener tal cual.
- **`CONTEXT_USER_SERVICES.md`** — Contexto para user-services, mantener tal cual.

---

## 8. ORDEN DE EJECUCIÓN

1. Crear `scripts/lib/common.sh` primero (todo depende de esto)
2. Crear `config/environments/dev.env` y `config/services.env`
3. Crear los 9 scripts en orden numérico (01 a 09)
4. Crear `gateway/openapi-spec.template.yaml`
5. Crear `deploy-all.sh`, `destroy-all.sh`, `status.sh`
6. Actualizar `README.md` y `CLAUDE.md`
7. Verificar que cada script individual funciona con `bash -n scripts/XX.sh` (syntax check)

---

## 9. DATOS DE REFERENCIA (del ambiente DEV actual)

Estos datos corresponden al deploy actual y deben mantenerse como defaults en `config/environments/dev.env`:

| Componente | Valor actual |
|---|---|
| GCP Project | `gen-lang-client-0930444414` |
| Region | `us-central1` |
| VPC | `travelhub-vpc` → será `dev-travelhub-vpc` |
| IP estática | `136.110.223.156` (se recreará con nuevo nombre) |
| Cloud SQL IP | `10.100.0.3` (asignada por GCP, no controlable) |
| DB | `travelhub` / `travelhub_app` |
| Gateway URL | `travelhub-gateway-1yvtqj7r.uc.gateway.dev` (cambiará al redesplegar) |
| user-services | `https://user-services-ridyy4wz4q-uc.a.run.app` |
| Dominio | `apitravelhub.site` |

### Microservicios registrados en OpenAPI spec:

| Servicio | Rutas | Estado |
|---|---|---|
| user-services | `/api/v1/auth/*`, `/api/v1/admin/*` | Desplegado |
| search-services | `/api/v1/search/*` | Pendiente |
| booking-services | `/api/v1/bookings/*` | Pendiente |
| payments-services | `/api/v1/payments/*` | Pendiente |
| inventory-services | `/api/v1/inventory/*` | Pendiente |
| notification-services | `/api/v1/notifications/*` | Pendiente |
| pms-integration-services | `/api/v1/pms/*` | Pendiente |
| shopping-cart-services | `/api/v1/cart/*` | Pendiente |

### Cloud Armor — Reglas (mantener exactamente las mismas):

| Prioridad | Tipo | Acción |
|---|---|---|
| 1000 | sqli-v33-stable | deny-403 |
| 1100 | xss-v33-stable | deny-403 |
| 1200 | lfi-v33-stable | deny-403 |
| 1300 | rfi-v33-stable | deny-403 |
| 1400 | protocolattack-v33-stable | deny-403 |
| 1500 | sessionfixation-v33-stable | deny-403 |
| 2000 | Rate limit global | 100 req/min/IP → throttle/deny-429 |
| 2100 | Rate limit login | 10 req/min/IP → throttle/deny-429 |
| 2200 | Rate limit pagos | 20 req/min/IP → throttle/deny-429 |
| 3000 | Geo-blocking | deny-403 |
| default | Allow | allow |

### Firewall Rules (mantener misma lógica, solo renombrar):

| Actual | Nuevo nombre |
|---|---|
| fw-deny-ssh-internet | ${PREFIX}-fw-deny-ssh |
| fw-allow-https-lb | ${PREFIX}-fw-allow-https-lb |
| fw-allow-health-checks | ${PREFIX}-fw-allow-health-checks |
| fw-allow-gateway-to-services | ${PREFIX}-fw-allow-gw-to-svc |
| fw-allow-services-to-data | ${PREFIX}-fw-allow-svc-to-data |
| fw-allow-inter-service | ${PREFIX}-fw-allow-inter-svc |
| fw-deny-all-ingress | ${PREFIX}-fw-deny-all-ingress |
| fw-allow-egress-external | ${PREFIX}-fw-allow-egress-ext |
| fw-deny-data-egress | ${PREFIX}-fw-deny-data-egress |

---

## 10. CRITERIOS DE COMPLETITUD

La refactorización está completa cuando:

1. ✅ `source config/environments/dev.env && bash deploy-all.sh` crea TODA la infra desde cero
2. ✅ Ejecutar `deploy-all.sh` una segunda vez no produce errores (idempotente)
3. ✅ `source config/environments/dev.env && bash destroy-all.sh` elimina TODO sin dejar recursos huérfanos
4. ✅ Ejecutar `destroy-all.sh` una segunda vez no produce errores (idempotente)
5. ✅ `status.sh` muestra el estado correcto (todo ✓ después de deploy, todo ✗ después de destroy)
6. ✅ Se puede crear un `config/environments/qa.env` apuntando a otro proyecto y desplegar sin conflictos
7. ✅ La contraseña de DB está en Secret Manager, no en texto plano
8. ✅ La OpenAPI spec se genera dinámicamente desde el template
9. ✅ Los tests de `09-tests.sh` pasan después del deploy
10. ✅ `bash -n` (syntax check) pasa en todos los scripts
