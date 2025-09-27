# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a Modern Data Hub infrastructure project that provides a complete data platform using Docker Compose. It's a modular, production-ready data lakehouse platform featuring Apache Spark, Airflow, Iceberg, Trino, MinIO, and PostgreSQL.

## Key Commands

### Starting Services

```bash
# Start complete data stack
docker-compose \
  -f docker-compose.base.yml \
  -f docker-compose.postgres.yml \
  -f docker-compose.minio.yml \
  -f docker-compose.hive.yml \
  -f docker-compose.spark.yml \
  -f docker-compose.airflow.yml \
  -f docker-compose.trino.yml \
  -f docker-compose.jupyter.yml \
  up -d

# Create useful alias (add to ~/.bashrc or ~/.zshrc)
alias dc-hub='docker-compose -f docker-compose.base.yml -f docker-compose.postgres.yml -f docker-compose.minio.yml -f docker-compose.hive.yml -f docker-compose.spark.yml -f docker-compose.airflow.yml -f docker-compose.trino.yml -f docker-compose.jupyter.yml'

# Then use:
dc-hub up -d
dc-hub logs -f spark-master
dc-hub down
```

### Service Management

```bash
# Check service status
docker-compose ps

# View logs for specific service
docker-compose logs -f [service-name]

# Restart specific service
docker-compose restart [service-name]

# Stop all services
dc-hub down

# Stop and remove volumes (WARNING: deletes data)
dc-hub down -v
```

### Health Checks

```bash
# Quick health verification
curl http://localhost:8080  # Spark Master
curl http://localhost:8088  # Airflow
curl http://localhost:9001  # MinIO Console
curl http://localhost:8089  # Trino

# Advanced health checks
docker-compose ps                    # Check all service statuses
docker-compose logs -f [service]     # Monitor service logs
```

## Architecture Overview

### Service Stack
- **Storage Layer**: PostgreSQL (metadata) + MinIO (S3-compatible object storage)
- **Data Catalog**: Hive Metastore with Apache Iceberg format
- **Compute Layer**: Apache Spark cluster (1 master, 2 workers, history server)
- **Orchestration**: Apache Airflow with LocalExecutor
- **Query Engine**: Trino for SQL analytics
- **Development**: Jupyter Lab with PySpark integration

### Network Architecture
- Custom bridge network: `data-hub-network` (172.28.0.0/16)
- Static IP assignments for predictable inter-service communication
- Services communicate via container names (e.g., `spark-master:7077`)

### Data Flow
1. **Ingestion**: Airflow orchestrates data pipelines
2. **Processing**: Spark processes data using Iceberg format
3. **Storage**: Data stored in MinIO (S3-compatible) as Iceberg tables
4. **Metadata**: Hive Metastore manages table schemas in PostgreSQL
5. **Analytics**: Trino provides SQL interface to query Iceberg tables
6. **Development**: Jupyter provides interactive development environment

## Configuration Structure

```
config/
├── airflow/airflow.cfg          # Airflow configuration
├── spark/spark-defaults.conf    # Spark cluster settings with Iceberg integration
└── trino/catalog/               # Trino data source catalogs
    ├── iceberg.properties       # Iceberg catalog configuration
    ├── postgres.properties      # PostgreSQL federation
    └── config.properties        # Trino coordinator settings

scripts/
└── init-postgres.sh             # PostgreSQL database initialization

.env.example                     # Environment variable template
```

### Key Configuration Files

#### Spark Configuration (`config/spark/spark-defaults.conf`)
- Iceberg integration enabled by default
- S3 connectivity to MinIO configured
- Event logging to MinIO for history server
- Default catalog set to Iceberg

#### Trino Catalogs
- **iceberg**: Points to Hive Metastore for Iceberg table access
- **postgres**: Direct PostgreSQL federation for metadata queries

## Service Access

| Service | URL | Default Credentials |
|---------|-----|-------------------|
| MinIO Console | http://localhost:9001 | minioadmin/minioadmin123 |
| Spark Master UI | http://localhost:8080 | - |
| Spark History Server | http://localhost:18080 | - |
| Airflow | http://localhost:8088 | admin/admin |
| Trino | http://localhost:8089 | - |
| Jupyter Lab | http://localhost:8888 | Token: jupyter123 |
| PostgreSQL | localhost:5432 | admin/admin123 |

