# CLAUDE.md — TravelHub Infra GCP (Grupo 9)

## Proyecto

Infraestructura de seguridad en GCP para TravelHub (PF2 Sprint 1).
Defensa en profundidad con 4 capas: Cloud Armor > VPC Firewall > API Gateway JWT > Chain of Responsibility.

## Variables de entorno

Toda la infra debe ser reproducible en múltiples proyectos GCP. Usar siempre variables con defaults:

```bash
GCP_PROJECT_ID="${GCP_PROJECT_ID:-gen-lang-client-0930444414}"
GCP_REGION="${GCP_REGION:-us-central1}"
```

- **No hardcodear** project IDs ni regiones en los scripts.
- Multi-región (southamerica-east1) se agregará después. Por ahora solo `us-central1`.

## Herramienta de IaC

- **gcloud CLI** (scripts bash). No usar Terraform.
- Todos los scripts deben empezar con `set -euo pipefail`.

## Estructura del repositorio

```
travelhub-gateway/
├── cloud-armor/          # Capa 1: WAF, rate limiting, DDoS, geo-blocking
├── firewall/             # Capa 2: VPC, subnets, reglas firewall
├── gateway/              # Capa 3: OpenAPI spec con validación JWT
├── database/             # Cloud SQL PostgreSQL setup
├── auth/                 # JWKS keys, config JWT, endpoint JWKS
├── middleware/            # Capa 4: Chain of Responsibility (Python/FastAPI)
├── tests/                # Tests unitarios + tests de infra
├── deploy/               # Scripts de despliegue gcloud
└── requirements.txt
```

## Orden de implementación (capa por capa)

1. **Cloud Armor** — WAF + DDoS + rate limiting — DESPLEGADO
2. **VPC Firewall** — Segmentación de red — DESPLEGADO
3. **API Gateway** — Validación JWT — DESPLEGADO
4. **Cloud SQL** — PostgreSQL 15 (IP privada 10.100.0.3) — DESPLEGADO
5. **Load Balancer** — IP estática + SSL + Cloud Armor asociado — DESPLEGADO
6. **Chain of Responsibility** — Middleware Python (RBAC, MFA, rate limit app) — va en cada microservicio

## URLs del entorno DEV

Estas URLs son del entorno de desarrollo. En producción serán distintas.

- **Entrada (LB):** `https://apitravelhub.site` (IP estática 136.110.223.156, cert SSL managed)
- **Gateway (directo):** `https://travelhub-gateway-1yvtqj7r.uc.gateway.dev`
- **user-services:** `https://user-services-ridyy4wz4q-uc.a.run.app`
- Los demás microservicios tienen PLACEHOLDER en `gateway/openapi-spec.yaml` — actualizar cuando se desplieguen

## Flujo de red completo

```text
apitravelhub.site → 136.110.223.156 (IP estática) → Load Balancer (HTTPS) → Cloud Armor (WAF) → API Gateway (JWT) → Cloud Run
```

## Microservicios Cloud Run

Desplegados:
- user-services (`https://user-services-ridyy4wz4q-uc.a.run.app`)

Pendientes (PLACEHOLDER en openapi-spec.yaml):
- search-services, booking-services, payments-services
- inventory-services, notification-services
- pms-integration-services, shopping-cart-services

## Convenciones de scripts bash

- Nombres descriptivos: `security-policy.sh`, `firewall-rules.sh`, `vpc-setup.sh`
- Variable `POLICY_NAME`, `VPC_NAME`, `BACKEND_SERVICE` siempre parametrizadas
- Incluir output informativo al final (resumen de lo creado)
- Usar `2>/dev/null || echo "... already exists"` para idempotencia en creates

## ASRs clave

- **AH008**: Seguridad — 100% bloqueo de accesos ilegítimos
- **AH009**: Control de acceso RBAC por roles (traveler, hotel_admin, platform_admin)
- **AH007**: Cifrado — JWT RS256
- **AH016**: Resiliencia — rate limiting distribuido (Cloud Armor resuelve debilidad PF1)

## Cloud SQL PostgreSQL

- Instancia: `travelhub-db` (db-f1-micro, desarrollo)
- IP privada: `10.100.0.3` (sin IP pública)
- BD: `travelhub`, usuario: `travelhub_app`
- Accesible solo desde subnet-services via VPC connector

## Reglas de trabajo

- No ejecutar acciones hasta que el usuario confirme explícitamente.
- Avanzar capa por capa, no saltar adelante.
- Código Python sigue FastAPI + pytest-asyncio.
- Los middleware van en cada microservicio, no en este repo (este repo es solo infra).
