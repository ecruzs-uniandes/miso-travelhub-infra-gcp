# TravelHub — Estado de Infraestructura GCP

> Proyecto: TravelHub — Grupo 9 (PF2 Sprint 1)
> GCP Project: gen-lang-client-0930444414
> Region: us-central1
> Dominio: apitravelhub.site
> Repo infra: uniandes-pf-infra-gcp

---

## Flujo de red completo

```text
apitravelhub.site
      |
      v
136.110.223.156 (IP estatica global)
      |
      v
Load Balancer (HTTPS, cert SSL managed)
      |
      v
Cloud Armor (WAF: SQLi, XSS, LFI, RFI, rate limiting, geo-blocking, DDoS ML)
      |
      v
API Gateway (valida JWT: firma RS256, issuer, audience, expiracion)
      |
      v
Cloud Run (microservicios con Chain of Responsibility: RBAC, MFA, rate limit app)
      |
      v
Cloud SQL PostgreSQL (IP privada 10.100.0.3, solo accesible via VPC)
```

---

## Componentes desplegados

| Componente | Recurso | Estado |
|---|---|---|
| IP Estatica | `travelhub-lb-ip` → 136.110.223.156 | Desplegado |
| Load Balancer | `travelhub-backend-service` + `travelhub-url-map` + HTTPS proxy | Desplegado |
| SSL Certificate | `travelhub-ssl-managed` (dominio apitravelhub.site) | Activo |
| Cloud Armor | `travelhub-security-policy` (asociado al LB) | Desplegado |
| VPC | `travelhub-vpc` (3 subnets + VPC connector) | Desplegado |
| Firewall | 9 reglas (DENY ALL default) | Desplegado |
| API Gateway | `travelhub-api` / `travelhub-gateway` | Desplegado |
| Cloud SQL | `travelhub-db` (PostgreSQL 15, db-f1-micro) | Desplegado |
| Private Access | Private Service Connection (10.100.0.0/20) | Desplegado |

---

## URLs entorno DEV

Estas URLs son del entorno de desarrollo. En produccion seran distintas.

| Servicio | URL |
|---|---|
| Entrada (LB + todas las capas) | `https://apitravelhub.site` |
| API Gateway (directo, sin Cloud Armor) | `https://travelhub-gateway-1yvtqj7r.uc.gateway.dev` |
| user-services (directo, sin gateway) | `https://user-services-ridyy4wz4q-uc.a.run.app` |

El punto de entrada para consumidores (frontend, mobile, integraciones) debe ser siempre `https://apitravelhub.site`, ya que es la unica ruta que pasa por todas las capas de seguridad.

---

## Cloud Armor — Reglas WAF

| Prioridad | Regla | Accion |
|---|---|---|
| 1000 | SQL Injection (sqli-v33-stable) | deny-403 |
| 1100 | Cross-Site Scripting (xss-v33-stable) | deny-403 |
| 1200 | Local File Inclusion (lfi-v33-stable) | deny-403 |
| 1300 | Remote File Inclusion (rfi-v33-stable) | deny-403 |
| 1400 | Protocol Attacks (protocolattack-v33-stable) | deny-403 |
| 1500 | Session Fixation (sessionfixation-v33-stable) | deny-403 |
| 2000 | Rate limit global: 100 req/min/IP | throttle/deny-429 |
| 2100 | Rate limit login: 10 req/min/IP | throttle/deny-429 |
| 2200 | Rate limit pagos: 20 req/min/IP | throttle/deny-429 |
| 3000 | Geo-blocking (solo LATAM + regiones de negocio) | deny-403 |
| default | Permitir trafico legitimo | allow |

Adaptive Protection habilitada (DDoS L7 con ML) + logging verbose.

---

## VPC y Firewall

**VPC:** `travelhub-vpc` (custom, single region us-central1)

**Subnets:**

| Subnet | CIDR | Proposito |
|---|---|---|
| subnet-public | 10.10.1.0/24 | Load Balancer + API Gateway |
| subnet-services | 10.10.2.0/24 | Cloud Run microservicios |
| subnet-data | 10.10.3.0/24 | PostgreSQL, Redis, Elasticsearch, Kafka |

**VPC Access Connector:** `travelhub-connector` (10.10.8.0/28) — Cloud Run lo usa para alcanzar la VPC.

**Reglas de firewall (principio DENY ALL):**

