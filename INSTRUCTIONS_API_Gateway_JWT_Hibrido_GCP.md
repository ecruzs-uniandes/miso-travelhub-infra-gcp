# Instrucciones para Claude Code — API Gateway JWT Híbrido + Cloud Armor + Firewall VPC en GCP

> **Proyecto:** TravelHub — Grupo 9  
> **Contexto:** PF2 Sprint 1  
> **ASR relacionado:** AH008 (Seguridad) + AH009 (Control de acceso RBAC) + AH007 (Cifrado) + AH016 (Resiliencia)  
> **Patrones:** Chain of Responsibility, Proxy (Authorization), Bulkhead  
> **Decisión arquitectónica:** Enfoque de defensa en profundidad con 4 capas:  
> 1. **Cloud Armor** → WAF + DDoS + Rate limiting distribuido (borde de red)  
> 2. **VPC Firewall** → Segmentación de red, reglas de ingress/egress  
> 3. **API Gateway** → Validación JWT (firma + expiración)  
> 4. **Chain of Responsibility** → Claims RBAC, MFA, lógica de negocio

---

## 1. Objetivo

Configurar GCP API Gateway como punto de entrada que:
1. Valida la **firma y expiración** de tokens JWT antes de que las peticiones lleguen a Cloud Run
2. Rechaza tokens inválidos/expirados con HTTP 401 a nivel de gateway (sin consumir recursos de backend)
3. Reenvía el JWT validado al backend, donde el **Chain of Responsibility** en `user-services` ejecuta la lógica de negocio: claims RBAC, MFA, rate limiting, bloqueo por intentos fallidos

---

## 2. Estructura de Archivos a Crear

```
travelhub-gateway/
├── gateway/
│   ├── openapi-spec.yaml          # Especificación OpenAPI con validación JWT
│   ├── gateway-config.yaml        # Configuración del API Gateway GCP
│   └── cors-policy.yaml           # Política CORS para React SPA
├── cloud-armor/
│   ├── security-policy.sh         # Script creación de política Cloud Armor
│   ├── waf-rules.sh               # Reglas WAF (OWASP Top 10, rate limiting)
│   └── adaptive-protection.sh     # Protección adaptativa contra DDoS
├── firewall/
│   ├── vpc-setup.sh               # Creación de VPC y subnets
│   ├── firewall-rules.sh          # Reglas de firewall ingress/egress
│   └── private-access.sh          # Configuración de acceso privado a servicios
├── auth/
│   ├── jwt_config.py              # Configuración de JWT (issuer, audience, keys)
│   ├── jwt_keys.py                # Generación y rotación de claves JWKS
│   └── jwks_endpoint.py           # Endpoint FastAPI que expone JWKS público
├── middleware/
│   ├── __init__.py
│   ├── jwt_claims_middleware.py   # Middleware FastAPI — valida claims (RBAC, MFA)
│   ├── rate_limit_middleware.py   # Rate limiting (usa Redis si disponible)
│   └── chain_of_responsibility.py # Cadena de filtros de seguridad completa
├── tests/
│   ├── test_jwt_validation.py     # Tests unitarios de validación JWT
│   ├── test_chain_filters.py      # Tests del Chain of Responsibility
│   ├── test_gateway_integration.py # Tests de integración gateway + backend
│   ├── test_cloud_armor.sh        # Tests de reglas Cloud Armor
│   ├── test_firewall_rules.sh     # Tests de reglas de firewall
│   └── conftest.py                # Fixtures compartidas
├── deploy/
│   ├── deploy-gateway.sh          # Script de despliegue del API Gateway
│   ├── deploy-jwks-service.sh     # Script de despliegue del servicio JWKS
│   ├── deploy-cloud-armor.sh      # Script de despliegue de Cloud Armor
│   ├── deploy-firewall.sh         # Script de despliegue de reglas de firewall
│   └── terraform/                 # IaC para toda la infra de seguridad
│       ├── main.tf
│       ├── cloud_armor.tf
│       ├── firewall.tf
│       ├── vpc.tf
│       ├── variables.tf
│       └── outputs.tf
├── requirements.txt
└── README.md
```

---

## 3. Paso a Paso

### 3.1 — Generar claves JWKS para firma de tokens

Crear el archivo `auth/jwt_keys.py`:

```python
"""
Generación de pares de claves RSA para firma JWT.
En producción, las claves privadas se almacenan en Cloud KMS.
Para desarrollo local, se generan y almacenan en memoria.
"""
import json
import time
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.hazmat.backends import default_backend
import base64


def generate_rsa_key_pair(key_id: str = "travelhub-key-1"):
    """Genera un par de claves RSA-256 para firma JWT."""
    private_key = rsa.generate_private_key(
        public_exponent=65537,
        key_size=2048,
        backend=default_backend()
    )
    public_key = private_key.public_key()

    # Extraer componentes públicos para JWKS
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


def build_jwks_document(jwk: dict) -> dict:
    """Construye el documento JWKS público que consume el API Gateway."""
    return {
        "keys": [jwk]
    }
```

---

### 3.2 — Crear endpoint JWKS en FastAPI

Crear el archivo `auth/jwks_endpoint.py`:

```python
"""
Endpoint público que expone las claves JWKS.
El API Gateway de GCP consulta esta URL para validar firmas JWT.
Se despliega como parte de user-services o como servicio independiente.
"""
from fastapi import APIRouter
from auth.jwt_keys import generate_rsa_key_pair, build_jwks_document

router = APIRouter()

# En producción: cargar desde Cloud KMS
# En desarrollo: generar al arrancar
_private_key, _jwk = generate_rsa_key_pair(key_id="travelhub-key-1")
_jwks_document = build_jwks_document(_jwk)


def get_private_key():
    """Acceso interno para firmar tokens (solo user-services)."""
    return _private_key


@router.get("/.well-known/jwks.json")
async def get_jwks():
    """
    Endpoint público JWKS.
    El API Gateway de GCP usa esta URL en x-google-jwks_uri
    para verificar las firmas de los JWT.
    """
    return _jwks_document
```

---

### 3.3 — Configuración JWT

Crear el archivo `auth/jwt_config.py`:

```python
"""
Configuración centralizada de JWT para TravelHub.
"""
import os

JWT_CONFIG = {
    # Issuer: identifica quién emitió el token
    "issuer": os.getenv("JWT_ISSUER", "https://auth.travelhub.app"),

    # Audience: identifica para quién es el token
    "audience": os.getenv("JWT_AUDIENCE", "travelhub-api"),

    # Algoritmo de firma
    "algorithm": "RS256",

    # Tiempo de vida del access token (15 minutos)
    "access_token_ttl_seconds": int(os.getenv("JWT_ACCESS_TTL", "900")),

    # Tiempo de vida del refresh token (7 días)
    "refresh_token_ttl_seconds": int(os.getenv("JWT_REFRESH_TTL", "604800")),

    # URL del endpoint JWKS (la que consume el API Gateway)
    "jwks_uri": os.getenv(
        "JWKS_URI",
        "https://user-services-HASH-uc.a.run.app/.well-known/jwks.json"
    ),
}

# Claims custom de TravelHub incluidos en el JWT payload
# Estos NO los valida el gateway — los valida el Chain of Responsibility
CUSTOM_CLAIMS = {
    "role": "Rol RBAC del usuario (traveler, hotel_admin, platform_admin)",
    "mfa_verified": "Boolean — si completó MFA en esta sesión",
    "country": "País de origen del usuario (para sharding geográfico)",
    "hotel_id": "ID del hotel (solo para hotel_admin)",
}
```

---

### 3.4 — Especificación OpenAPI del API Gateway

Crear el archivo `gateway/openapi-spec.yaml`:

