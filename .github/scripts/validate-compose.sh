#!/bin/bash
set -e

echo "Validating Docker Compose files..."

# Find all compose files
COMPOSE_FILES=$(find . -name "docker-compose.*.yml" | sort)

# Validate each file
for FILE in $COMPOSE_FILES; do
  echo -n "Validating $FILE... "
  
  # Check YAML syntax
  python3 -c "import yaml; yaml.safe_load(open('$FILE'))" 2>/dev/null
  if [ $? -ne 0 ]; then
    echo "❌ Invalid YAML"
    exit 1
  fi
  
  # Check Docker Compose syntax
  docker-compose -f docker-compose.base.yml -f $FILE config > /dev/null 2>&1
  if [ $? -ne 0 ]; then
    echo "❌ Invalid Compose syntax"
    exit 1
  fi
  
  echo "✅ Valid"
done

echo
echo "✅ All compose files are valid!"