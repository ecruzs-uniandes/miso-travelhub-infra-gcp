# TravelHub — Infraestructura de Seguridad GCP

**Proyecto:** TravelHub — Grupo 9
**Contexto:** PF2 Sprint 1
**ASRs:** AH008 (Seguridad), AH009 (RBAC), AH007 (Cifrado), AH016 (Resiliencia)

Repositorio de infraestructura de seguridad en GCP para la plataforma TravelHub. Implementa un modelo de defensa en profundidad con 4 capas que protegen los microservicios desplegados en Cloud Run.

---

## Arquitectura de Seguridad — Defensa en Profundidad

```text
Internet
   |
   v
[ apitravelhub.site -> 136.110.223.156 ]
   |
   v
+------------------------------------------+
|  LOAD BALANCER (HTTPS)                   |
|  SSL termination, forwarding rule        |
+------------------------------------------+
   |
   v
+------------------------------------------+
|  CAPA 1: Cloud Armor (WAF)               |
|  OWASP Top 10, rate limiting, DDoS,      |
|  geo-blocking                             |
+------------------------------------------+
   |
   v
+------------------------------------------+
|  CAPA 2: VPC Firewall                    |
|  Segmentacion de red, DENY ALL default,  |
|  aislamiento de capa de datos            |
+------------------------------------------+
   |
   v
+------------------------------------------+
|  CAPA 3: API Gateway                     |
|  Validacion JWT (firma RS256, issuer,    |
|  audience, expiracion)                   |
+------------------------------------------+
   |
   v
+------------------------------------------+
|  CAPA 4: Chain of Responsibility         |
|  RBAC por ruta, MFA, rate limiting app   |
|  (implementado en cada microservicio)    |
+------------------------------------------+
   |
   v
Cloud Run Microservices
```

---

## Componentes Desplegados

### Load Balancer — Punto de Entrada

**Recursos:**

| Recurso | Nombre | Funcion |
|---|---|---|
| IP Estatica Global | `travelhub-lb-ip` | Direccion fija: 136.110.223.156 |
| Internet NEG | `travelhub-gateway-neg` | Apunta al hostname del API Gateway |
| Backend Service | `travelhub-backend-service` | Conecta NEG + Cloud Armor |
| URL Map | `travelhub-url-map` | Enruta todo al backend service |
| SSL Certificate | `travelhub-ssl-cert` | Self-signed (dev). En prod: managed con dominio |
| HTTPS Proxy | `travelhub-https-proxy` | Termina SSL |
| Forwarding Rule | `travelhub-forwarding-rule` | Conecta IP estatica con proxy |

El Load Balancer recibe todo el trafico HTTPS en la IP estatica, termina SSL, pasa por Cloud Armor (WAF) y reenvía al API Gateway. Se configura un custom header `Host` apuntando al hostname del gateway para que el routing funcione correctamente.

**Script:** `deploy/deploy-load-balancer.sh`

---

### Capa 1 — Cloud Armor (WAF + DDoS)

**Recurso:** `travelhub-security-policy`

Cloud Armor opera en el borde de red de GCP, filtrando trafico antes de que llegue al API Gateway. Resuelve la debilidad de PF1 donde el rate limiting operaba por instancia en vez de forma distribuida.

**Reglas WAF (OWASP Top 10):**

| Prioridad | Regla | Accion |
|---|---|---|
| 1000 | SQL Injection (sqli-v33-stable) | deny-403 |
| 1100 | Cross-Site Scripting (xss-v33-stable) | deny-403 |
| 1200 | Local File Inclusion (lfi-v33-stable) | deny-403 |
| 1300 | Remote File Inclusion (rfi-v33-stable) | deny-403 |
| 1400 | Protocol Attacks (protocolattack-v33-stable) | deny-403 |
| 1500 | Session Fixation (sessionfixation-v33-stable) | deny-403 |

**Reglas de Rate Limiting:**

| Prioridad | Regla | Limite | Accion |
|---|---|---|---|
| 2000 | Global por IP | 100 req/min | deny-429 |
| 2100 | Login (anti brute-force) | 10 req/min | deny-429 |
| 2200 | Pagos (PCI-DSS) | 20 req/min | deny-429 |

**Otras reglas:**

| Prioridad | Regla | Accion |
|---|---|---|
| 3000 | Geo-blocking (solo LATAM + regiones de negocio) | deny-403 |
| default | Permitir trafico legitimo | allow |

Adaptive Protection habilitada (deteccion DDoS L7 con ML) con logging verbose.