```yaml
# =============================================================================
# TravelHub — API Gateway OpenAPI Specification
# =============================================================================
# Este archivo configura GCP API Gateway con validación JWT nativa.
# El gateway valida: firma RS256, issuer, audience, expiración.
# Los claims de negocio (role, mfa_verified) los valida el backend.
# =============================================================================

swagger: "2.0"
info:
  title: "TravelHub API Gateway"
  version: "1.0.0"
  description: |
    Gateway de entrada para TravelHub. Valida JWT a nivel de infraestructura
    y rutea a microservicios en Cloud Run.

host: "travelhub-gateway-HASH-uc.a.run.app"
basePath: "/"
schemes:
  - "https"

# =============================================================================
# Configuración de seguridad JWT
# =============================================================================
securityDefinitions:
  travelhub_jwt:
    authorizationUrl: ""
    flow: "implicit"
    type: "oauth2"
    x-google-issuer: "https://auth.travelhub.app"
    x-google-audiences: "travelhub-api"
    x-google-jwks_uri: "https://user-services-HASH-uc.a.run.app/.well-known/jwks.json"

# =============================================================================
# Rutas — Microservicios
# =============================================================================
paths:

  # ---------- Rutas PÚBLICAS (sin JWT) ----------

  /api/v1/auth/login:
    post:
      operationId: "authLogin"
      summary: "Login — no requiere JWT"
      x-google-backend:
        address: "https://user-services-HASH-uc.a.run.app"
        path_translation: APPEND_PATH_TO_ADDRESS
      responses:
        200:
          description: "Login exitoso, retorna JWT"

  /api/v1/auth/register:
    post:
      operationId: "authRegister"
      summary: "Registro de usuario — no requiere JWT"
      x-google-backend:
        address: "https://user-services-HASH-uc.a.run.app"
        path_translation: APPEND_PATH_TO_ADDRESS
      responses:
        201:
          description: "Usuario registrado"

  /api/v1/auth/refresh:
    post:
      operationId: "authRefresh"
      summary: "Refresh token — no requiere JWT (usa refresh token)"
      x-google-backend:
        address: "https://user-services-HASH-uc.a.run.app"
        path_translation: APPEND_PATH_TO_ADDRESS
      responses:
        200:
          description: "Nuevo access token emitido"

  /.well-known/jwks.json:
    get:
      operationId: "getJwks"
      summary: "Endpoint JWKS público"
      x-google-backend:
        address: "https://user-services-HASH-uc.a.run.app"
        path_translation: APPEND_PATH_TO_ADDRESS
      responses:
        200:
          description: "JWKS document"

  # ---------- Rutas PROTEGIDAS (requieren JWT válido) ----------

  /api/v1/search/{path}:
    get:
      operationId: "searchServices"
      summary: "Búsqueda de hospedajes"
      security:
        - travelhub_jwt: []
      x-google-backend:
        address: "https://search-services-HASH-uc.a.run.app"
        path_translation: APPEND_PATH_TO_ADDRESS
      parameters:
        - name: path
          in: path
          required: true
          type: string
      responses:
        200:
          description: "Resultados de búsqueda"
        401:
          description: "JWT inválido o expirado — rechazado por gateway"

  /api/v1/bookings/{path}:
    get:
      operationId: "bookingServicesGet"
      summary: "Consultar reservas"
      security:
        - travelhub_jwt: []
      x-google-backend:
        address: "https://booking-services-HASH-uc.a.run.app"
        path_translation: APPEND_PATH_TO_ADDRESS
      parameters:
        - name: path
          in: path
          required: true
          type: string
      responses:
        200:
          description: "Reservas del usuario"
        401:
          description: "JWT inválido"
    post:
      operationId: "bookingServicesPost"
      summary: "Crear reserva"
      security:
        - travelhub_jwt: []
      x-google-backend:
        address: "https://booking-services-HASH-uc.a.run.app"
        path_translation: APPEND_PATH_TO_ADDRESS
      parameters:
        - name: path
          in: path
          required: true
          type: string
      responses:
        201:
          description: "Reserva creada"
        401:
          description: "JWT inválido"

  /api/v1/payments/{path}:
    post:
      operationId: "paymentServices"
      summary: "Procesar pago"
      security:
        - travelhub_jwt: []
      x-google-backend:
        address: "https://payments-services-HASH-uc.a.run.app"
        path_translation: APPEND_PATH_TO_ADDRESS
      parameters:
        - name: path
          in: path
          required: true
          type: string
      responses:
        200:
          description: "Pago procesado"
        401:
          description: "JWT inválido"

  /api/v1/inventory/{path}:
    get:
      operationId: "inventoryServicesGet"
      summary: "Consultar inventario"
      security:
        - travelhub_jwt: []
      x-google-backend:
        address: "https://inventory-services-HASH-uc.a.run.app"
        path_translation: APPEND_PATH_TO_ADDRESS
      parameters:
        - name: path
          in: path
          required: true
          type: string
      responses:
        200:
          description: "Inventario"
        401:
          description: "JWT inválido"
    put:
      operationId: "inventoryServicesPut"
      summary: "Actualizar inventario"
      security:
        - travelhub_jwt: []
      x-google-backend:
        address: "https://inventory-services-HASH-uc.a.run.app"
        path_translation: APPEND_PATH_TO_ADDRESS
      parameters:
        - name: path
          in: path
          required: true
          type: string
      responses:
        200:
          description: "Inventario actualizado"
        401:
          description: "JWT inválido"

  /api/v1/notifications/{path}:
    get:
      operationId: "notificationServices"
      summary: "Notificaciones"
      security:
        - travelhub_jwt: []
      x-google-backend:
        address: "https://notification-services-HASH-uc.a.run.app"
        path_translation: APPEND_PATH_TO_ADDRESS
      parameters:
        - name: path
          in: path
          required: true
          type: string
      responses:
        200:
          description: "Notificaciones"
        401:
          description: "JWT inválido"

  /api/v1/pms/{path}:
    get:
      operationId: "pmsServicesGet"
      summary: "Integración PMS"
      security:
        - travelhub_jwt: []
      x-google-backend:
        address: "https://pms-integration-services-HASH-uc.a.run.app"
        path_translation: APPEND_PATH_TO_ADDRESS
      parameters:
        - name: path
          in: path
          required: true
          type: string
      responses:
        200:
          description: "Datos PMS"
        401:
          description: "JWT inválido"
    post:
      operationId: "pmsServicesPost"
      summary: "Webhook PMS"
      security:
        - travelhub_jwt: []
      x-google-backend:
        address: "https://pms-integration-services-HASH-uc.a.run.app"
        path_translation: APPEND_PATH_TO_ADDRESS
      parameters:
        - name: path
          in: path
          required: true
          type: string
      responses:
        200:
          description: "PMS sincronizado"
        401:
          description: "JWT inválido"

  /api/v1/cart/{path}:
    get:
      operationId: "cartServicesGet"
      summary: "Carrito de compras"
      security:
        - travelhub_jwt: []
      x-google-backend:
        address: "https://shopping-cart-services-HASH-uc.a.run.app"
        path_translation: APPEND_PATH_TO_ADDRESS
      parameters:
        - name: path
          in: path
          required: true
          type: string
      responses:
        200:
          description: "Carrito"
        401:
          description: "JWT inválido"
    post:
      operationId: "cartServicesPost"
      summary: "Agregar al carrito"
      security:
        - travelhub_jwt: []
      x-google-backend:
        address: "https://shopping-cart-services-HASH-uc.a.run.app"
        path_translation: APPEND_PATH_TO_ADDRESS
      parameters:
        - name: path
          in: path
          required: true
          type: string
      responses:
        201:
          description: "Item agregado"
        401:
          description: "JWT inválido"

  # ---------- Rutas ADMIN (requieren JWT + validación RBAC en backend) ----------

  /api/v1/admin/{path}:
    get:
      operationId: "adminGet"
      summary: "Panel admin — JWT validado en gateway, RBAC en backend"
      security:
        - travelhub_jwt: []
      x-google-backend:
        address: "https://user-services-HASH-uc.a.run.app"
        path_translation: APPEND_PATH_TO_ADDRESS
      parameters:
        - name: path
          in: path
          required: true
          type: string
      responses:
        200:
          description: "Datos admin"
        401:
          description: "JWT inválido"
        403:
          description: "Rol insuficiente — rechazado por Chain of Responsibility"
```

---

### 3.5 — Middleware del Chain of Responsibility (backend)

Crear el archivo `middleware/chain_of_responsibility.py`:

```python
"""
Chain of Responsibility — Validación de seguridad en backend.
El API Gateway ya validó firma y expiración del JWT.
Este chain valida la lógica de negocio: claims, roles, MFA, rate limiting.

Flujo:
  Gateway (firma + exp) → RateLimitFilter → RBACFilter → MFAFilter → Handler

Patrón: GoF Chain of Responsibility (AH008 + AH009)
"""
from abc import ABC, abstractmethod
from fastapi import Request, HTTPException
from typing import Optional
import logging

logger = logging.getLogger(__name__)


class SecurityFilter(ABC):
    """Filtro base del Chain of Responsibility."""

    def __init__(self):
        self._next_filter: Optional[SecurityFilter] = None

    def set_next(self, filter: "SecurityFilter") -> "SecurityFilter":
        self._next_filter = filter
        return filter

    async def handle(self, request: Request, jwt_payload: dict) -> dict:
        """Procesa el filtro y pasa al siguiente si es exitoso."""
        await self._validate(request, jwt_payload)
        if self._next_filter:
            return await self._next_filter.handle(request, jwt_payload)
        return jwt_payload

    @abstractmethod
    async def _validate(self, request: Request, jwt_payload: dict) -> None:
        """Implementar validación específica. Lanzar HTTPException si falla."""
        pass


class RateLimitFilter(SecurityFilter):
    """
    Filtro de rate limiting.
    TODO PF2: Implementar con Redis (MemoryStore) para rate limiting distribuido.
    Por ahora opera por instancia (debilidad documentada en PF1).
    """

    def __init__(self, max_requests_per_minute: int = 60):
        super().__init__()
        self.max_rpm = max_requests_per_minute
        # En memoria por instancia — migrar a Redis en PF2
        self._request_counts: dict = {}

    async def _validate(self, request: Request, jwt_payload: dict) -> None:
        user_id = jwt_payload.get("sub", "anonymous")
        client_ip = request.client.host if request.client else "unknown"
        key = f"{user_id}:{client_ip}"

        import time
        current_minute = int(time.time() / 60)
        count_key = f"{key}:{current_minute}"

        self._request_counts[count_key] = self._request_counts.get(count_key, 0) + 1

        if self._request_counts[count_key] > self.max_rpm:
            logger.warning(f"Rate limit exceeded for {key}")
            raise HTTPException(
                status_code=429,
                detail="Rate limit exceeded. Try again later."
            )


class IPValidationFilter(SecurityFilter):
    """
    Valida que el IP del request sea consistente con el país del usuario.
    Detecta accesos desde ubicaciones imposibles (AH008).
    """

    async def _validate(self, request: Request, jwt_payload: dict) -> None:
        # TODO: Implementar validación de geolocalización
        # Si el usuario estaba en Colombia hace 5 min y ahora está en China → alerta
        user_country = jwt_payload.get("country", None)
        if user_country:
            logger.info(f"IP validation for user country: {user_country}")
            # Placeholder — integrar con servicio de geolocalización
            pass


class RBACFilter(SecurityFilter):
    """
    Valida que el rol del usuario permita acceder al recurso solicitado.
    Patrón: Proxy (Authorization Proxy) — AH009.
    """

    # Mapeo de rutas a roles permitidos
    ROLE_PERMISSIONS = {
        "/api/v1/admin": ["platform_admin"],
        "/api/v1/inventory": ["hotel_admin", "platform_admin"],
        "/api/v1/pms": ["hotel_admin", "platform_admin"],
        "/api/v1/bookings": ["traveler", "hotel_admin", "platform_admin"],
        "/api/v1/search": ["traveler", "hotel_admin", "platform_admin"],
        "/api/v1/payments": ["traveler", "platform_admin"],
        "/api/v1/cart": ["traveler"],
        "/api/v1/notifications": ["traveler", "hotel_admin", "platform_admin"],
    }

    async def _validate(self, request: Request, jwt_payload: dict) -> None:
        user_role = jwt_payload.get("role", None)
        request_path = request.url.path

        if not user_role:
            logger.warning(f"No role claim in JWT for path: {request_path}")
            raise HTTPException(
                status_code=403,
                detail="Access denied: no role assigned"
            )

        # Buscar la ruta más específica que coincida
        for route_prefix, allowed_roles in self.ROLE_PERMISSIONS.items():
            if request_path.startswith(route_prefix):
                if user_role not in allowed_roles:
                    logger.warning(
                        f"RBAC denied: role={user_role} path={request_path} "
                        f"allowed={allowed_roles}"
                    )
                    raise HTTPException(
                        status_code=403,
                        detail=f"Access denied: role '{user_role}' cannot access this resource"
                    )
                return

        # Si no hay regla explícita, permitir (el gateway ya validó el JWT)
        logger.info(f"No RBAC rule for {request_path}, allowing authenticated user")


class MFAFilter(SecurityFilter):
    """
    Valida que operaciones sensibles tengan MFA verificado.
    Aplica solo a rutas que lo requieren (pagos, admin, cambios de perfil).
    """

    MFA_REQUIRED_PREFIXES = [
        "/api/v1/payments",
        "/api/v1/admin",
    ]

    async def _validate(self, request: Request, jwt_payload: dict) -> None:
        request_path = request.url.path

        requires_mfa = any(
            request_path.startswith(prefix)
            for prefix in self.MFA_REQUIRED_PREFIXES
        )

        if requires_mfa:
            mfa_verified = jwt_payload.get("mfa_verified", False)
            if not mfa_verified:
                logger.warning(
                    f"MFA required but not verified for path: {request_path}"
                )
                raise HTTPException(
                    status_code=403,
                    detail="MFA verification required for this operation"
                )


def build_security_chain() -> SecurityFilter:
    """
    Construye la cadena de filtros de seguridad.
    Orden: RateLimit → IP → RBAC → MFA

    El API Gateway ya validó:
      ✅ Firma JWT (RS256)
      ✅ Issuer (https://auth.travelhub.app)
      ✅ Audience (travelhub-api)
      ✅ Expiración (exp claim)

    Este chain valida:
      🔒 Rate limiting por usuario/IP
      🔒 Geolocalización del IP
      🔒 Roles RBAC por ruta
      🔒 MFA para operaciones sensibles
    """
    rate_limit = RateLimitFilter(max_requests_per_minute=60)
    ip_validation = IPValidationFilter()
    rbac = RBACFilter()
    mfa = MFAFilter()

    rate_limit.set_next(ip_validation).set_next(rbac).set_next(mfa)

    return rate_limit
```