## Development Workflows

### Working with Iceberg Tables

```python
# In Jupyter or Spark jobs
from pyspark.sql import SparkSession

spark = SparkSession.builder \
    .appName("IcebergExample") \
    .config("spark.sql.catalog.iceberg", "org.apache.iceberg.spark.SparkCatalog") \
    .config("spark.sql.catalog.iceberg.type", "hive") \
    .config("spark.sql.catalog.iceberg.uri", "thrift://hive-metastore:9083") \
    .getOrCreate()

# Create Iceberg table
spark.sql("""
    CREATE TABLE IF NOT EXISTS iceberg.default.users (
        id BIGINT,
        name STRING,
        email STRING,
        created_at TIMESTAMP
    ) USING iceberg
    LOCATION 's3a://warehouse/users'
""")
```

### Querying with Trino

```sql
-- Connect via Trino CLI: docker exec -it data-hub-trino trino
SELECT * FROM iceberg.default.users;
SELECT * FROM iceberg.default.users FOR VERSION AS OF 1; -- Time travel
```

### Creating Airflow DAGs

- Place DAG files in `dags/` directory
- Use `SparkSubmitOperator` for Spark job orchestration
- Pre-configured connections: `spark_default`, S3 connection to MinIO

## Prerequisites and Setup

### Initial Setup
1. Install Docker (20.10+) and Docker Compose (2.0+)
2. Minimum 8GB RAM, 16GB recommended
3. Create required directories: `mkdir -p config/{airflow,spark,trino/catalog} dags plugins notebooks scripts jars`
4. Download required JAR files to `jars/` directory (see data-hub-readme.md for URLs)
5. Create `.env` file with service credentials
6. Initialize with `dc-hub up -d`

### JAR Dependencies
Required JAR files must be downloaded to `jars/` directory:
- `iceberg-spark-runtime-3.5_2.12-1.4.2.jar`
- `aws-java-sdk-bundle-1.12.367.jar`
- `hadoop-aws-3.3.4.jar`
- `postgresql-42.5.1.jar`

Download commands (see README.md for specific URLs):
```bash
mkdir -p jars
wget -P jars/ [JAR_URLS]
```

## Data Storage

### MinIO Buckets
- `warehouse`: Iceberg table data
- `spark-logs`: Spark history server logs
- `airflow`: Airflow artifacts
- `temp`: Temporary/intermediate data

### PostgreSQL Databases
- `airflow`: Airflow metadata
- `hive_metastore`: Iceberg table schemas
- `trino`: Trino configuration

## Troubleshooting

### Common Issues
1. **Out of Memory**: Reduce worker memory in compose files or increase Docker memory allocation
2. **Port Conflicts**: Check if ports 5432, 8080, 8088, 9000, 9001 are available
3. **Service Dependencies**: Use `docker-compose logs [service]` to debug startup issues
4. **Network Issues**: Verify `data-hub-network` exists and containers can communicate

### Resource Monitoring
```bash
docker stats                    # Monitor container resource usage
docker system df               # Check disk usage
du -sh data/*                 # Check data directory sizes
```

## Modular Deployment

The architecture supports deploying service subsets:

```bash
# Storage layer only
docker-compose -f docker-compose.base.yml -f docker-compose.postgres.yml -f docker-compose.minio.yml up -d

# Add compute layer
docker-compose -f docker-compose.base.yml -f docker-compose.spark.yml up -d

# Full analytics stack
dc-hub up -d
```

## Scaling

```bash
# Scale Spark workers
docker-compose -f docker-compose.spark.yml up -d --scale spark-worker=3

# Scale horizontally by adjusting worker resources in compose files
```

## Testing and Linting

```bash
# Lint Docker Compose files
dclint docker-compose*.yml

# Validate compose configuration
docker-compose config

# Test individual services
docker-compose up -d postgres minio  # Start subset for testing
```

## Container Management

```bash
# Access containers
docker exec -it data-hub-postgres psql -U admin
docker exec -it data-hub-trino trino
docker exec -it data-hub-spark-master /opt/spark/bin/spark-shell

# Container naming convention: data-hub-[service-name]
# Network: data-hub-network (172.28.0.0/16)
# Volumes: [service]-data, shared-workspace
```