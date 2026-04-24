# Contexto para user-services — Integración con API Gateway JWT

> **Proyecto:** TravelHub — Grupo 9 (PF2 Sprint 1)
> **Infra repo:** uniandes-pf-infra-gcp
> **GCP Project:** gen-lang-client-0930444414
> **Región:** us-central1

---

## 1. Endpoints que user-services DEBE exponer

```
POST /api/v1/auth/login        → Autentica usuario, retorna JWT firmado
POST /api/v1/auth/register     → Registra usuario nuevo
POST /api/v1/auth/refresh      → Renueva access token usando refresh token
GET  /api/v1/auth/me           → Perfil del usuario autenticado
PUT  /api/v1/auth/me           → Actualizar perfil (nombre, password, telefono)
POST /api/v1/auth/mfa/setup    → Generar secreto TOTP para MFA
POST /api/v1/auth/mfa/verify   → Verificar código TOTP y activar MFA
GET  /.well-known/jwks.json    → Expone clave pública JWKS (el gateway la consume)
GET  /api/v1/admin/{path}      → Panel admin (protegido por JWT + RBAC)
GET  /health                   → Health check para GCP
```

---

## 2. Generación de claves RSA

user-services debe generar un par de claves RSA al arrancar:
- **Clave privada** → se usa para firmar JWT en login. Nunca se expone.
- **Clave pública** → se expone como JWKS en `/.well-known/jwks.json`

Algoritmo: **RS256** (RSA 2048 bits).

En producción debería estar en Cloud KMS, pero para este sprint se genera en memoria.

Referencia de implementación:

```python
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.hazmat.backends import default_backend
import base64

def generate_rsa_key_pair(key_id: str = "travelhub-key-1"):
    private_key = rsa.generate_private_key(
        public_exponent=65537,
        key_size=2048,
        backend=default_backend()
    )
    public_key = private_key.public_key()
    public_numbers = public_key.public_numbers()
    n_bytes = public_numbers.n.to_bytes(256, byteorder='big')
    e_bytes = public_numbers.e.to_bytes(3, byteorder='big')

    jwk = {
        "kty": "RSA",
        "kid": key_id,
        "use": "sig",
        "alg": "RS256",
        "n": base64.urlsafe_b64encode(n_bytes).rstrip(b'=').decode('utf-8'),
        "e": base64.urlsafe_b64encode(e_bytes).rstrip(b'=').decode('utf-8'),
    }
    return private_key, jwk
```

---

## 3. Estructura del JWT que debe emitir el login

El token firmado debe incluir estos campos **exactos**:

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

| Campo | Quién lo valida | Detalle |
|---|---|---|
| `sub` | Backend (Chain) | ID único del usuario |
| `iss` | **API Gateway** | DEBE ser exactamente `https://auth.travelhub.app` |
| `aud` | **API Gateway** | DEBE ser exactamente `travelhub-api` |
| `exp` | **API Gateway** | Timestamp de expiración. Access token: **900 seg** (15 min) |
| `iat` | Informativo | Timestamp de emisión |
| `role` | Backend (RBACFilter) | Uno de: `traveler`, `hotel_admin`, `platform_admin` |
| `mfa_verified` | Backend (MFAFilter) | Boolean. Requerido para `/payments` y `/admin` |
| `country` | Backend (IPValidationFilter) | Código ISO del país del usuario |
| `hotel_id` | Backend (lógica de negocio) | Solo para `hotel_admin`, null para otros |

El header del JWT DEBE incluir `"kid": "travelhub-key-1"` para que el gateway sepa qué clave usar del JWKS.

---

## 4. Variables de entorno JWT

```bash
JWT_ISSUER=https://auth.travelhub.app
JWT_AUDIENCE=travelhub-api
JWT_ACCESS_TTL=900          # 15 minutos
JWT_REFRESH_TTL=604800      # 7 días
```

---

## 5. Formato del endpoint JWKS

`GET /.well-known/jwks.json` debe retornar:

```json
{
  "keys": [
    {
      "kty": "RSA",
      "kid": "travelhub-key-1",
      "use": "sig",
      "alg": "RS256",
      "n": "<modulus-base64url>",
      "e": "<exponent-base64url>"
    }
  ]
}
```

