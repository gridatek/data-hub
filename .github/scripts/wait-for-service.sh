#!/bin/bash
# Usage: wait-for-service.sh <service-name> <health-check-command> <timeout>

SERVICE=$1
HEALTH_CMD=$2
TIMEOUT=${3:-60}

echo "Waiting for $SERVICE (timeout: ${TIMEOUT}s)..."
timeout $TIMEOUT bash -c "
  until $HEALTH_CMD > /dev/null 2>&1; do
    echo -n '.'
    sleep 2
  done
"

if [ $? -eq 0 ]; then
  echo " ✅ $SERVICE is ready!"
  exit 0
else
  echo " ❌ $SERVICE failed to start within ${TIMEOUT}s"
  exit 1
fi