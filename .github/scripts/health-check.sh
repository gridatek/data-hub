#!/bin/bash
set -e

echo "=== Data Hub Health Check ==="
echo

# Define services and their health endpoints
declare -A SERVICES=(
  ["PostgreSQL"]="docker exec data-hub-postgres pg_isready -U admin"
  ["MinIO"]="curl -f -s http://localhost:9000/minio/health/live"
  ["Spark Master"]="curl -f -s http://localhost:8080"
  ["Spark Worker 1"]="curl -f -s http://localhost:8081"
  ["Spark Worker 2"]="curl -f -s http://localhost:8082"
  ["Airflow Webserver"]="curl -f -s http://localhost:8088/health"
  ["Trino"]="curl -f -s http://localhost:8089/v1/info"
  ["Jupyter"]="curl -f -s http://localhost:8888/api"
)

# Check each service
FAILED=0
for SERVICE in "${!SERVICES[@]}"; do
  echo -n "Checking $SERVICE... "
  if eval "${SERVICES[$SERVICE]}" > /dev/null 2>&1; then
    echo "✅ OK"
  else
    echo "❌ FAILED"
    FAILED=$((FAILED + 1))
  fi
done

echo
if [ $FAILED -eq 0 ]; then
  echo "✅ All services are healthy!"
  exit 0
else
  echo "❌ $FAILED service(s) failed health check"
  exit 1
fi