---

### 3.6 — Middleware FastAPI para claims JWT

Crear el archivo `middleware/jwt_claims_middleware.py`:

```python
"""
Middleware FastAPI que extrae los claims del JWT (ya validado por el gateway)
y ejecuta el Chain of Responsibility.

IMPORTANTE: El gateway ya validó firma y expiración.
Aquí solo decodificamos el payload para leer los claims (sin verificar firma,
porque ya fue verificada). Si el gateway está habilitado, el token es confiable.
"""
import base64
import json
import logging
from fastapi import Request, HTTPException
from starlette.middleware.base import BaseHTTPMiddleware
from middleware.chain_of_responsibility import build_security_chain

logger = logging.getLogger(__name__)

# Rutas que NO pasan por el chain (ya definidas como públicas en el gateway)
PUBLIC_PATHS = [
    "/api/v1/auth/login",
    "/api/v1/auth/register",
    "/api/v1/auth/refresh",
    "/.well-known/jwks.json",
    "/health",
    "/docs",
    "/openapi.json",
]


def decode_jwt_payload_without_verification(token: str) -> dict:
    """
    Decodifica el payload del JWT SIN verificar la firma.
    Esto es seguro porque el API Gateway ya verificó la firma.
    Solo extraemos los claims para la lógica de negocio.
    """
    try:
        parts = token.split(".")
        if len(parts) != 3:
            raise ValueError("Invalid JWT format")

        # Decodificar payload (parte 2, base64url)
        payload_b64 = parts[1]
        # Agregar padding si es necesario
        padding = 4 - len(payload_b64) % 4
        if padding != 4:
            payload_b64 += "=" * padding

        payload_json = base64.urlsafe_b64decode(payload_b64)
        return json.loads(payload_json)
    except Exception as e:
        logger.error(f"Failed to decode JWT payload: {e}")
        raise HTTPException(status_code=401, detail="Invalid token format")


class JWTClaimsMiddleware(BaseHTTPMiddleware):
    """
    Middleware que:
    1. Extrae el JWT del header Authorization
    2. Decodifica el payload (firma ya validada por gateway)
    3. Ejecuta el Chain of Responsibility
    4. Inyecta los claims en request.state para uso en los handlers
    """

    def __init__(self, app):
        super().__init__(app)
        self.security_chain = build_security_chain()

    async def dispatch(self, request: Request, call_next):
        # Saltar rutas públicas
        if any(request.url.path.startswith(path) for path in PUBLIC_PATHS):
            return await call_next(request)

        # Extraer token del header
        auth_header = request.headers.get("Authorization", "")
        if not auth_header.startswith("Bearer "):
            # Si el gateway está configurado, esto no debería pasar
            # Pero por defensa en profundidad, rechazamos
            raise HTTPException(status_code=401, detail="Missing Bearer token")

        token = auth_header[7:]  # Quitar "Bearer "

        # Decodificar payload (sin verificar firma — gateway ya lo hizo)
        jwt_payload = decode_jwt_payload_without_verification(token)

        # Ejecutar Chain of Responsibility
        await self.security_chain.handle(request, jwt_payload)

        # Inyectar claims en request.state para uso en handlers
        request.state.user_id = jwt_payload.get("sub")
        request.state.user_role = jwt_payload.get("role")
        request.state.user_country = jwt_payload.get("country")
        request.state.mfa_verified = jwt_payload.get("mfa_verified", False)
        request.state.hotel_id = jwt_payload.get("hotel_id")

        return await call_next(request)
```

---

### 3.7 — Integración en la app FastAPI

Agregar el middleware en el archivo principal de cada microservicio (ejemplo `main.py`):

```python
"""
Ejemplo de integración del middleware JWT en un microservicio FastAPI.
Agregar en cada microservicio que requiera autenticación.
"""
from fastapi import FastAPI
from middleware.jwt_claims_middleware import JWTClaimsMiddleware

app = FastAPI(title="TravelHub - Booking Services")

# Middleware de seguridad — Chain of Responsibility
app.add_middleware(JWTClaimsMiddleware)


# Ejemplo de uso en un endpoint
from fastapi import Request

@app.get("/api/v1/bookings/my-bookings")
async def get_my_bookings(request: Request):
    """Los claims ya están disponibles en request.state."""
    user_id = request.state.user_id
    user_role = request.state.user_role
    user_country = request.state.user_country

    # Lógica de negocio...
    return {
        "user_id": user_id,
        "role": user_role,
        "country": user_country,
        "bookings": []
    }
```

---

### 3.8 — Tests unitarios

Crear el archivo `tests/test_chain_filters.py`:

```python
"""
Tests unitarios para el Chain of Responsibility de seguridad.
Valida: rate limiting, RBAC, MFA.
Cubre ASR AH008 (100% bloqueo de accesos ilegítimos).
"""
import pytest
from unittest.mock import MagicMock, AsyncMock
from fastapi import HTTPException
from middleware.chain_of_responsibility import (
    RateLimitFilter,
    RBACFilter,
    MFAFilter,
    build_security_chain,
)


def make_mock_request(path: str = "/api/v1/bookings", client_ip: str = "192.168.1.1"):
    """Crea un request mock para tests."""
    request = MagicMock()
    request.url.path = path
    request.client.host = client_ip
    return request


# ============ RBAC Tests ============

@pytest.mark.asyncio
async def test_rbac_allows_traveler_to_book():
    """Traveler puede acceder a bookings."""
    rbac = RBACFilter()
    request = make_mock_request("/api/v1/bookings/create")
    payload = {"sub": "user-1", "role": "traveler"}
    await rbac._validate(request, payload)  # No debe lanzar excepción


@pytest.mark.asyncio
async def test_rbac_blocks_traveler_from_admin():
    """Traveler NO puede acceder a admin."""
    rbac = RBACFilter()
    request = make_mock_request("/api/v1/admin/dashboard")
    payload = {"sub": "user-1", "role": "traveler"}
    with pytest.raises(HTTPException) as exc_info:
        await rbac._validate(request, payload)
    assert exc_info.value.status_code == 403


@pytest.mark.asyncio
async def test_rbac_allows_admin_to_admin():
    """Platform admin puede acceder a admin."""
    rbac = RBACFilter()
    request = make_mock_request("/api/v1/admin/dashboard")
    payload = {"sub": "admin-1", "role": "platform_admin"}
    await rbac._validate(request, payload)


@pytest.mark.asyncio
async def test_rbac_blocks_missing_role():
    """Sin rol → acceso denegado."""
    rbac = RBACFilter()
    request = make_mock_request("/api/v1/bookings/list")
    payload = {"sub": "user-1"}  # Sin claim 'role'
    with pytest.raises(HTTPException) as exc_info:
        await rbac._validate(request, payload)
    assert exc_info.value.status_code == 403


@pytest.mark.asyncio
async def test_rbac_hotel_admin_can_access_inventory():
    """Hotel admin puede gestionar inventario."""
    rbac = RBACFilter()
    request = make_mock_request("/api/v1/inventory/rooms")
    payload = {"sub": "hotel-1", "role": "hotel_admin"}
    await rbac._validate(request, payload)


@pytest.mark.asyncio
async def test_rbac_traveler_cannot_access_inventory():
    """Traveler NO puede gestionar inventario."""
    rbac = RBACFilter()
    request = make_mock_request("/api/v1/inventory/rooms")
    payload = {"sub": "user-1", "role": "traveler"}
    with pytest.raises(HTTPException) as exc_info:
        await rbac._validate(request, payload)
    assert exc_info.value.status_code == 403


# ============ MFA Tests ============

@pytest.mark.asyncio
async def test_mfa_required_for_payments():
    """Pagos requieren MFA verificado."""
    mfa = MFAFilter()
    request = make_mock_request("/api/v1/payments/process")
    payload = {"sub": "user-1", "role": "traveler", "mfa_verified": False}
    with pytest.raises(HTTPException) as exc_info:
        await mfa._validate(request, payload)
    assert exc_info.value.status_code == 403


@pytest.mark.asyncio
async def test_mfa_passes_when_verified():
    """Pagos pasan si MFA está verificado."""
    mfa = MFAFilter()
    request = make_mock_request("/api/v1/payments/process")
    payload = {"sub": "user-1", "role": "traveler", "mfa_verified": True}
    await mfa._validate(request, payload)


@pytest.mark.asyncio
async def test_mfa_not_required_for_search():
    """Búsquedas no requieren MFA."""
    mfa = MFAFilter()
    request = make_mock_request("/api/v1/search/hotels")
    payload = {"sub": "user-1", "role": "traveler", "mfa_verified": False}
    await mfa._validate(request, payload)


# ============ Rate Limit Tests ============

@pytest.mark.asyncio
async def test_rate_limit_allows_normal_traffic():
    """Tráfico normal pasa sin problemas."""
    rl = RateLimitFilter(max_requests_per_minute=10)
    request = make_mock_request()
    payload = {"sub": "user-1"}
    # 10 requests deben pasar
    for _ in range(10):
        await rl._validate(request, payload)


@pytest.mark.asyncio
async def test_rate_limit_blocks_excess():
    """Exceder el límite genera 429."""
    rl = RateLimitFilter(max_requests_per_minute=5)
    request = make_mock_request()
    payload = {"sub": "user-1"}
    # 5 requests pasan
    for _ in range(5):
        await rl._validate(request, payload)
    # La 6ta debe fallar
    with pytest.raises(HTTPException) as exc_info:
        await rl._validate(request, payload)
    assert exc_info.value.status_code == 429


# ============ Full Chain Tests ============

@pytest.mark.asyncio
async def test_full_chain_valid_request():
    """Request completamente válido pasa toda la cadena."""
    chain = build_security_chain()
    request = make_mock_request("/api/v1/bookings/list")
    payload = {
        "sub": "user-1",
        "role": "traveler",
        "mfa_verified": True,
        "country": "CO",
    }
    result = await chain.handle(request, payload)
    assert result["sub"] == "user-1"


@pytest.mark.asyncio
async def test_full_chain_blocks_unauthorized_role():
    """Chain bloquea acceso con rol insuficiente."""
    chain = build_security_chain()
    request = make_mock_request("/api/v1/admin/users")
    payload = {
        "sub": "user-1",
        "role": "traveler",
        "mfa_verified": True,
    }
    with pytest.raises(HTTPException) as exc_info:
        await chain.handle(request, payload)
    assert exc_info.value.status_code == 403
```

