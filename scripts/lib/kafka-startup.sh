#!/bin/bash
# ============================================================
# TravelHub — Startup script de la VM de Kafka
# ============================================================
# Se inyecta como metadata `startup-script` en la VM creada por
# `scripts/07-kafka.sh`. GCP lo ejecuta en el primer boot.
#
# Levanta via docker compose:
#   - Zookeeper (cp-zookeeper 7.6.0)
#   - Kafka broker (cp-kafka 7.6.0) — puertos 9092 (broker) y 29092 (host)
#   - Kafka UI (provectuslabs) — puerto 8080, accesible via IAP tunnel
#   - kafka-init: crea topics pms-sync-queue (3 part.) y pms-sync-dlq (1 part.)
#
# Logs: /var/log/kafka-startup.log
# ============================================================
set -euo pipefail
exec > >(tee -a /var/log/kafka-startup.log) 2>&1
echo "[$(date)] Iniciando setup de Kafka..."

apt-get update
apt-get install -y ca-certificates curl gnupg lsb-release

# Docker
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
systemctl enable --now docker

# IP interna para advertised listener
INTERNAL_IP=$(curl -s -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/ip)
echo "[$(date)] IP interna detectada: $INTERNAL_IP"

mkdir -p /opt/kafka
cat > /opt/kafka/docker-compose.yml <<EOF
services:
  zookeeper:
    image: confluentinc/cp-zookeeper:7.6.0
    container_name: travelhub-zookeeper
    restart: unless-stopped
    environment:
      ZOOKEEPER_CLIENT_PORT: 2181
      ZOOKEEPER_TICK_TIME: 2000
    volumes:
      - /data/zookeeper/data:/var/lib/zookeeper/data
      - /data/zookeeper/log:/var/lib/zookeeper/log

  kafka:
    image: confluentinc/cp-kafka:7.6.0
    container_name: travelhub-kafka
    restart: unless-stopped
    depends_on:
      - zookeeper
    ports:
      - "9092:9092"
      - "29092:29092"
    environment:
      KAFKA_BROKER_ID: 1
      KAFKA_ZOOKEEPER_CONNECT: zookeeper:2181
      KAFKA_ADVERTISED_LISTENERS: PLAINTEXT://${INTERNAL_IP}:9092,PLAINTEXT_HOST://localhost:29092
      KAFKA_LISTENER_SECURITY_PROTOCOL_MAP: PLAINTEXT:PLAINTEXT,PLAINTEXT_HOST:PLAINTEXT
      KAFKA_INTER_BROKER_LISTENER_NAME: PLAINTEXT
      KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR: 1
      KAFKA_AUTO_CREATE_TOPICS_ENABLE: "true"
      KAFKA_LOG_RETENTION_HOURS: 168
      KAFKA_LOG_DIRS: /var/lib/kafka/data
    volumes:
      - /data/kafka/data:/var/lib/kafka/data

  kafka-init:
    image: confluentinc/cp-kafka:7.6.0
    container_name: travelhub-kafka-init
    depends_on:
      - kafka
    restart: "no"
    entrypoint: ["/bin/sh", "-c"]
    command: |
      "
      echo 'Esperando a Kafka...'
      for i in \$\$(seq 1 30); do
        kafka-topics --bootstrap-server kafka:9092 --list >/dev/null 2>&1 && break
        sleep 5
      done
      kafka-topics --create --if-not-exists --bootstrap-server kafka:9092 --replication-factor 1 --partitions 3 --topic pms-sync-queue
      kafka-topics --create --if-not-exists --bootstrap-server kafka:9092 --replication-factor 1 --partitions 1 --topic pms-sync-dlq
      echo 'Topics listos:'
      kafka-topics --list --bootstrap-server kafka:9092
      "

  kafka-ui:
    image: provectuslabs/kafka-ui:latest
    container_name: travelhub-kafka-ui
    restart: unless-stopped
    depends_on:
      - kafka
    ports:
      - "8080:8080"
    environment:
      KAFKA_CLUSTERS_0_NAME: travelhub-dev
      KAFKA_CLUSTERS_0_BOOTSTRAPSERVERS: kafka:9092
EOF

mkdir -p /data/kafka/data /data/zookeeper/data /data/zookeeper/log
chown -R 1000:1000 /data

cd /opt/kafka
docker compose up -d
echo "[$(date)] docker compose levantado"
docker compose ps