---

## 6. Roles RBAC

```
traveler        → search, bookings, payments, cart, notifications
hotel_admin     → search, bookings, inventory, pms, notifications
platform_admin  → todo, incluyendo /admin
```

---

## 7. Middleware Chain of Responsibility

user-services (y cada microservicio protegido) debe integrar un middleware FastAPI que ejecute la cadena de filtros DESPUÉS de que el gateway ya validó firma + expiración:

```
Request con JWT en header Authorization: Bearer <token>
  ↓
Middleware decodifica payload (SIN verificar firma, el gateway ya lo hizo)
  ↓
RateLimitFilter → 60 req/min por usuario/IP → 429 si excede
  ↓
IPValidationFilter → Geolocalización consistente (placeholder por ahora)
  ↓
RBACFilter → Valida role vs ruta → 403 si no tiene permiso
  ↓
MFAFilter → Valida mfa_verified=true para /payments y /admin → 403 si no
  ↓
Handler del endpoint
```

Claims disponibles después del middleware en `request.state`:

```python
request.state.user_id       # sub
request.state.user_role     # role
request.state.user_country  # country
request.state.mfa_verified  # mfa_verified
request.state.hotel_id      # hotel_id
```

---

## 8. Rutas públicas (NO pasan por el chain)

```python
PUBLIC_PATHS = [
    "/api/v1/auth/login",
    "/api/v1/auth/register",
    "/api/v1/auth/refresh",
    "/.well-known/jwks.json",
    "/health",
    "/docs",
    "/openapi.json",
]
```

---

## 9. Dependencias Python requeridas

```
fastapi>=0.104.0
uvicorn>=0.24.0
cryptography>=41.0.0
python-jose[cryptography]>=3.3.0
pydantic>=2.0.0
```

---

## 10. Deploy en Cloud Run — flags importantes

```bash
gcloud run deploy user-services \
  --vpc-connector=travelhub-connector \
  --set-env-vars "JWT_ISSUER=https://auth.travelhub.app,JWT_AUDIENCE=travelhub-api" \
  --allow-unauthenticated \
  --port 8000 \
  --region us-central1 \
  --project gen-lang-client-0930444414
```

- `--allow-unauthenticated` → el gateway controla el acceso, no Cloud Run IAM
- `--vpc-connector=travelhub-connector` → comunicación con Redis/PostgreSQL por IP privada
- Puerto **8000** (FastAPI con uvicorn)

---

## 11. Infra desplegada

| Capa | Estado | Recurso |
|---|---|---|
| Cloud Armor | Desplegado | `travelhub-security-policy` (WAF + rate limiting + geo-blocking) |
| VPC | Desplegado | `travelhub-vpc` con 3 subnets + VPC connector |
| Firewall | Desplegado | 9 reglas (DENY ALL default) |
| Cloud SQL | Desplegado | `travelhub-db` (PostgreSQL 15, IP privada `10.100.0.3`) |
| Cloud Run | Desplegado | `user-services` con VPC connector |
| API Gateway | Desplegado | `travelhub-gateway-1yvtqj7r.uc.gateway.dev` |

---

## 12. URLs del servicio desplegado

| Recurso | URL |
|---|---|
| Cloud Run (directo) | `https://user-services-ridyy4wz4q-uc.a.run.app` |
| API Gateway | `https://travelhub-gateway-1yvtqj7r.uc.gateway.dev` |
| JWKS | `https://user-services-ridyy4wz4q-uc.a.run.app/.well-known/jwks.json` |

---

## 13. Notas de integración gateway ↔ backend

- El API Gateway reemplaza el header `Authorization` con un OIDC token de servicio y mueve el JWT original del usuario a `X-Forwarded-Authorization`.
- El middleware `TokenValidationFilter` lee primero `X-Forwarded-Authorization` y luego `Authorization` como fallback.
- Las claves RSA se persisten via variable de entorno `RSA_PRIVATE_KEY_B64` (base64 del PEM). Se setea con `gcloud run services update`, no en `cloudbuild.yaml`.
- Al redesplegar el servicio con una nueva clave RSA, hay que redesplegar la config del API Gateway para que refresque el JWKS cacheado.