---

### 3.9 — requirements.txt

```
fastapi>=0.104.0
uvicorn>=0.24.0
cryptography>=41.0.0
python-jose[cryptography]>=3.3.0
pydantic>=2.0.0
pytest>=7.4.0
pytest-asyncio>=0.23.0
httpx>=0.25.0
```

---

## 4. Despliegue en GCP

### 4.1 — Desplegar el servicio JWKS (user-services)

Crear el archivo `deploy/deploy-jwks-service.sh`:

```bash
#!/bin/bash
# =============================================================================
# Deploy user-services con endpoint JWKS a Cloud Run
# =============================================================================
set -euo pipefail

PROJECT_ID="${GCP_PROJECT_ID:-travelhub-g09}"
REGION="${GCP_REGION:-us-central1}"
SERVICE_NAME="user-services"
IMAGE="gcr.io/${PROJECT_ID}/${SERVICE_NAME}:latest"

echo "=== Building Docker image ==="
docker build -t ${IMAGE} -f Dockerfile.user-services .

echo "=== Pushing to GCR ==="
docker push ${IMAGE}

echo "=== Deploying to Cloud Run ==="
gcloud run deploy ${SERVICE_NAME} \
  --image ${IMAGE} \
  --region ${REGION} \
  --platform managed \
  --allow-unauthenticated \
  --set-env-vars "JWT_ISSUER=https://auth.travelhub.app,JWT_AUDIENCE=travelhub-api" \
  --memory 512Mi \
  --cpu 1 \
  --min-instances 1 \
  --max-instances 10 \
  --port 8000

echo "=== Getting service URL ==="
SERVICE_URL=$(gcloud run services describe ${SERVICE_NAME} \
  --region ${REGION} \
  --format 'value(status.url)')

echo ""
echo "✅ user-services deployed at: ${SERVICE_URL}"
echo "📄 JWKS endpoint: ${SERVICE_URL}/.well-known/jwks.json"
echo ""
echo "⚠️  IMPORTANTE: Actualizar la URL de JWKS en gateway/openapi-spec.yaml:"
echo "   x-google-jwks_uri: ${SERVICE_URL}/.well-known/jwks.json"
```

### 4.2 — Desplegar el API Gateway

Crear el archivo `deploy/deploy-gateway.sh`:

```bash
#!/bin/bash
# =============================================================================
# Deploy API Gateway con validación JWT en GCP
# =============================================================================
set -euo pipefail

PROJECT_ID="${GCP_PROJECT_ID:-travelhub-g09}"
REGION="${GCP_REGION:-us-central1}"
API_ID="travelhub-api"
CONFIG_ID="travelhub-config-$(date +%Y%m%d-%H%M%S)"
GATEWAY_ID="travelhub-gateway"

echo "=== Step 1: Habilitar APIs necesarias ==="
gcloud services enable apigateway.googleapis.com --project=${PROJECT_ID}
gcloud services enable servicemanagement.googleapis.com --project=${PROJECT_ID}
gcloud services enable servicecontrol.googleapis.com --project=${PROJECT_ID}

echo "=== Step 2: Crear la API (si no existe) ==="
gcloud api-gateway apis create ${API_ID} \
  --project=${PROJECT_ID} \
  2>/dev/null || echo "API '${API_ID}' already exists, continuing..."

echo "=== Step 3: Crear la configuración del API con OpenAPI spec ==="
gcloud api-gateway api-configs create ${CONFIG_ID} \
  --api=${API_ID} \
  --openapi-spec=gateway/openapi-spec.yaml \
  --project=${PROJECT_ID}

echo "=== Step 4: Desplegar el Gateway ==="
gcloud api-gateway gateways create ${GATEWAY_ID} \
  --api=${API_ID} \
  --api-config=${CONFIG_ID} \
  --location=${REGION} \
  --project=${PROJECT_ID} \
  2>/dev/null || \
gcloud api-gateway gateways update ${GATEWAY_ID} \
  --api=${API_ID} \
  --api-config=${CONFIG_ID} \
  --location=${REGION} \
  --project=${PROJECT_ID}

echo "=== Step 5: Obtener URL del Gateway ==="
GATEWAY_URL=$(gcloud api-gateway gateways describe ${GATEWAY_ID} \
  --location=${REGION} \
  --project=${PROJECT_ID} \
  --format 'value(defaultHostname)')

echo ""
echo "============================================"
echo "✅ API Gateway deployed successfully!"
echo "============================================"
echo "Gateway URL: https://${GATEWAY_URL}"
echo "API Config:  ${CONFIG_ID}"
echo ""
echo "Test commands:"
echo "  # Sin JWT (debe retornar 401 en rutas protegidas):"
echo "  curl -s https://${GATEWAY_URL}/api/v1/bookings/list"
echo ""
echo "  # Con JWT válido:"
echo "  curl -s -H 'Authorization: Bearer <TOKEN>' https://${GATEWAY_URL}/api/v1/bookings/list"
echo ""
echo "  # Ruta pública (no requiere JWT):"
echo "  curl -s https://${GATEWAY_URL}/api/v1/auth/login"
echo "============================================"
```

---

## 5. Verificación Post-Despliegue

Ejecutar estas validaciones después del despliegue:

```bash
# 1. Verificar que el JWKS endpoint responde
curl -s https://user-services-HASH-uc.a.run.app/.well-known/jwks.json | jq .

# 2. Verificar que el gateway rechaza peticiones sin JWT (esperado: 401)
curl -s -o /dev/null -w "%{http_code}" https://GATEWAY_URL/api/v1/bookings/list
# Esperado: 401

# 3. Verificar que rutas públicas funcionan sin JWT (esperado: 200 o 405)
curl -s -o /dev/null -w "%{http_code}" -X POST https://GATEWAY_URL/api/v1/auth/login
# Esperado: 200 o 422 (depende de si envías body)

# 4. Tests con JWT válido (generar token de prueba y probar)
python -c "
from auth.jwt_keys import generate_rsa_key_pair
from jose import jwt
import time

private_key, jwk = generate_rsa_key_pair()
from cryptography.hazmat.primitives import serialization
pem = private_key.private_bytes(
    serialization.Encoding.PEM,
    serialization.PrivateFormat.PKCS8,
    serialization.NoEncryption()
)
token = jwt.encode(
    {
        'sub': 'test-user-1',
        'iss': 'https://auth.travelhub.app',
        'aud': 'travelhub-api',
        'exp': int(time.time()) + 900,
        'role': 'traveler',
        'mfa_verified': True,
        'country': 'CO'
    },
    pem,
    algorithm='RS256',
    headers={'kid': 'travelhub-key-1'}
)
print(token)
"

# 5. Ejecutar tests unitarios
pytest tests/ -v --tb=short
```

---

## 6. Resumen — Qué valida cada capa

| Capa | Qué valida | Qué rechaza |
|------|-----------|-------------|
| **Cloud Armor (WAF)** | OWASP Top 10, rate limiting distribuido, geoblocking, DDoS | SQLi, XSS, floods → HTTP 403/429 |
| **VPC Firewall** | Segmentación de red, puertos permitidos, acceso entre servicios | Tráfico no autorizado entre subnets → DROP |
| **API Gateway** | Firma RS256, issuer, audience, expiración | Tokens inválidos/expirados → HTTP 401 |
| **RateLimitFilter** | Requests por minuto por usuario/IP (complemento en app) | Exceso de requests → HTTP 429 |
| **IPValidationFilter** | Geolocalización consistente | Ubicación imposible → Alerta |
| **RBACFilter** | Rol del usuario vs ruta solicitada | Rol insuficiente → HTTP 403 |
| **MFAFilter** | MFA verificado para operaciones sensibles | Sin MFA en pagos/admin → HTTP 403 |

---

## 7. Notas para el equipo

- **Cloud KMS**: En producción, la clave privada de firma JWT debe estar en Cloud KMS, NO en el código. Este `.md` usa generación local para desarrollo.
- **Rate limiting distribuido**: Cloud Armor resuelve la debilidad de PF1 (rate limiting por instancia). El `RateLimitFilter` en app queda como segunda línea de defensa.
- **URLs de Cloud Run**: Reemplazar todos los `HASH` en `openapi-spec.yaml` con los hashes reales de los servicios desplegados.
- **CORS**: Configurar CORS en el gateway o en cada microservicio para permitir requests desde el React SPA.

---

## 8. Cloud Armor — WAF y Protección DDoS

Cloud Armor se aplica al **Cloud Load Balancer** (no al API Gateway directamente). Esto significa que Cloud Armor filtra tráfico ANTES de que llegue al API Gateway, funcionando como la primera línea de defensa.

> **Trazabilidad:** Cloud Armor resuelve directamente la debilidad "Rate Limiting distribuido" documentada en PF1 — el rate limiting ahora opera a nivel global en el borde de red, no por instancia.

### 8.1 — Crear la política de seguridad Cloud Armor

Crear el archivo `cloud-armor/security-policy.sh`:

