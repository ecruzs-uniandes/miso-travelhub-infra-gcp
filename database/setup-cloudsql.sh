#!/bin/bash
# =============================================================================
# TravelHub — Cloud SQL PostgreSQL (solo IP privada)
# =============================================================================
# Crea una instancia PostgreSQL en la VPC travelhub-vpc.
# Accesible solo desde subnet-services via IP privada.
# Sin IP pública — no accesible desde internet.
#
# Prerequisitos:
#   - VPC travelhub-vpc creada (firewall/vpc-setup.sh)
#   - Private Service Connection configurado (firewall/private-access.sh)
# =============================================================================
set -euo pipefail

PROJECT_ID="${GCP_PROJECT_ID:-gen-lang-client-0930444414}"
REGION="${GCP_REGION:-us-central1}"
INSTANCE_NAME="${DB_INSTANCE_NAME:-travelhub-db}"
DB_NAME="${DB_NAME:-travelhub}"
DB_USER="${DB_USER:-travelhub_app}"
VPC_NAME="${VPC_NAME:-travelhub-vpc}"

echo "=== Habilitando Cloud SQL API ==="
gcloud services enable sqladmin.googleapis.com --project="${PROJECT_ID}"

echo "=== Creando instancia Cloud SQL PostgreSQL ==="
gcloud sql instances create "${INSTANCE_NAME}" \
  --database-version=POSTGRES_15 \
  --tier=db-f1-micro \
  --region="${REGION}" \
  --network="projects/${PROJECT_ID}/global/networks/${VPC_NAME}" \
  --no-assign-ip \
  --storage-type=SSD \
  --storage-size=10GB \
  --storage-auto-increase \
  --no-backup \
  --availability-type=zonal \
  --project="${PROJECT_ID}"

echo "=== Creando base de datos '${DB_NAME}' ==="
gcloud sql databases create "${DB_NAME}" \
  --instance="${INSTANCE_NAME}" \
  --project="${PROJECT_ID}"

echo "=== Generando password para usuario '${DB_USER}' ==="
DB_PASSWORD=$(openssl rand -base64 24)

echo "=== Creando usuario '${DB_USER}' ==="
gcloud sql users create "${DB_USER}" \
  --instance="${INSTANCE_NAME}" \
  --password="${DB_PASSWORD}" \
  --project="${PROJECT_ID}"

echo "=== Obteniendo IP privada de la instancia ==="
PRIVATE_IP=$(gcloud sql instances describe "${INSTANCE_NAME}" \
  --format="value(ipAddresses[0].ipAddress)" \
  --project="${PROJECT_ID}")

echo ""
echo "============================================"
echo "Cloud SQL PostgreSQL created"
echo "============================================"
echo "Project:   ${PROJECT_ID}"
echo "Region:    ${REGION}"
echo "Instance:  ${INSTANCE_NAME}"
echo "Database:  ${DB_NAME}"
echo "User:      ${DB_USER}"
echo "Password:  ${DB_PASSWORD}"
echo "Private IP: ${PRIVATE_IP}"
echo ""
echo "Connection string:"
echo "  postgresql://${DB_USER}:${DB_PASSWORD}@${PRIVATE_IP}:5432/${DB_NAME}"
echo ""
echo "Variables de entorno para Cloud Run:"
echo "  DATABASE_HOST=${PRIVATE_IP}"
echo "  DATABASE_PORT=5432"
echo "  DATABASE_NAME=${DB_NAME}"
echo "  DATABASE_USER=${DB_USER}"
echo "  DATABASE_PASSWORD=${DB_PASSWORD}"
echo ""
echo "IMPORTANTE: Guarda el password en un lugar seguro."
echo "En produccion usar Secret Manager."
echo "============================================"
