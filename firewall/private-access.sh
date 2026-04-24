#!/bin/bash
# =============================================================================
# TravelHub — Private Google Access + Private Service Connect
# =============================================================================
# Asegura que los servicios GCP internos (Cloud SQL, MemoryStore, etc.)
# sean accesibles solo por IP privada, sin pasar por internet.
# =============================================================================
set -euo pipefail

PROJECT_ID="${GCP_PROJECT_ID:-gen-lang-client-0930444414}"
VPC_NAME="${VPC_NAME:-travelhub-vpc}"
REGION="${GCP_REGION:-us-central1}"

# ─────────────────────────────────────────────
# Habilitar Private Google Access en subnet de datos
# Los servicios managed (Cloud SQL, MemoryStore) usan IPs privadas
# ─────────────────────────────────────────────
echo "=== Habilitando Private Google Access en subnet-data ==="
gcloud compute networks subnets update subnet-data \
  --region="${REGION}" \
  --enable-private-ip-google-access \
  --project="${PROJECT_ID}"

# ─────────────────────────────────────────────
# Habilitar API de Service Networking
# ─────────────────────────────────────────────
echo "=== Habilitando Service Networking API ==="
gcloud services enable servicenetworking.googleapis.com --project="${PROJECT_ID}"

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
  --network="${VPC_NAME}" \
  --project="${PROJECT_ID}"

echo "=== Creando Private Service Connection ==="
gcloud services vpc-peerings connect \
  --service=servicenetworking.googleapis.com \
  --ranges=travelhub-private-range \
  --network="${VPC_NAME}" \
  --project="${PROJECT_ID}"

echo ""
echo "============================================"
echo "Private access configured"
echo "============================================"
echo "Project: ${PROJECT_ID}"
echo "VPC:     ${VPC_NAME}"
echo "Region:  ${REGION}"
echo ""
echo "  - Cloud SQL accesible solo por IP privada"
echo "  - MemoryStore (Redis) accesible solo por IP privada"
echo "  - Sin exposicion a internet de la capa de datos"
echo "  - Rango reservado: 10.100.0.0/20"
echo "============================================"