```bash
#!/bin/bash
# =============================================================================
# TravelHub — Cloud Armor Security Policy
# =============================================================================
# Crea la política de seguridad base para el Load Balancer.
# Cloud Armor opera en el borde de red (edge) de GCP.
# =============================================================================
set -euo pipefail

PROJECT_ID="${GCP_PROJECT_ID:-travelhub-g09}"
POLICY_NAME="travelhub-security-policy"

echo "=== Habilitando Cloud Armor API ==="
gcloud services enable compute.googleapis.com --project=${PROJECT_ID}

echo "=== Creando política de seguridad ==="
gcloud compute security-policies create ${POLICY_NAME} \
  --project=${PROJECT_ID} \
  --description="TravelHub WAF + DDoS protection policy"

# ─────────────────────────────────────────────────────────────────────────────
# REGLA 1: Bloquear SQL Injection (OWASP CRS - sqli)
# Mitiga: STRIDE Tampering, AH007
# ─────────────────────────────────────────────────────────────────────────────
echo "=== Regla 1: Bloquear SQL Injection ==="
gcloud compute security-policies rules create 1000 \
  --security-policy=${POLICY_NAME} \
  --expression="evaluatePreconfiguredExpr('sqli-v33-stable')" \
  --action=deny-403 \
  --description="Block SQL injection attempts (OWASP CRS)" \
  --project=${PROJECT_ID}

# ─────────────────────────────────────────────────────────────────────────────
# REGLA 2: Bloquear Cross-Site Scripting (XSS)
# Mitiga: STRIDE Tampering + Information Disclosure
# ─────────────────────────────────────────────────────────────────────────────
echo "=== Regla 2: Bloquear XSS ==="
gcloud compute security-policies rules create 1100 \
  --security-policy=${POLICY_NAME} \
  --expression="evaluatePreconfiguredExpr('xss-v33-stable')" \
  --action=deny-403 \
  --description="Block cross-site scripting attacks (OWASP CRS)" \
  --project=${PROJECT_ID}

# ─────────────────────────────────────────────────────────────────────────────
# REGLA 3: Bloquear Local File Inclusion (LFI)
# Mitiga: STRIDE Information Disclosure
# ─────────────────────────────────────────────────────────────────────────────
echo "=== Regla 3: Bloquear LFI ==="
gcloud compute security-policies rules create 1200 \
  --security-policy=${POLICY_NAME} \
  --expression="evaluatePreconfiguredExpr('lfi-v33-stable')" \
  --action=deny-403 \
  --description="Block local file inclusion attacks" \
  --project=${PROJECT_ID}

# ─────────────────────────────────────────────────────────────────────────────
# REGLA 4: Bloquear Remote File Inclusion (RFI)
# Mitiga: STRIDE Elevation of Privilege
# ─────────────────────────────────────────────────────────────────────────────
echo "=== Regla 4: Bloquear RFI ==="
gcloud compute security-policies rules create 1300 \
  --security-policy=${POLICY_NAME} \
  --expression="evaluatePreconfiguredExpr('rfi-v33-stable')" \
  --action=deny-403 \
  --description="Block remote file inclusion attacks" \
  --project=${PROJECT_ID}

# ─────────────────────────────────────────────────────────────────────────────
# REGLA 5: Bloquear Remote Code Execution (RCE) / Protocol attacks
# Mitiga: STRIDE Elevation of Privilege
# ─────────────────────────────────────────────────────────────────────────────
echo "=== Regla 5: Bloquear Protocol Attacks ==="
gcloud compute security-policies rules create 1400 \
  --security-policy=${POLICY_NAME} \
  --expression="evaluatePreconfiguredExpr('protocolattack-v33-stable')" \
  --action=deny-403 \
  --description="Block protocol-level attacks" \
  --project=${PROJECT_ID}

# ─────────────────────────────────────────────────────────────────────────────
# REGLA 6: Bloquear Session Fixation
# Mitiga: STRIDE Spoofing
# ─────────────────────────────────────────────────────────────────────────────
echo "=== Regla 6: Bloquear Session Fixation ==="
gcloud compute security-policies rules create 1500 \
  --security-policy=${POLICY_NAME} \
  --expression="evaluatePreconfiguredExpr('sessionfixation-v33-stable')" \
  --action=deny-403 \
  --description="Block session fixation attacks" \
  --project=${PROJECT_ID}

# ─────────────────────────────────────────────────────────────────────────────
# REGLA 7: Rate Limiting GLOBAL (resuelve debilidad PF1)
# 100 requests por IP por minuto — aplica a TODAS las IPs
# ─────────────────────────────────────────────────────────────────────────────
echo "=== Regla 7: Rate Limiting Global por IP ==="
gcloud compute security-policies rules create 2000 \
  --security-policy=${POLICY_NAME} \
  --src-ip-ranges="*" \
  --action=throttle \
  --rate-limit-threshold-count=100 \
  --rate-limit-threshold-interval-sec=60 \
  --conform-action=allow \
  --exceed-action=deny-429 \
  --enforce-on-key=IP \
  --description="Global rate limiting: 100 req/min per IP (fixes PF1 gap)" \
  --project=${PROJECT_ID}

# ─────────────────────────────────────────────────────────────────────────────
# REGLA 8: Rate Limiting estricto para endpoint de login (anti brute-force)
# 10 requests por IP por minuto al login — mitiga AH008
# ─────────────────────────────────────────────────────────────────────────────
echo "=== Regla 8: Rate Limiting Login (anti brute-force) ==="
gcloud compute security-policies rules create 2100 \
  --security-policy=${POLICY_NAME} \
  --expression="request.path.matches('/api/v1/auth/login')" \
  --action=throttle \
  --rate-limit-threshold-count=10 \
  --rate-limit-threshold-interval-sec=60 \
  --conform-action=allow \
  --exceed-action=deny-429 \
  --enforce-on-key=IP \
  --description="Strict rate limit on login: 10 req/min per IP (AH008)" \
  --project=${PROJECT_ID}

# ─────────────────────────────────────────────────────────────────────────────
# REGLA 9: Rate Limiting para endpoint de pagos
# 20 requests por IP por minuto — protección adicional PCI-DSS
# ─────────────────────────────────────────────────────────────────────────────
echo "=== Regla 9: Rate Limiting Pagos ==="
gcloud compute security-policies rules create 2200 \
  --security-policy=${POLICY_NAME} \
  --expression="request.path.matches('/api/v1/payments/.*')" \
  --action=throttle \
  --rate-limit-threshold-count=20 \
  --rate-limit-threshold-interval-sec=60 \
  --conform-action=allow \
  --exceed-action=deny-429 \
  --enforce-on-key=IP \
  --description="Rate limit on payments: 20 req/min per IP (PCI-DSS)" \
  --project=${PROJECT_ID}

# ─────────────────────────────────────────────────────────────────────────────
# REGLA 10: Geo-blocking — Permitir solo LATAM + regiones de negocio
# TravelHub opera en: CO, PE, EC, MX, CL, AR + US/EU para turismo
# ─────────────────────────────────────────────────────────────────────────────
echo "=== Regla 10: Geo-blocking (permitir regiones de operación) ==="
gcloud compute security-policies rules create 3000 \
  --security-policy=${POLICY_NAME} \
  --expression="!origin.region_code.matches('CO|PE|EC|MX|CL|AR|US|BR|ES|FR|DE|GB|IT')" \
  --action=deny-403 \
  --description="Block traffic from non-operational regions" \
  --project=${PROJECT_ID}

# ─────────────────────────────────────────────────────────────────────────────
# REGLA DEFAULT: Permitir tráfico legítimo
# ─────────────────────────────────────────────────────────────────────────────
echo "=== Actualizando regla default (allow) ==="
gcloud compute security-policies rules update 2147483647 \
  --security-policy=${POLICY_NAME} \
  --action=allow \
  --description="Default: allow legitimate traffic" \
  --project=${PROJECT_ID}

echo ""
echo "============================================"
echo "✅ Cloud Armor policy '${POLICY_NAME}' created"
echo "============================================"
echo "Rules configured:"
echo "  1000 - Block SQLi"
echo "  1100 - Block XSS"
echo "  1200 - Block LFI"
echo "  1300 - Block RFI"
echo "  1400 - Block Protocol Attacks"
echo "  1500 - Block Session Fixation"
echo "  2000 - Rate Limit Global: 100 req/min/IP"
echo "  2100 - Rate Limit Login: 10 req/min/IP"
echo "  2200 - Rate Limit Payments: 20 req/min/IP"
echo "  3000 - Geo-blocking (LATAM + business regions)"
echo "============================================"
```

---

### 8.2 — Habilitar protección adaptativa contra DDoS

Crear el archivo `cloud-armor/adaptive-protection.sh`:

```bash
#!/bin/bash
# =============================================================================
# TravelHub — Cloud Armor Adaptive Protection
# =============================================================================
# Activa la protección adaptativa que usa ML para detectar ataques DDoS L7.
# Genera alertas automáticas y puede sugerir reglas de bloqueo.
# =============================================================================
set -euo pipefail

PROJECT_ID="${GCP_PROJECT_ID:-travelhub-g09}"
POLICY_NAME="travelhub-security-policy"

echo "=== Habilitando Adaptive Protection ==="
gcloud compute security-policies update ${POLICY_NAME} \
  --enable-layer7-ddos-defense \
  --project=${PROJECT_ID}

echo "=== Configurando logging detallado ==="
gcloud compute security-policies update ${POLICY_NAME} \
  --log-level=VERBOSE \
  --project=${PROJECT_ID}

echo ""
echo "✅ Adaptive Protection habilitada"
echo "   - Detección de anomalías L7 con ML"
echo "   - Alertas automáticas en Cloud Monitoring"
echo "   - Logging verbose para auditoría"
```

---

### 8.3 — Asociar Cloud Armor al Load Balancer

Crear el archivo `deploy/deploy-cloud-armor.sh`:

```bash
#!/bin/bash
# =============================================================================
# Asociar la política Cloud Armor al backend service del Load Balancer
# =============================================================================
set -euo pipefail

PROJECT_ID="${GCP_PROJECT_ID:-travelhub-g09}"
POLICY_NAME="travelhub-security-policy"
BACKEND_SERVICE="${BACKEND_SERVICE_NAME:-travelhub-backend-service}"

echo "=== Asociando Cloud Armor al Backend Service ==="
gcloud compute backend-services update ${BACKEND_SERVICE} \
  --security-policy=${POLICY_NAME} \
  --global \
  --project=${PROJECT_ID}

echo ""
echo "✅ Cloud Armor '${POLICY_NAME}' asociado a '${BACKEND_SERVICE}'"
echo ""
echo "Verificar con:"
echo "  gcloud compute backend-services describe ${BACKEND_SERVICE} --global --format='value(securityPolicy)'"
```

---

## 9. VPC Firewall — Segmentación de Red

La VPC y las reglas de firewall segmentan la red para que los microservicios solo se comuniquen entre sí de forma controlada. Cada capa de la arquitectura vive en su propia subnet.

### 9.1 — Crear la VPC y Subnets

Crear el archivo `firewall/vpc-setup.sh`:

```bash
#!/bin/bash
# =============================================================================
# TravelHub — VPC y Subnets para segmentación de red
# =============================================================================
# Arquitectura de red:
#   - subnet-public:    Load Balancer, API Gateway (acceso desde internet)
#   - subnet-services:  Cloud Run microservicios (solo acceso interno)
#   - subnet-data:      PostgreSQL, Redis, Elasticsearch, Kafka (aislada)
# =============================================================================
set -euo pipefail

PROJECT_ID="${GCP_PROJECT_ID:-travelhub-g09}"
REGION_1="${GCP_REGION_1:-us-central1}"
REGION_2="${GCP_REGION_2:-southamerica-east1}"
VPC_NAME="travelhub-vpc"

echo "=== Creando VPC ==="
gcloud compute networks create ${VPC_NAME} \
  --subnet-mode=custom \
  --bgp-routing-mode=global \
  --project=${PROJECT_ID}

# ─────────────────────────────────────────────
# Region 1 — Subnets
# ─────────────────────────────────────────────
echo "=== Creando subnets Region 1 (${REGION_1}) ==="

# Subnet pública — Load Balancer y API Gateway
gcloud compute networks subnets create subnet-public-r1 \
  --network=${VPC_NAME} \
  --region=${REGION_1} \
  --range=10.10.1.0/24 \
  --purpose=PRIVATE \
  --project=${PROJECT_ID}

# Subnet de servicios — Cloud Run microservicios
gcloud compute networks subnets create subnet-services-r1 \
  --network=${VPC_NAME} \
  --region=${REGION_1} \
  --range=10.10.2.0/24 \
  --purpose=PRIVATE \
  --enable-private-ip-google-access \
  --project=${PROJECT_ID}

# Subnet de datos — PostgreSQL, Redis, Elasticsearch, Kafka
gcloud compute networks subnets create subnet-data-r1 \
  --network=${VPC_NAME} \
  --region=${REGION_1} \
  --range=10.10.3.0/24 \
  --purpose=PRIVATE \
  --enable-private-ip-google-access \
  --project=${PROJECT_ID}

# ─────────────────────────────────────────────
# Region 2 — Subnets (réplica activo-activo)
# ─────────────────────────────────────────────
echo "=== Creando subnets Region 2 (${REGION_2}) ==="

gcloud compute networks subnets create subnet-public-r2 \
  --network=${VPC_NAME} \
  --region=${REGION_2} \
  --range=10.20.1.0/24 \
  --purpose=PRIVATE \
  --project=${PROJECT_ID}

gcloud compute networks subnets create subnet-services-r2 \
  --network=${VPC_NAME} \
  --region=${REGION_2} \
  --range=10.20.2.0/24 \
  --purpose=PRIVATE \
  --enable-private-ip-google-access \
  --project=${PROJECT_ID}

gcloud compute networks subnets create subnet-data-r2 \
  --network=${VPC_NAME} \
  --region=${REGION_2} \
  --range=10.20.3.0/24 \
  --purpose=PRIVATE \
  --enable-private-ip-google-access \
  --project=${PROJECT_ID}

# ─────────────────────────────────────────────
# Connector para Cloud Run → VPC
# Cloud Run necesita un Serverless VPC Access Connector
# para comunicarse con recursos en la VPC (Redis, PostgreSQL)
# ─────────────────────────────────────────────
echo "=== Creando VPC Access Connectors para Cloud Run ==="

gcloud compute networks vpc-access connectors create travelhub-connector-r1 \
  --region=${REGION_1} \
  --network=${VPC_NAME} \
  --range=10.10.8.0/28 \
  --min-instances=2 \
  --max-instances=10 \
  --project=${PROJECT_ID}

gcloud compute networks vpc-access connectors create travelhub-connector-r2 \
  --region=${REGION_2} \
  --network=${VPC_NAME} \
  --range=10.20.8.0/28 \
  --min-instances=2 \
  --max-instances=10 \
  --project=${PROJECT_ID}

echo ""
echo "============================================"
echo "✅ VPC '${VPC_NAME}' created with subnets"
echo "============================================"
echo "Region 1 (${REGION_1}):"
echo "  subnet-public-r1:    10.10.1.0/24"
echo "  subnet-services-r1:  10.10.2.0/24"
echo "  subnet-data-r1:      10.10.3.0/24"
echo "  connector:           10.10.8.0/28"
echo ""
echo "Region 2 (${REGION_2}):"
echo "  subnet-public-r2:    10.20.1.0/24"
echo "  subnet-services-r2:  10.20.2.0/24"
echo "  subnet-data-r2:      10.20.3.0/24"
echo "  connector:           10.20.8.0/28"
echo "============================================"
```

---

### 9.2 — Reglas de Firewall

Crear el archivo `firewall/firewall-rules.sh`:

```bash
#!/bin/bash
# =============================================================================
# TravelHub — Reglas de Firewall VPC
# =============================================================================
# Principio: DENY ALL por defecto, permitir solo lo necesario.
#
# Capas:
#   subnet-public    → Solo recibe tráfico HTTPS (443) desde internet
#   subnet-services  → Solo recibe tráfico desde subnet-public (gateway)
#   subnet-data      → Solo recibe tráfico desde subnet-services
#
# Los microservicios NO son accesibles directamente desde internet.
# Solo el Load Balancer + API Gateway están expuestos.
# =============================================================================
set -euo pipefail

PROJECT_ID="${GCP_PROJECT_ID:-travelhub-g09}"
VPC_NAME="travelhub-vpc"

# ─────────────────────────────────────────────────────────────────────────────
# REGLA 0: Bloquear todo el tráfico SSH desde internet (seguridad base)
# ─────────────────────────────────────────────────────────────────────────────
echo "=== FW-000: Deny SSH from internet ==="
gcloud compute firewall-rules create fw-deny-ssh-internet \
  --network=${VPC_NAME} \
  --direction=INGRESS \
  --priority=100 \
  --action=DENY \
  --rules=tcp:22 \
  --source-ranges=0.0.0.0/0 \
  --description="Block SSH access from internet" \
  --project=${PROJECT_ID}

# ─────────────────────────────────────────────────────────────────────────────
# REGLA 1: Permitir HTTPS (443) hacia el Load Balancer
# Tráfico de internet → subnet-public (LB + API Gateway)
# ─────────────────────────────────────────────────────────────────────────────
echo "=== FW-001: Allow HTTPS to Load Balancer ==="
gcloud compute firewall-rules create fw-allow-https-lb \
  --network=${VPC_NAME} \
  --direction=INGRESS \
  --priority=1000 \
  --action=ALLOW \
  --rules=tcp:443 \
  --source-ranges=0.0.0.0/0 \
  --target-tags=load-balancer \
  --description="Allow HTTPS from internet to Load Balancer" \
  --project=${PROJECT_ID}

# ─────────────────────────────────────────────────────────────────────────────
# REGLA 2: Permitir Health Checks de GCP
# GCP necesita verificar la salud de los backend services
# ─────────────────────────────────────────────────────────────────────────────
echo "=== FW-002: Allow GCP Health Checks ==="
gcloud compute firewall-rules create fw-allow-health-checks \
  --network=${VPC_NAME} \
  --direction=INGRESS \
  --priority=1100 \
  --action=ALLOW \
  --rules=tcp:8000,tcp:8080 \
  --source-ranges=130.211.0.0/22,35.191.0.0/16 \
  --target-tags=cloud-run-service \
  --description="Allow GCP health check probes" \
  --project=${PROJECT_ID}

# ─────────────────────────────────────────────────────────────────────────────
# REGLA 3: Permitir tráfico del Gateway → Microservicios
# subnet-public → subnet-services en puerto 8000 (FastAPI)
# ─────────────────────────────────────────────────────────────────────────────
echo "=== FW-003: Allow Gateway to Microservices ==="
gcloud compute firewall-rules create fw-allow-gateway-to-services \
  --network=${VPC_NAME} \
  --direction=INGRESS \
  --priority=1200 \
  --action=ALLOW \
  --rules=tcp:8000 \
  --source-ranges=10.10.1.0/24,10.20.1.0/24 \
  --target-tags=cloud-run-service \
  --description="Allow API Gateway to reach Cloud Run services on port 8000" \
  --project=${PROJECT_ID}

# ─────────────────────────────────────────────────────────────────────────────
# REGLA 4: Permitir Microservicios → Capa de Datos
# subnet-services → subnet-data
#   PostgreSQL: 5432
#   Redis:      6379
#   Elasticsearch: 9200
#   Kafka:      9092
# ─────────────────────────────────────────────────────────────────────────────
echo "=== FW-004: Allow Services to Data Layer ==="
gcloud compute firewall-rules create fw-allow-services-to-data \
  --network=${VPC_NAME} \
  --direction=INGRESS \
  --priority=1300 \
  --action=ALLOW \
  --rules=tcp:5432,tcp:6379,tcp:9200,tcp:9092 \
  --source-ranges=10.10.2.0/24,10.20.2.0/24 \
  --target-tags=data-layer \
  --description="Allow microservices to reach PostgreSQL(5432), Redis(6379), Elasticsearch(9200), Kafka(9092)" \
  --project=${PROJECT_ID}

# ─────────────────────────────────────────────────────────────────────────────
# REGLA 5: Permitir comunicación inter-microservicios
# Los servicios pueden llamarse entre sí (ej. booking → payments)
# ─────────────────────────────────────────────────────────────────────────────
echo "=== FW-005: Allow Inter-Service Communication ==="
gcloud compute firewall-rules create fw-allow-inter-service \
  --network=${VPC_NAME} \
  --direction=INGRESS \
  --priority=1400 \
  --action=ALLOW \
  --rules=tcp:8000 \
  --source-tags=cloud-run-service \
  --target-tags=cloud-run-service \
  --description="Allow Cloud Run services to communicate with each other" \
  --project=${PROJECT_ID}

# ─────────────────────────────────────────────────────────────────────────────
# REGLA 6: Permitir replicación entre regiones (capa de datos)
# subnet-data-r1 ↔ subnet-data-r2 para PostgreSQL streaming replication
# y Kafka mirroring
# ─────────────────────────────────────────────────────────────────────────────
echo "=== FW-006: Allow Cross-Region Data Replication ==="
gcloud compute firewall-rules create fw-allow-data-replication \
  --network=${VPC_NAME} \
  --direction=INGRESS \
  --priority=1500 \
  --action=ALLOW \
  --rules=tcp:5432,tcp:9092 \
  --source-ranges=10.10.3.0/24,10.20.3.0/24 \
  --target-tags=data-layer \
  --description="Allow cross-region replication for PostgreSQL and Kafka" \
  --project=${PROJECT_ID}

# ─────────────────────────────────────────────────────────────────────────────
# REGLA 7: DENY ALL — Bloquear cualquier otro tráfico ingress
# Prioridad baja (65534) — todo lo que no matchee arriba se bloquea
# ─────────────────────────────────────────────────────────────────────────────
echo "=== FW-007: Deny All Other Ingress ==="
gcloud compute firewall-rules create fw-deny-all-ingress \
  --network=${VPC_NAME} \
  --direction=INGRESS \
  --priority=65534 \
  --action=DENY \
  --rules=all \
  --source-ranges=0.0.0.0/0 \
  --description="Default deny: block all ingress not explicitly allowed" \
  --project=${PROJECT_ID}

# ─────────────────────────────────────────────────────────────────────────────
# REGLA 8: Egress — Permitir salida a servicios externos
# Los microservicios necesitan alcanzar: Stripe, PMS, Email, APIs externas
# ─────────────────────────────────────────────────────────────────────────────
echo "=== FW-008: Allow Egress to External Services ==="
gcloud compute firewall-rules create fw-allow-egress-external \
  --network=${VPC_NAME} \
  --direction=EGRESS \
  --priority=1000 \
  --action=ALLOW \
  --rules=tcp:443 \
  --destination-ranges=0.0.0.0/0 \
  --target-tags=cloud-run-service \
  --description="Allow HTTPS egress to external services (Stripe, PMS, Email)" \
  --project=${PROJECT_ID}

# ─────────────────────────────────────────────────────────────────────────────
# REGLA 9: Egress — Bloquear salida no HTTPS desde capa de datos
# La capa de datos NO debe tener salida a internet
# ─────────────────────────────────────────────────────────────────────────────
echo "=== FW-009: Deny Egress from Data Layer to Internet ==="
gcloud compute firewall-rules create fw-deny-data-egress \
  --network=${VPC_NAME} \
  --direction=EGRESS \
  --priority=1000 \
  --action=DENY \
  --rules=all \
  --destination-ranges=0.0.0.0/0 \
  --target-tags=data-layer \
  --description="Block all egress from data layer to internet" \
  --project=${PROJECT_ID}

echo ""
echo "============================================"
echo "✅ Firewall rules created for '${VPC_NAME}'"
echo "============================================"
echo "Ingress rules:"
echo "  FW-000 [P100]   DENY  SSH from internet"
echo "  FW-001 [P1000]  ALLOW HTTPS (443) → Load Balancer"
echo "  FW-002 [P1100]  ALLOW GCP Health Checks → Services"
echo "  FW-003 [P1200]  ALLOW Gateway → Microservices (8000)"
echo "  FW-004 [P1300]  ALLOW Services → Data (5432,6379,9200,9092)"
echo "  FW-005 [P1400]  ALLOW Inter-service (8000)"
echo "  FW-006 [P1500]  ALLOW Cross-region data replication"
echo "  FW-007 [P65534] DENY  All other ingress"
echo ""
echo "Egress rules:"
echo "  FW-008 [P1000]  ALLOW Services → External HTTPS (443)"
echo "  FW-009 [P1000]  DENY  Data layer → Internet"
echo "============================================"
```