| Regla | Prioridad | Dir | Accion | Detalle |
|---|---|---|---|---|
| fw-deny-ssh-internet | 100 | INGRESS | DENY | SSH bloqueado desde internet |
| fw-allow-https-lb | 1000 | INGRESS | ALLOW | HTTPS (443) hacia LB |
| fw-allow-health-checks | 1100 | INGRESS | ALLOW | Health checks GCP (8000, 8080) |
| fw-allow-gateway-to-services | 1200 | INGRESS | ALLOW | Gateway hacia microservicios (8000) |
| fw-allow-services-to-data | 1300 | INGRESS | ALLOW | Servicios hacia BD (5432, 6379, 9200, 9092) |
| fw-allow-inter-service | 1400 | INGRESS | ALLOW | Comunicacion entre microservicios (8000) |
| fw-deny-all-ingress | 65534 | INGRESS | DENY | Bloquear todo lo demas |
| fw-allow-egress-external | 1000 | EGRESS | ALLOW | Servicios hacia internet HTTPS (443) |
| fw-deny-data-egress | 1000 | EGRESS | DENY | Capa de datos sin salida a internet |

---

## API Gateway — Validacion JWT

El gateway valida antes de rutear al backend:
- Firma RS256 (verifica con clave publica del endpoint JWKS)
- Issuer: `https://auth.travelhub.app`
- Audience: `travelhub-api`
- Expiracion (claim `exp`)

NO valida: roles, MFA, logica de negocio (eso lo hace el Chain of Responsibility en el backend).

**Rutas publicas (sin JWT):**

| Ruta | Backend |
|---|---|
| POST /api/v1/auth/login | user-services |
| POST /api/v1/auth/register | user-services |
| POST /api/v1/auth/refresh | user-services |
| GET /.well-known/jwks.json | user-services |
| GET /health | user-services |

**Rutas protegidas (requieren JWT valido):**