**Scripts:** `cloud-armor/security-policy.sh`, `cloud-armor/adaptive-protection.sh`

---

### Capa 2 — VPC y Firewall

**Recurso:** `travelhub-vpc`

VPC con subnets segmentadas por funcion. Cada capa de la arquitectura vive en su propia subnet. Principio DENY ALL por defecto.

**Subnets (us-central1):**

| Subnet | CIDR | Proposito |
|---|---|---|
| subnet-public | 10.10.1.0/24 | Load Balancer + API Gateway |
| subnet-services | 10.10.2.0/24 | Cloud Run microservicios |
| subnet-data | 10.10.3.0/24 | PostgreSQL, Redis, Elasticsearch, Kafka |

**VPC Access Connector:** `travelhub-connector` (10.10.8.0/28) — permite a Cloud Run comunicarse con recursos en la VPC.

**Reglas de Firewall:**

| Regla | Prioridad | Direccion | Accion | Detalle |
|---|---|---|---|---|
| fw-deny-ssh-internet | 100 | INGRESS | DENY | SSH bloqueado desde internet |
| fw-allow-https-lb | 1000 | INGRESS | ALLOW | HTTPS (443) hacia Load Balancer |
| fw-allow-health-checks | 1100 | INGRESS | ALLOW | Health checks de GCP (8000, 8080) |
| fw-allow-gateway-to-services | 1200 | INGRESS | ALLOW | Gateway hacia microservicios (8000) |
| fw-allow-services-to-data | 1300 | INGRESS | ALLOW | Servicios hacia BD (5432, 6379, 9200, 9092) |
| fw-allow-inter-service | 1400 | INGRESS | ALLOW | Comunicacion entre microservicios (8000) |
| fw-deny-all-ingress | 65534 | INGRESS | DENY | Bloquear todo lo demas |
| fw-allow-egress-external | 1000 | EGRESS | ALLOW | Servicios hacia internet solo HTTPS (443) |
| fw-deny-data-egress | 1000 | EGRESS | DENY | Capa de datos sin salida a internet |

**Private Service Connection:** Rango 10.100.0.0/20 reservado para acceso privado a Cloud SQL y MemoryStore.

**Scripts:** `firewall/vpc-setup.sh`, `firewall/firewall-rules.sh`, `firewall/private-access.sh`

---

### Capa 3 — API Gateway (Validacion JWT)

**Recurso:** `travelhub-api` / `travelhub-gateway`

GCP API Gateway como punto de entrada unico. Valida la autenticidad del JWT antes de rutear al backend. No valida logica de negocio (roles, MFA) — eso lo hace la Capa 4 en cada microservicio.

**Que valida el gateway:**

- Firma RS256 — verifica con clave publica del endpoint JWKS
- Issuer — debe ser `https://auth.travelhub.app`
- Audience — debe ser `travelhub-api`
- Expiracion — token no vencido (claim `exp`)

**Routing de rutas:**

Rutas publicas (sin JWT):

| Ruta | Backend |
|---|---|
| POST /api/v1/auth/login | user-services |
| POST /api/v1/auth/register | user-services |
| POST /api/v1/auth/refresh | user-services |
| GET /.well-known/jwks.json | user-services |

Rutas protegidas (requieren JWT valido):

