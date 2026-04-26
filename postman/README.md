# Postman - TravelHub GCP

Colección unificada para probar todos los servicios de TravelHub desplegados en GCP, atravesando las 4 capas de seguridad (Cloud Armor → API Gateway → Cloud Run → Chain of Responsibility).

## Archivos

| Archivo | Contenido |
|---|---|
| [`travelhub-gcp.postman_collection.json`](travelhub-gcp.postman_collection.json) | Colección completa: health, auth, PMS, sync-worker, seguridad, microservicios pendientes |
| [`travelhub-gcp.postman_environment.dev.json`](travelhub-gcp.postman_environment.dev.json) | Variables de entorno DEV (`gen-lang-client-0930444414`) |
| [`travelhub-gcp.postman_environment.prod.json`](travelhub-gcp.postman_environment.prod.json) | Variables de entorno PROD (`travelhub-prod-492116`) — incompleto, hay servicios pendientes |

## Importar

```
Postman → Import → arrastrar los 3 archivos JSON
```

Seleccionar el environment **TravelHub GCP - DEV** en el selector arriba a la derecha.

## Variables clave

| Variable | Default DEV | Para qué sirve |
|---|---|---|
| `lb_url` | `https://apitravelhub.site` | Entrada pública (LB + Cloud Armor + gateway + Cloud Run) |
| `gateway_url` | `https://travelhub-gateway-1yvtqj7r.uc.gateway.dev` | API Gateway directo (saltea Cloud Armor) |
| `user_services_url` | `https://user-services-ridyy4wz4q-uc.a.run.app` | Cloud Run user-services directo |
| `pms_integration_url` | `https://pms-integration-services-ridyy4wz4q-uc.a.run.app` | Cloud Run pms-integration directo |
| `pms_sync_worker_url` | `https://pms-sync-worker-ridyy4wz4q-uc.a.run.app` | Cloud Run pms-sync-worker directo (solo /health) |
| `base_url` | `{{lb_url}}` | URL principal usada por la mayoría de requests. Cambiar a `{{gateway_url}}` para diagnosticar Cloud Armor. |

`access_token`, `refresh_token`, `mfa_secret`, `property_id`, `event_id` se llenan automáticamente con los scripts de tests al ejecutar Login / Setup / Webhook respectivos.

## Estructura de la colección

| # | Carpeta | Contenido |
|---|---|---|
| 1 | **Health & Infraestructura** | Smoke tests de las 5 superficies (LB, gateway, 3 Cloud Run) + JWKS |
| 2 | **Auth - Público** | `register`, `login` (guarda tokens), `refresh` |
| 3 | **Auth - Protegido** | `me`, update, MFA setup/verify, login con MFA |
| 4 | **PMS Integration** | CRUD properties, webhook (JWT y HMAC), availability, sync-status |
| 5 | **PMS Sync Worker** | health + referencia del contrato Kafka |
| 6 | **Seguridad - Cloud Armor** | SQLi, XSS, LFI, RFI → 403; rate limit → 429 |
| 7 | **Seguridad - Gateway JWT** | sin token, token mal formado, audience equivocada, RBAC backend |
| 8 | **Microservicios pendientes** | placeholders para search, bookings, payments, inventory, notifications, cart, admin |

## Flujo recomendado de prueba

1. **Health & Infraestructura** — verifica que todo responde
2. **Auth - Público → Login** — se guardan los tokens automáticamente
3. **Auth - Protegido → Get Me** — valida que el JWT funciona end-to-end
4. **PMS Integration** — opera las propiedades y dispara un webhook (verifica que llega a Kafka mirando sync-status)
5. **Seguridad - Cloud Armor** — confirma que SQLi/XSS/LFI son bloqueados
6. **Seguridad - Gateway JWT** — confirma que requests sin token o con token inválido se rechazan en el borde

## Diagnóstico (¿dónde está el fallo?)

Si la **carpeta 1 (Health)** falla en una superficie pero pasa en otra:

| LB ❌ | Gateway ❌ | Cloud Run ❌ | Diagnóstico |
|:-:|:-:|:-:|---|
| ✅ | ✅ | ✅ | Todo OK |
| ❌ | ✅ | ✅ | Problema en LB / Cloud Armor / SSL cert |
| ❌ | ❌ | ✅ | Problema en API Gateway o config OpenAPI |
| ❌ | ❌ | ❌ | Problema en Cloud Run (cold start, deploy, secrets) |

## Notas sobre Cloud Armor

- Las pruebas de WAF (SQLi/XSS/LFI/RFI) **solo funcionan via `lb_url`**. Si las ejecutas contra `gateway_url` o `user_services_url`, te saltas Cloud Armor y el WAF no aplica.
- El rate limit de login (10 req/min) requiere **ejecutar el request 12 veces seguidas** (Postman Runner es la forma más fácil). El test acepta `401` o `429`; busca que en algún momento aparezca `429`.

## Notas sobre JWT

- El JWT se valida en el gateway (firma RS256 + issuer + audience).
- El backend lee el JWT desde `X-Forwarded-Authorization` (el gateway lo mueve ahí) y vuelve a decodificarlo sin verificar firma para extraer claims (`role`, `mfa_verified`, `country`, `hotel_id`).
- Para probar RBAC con distintos roles necesitas **registrar usuarios con rol `admin_hotel` o `admin_plataforma` directamente en BD** (el endpoint `/register` siempre asigna `viajero`). Una vez logueado, el JWT lleva el role mapeado.

## Servicios cubiertos

| Servicio | Estado DEV | Vía gateway | Notas |
|---|---|---|---|
| user-services | ✅ desplegado | sí (`/api/v1/auth/*`) | Emisor JWT, expone JWKS |
| pms-integration-services | ✅ desplegado | sí (`/api/v1/pms/*`) | Webhook + CRUD + availability |
| pms-sync-worker | ✅ desplegado | no | Worker Kafka, solo /health HTTP |
| search-services | ⏸ placeholder | sí (`/api/v1/search/*`) | Pendiente desplegar |
| booking-services | ⏸ placeholder | sí (`/api/v1/bookings/*`) | Pendiente desplegar |
| payments-services | ⏸ placeholder | sí (`/api/v1/payments/*`) | Pendiente desplegar |
| inventory-services | ⏸ placeholder | sí (`/api/v1/inventory/*`) | Pendiente desplegar |
| notification-services | ⏸ placeholder | sí (`/api/v1/notifications/*`) | Pendiente desplegar |
| shopping-cart-services | ⏸ placeholder | sí (`/api/v1/cart/*`) | Pendiente desplegar |

Para los servicios pendientes, las rutas están registradas en `gateway/openapi-spec.yaml` con backend `*-PLACEHOLDER.a.run.app`. Cuando se desplieguen hay que actualizar el spec y re-aplicar el config del gateway.