---

### 9.3 — Configurar acceso privado a servicios GCP

Crear el archivo `firewall/private-access.sh`:

```bash
#!/bin/bash
# =============================================================================
# TravelHub — Private Google Access + Private Service Connect
# =============================================================================
# Asegura que los servicios GCP internos (Cloud SQL, MemoryStore, etc.)
# sean accesibles solo por IP privada, sin pasar por internet.
# =============================================================================
set -euo pipefail

PROJECT_ID="${GCP_PROJECT_ID:-travelhub-g09}"
VPC_NAME="travelhub-vpc"
REGION_1="${GCP_REGION_1:-us-central1}"
REGION_2="${GCP_REGION_2:-southamerica-east1}"

# ─────────────────────────────────────────────
# Habilitar Private Google Access en subnets de datos
# Los servicios managed (Cloud SQL, MemoryStore) usan IPs privadas
# ─────────────────────────────────────────────
echo "=== Habilitando Private Google Access ==="
gcloud compute networks subnets update subnet-data-r1 \
  --region=${REGION_1} \
  --enable-private-ip-google-access \
  --project=${PROJECT_ID}

gcloud compute networks subnets update subnet-data-r2 \
  --region=${REGION_2} \
  --enable-private-ip-google-access \
  --project=${PROJECT_ID}

# ─────────────────────────────────────────────
# Reservar rango de IP para Private Service Connection
# Usado por Cloud SQL y MemoryStore
# ─────────────────────────────────────────────
echo "=== Reservando rango para Private Service Connection ==="
gcloud compute addresses create travelhub-private-range \
  --global \
  --purpose=VPC_PEERING \
  --addresses=10.100.0.0 \
  --prefix-length=20 \
  --network=${VPC_NAME} \
  --project=${PROJECT_ID}

echo "=== Creando Private Service Connection ==="
gcloud services vpc-peerings connect \
  --service=servicenetworking.googleapis.com \
  --ranges=travelhub-private-range \
  --network=${VPC_NAME} \
  --project=${PROJECT_ID}

echo ""
echo "✅ Private access configured"
echo "   - Cloud SQL accesible solo por IP privada"
echo "   - MemoryStore (Redis) accesible solo por IP privada"
echo "   - Sin exposición a internet de la capa de datos"
```

---

## 10. Tests de Infraestructura de Seguridad

### 10.1 — Tests de Cloud Armor

Crear el archivo `tests/test_cloud_armor.sh`:

```bash
#!/bin/bash
# =============================================================================
# Tests de validación de reglas Cloud Armor
# Ejecutar después del despliegue para verificar que las reglas funcionan.
# =============================================================================
set -euo pipefail

GATEWAY_URL="${GATEWAY_URL:-https://travelhub-gateway-HASH-uc.a.run.app}"
PASS=0
FAIL=0

run_test() {
  local name="$1"
  local expected="$2"
  local actual="$3"
  if [ "$actual" == "$expected" ]; then
    echo "  ✅ PASS: ${name} (got ${actual})"
    ((PASS++))
  else
    echo "  ❌ FAIL: ${name} (expected ${expected}, got ${actual})"
    ((FAIL++))
  fi
}

echo "=== Testing Cloud Armor Rules ==="
echo ""

# Test 1: SQL Injection debe ser bloqueado (403)
echo "--- Test SQLi Protection ---"
STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
  "${GATEWAY_URL}/api/v1/search/hotels?q=1'%20OR%201=1--")
run_test "SQLi blocked" "403" "${STATUS}"

# Test 2: XSS debe ser bloqueado (403)
echo "--- Test XSS Protection ---"
STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
  "${GATEWAY_URL}/api/v1/search/hotels?q=<script>alert(1)</script>")
run_test "XSS blocked" "403" "${STATUS}"

# Test 3: Rate limiting en login (>10 req/min → 429)
echo "--- Test Login Rate Limiting ---"
for i in $(seq 1 12); do
  STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST "${GATEWAY_URL}/api/v1/auth/login" \
    -H "Content-Type: application/json" \
    -d '{"email":"test@test.com","password":"wrong"}')
  if [ "$i" -gt 10 ] && [ "$STATUS" == "429" ]; then
    run_test "Login rate limit triggered at request ${i}" "429" "${STATUS}"
    break
  fi
done

# Test 4: Tráfico normal debe pasar (200 o 401 sin JWT)
echo "--- Test Normal Traffic ---"
STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
  "${GATEWAY_URL}/.well-known/jwks.json")
run_test "JWKS public endpoint accessible" "200" "${STATUS}"

# Test 5: LFI debe ser bloqueado
echo "--- Test LFI Protection ---"
STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
  "${GATEWAY_URL}/api/v1/search/../../etc/passwd")
run_test "LFI blocked" "403" "${STATUS}"

echo ""
echo "============================================"
echo "Results: ${PASS} passed, ${FAIL} failed"
echo "============================================"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
```

### 10.2 — Tests de Firewall

Crear el archivo `tests/test_firewall_rules.sh`:

```bash
#!/bin/bash
# =============================================================================
# Tests de validación de reglas de Firewall VPC
# Ejecutar desde una instancia dentro de la VPC.
# =============================================================================
set -euo pipefail

PROJECT_ID="${GCP_PROJECT_ID:-travelhub-g09}"
VPC_NAME="travelhub-vpc"

echo "=== Verificando reglas de firewall ==="
echo ""

# Listar todas las reglas
echo "--- Reglas configuradas ---"
gcloud compute firewall-rules list \
  --filter="network=${VPC_NAME}" \
  --format="table(name, direction, priority, allowed[].map().firewall_rule().list():label=ALLOWED, sourceRanges.list():label=SRC_RANGES, targetTags.list():label=TARGETS)" \
  --project=${PROJECT_ID}

echo ""

# Verificar que SSH está bloqueado
echo "--- Verificando SSH bloqueado ---"
SSH_RULE=$(gcloud compute firewall-rules describe fw-deny-ssh-internet \
  --format="value(disabled)" \
  --project=${PROJECT_ID} 2>/dev/null)
if [ "$SSH_RULE" != "True" ]; then
  echo "  ✅ SSH deny rule is active"
else
  echo "  ❌ SSH deny rule is DISABLED"
fi

# Verificar que deny-all-ingress existe
echo "--- Verificando deny-all-ingress ---"
DENY_ALL=$(gcloud compute firewall-rules describe fw-deny-all-ingress \
  --format="value(priority)" \
  --project=${PROJECT_ID} 2>/dev/null)
if [ "$DENY_ALL" == "65534" ]; then
  echo "  ✅ Deny-all-ingress rule at priority 65534"
else
  echo "  ❌ Deny-all-ingress rule not found or wrong priority"
fi

# Verificar que data layer no tiene egress a internet
echo "--- Verificando data layer egress blocked ---"
DATA_EGRESS=$(gcloud compute firewall-rules describe fw-deny-data-egress \
  --format="value(direction)" \
  --project=${PROJECT_ID} 2>/dev/null)
if [ "$DATA_EGRESS" == "EGRESS" ]; then
  echo "  ✅ Data layer egress to internet is blocked"
else
  echo "  ❌ Data layer egress rule not found"
fi

echo ""
echo "=== Firewall validation complete ==="
```

---

## 11. Terraform — IaC Consolidado (Opcional)

Para quienes prefieran Infrastructure as Code, aquí los módulos Terraform.

### 11.1 — `deploy/terraform/cloud_armor.tf`

```hcl
# =============================================================================
# TravelHub — Cloud Armor via Terraform
# =============================================================================

resource "google_compute_security_policy" "travelhub" {
  name        = "travelhub-security-policy"
  description = "TravelHub WAF + DDoS protection"
  project     = var.project_id

  # Adaptive Protection (DDoS L7)
  adaptive_protection_config {
    layer_7_ddos_defense_config {
      enable = true
    }
  }

  # Rule: Block SQLi
  rule {
    action   = "deny(403)"
    priority = 1000
    match {
      expr {
        expression = "evaluatePreconfiguredExpr('sqli-v33-stable')"
      }
    }
    description = "Block SQL injection"
  }

  # Rule: Block XSS
  rule {
    action   = "deny(403)"
    priority = 1100
    match {
      expr {
        expression = "evaluatePreconfiguredExpr('xss-v33-stable')"
      }
    }
    description = "Block XSS"
  }

  # Rule: Block LFI
  rule {
    action   = "deny(403)"
    priority = 1200
    match {
      expr {
        expression = "evaluatePreconfiguredExpr('lfi-v33-stable')"
      }
    }
    description = "Block LFI"
  }

  # Rule: Block RFI
  rule {
    action   = "deny(403)"
    priority = 1300
    match {
      expr {
        expression = "evaluatePreconfiguredExpr('rfi-v33-stable')"
      }
    }
    description = "Block RFI"
  }

  # Rule: Rate limit global (100 req/min/IP)
  rule {
    action   = "throttle"
    priority = 2000
    match {
      versioned_expr = "SRC_IPS_V1"
      config {
        src_ip_ranges = ["*"]
      }
    }
    rate_limit_options {
      conform_action = "allow"
      exceed_action  = "deny(429)"
      rate_limit_threshold {
        count        = 100
        interval_sec = 60
      }
      enforce_on_key = "IP"
    }
    description = "Global rate limit: 100 req/min/IP"
  }

  # Rule: Rate limit login (10 req/min/IP)
  rule {
    action   = "throttle"
    priority = 2100
    match {
      expr {
        expression = "request.path.matches('/api/v1/auth/login')"
      }
    }
    rate_limit_options {
      conform_action = "allow"
      exceed_action  = "deny(429)"
      rate_limit_threshold {
        count        = 10
        interval_sec = 60
      }
      enforce_on_key = "IP"
    }
    description = "Login rate limit: 10 req/min/IP"
  }

  # Rule: Geo-blocking
  rule {
    action   = "deny(403)"
    priority = 3000
    match {
      expr {
        expression = "!origin.region_code.matches('CO|PE|EC|MX|CL|AR|US|BR|ES|FR|DE|GB|IT')"
      }
    }
    description = "Block non-operational regions"
  }

  # Default: Allow
  rule {
    action   = "allow"
    priority = 2147483647
    match {
      versioned_expr = "SRC_IPS_V1"
      config {
        src_ip_ranges = ["*"]
      }
    }
    description = "Default allow"
  }
}
```

