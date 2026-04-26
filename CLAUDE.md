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
5. **Kafka VM** — Compute Engine, broker self-managed en `subnet-data` (IP `10.10.3.3` dev / `10.20.3.3` prod) — DESPLEGADO
6. **Load Balancer** — IP estática + SSL + Cloud Armor asociado — DESPLEGADO
7. **Chain of Responsibility** — Middleware Python (RBAC, MFA, rate limit app) — va en cada microservicio

## URLs del entorno DEV

Estas URLs son del entorno de desarrollo. En producción serán distintas.

- **Entrada (LB):** `https://apitravelhub.site` (IP estática 136.110.223.156, cert SSL managed)
- **Gateway (directo):** `https://travelhub-gateway-1yvtqj7r.uc.gateway.dev`
- **user-services:** `https://user-services-ridyy4wz4q-uc.a.run.app`
- **pms-integration-services:** `https://pms-integration-services-ridyy4wz4q-uc.a.run.app` (gateway lo rutea desde 2026-04-26)
- Los demás microservicios siguen como placeholder en el spec del gateway hasta que se desplieguen.

## Convención de naming vs estado actual del proyecto DEV

El IaC en `scripts/` y `config/environments/` está parametrizado para crear todos los recursos con prefijo `${PREFIX}-*` donde `PREFIX="${ENV}-travelhub"`. En un despliegue limpio quedaría:

| Ambiente | PREFIX | Ejemplo de recursos |
|---|---|---|
| dev | `dev-travelhub` | `dev-travelhub-vpc`, `dev-travelhub-db`, `dev-travelhub-gateway`, `dev-travelhub-kafka`, ... |
| prod | `prod-travelhub` | `prod-travelhub-vpc`, `prod-travelhub-db`, `prod-travelhub-gateway`, ... |

**Sin embargo, el proyecto actual `gen-lang-client-0930444414` tiene recursos legacy sin prefijo** (creados antes de la convención):

```
travelhub-vpc, travelhub-db, travelhub-security-policy,
travelhub-backend-service, travelhub-gateway, travelhub-api,
travelhub-gateway-neg, travelhub-kafka (VM), ...
```

**Decisión (2026-04-26):** No renombrar el legacy aquí. Aprovechar la migración a `secret-lambda-491419-p2` para desplegar todo desde cero con `bash deploy-all.sh` y la convención correcta.

> **Implicación práctica:** si ejecutas un script de scripts/0X-*.sh contra el proyecto actual, el script no encontrará el recurso `dev-travelhub-*` esperado y creará uno nuevo en paralelo (esto pasó con `08-gateway.sh` el 2026-04-26 antes del fix manual). Para el proyecto actual usa `gcloud` directo apuntando a los nombres legacy.

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

## Kafka VM (Compute Engine)

- Instancia: `${PREFIX}-kafka` (e2-small, Ubuntu 22.04, 20 GB pd-balanced)
- Subnet: `subnet-data` con IP privada fija `10.10.3.3` (dev) / `10.20.3.3` (prod)
- **Sin IP pública** — admin via IAP tunnel (puerto 8080 = Kafka UI, 22 = SSH)
- Stack: docker-compose con `cp-zookeeper:7.6.0` + `cp-kafka:7.6.0` + `provectuslabs/kafka-ui` + container `kafka-init` que crea topics
- Topics auto-creados: `pms-sync-queue` (3 partitions), `pms-sync-dlq` (1 partition)
- Bootstrap servers (`<ip>:9092`) → secret `${PREFIX}-kafka-bootstrap-servers` (lo consumen pms-integration y pms-sync-worker)
- Startup-script en `scripts/lib/kafka-startup.sh` (verbatim, no editar a la ligera)
- Firewall: `fw-allow-svc-to-data` (port 9092 desde subnet-services) + `fw-allow-iap-kafka` (P50, IAP → 22+8080)

## Reglas de trabajo

- No ejecutar acciones hasta que el usuario confirme explícitamente.
- Avanzar capa por capa, no saltar adelante.
- Código Python sigue FastAPI + pytest-asyncio.
- Los middleware van en cada microservicio, no en este repo (este repo es solo infra).
