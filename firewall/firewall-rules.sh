#!/bin/bash
# =============================================================================
# TravelHub — Reglas de Firewall VPC
# =============================================================================
# Principio: DENY ALL por defecto, permitir solo lo necesario.
#
# Capas:
#   subnet-public    -> Solo recibe trafico HTTPS (443) desde internet
#   subnet-services  -> Solo recibe trafico desde subnet-public (gateway)
#   subnet-data      -> Solo recibe trafico desde subnet-services
#
# Los microservicios NO son accesibles directamente desde internet.
# Solo el Load Balancer + API Gateway estan expuestos.
# =============================================================================
set -euo pipefail

PROJECT_ID="${GCP_PROJECT_ID:-gen-lang-client-0930444414}"
VPC_NAME="${VPC_NAME:-travelhub-vpc}"

# ─────────────────────────────────────────────────────────────────────────────
# REGLA 0: Bloquear todo el trafico SSH desde internet (seguridad base)
# ─────────────────────────────────────────────────────────────────────────────
echo "=== FW-000: Deny SSH from internet ==="
gcloud compute firewall-rules create fw-deny-ssh-internet \
  --network="${VPC_NAME}" \
  --direction=INGRESS \
  --priority=100 \
  --action=DENY \
  --rules=tcp:22 \
  --source-ranges=0.0.0.0/0 \
  --description="Block SSH access from internet" \
  --project="${PROJECT_ID}"

# ─────────────────────────────────────────────────────────────────────────────
# REGLA 1: Permitir HTTPS (443) hacia el Load Balancer
# Trafico de internet -> subnet-public (LB + API Gateway)
# ─────────────────────────────────────────────────────────────────────────────
echo "=== FW-001: Allow HTTPS to Load Balancer ==="
gcloud compute firewall-rules create fw-allow-https-lb \
  --network="${VPC_NAME}" \
  --direction=INGRESS \
  --priority=1000 \
  --action=ALLOW \
  --rules=tcp:443 \
  --source-ranges=0.0.0.0/0 \
  --target-tags=load-balancer \
  --description="Allow HTTPS from internet to Load Balancer" \
  --project="${PROJECT_ID}"

# ─────────────────────────────────────────────────────────────────────────────
# REGLA 2: Permitir Health Checks de GCP
# GCP necesita verificar la salud de los backend services
# ─────────────────────────────────────────────────────────────────────────────
echo "=== FW-002: Allow GCP Health Checks ==="
gcloud compute firewall-rules create fw-allow-health-checks \
  --network="${VPC_NAME}" \
  --direction=INGRESS \
  --priority=1100 \
  --action=ALLOW \
  --rules=tcp:8000,tcp:8080 \
  --source-ranges=130.211.0.0/22,35.191.0.0/16 \
  --target-tags=cloud-run-service \
  --description="Allow GCP health check probes" \
  --project="${PROJECT_ID}"

# ─────────────────────────────────────────────────────────────────────────────
# REGLA 3: Permitir trafico del Gateway -> Microservicios
# subnet-public -> subnet-services en puerto 8000 (FastAPI)
# ─────────────────────────────────────────────────────────────────────────────
echo "=== FW-003: Allow Gateway to Microservices ==="
gcloud compute firewall-rules create fw-allow-gateway-to-services \
  --network="${VPC_NAME}" \
  --direction=INGRESS \
  --priority=1200 \
  --action=ALLOW \
  --rules=tcp:8000 \
  --source-ranges=10.10.1.0/24 \
  --target-tags=cloud-run-service \
  --description="Allow API Gateway to reach Cloud Run services on port 8000" \
  --project="${PROJECT_ID}"

# ─────────────────────────────────────────────────────────────────────────────
# REGLA 4: Permitir Microservicios -> Capa de Datos
# subnet-services -> subnet-data
#   PostgreSQL:    5432
#   Redis:         6379
#   Elasticsearch: 9200
#   Kafka:         9092
# ─────────────────────────────────────────────────────────────────────────────
echo "=== FW-004: Allow Services to Data Layer ==="
gcloud compute firewall-rules create fw-allow-services-to-data \
  --network="${VPC_NAME}" \
  --direction=INGRESS \
  --priority=1300 \
  --action=ALLOW \
  --rules=tcp:5432,tcp:6379,tcp:9200,tcp:9092 \
  --source-ranges=10.10.2.0/24 \
  --target-tags=data-layer \
  --description="Allow microservices to reach PostgreSQL(5432), Redis(6379), Elasticsearch(9200), Kafka(9092)" \
  --project="${PROJECT_ID}"

