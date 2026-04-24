#!/bin/bash
# =============================================================================
# TravelHub — VPC y Subnets para segmentacion de red
# =============================================================================
# Arquitectura de red:
#   - subnet-public:    Load Balancer, API Gateway (acceso desde internet)
#   - subnet-services:  Cloud Run microservicios (solo acceso interno)
#   - subnet-data:      PostgreSQL, Redis, Elasticsearch, Kafka (aislada)
#
# Esquema CIDR:
#   10.10.1.0/24  = publica
#   10.10.2.0/24  = servicios
#   10.10.3.0/24  = datos
#   10.10.8.0/28  = VPC Access Connector (Cloud Run -> VPC)
# =============================================================================
set -euo pipefail

PROJECT_ID="${GCP_PROJECT_ID:-gen-lang-client-0930444414}"
REGION="${GCP_REGION:-us-central1}"
VPC_NAME="${VPC_NAME:-travelhub-vpc}"

echo "=== Creando VPC ==="
gcloud compute networks create "${VPC_NAME}" \
  --subnet-mode=custom \
  --bgp-routing-mode=global \
  --project="${PROJECT_ID}"

# ─────────────────────────────────────────────
# Subnet publica — Load Balancer y API Gateway
# ─────────────────────────────────────────────
echo "=== Creando subnet-public (${REGION}) ==="
gcloud compute networks subnets create subnet-public \
  --network="${VPC_NAME}" \
  --region="${REGION}" \
  --range=10.10.1.0/24 \
  --purpose=PRIVATE \
  --project="${PROJECT_ID}"

# ─────────────────────────────────────────────
# Subnet de servicios — Cloud Run microservicios
# ─────────────────────────────────────────────
echo "=== Creando subnet-services (${REGION}) ==="
gcloud compute networks subnets create subnet-services \
  --network="${VPC_NAME}" \
  --region="${REGION}" \
  --range=10.10.2.0/24 \
  --purpose=PRIVATE \
  --enable-private-ip-google-access \
  --project="${PROJECT_ID}"

# ─────────────────────────────────────────────
# Subnet de datos — PostgreSQL, Redis, Elasticsearch, Kafka
# ─────────────────────────────────────────────
echo "=== Creando subnet-data (${REGION}) ==="
gcloud compute networks subnets create subnet-data \
  --network="${VPC_NAME}" \
  --region="${REGION}" \
  --range=10.10.3.0/24 \
  --purpose=PRIVATE \
  --enable-private-ip-google-access \
  --project="${PROJECT_ID}"

# ─────────────────────────────────────────────
# VPC Access Connector para Cloud Run -> VPC
# Cloud Run necesita este connector para comunicarse
# con recursos en la VPC (Redis, PostgreSQL)
# ─────────────────────────────────────────────
echo "=== Habilitando VPC Access API ==="
gcloud services enable vpcaccess.googleapis.com --project="${PROJECT_ID}"

echo "=== Creando VPC Access Connector ==="
gcloud compute networks vpc-access connectors create travelhub-connector \
  --region="${REGION}" \
  --network="${VPC_NAME}" \
  --range=10.10.8.0/28 \
  --min-instances=2 \
  --max-instances=10 \
  --project="${PROJECT_ID}"

echo ""
echo "============================================"
echo "VPC '${VPC_NAME}' created"
echo "============================================"
echo "Project: ${PROJECT_ID}"
echo "Region:  ${REGION}"
echo ""
echo "Subnets:"
echo "  subnet-public:    10.10.1.0/24  (LB + API Gateway)"
echo "  subnet-services:  10.10.2.0/24  (Cloud Run microservicios)"
echo "  subnet-data:      10.10.3.0/24  (PostgreSQL, Redis, ES, Kafka)"
echo ""
echo "VPC Access Connector:"
echo "  travelhub-connector: 10.10.8.0/28"
echo "============================================"