| Ruta | Backend |
|---|---|
| GET /api/v1/auth/me | user-services |
| PUT /api/v1/auth/me | user-services |
| POST /api/v1/auth/mfa/setup | user-services |
| POST /api/v1/auth/mfa/verify | user-services |
| GET /api/v1/admin/* | user-services |
| /api/v1/search/* | search-services |
| /api/v1/bookings/* | booking-services |
| /api/v1/payments/* | payments-services |
| /api/v1/inventory/* | inventory-services |
| /api/v1/notifications/* | notification-services |
| /api/v1/pms/* | pms-integration-services |
| /api/v1/cart/* | shopping-cart-services |

---

## Cloud SQL PostgreSQL

| Campo | Valor |
|---|---|
| Instancia | `travelhub-db` |
| Motor | PostgreSQL 15 |
| Tier | db-f1-micro (desarrollo) |
| IP privada | 10.100.0.3 |
| IP publica | Deshabilitada |
| Base de datos | `travelhub` |
| Usuario | `travelhub_app` |
| Password | `lALk8rAOj1TSltRQzGavZdBCrSu67ZJg` |
| Backups | Deshabilitados (entorno dev) |

Connection string:

```text
postgresql://travelhub_app:lALk8rAOj1TSltRQzGavZdBCrSu67ZJg@10.100.0.3:5432/travelhub
```

Solo accesible desde subnet-services a traves del VPC connector. Sin acceso desde internet.

---

## Estructura del JWT que emite user-services

```json
{
  "sub": "user-id-uuid",
  "iss": "https://auth.travelhub.app",
  "aud": "travelhub-api",
  "exp": 1234567890,
  "iat": 1234567890,
  "role": "traveler | hotel_admin | platform_admin",
  "mfa_verified": true,
  "country": "CO",
  "hotel_id": "hotel-uuid o null"
}
```

| Campo | Validado por | Detalle |
|---|---|---|
| sub | Backend | ID unico del usuario |
| iss | API Gateway | DEBE ser `https://auth.travelhub.app` |
| aud | API Gateway | DEBE ser `travelhub-api` |
| exp | API Gateway | Expiracion: 900 seg (15 min) para access token |
| role | Backend (RBACFilter) | `traveler`, `hotel_admin`, `platform_admin` |
| mfa_verified | Backend (MFAFilter) | Requerido para /payments y /admin |
| country | Backend (IPValidationFilter) | Codigo ISO del pais |
| hotel_id | Backend | Solo para hotel_admin |

Header del JWT debe incluir `"kid": "travelhub-key-1"`.

---

## Roles RBAC

| Rol | Acceso permitido |
|---|---|
| traveler | search, bookings, payments, cart, notifications |
| hotel_admin | search, bookings, inventory, pms, notifications |
| platform_admin | todo, incluyendo /admin |

---

## Chain of Responsibility (Capa 4 — en cada microservicio)

Middleware FastAPI que se ejecuta despues del gateway. El gateway ya valido firma + expiracion.

**Nota:** El API Gateway reemplaza el header `Authorization` con un OIDC token de servicio y mueve el JWT original a `X-Forwarded-Authorization`. El middleware debe leer `X-Forwarded-Authorization` primero y `Authorization` como fallback.

```text
Request con JWT en header Authorization: Bearer <token>
  |
  v
Gateway reemplaza Authorization con OIDC token propio
JWT original del usuario → X-Forwarded-Authorization
  |
  v
Decodifica payload (SIN verificar firma, el gateway ya lo hizo)
  |
  v
RateLimitFilter: 60 req/min por usuario/IP → 429 si excede
  |
  v
IPValidationFilter: geolocalizacion consistente (placeholder)
  |
  v
RBACFilter: valida role vs ruta → 403 si no tiene permiso
  |
  v
MFAFilter: valida mfa_verified=true para /payments y /admin → 403 si no
  |
  v
Handler del endpoint
```

---

## Deploy de microservicios en Cloud Run

Todos los microservicios deben desplegarse con estos flags:

```bash
gcloud run deploy <nombre-servicio> \
  --vpc-connector=travelhub-connector \
  --set-env-vars "JWT_ISSUER=https://auth.travelhub.app,JWT_AUDIENCE=travelhub-api,DATABASE_HOST=10.100.0.3,DATABASE_PORT=5432,DATABASE_NAME=travelhub,DATABASE_USER=travelhub_app,DATABASE_PASSWORD=lALk8rAOj1TSltRQzGavZdBCrSu67ZJg" \
  --allow-unauthenticated \
  --port 8000 \
  --region us-central1 \
  --project gen-lang-client-0930444414
```

Despues de desplegar un nuevo microservicio:
1. Actualizar la URL en `gateway/openapi-spec.yaml` (reemplazar PLACEHOLDER)
2. Redesplegar el API Gateway con `bash deploy/deploy-gateway.sh`

---

## Microservicios Cloud Run

| Servicio | Estado | URL |
|---|---|---|
| user-services | Desplegado | `https://user-services-ridyy4wz4q-uc.a.run.app` |
| search-services | Pendiente | PLACEHOLDER |
| booking-services | Pendiente | PLACEHOLDER |
| payments-services | Pendiente | PLACEHOLDER |
| inventory-services | Pendiente | PLACEHOLDER |
| notification-services | Pendiente | PLACEHOLDER |
| pms-integration-services | Pendiente | PLACEHOLDER |
| shopping-cart-services | Pendiente | PLACEHOLDER |

---

## ASRs que resuelve esta infraestructura

| ASR | Descripcion | Como se resuelve |
|---|---|---|
| AH008 | Seguridad — 100% bloqueo accesos ilegitimos | 4 capas de defensa en profundidad |
| AH009 | Control de acceso RBAC | RBACFilter en Chain of Responsibility |
| AH007 | Cifrado JWT RS256 | API Gateway valida firma + backend valida claims |
| AH016 | Resiliencia — rate limiting distribuido | Cloud Armor (borde de red, no por instancia como en PF1) |

---

## Variables de entorno para reproducir en otro proyecto

```bash
GCP_PROJECT_ID=otro-proyecto bash firewall/vpc-setup.sh
GCP_PROJECT_ID=otro-proyecto bash firewall/firewall-rules.sh
GCP_PROJECT_ID=otro-proyecto bash firewall/private-access.sh
GCP_PROJECT_ID=otro-proyecto bash cloud-armor/security-policy.sh
GCP_PROJECT_ID=otro-proyecto bash cloud-armor/adaptive-protection.sh
GCP_PROJECT_ID=otro-proyecto bash database/setup-cloudsql.sh
GCP_PROJECT_ID=otro-proyecto bash deploy/deploy-gateway.sh
GCP_PROJECT_ID=otro-proyecto bash deploy/deploy-load-balancer.sh
```