### 11.2 — `deploy/terraform/vpc.tf`

```hcl
# =============================================================================
# TravelHub — VPC + Subnets
# =============================================================================

resource "google_compute_network" "travelhub" {
  name                    = "travelhub-vpc"
  auto_create_subnetworks = false
  routing_mode            = "GLOBAL"
  project                 = var.project_id
}

# Region 1 subnets
resource "google_compute_subnetwork" "public_r1" {
  name                     = "subnet-public-r1"
  ip_cidr_range            = "10.10.1.0/24"
  region                   = var.region_1
  network                  = google_compute_network.travelhub.id
  private_ip_google_access = false
}

resource "google_compute_subnetwork" "services_r1" {
  name                     = "subnet-services-r1"
  ip_cidr_range            = "10.10.2.0/24"
  region                   = var.region_1
  network                  = google_compute_network.travelhub.id
  private_ip_google_access = true
}

resource "google_compute_subnetwork" "data_r1" {
  name                     = "subnet-data-r1"
  ip_cidr_range            = "10.10.3.0/24"
  region                   = var.region_1
  network                  = google_compute_network.travelhub.id
  private_ip_google_access = true
}

# Region 2 subnets
resource "google_compute_subnetwork" "public_r2" {
  name                     = "subnet-public-r2"
  ip_cidr_range            = "10.20.1.0/24"
  region                   = var.region_2
  network                  = google_compute_network.travelhub.id
  private_ip_google_access = false
}

resource "google_compute_subnetwork" "services_r2" {
  name                     = "subnet-services-r2"
  ip_cidr_range            = "10.20.2.0/24"
  region                   = var.region_2
  network                  = google_compute_network.travelhub.id
  private_ip_google_access = true
}

resource "google_compute_subnetwork" "data_r2" {
  name                     = "subnet-data-r2"
  ip_cidr_range            = "10.20.3.0/24"
  region                   = var.region_2
  network                  = google_compute_network.travelhub.id
  private_ip_google_access = true
}

# VPC Access Connectors for Cloud Run
resource "google_vpc_access_connector" "connector_r1" {
  name          = "travelhub-connector-r1"
  region        = var.region_1
  network       = google_compute_network.travelhub.name
  ip_cidr_range = "10.10.8.0/28"
  min_instances = 2
  max_instances = 10
}

resource "google_vpc_access_connector" "connector_r2" {
  name          = "travelhub-connector-r2"
  region        = var.region_2
  network       = google_compute_network.travelhub.name
  ip_cidr_range = "10.20.8.0/28"
  min_instances = 2
  max_instances = 10
}
```

### 11.3 — `deploy/terraform/firewall.tf`

```hcl
# =============================================================================
# TravelHub — Firewall Rules
# =============================================================================

# Deny SSH from internet
resource "google_compute_firewall" "deny_ssh" {
  name      = "fw-deny-ssh-internet"
  network   = google_compute_network.travelhub.name
  direction = "INGRESS"
  priority  = 100

  deny {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = ["0.0.0.0/0"]
  description   = "Block SSH from internet"
}

# Allow HTTPS to Load Balancer
resource "google_compute_firewall" "allow_https_lb" {
  name      = "fw-allow-https-lb"
  network   = google_compute_network.travelhub.name
  direction = "INGRESS"
  priority  = 1000

  allow {
    protocol = "tcp"
    ports    = ["443"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["load-balancer"]
  description   = "Allow HTTPS to Load Balancer"
}

# Allow GCP Health Checks
resource "google_compute_firewall" "allow_health_checks" {
  name      = "fw-allow-health-checks"
  network   = google_compute_network.travelhub.name
  direction = "INGRESS"
  priority  = 1100

  allow {
    protocol = "tcp"
    ports    = ["8000", "8080"]
  }

  source_ranges = ["130.211.0.0/22", "35.191.0.0/16"]
  target_tags   = ["cloud-run-service"]
  description   = "Allow GCP health check probes"
}

# Allow Gateway to Microservices
resource "google_compute_firewall" "allow_gateway_to_services" {
  name      = "fw-allow-gateway-to-services"
  network   = google_compute_network.travelhub.name
  direction = "INGRESS"
  priority  = 1200

  allow {
    protocol = "tcp"
    ports    = ["8000"]
  }

  source_ranges = ["10.10.1.0/24", "10.20.1.0/24"]
  target_tags   = ["cloud-run-service"]
  description   = "Allow Gateway to Cloud Run services"
}

# Allow Services to Data Layer
resource "google_compute_firewall" "allow_services_to_data" {
  name      = "fw-allow-services-to-data"
  network   = google_compute_network.travelhub.name
  direction = "INGRESS"
  priority  = 1300

  allow {
    protocol = "tcp"
    ports    = ["5432", "6379", "9200", "9092"]
  }

  source_ranges = ["10.10.2.0/24", "10.20.2.0/24"]
  target_tags   = ["data-layer"]
  description   = "Allow services to PostgreSQL, Redis, Elasticsearch, Kafka"
}

# Allow Inter-Service Communication
resource "google_compute_firewall" "allow_inter_service" {
  name      = "fw-allow-inter-service"
  network   = google_compute_network.travelhub.name
  direction = "INGRESS"
  priority  = 1400

  allow {
    protocol = "tcp"
    ports    = ["8000"]
  }

  source_tags = ["cloud-run-service"]
  target_tags = ["cloud-run-service"]
  description = "Allow inter-service communication"
}

# Allow Cross-Region Data Replication
resource "google_compute_firewall" "allow_data_replication" {
  name      = "fw-allow-data-replication"
  network   = google_compute_network.travelhub.name
  direction = "INGRESS"
  priority  = 1500

  allow {
    protocol = "tcp"
    ports    = ["5432", "9092"]
  }

  source_ranges = ["10.10.3.0/24", "10.20.3.0/24"]
  target_tags   = ["data-layer"]
  description   = "Allow cross-region replication"
}

# Deny all other ingress
resource "google_compute_firewall" "deny_all_ingress" {
  name      = "fw-deny-all-ingress"
  network   = google_compute_network.travelhub.name
  direction = "INGRESS"
  priority  = 65534

  deny {
    protocol = "all"
  }

  source_ranges = ["0.0.0.0/0"]
  description   = "Default deny all ingress"
}

# Allow egress to external services (HTTPS only)
resource "google_compute_firewall" "allow_egress_external" {
  name      = "fw-allow-egress-external"
  network   = google_compute_network.travelhub.name
  direction = "EGRESS"
  priority  = 1000

  allow {
    protocol = "tcp"
    ports    = ["443"]
  }

  destination_ranges = ["0.0.0.0/0"]
  target_tags        = ["cloud-run-service"]
  description        = "Allow HTTPS egress to Stripe, PMS, Email"
}

# Deny egress from data layer
resource "google_compute_firewall" "deny_data_egress" {
  name      = "fw-deny-data-egress"
  network   = google_compute_network.travelhub.name
  direction = "EGRESS"
  priority  = 1000

  deny {
    protocol = "all"
  }

  destination_ranges = ["0.0.0.0/0"]
  target_tags        = ["data-layer"]
  description        = "Block data layer egress to internet"
}
```

### 11.4 — `deploy/terraform/variables.tf`

```hcl
variable "project_id" {
  description = "GCP Project ID"
  type        = string
  default     = "travelhub-g09"
}

variable "region_1" {
  description = "Primary region"
  type        = string
  default     = "us-central1"
}

variable "region_2" {
  description = "Secondary region (LATAM)"
  type        = string
  default     = "southamerica-east1"
}
```

---

## 12. Orden de Despliegue

Ejecutar los scripts en este orden para respetar las dependencias:

```bash
# Paso 1: VPC y Subnets (base de red)
bash firewall/vpc-setup.sh

# Paso 2: Reglas de Firewall (segmentación)
bash firewall/firewall-rules.sh

# Paso 3: Acceso privado a servicios managed
bash firewall/private-access.sh

# Paso 4: Cloud Armor (WAF en el borde)
bash cloud-armor/security-policy.sh
bash cloud-armor/adaptive-protection.sh

# Paso 5: Desplegar microservicios en Cloud Run (con VPC connector)
# Agregar --vpc-connector=travelhub-connector-r1 al deploy de cada servicio
bash deploy/deploy-jwks-service.sh

# Paso 6: API Gateway con JWT
bash deploy/deploy-gateway.sh

# Paso 7: Asociar Cloud Armor al Load Balancer
bash deploy/deploy-cloud-armor.sh

# Paso 8: Verificación
bash tests/test_cloud_armor.sh
bash tests/test_firewall_rules.sh
pytest tests/ -v --tb=short
```

---

## 13. Resumen de Capas de Seguridad — Defensa en Profundidad

```
Internet
   │
   ▼
┌──────────────────────────────────────────┐
│  CAPA 1: Cloud Armor (WAF)               │
│  - OWASP Top 10 (SQLi, XSS, LFI, RFI)  │
│  - Rate limiting distribuido por IP       │
│  - Rate limiting estricto en login/pagos │
│  - Geo-blocking (solo LATAM + business)  │
│  - DDoS L7 con Adaptive Protection (ML) │
└──────────────────────────────────────────┘
   │
   ▼
┌──────────────────────────────────────────┐
│  CAPA 2: VPC Firewall                    │
│  - DENY ALL por defecto                  │
│  - Solo HTTPS (443) desde internet → LB  │
│  - Gateway → Services (8000)             │
│  - Services → Data (5432,6379,9200,9092) │
│  - Data layer sin egress a internet      │
│  - SSH bloqueado desde internet           │
└──────────────────────────────────────────┘
   │
   ▼
┌──────────────────────────────────────────┐
│  CAPA 3: API Gateway                     │
│  - Validación JWT (firma RS256)          │
│  - Validación issuer + audience          │
│  - Validación expiración                 │
│  - Rutas públicas sin JWT (login, JWKS)  │
└──────────────────────────────────────────┘
   │
   ▼
┌──────────────────────────────────────────┐
│  CAPA 4: Chain of Responsibility (App)   │
│  - Rate limiting por usuario (backup)    │
│  - Validación IP / geolocalización       │
│  - RBAC por ruta y rol                   │
│  - MFA para operaciones sensibles        │
└──────────────────────────────────────────┘
   │
   ▼
  Cloud Run Microservices
```