| Ruta | Backend |
|---|---|
| /api/v1/search/* | search-services |
| /api/v1/bookings/* | booking-services |
| /api/v1/payments/* | payments-services |
| /api/v1/inventory/* | inventory-services |
| /api/v1/notifications/* | notification-services |
| /api/v1/pms/* | pms-integration-services |
| /api/v1/cart/* | shopping-cart-services |
| /api/v1/admin/* | user-services |

**Scripts:** `deploy/deploy-gateway.sh`
**Spec:** `gateway/openapi-spec.yaml`

---

### Capa 4 — Chain of Responsibility (Backend)

Implementado en cada microservicio (no en este repositorio). El middleware FastAPI ejecuta una cadena de filtros de seguridad despues de que el gateway ya valido la firma y expiracion del JWT:

1. **RateLimitFilter** — 60 req/min por usuario/IP (segunda linea de defensa)
2. **IPValidationFilter** — Geolocalizacion consistente (placeholder)
3. **RBACFilter** — Valida rol del usuario vs ruta solicitada
4. **MFAFilter** — Requiere MFA verificado para pagos y admin

La referencia de implementacion esta en `CONTEXT_USER_SERVICES.md`.

---

### Base de Datos — Cloud SQL PostgreSQL

**Recurso:** `travelhub-db`

| Campo | Valor |
|---|---|
| Motor | PostgreSQL 15 |
| Tier | db-f1-micro (desarrollo) |
| IP privada | 10.100.0.3 |
| IP publica | Deshabilitada |
| Base de datos | travelhub |
| Usuario | travelhub_app |
| Backups | Deshabilitados (entorno dev) |
| Storage | 10 GB SSD, auto-increase |

Accesible unicamente desde subnet-services a traves del VPC connector. Sin acceso desde internet.

**Script:** `database/setup-cloudsql.sh`

---

## Estructura del Repositorio

```
uniandes-pf-infra-gcp/
├── cloud-armor/
│   ├── security-policy.sh          # Politica WAF + rate limiting + geo-blocking
│   └── adaptive-protection.sh      # Proteccion DDoS L7 con ML
├── firewall/
│   ├── vpc-setup.sh                # VPC + subnets + VPC Access Connector
│   ├── firewall-rules.sh           # Reglas de firewall ingress/egress
│   └── private-access.sh           # Private Service Connection
├── gateway/
│   ├── openapi-spec.yaml           # Spec OpenAPI con validacion JWT + routing
│   └── cors-policy.yaml            # Politica CORS para React SPA
├── database/
│   └── setup-cloudsql.sh           # Cloud SQL PostgreSQL
├── deploy/
│   ├── deploy-gateway.sh           # Despliegue del API Gateway
│   ├── deploy-load-balancer.sh     # IP estatica + LB + NEG + Cloud Armor
│   └── deploy-cloud-armor.sh       # Asociar Cloud Armor (standalone, sin LB)
├── tests/
│   ├── test_cloud_armor.sh         # Tests de reglas WAF
│   └── test_firewall_rules.sh      # Tests de reglas de firewall
├── CLAUDE.md                       # Contexto para Claude Code
├── CONTEXT_USER_SERVICES.md        # Contexto de integracion para user-services
└── README.md
```

---

## URLs del Entorno de Desarrollo

Estas URLs corresponden al entorno de desarrollo. En produccion seran distintas.

| Servicio | URL | Notas |
|---|---|---|
| Entrada (LB) | https://apitravelhub.site | IP estatica 136.110.223.156, cert SSL managed |
| API Gateway (directo) | https://travelhub-gateway-1yvtqj7r.uc.gateway.dev | Acceso sin pasar por Cloud Armor |
| user-services | https://user-services-154299161799.us-central1.run.app | Acceso directo a Cloud Run |

El punto de entrada para consumidores debe ser siempre la IP del Load Balancer, ya que es la unica ruta que pasa por todas las capas de seguridad (Cloud Armor + JWT).

Los demas microservicios tienen PLACEHOLDER en `gateway/openapi-spec.yaml`. Cuando se desplieguen, actualizar las URLs y redesplegar el gateway.

---

## Variables de Entorno

Toda la infraestructura esta parametrizada para ser reproducible en multiples proyectos GCP:

```bash
GCP_PROJECT_ID="${GCP_PROJECT_ID:-gen-lang-client-0930444414}"
GCP_REGION="${GCP_REGION:-us-central1}"
VPC_NAME="${VPC_NAME:-travelhub-vpc}"
CLOUD_ARMOR_POLICY="${CLOUD_ARMOR_POLICY:-travelhub-security-policy}"
```

Para desplegar en otro proyecto:

```bash
GCP_PROJECT_ID=otro-proyecto bash cloud-armor/security-policy.sh
```

---

## Orden de Despliegue

Los scripts deben ejecutarse en este orden para respetar dependencias:

```bash
# 1. VPC y Subnets (base de red)
bash firewall/vpc-setup.sh

# 2. Reglas de Firewall (segmentacion)
bash firewall/firewall-rules.sh

# 3. Acceso privado a servicios managed
bash firewall/private-access.sh

# 4. Cloud Armor (WAF en el borde)
bash cloud-armor/security-policy.sh
bash cloud-armor/adaptive-protection.sh

# 5. Base de datos
bash database/setup-cloudsql.sh

# 6. API Gateway (requiere URLs de Cloud Run)
bash deploy/deploy-gateway.sh

# 7. Load Balancer + IP estatica + Cloud Armor asociado
bash deploy/deploy-load-balancer.sh

# 8. Verificacion
bash tests/test_cloud_armor.sh
bash tests/test_firewall_rules.sh
```

---

## Pendientes

- Actualizar URLs de microservicios en `gateway/openapi-spec.yaml` conforme se desplieguen
- Redesplegar gateway cuando se agreguen nuevos servicios
- Configurar segunda region (southamerica-east1) para replica activo-activo