# ─────────────────────────────────────────────────────────────────────────────
# REGLA 5: Permitir comunicacion inter-microservicios
# Los servicios pueden llamarse entre si (ej. booking -> payments)
# ─────────────────────────────────────────────────────────────────────────────
echo "=== FW-005: Allow Inter-Service Communication ==="
gcloud compute firewall-rules create fw-allow-inter-service \
  --network="${VPC_NAME}" \
  --direction=INGRESS \
  --priority=1400 \
  --action=ALLOW \
  --rules=tcp:8000 \
  --source-tags=cloud-run-service \
  --target-tags=cloud-run-service \
  --description="Allow Cloud Run services to communicate with each other" \
  --project="${PROJECT_ID}"

# ─────────────────────────────────────────────────────────────────────────────
# REGLA 6: DENY ALL — Bloquear cualquier otro trafico ingress
# Prioridad baja (65534) — todo lo que no matchee arriba se bloquea
# ─────────────────────────────────────────────────────────────────────────────
echo "=== FW-006: Deny All Other Ingress ==="
gcloud compute firewall-rules create fw-deny-all-ingress \
  --network="${VPC_NAME}" \
  --direction=INGRESS \
  --priority=65534 \
  --action=DENY \
  --rules=all \
  --source-ranges=0.0.0.0/0 \
  --description="Default deny: block all ingress not explicitly allowed" \
  --project="${PROJECT_ID}"

# ─────────────────────────────────────────────────────────────────────────────
# REGLA 7: Egress — Permitir salida HTTPS a servicios externos
# Los microservicios necesitan alcanzar: Stripe, PMS, Email, APIs externas
# ─────────────────────────────────────────────────────────────────────────────
echo "=== FW-007: Allow Egress to External Services ==="
gcloud compute firewall-rules create fw-allow-egress-external \
  --network="${VPC_NAME}" \
  --direction=EGRESS \
  --priority=1000 \
  --action=ALLOW \
  --rules=tcp:443 \
  --destination-ranges=0.0.0.0/0 \
  --target-tags=cloud-run-service \
  --description="Allow HTTPS egress to external services (Stripe, PMS, Email)" \
  --project="${PROJECT_ID}"

# ─────────────────────────────────────────────────────────────────────────────
# REGLA 8: Egress — Bloquear salida desde capa de datos
# La capa de datos NO debe tener salida a internet
# ─────────────────────────────────────────────────────────────────────────────
echo "=== FW-008: Deny Egress from Data Layer to Internet ==="
gcloud compute firewall-rules create fw-deny-data-egress \
  --network="${VPC_NAME}" \
  --direction=EGRESS \
  --priority=1000 \
  --action=DENY \
  --rules=all \
  --destination-ranges=0.0.0.0/0 \
  --target-tags=data-layer \
  --description="Block all egress from data layer to internet" \
  --project="${PROJECT_ID}"

echo ""
echo "============================================"
echo "Firewall rules created for '${VPC_NAME}'"
echo "============================================"
echo "Project: ${PROJECT_ID}"
echo ""
echo "Ingress rules:"
echo "  FW-000 [P100]   DENY  SSH from internet"
echo "  FW-001 [P1000]  ALLOW HTTPS (443) -> Load Balancer"
echo "  FW-002 [P1100]  ALLOW GCP Health Checks -> Services"
echo "  FW-003 [P1200]  ALLOW Gateway -> Microservices (8000)"
echo "  FW-004 [P1300]  ALLOW Services -> Data (5432,6379,9200,9092)"
echo "  FW-005 [P1400]  ALLOW Inter-service (8000)"
echo "  FW-006 [P65534] DENY  All other ingress"
echo ""
echo "Egress rules:"
echo "  FW-007 [P1000]  ALLOW Services -> External HTTPS (443)"
echo "  FW-008 [P1000]  DENY  Data layer -> Internet"
echo "============================================"
