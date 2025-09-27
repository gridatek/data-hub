# Modern Data Hub - Docker Compose Architecture

## Project Structure
```
data-hub/
├── docker-compose.base.yml      # Base configuration, networks, volumes
├── docker-compose.postgres.yml  # PostgreSQL for metadata
├── docker-compose.minio.yml     # MinIO for S3-compatible storage
├── docker-compose.hive.yml      # Hive Metastore for Iceberg catalog
├── docker-compose.spark.yml     # Apache Spark cluster
├── docker-compose.airflow.yml   # Apache Airflow
├── docker-compose.trino.yml     # Trino for querying
├── docker-compose.jupyter.yml   # Jupyter for interactive work
├── .env                         # Environment variables
├── config/
│   ├── airflow/
│   │   └── airflow.cfg
│   ├── spark/
│   │   └── spark-defaults.conf
│   └── trino/
│       └── catalog/
└── data/                        # Shared data directory
```

## 1. Base Configuration (docker-compose.base.yml)

```yaml
version: '3.8'

networks:
  data-hub:
    driver: bridge
    name: data-hub-network
    ipam:
      config:
        - subnet: 172.28.0.0/16

volumes:
  postgres-data:
    driver: local
  minio-data:
    driver: local
  airflow-logs:
    driver: local
  spark-logs:
    driver: local
  jupyter-work:
    driver: local
  shared-workspace:
    driver: local

x-common-variables: &common-variables
  TZ: UTC
  PYTHONUNBUFFERED: 1

x-healthcheck-defaults: &healthcheck-defaults
  interval: 30s
  timeout: 10s
  retries: 5
  start_period: 30s
```

## 2. PostgreSQL (docker-compose.postgres.yml)

```yaml
version: '3.8'

services:
  postgres:
    image: postgres:15-alpine
    container_name: data-hub-postgres
    restart: unless-stopped
    environment:
      POSTGRES_USER: ${POSTGRES_USER:-admin}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD:-admin123}
      POSTGRES_MULTIPLE_DATABASES: airflow,hive_metastore,trino
      PGDATA: /var/lib/postgresql/data/pgdata
    volumes:
      - postgres-data:/var/lib/postgresql/data
      - ./scripts/init-postgres.sh:/docker-entrypoint-initdb.d/init-postgres.sh
    ports:
      - "5432:5432"
    networks:
      data-hub:
        ipv4_address: 172.28.1.1
    healthcheck:
      <<: *healthcheck-defaults
      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER:-admin}"]
```

## 3. MinIO (docker-compose.minio.yml)

```yaml
version: '3.8'

services:
  minio:
    image: minio/minio:latest
    container_name: data-hub-minio
    restart: unless-stopped
    command: server /data --console-address ":9001"
    environment:
      MINIO_ROOT_USER: ${MINIO_ACCESS_KEY:-minioadmin}
      MINIO_ROOT_PASSWORD: ${MINIO_SECRET_KEY:-minioadmin123}
    volumes:
      - minio-data:/data
    ports:
      - "9000:9000"
      - "9001:9001"
    networks:
      data-hub:
        ipv4_address: 172.28.1.2
    healthcheck:
      <<: *healthcheck-defaults
      test: ["CMD", "curl", "-f", "http://localhost:9000/minio/health/live"]

  minio-init:
    image: minio/mc:latest
    container_name: data-hub-minio-init
    depends_on:
      minio:
        condition: service_healthy
    entrypoint: >
      /bin/sh -c "
      mc alias set myminio http://minio:9000 ${MINIO_ACCESS_KEY:-minioadmin} ${MINIO_SECRET_KEY:-minioadmin123};
      mc mb -p myminio/warehouse;
      mc mb -p myminio/spark-logs;
      mc mb -p myminio/airflow;
      mc mb -p myminio/temp;
      exit 0;
      "
    networks:
      - data-hub
```

## 4. Hive Metastore (docker-compose.hive.yml)

```yaml
version: '3.8'

services:
  hive-metastore:
    image: apache/hive:4.0.0-beta-1
    container_name: data-hub-hive-metastore
    restart: unless-stopped
    environment:
      SERVICE_NAME: metastore
      DB_DRIVER: postgres
      SERVICE_OPTS: >
        -Djavax.jdo.option.ConnectionDriverName=org.postgresql.Driver
        -Djavax.jdo.option.ConnectionURL=jdbc:postgresql://postgres:5432/hive_metastore
        -Djavax.jdo.option.ConnectionUserName=${POSTGRES_USER:-admin}
        -Djavax.jdo.option.ConnectionPassword=${POSTGRES_PASSWORD:-admin123}
        -Dfs.s3a.endpoint=http://minio:9000
        -Dfs.s3a.access.key=${MINIO_ACCESS_KEY:-minioadmin}
        -Dfs.s3a.secret.key=${MINIO_SECRET_KEY:-minioadmin123}
        -Dfs.s3a.path.style.access=true
        -Dfs.s3a.impl=org.apache.hadoop.fs.s3a.S3AFileSystem
    depends_on:
      postgres:
        condition: service_healthy
      minio:
        condition: service_healthy
    ports:
      - "9083:9083"
    networks:
      data-hub:
        ipv4_address: 172.28.1.3
    volumes:
      - ./jars/postgresql-42.5.1.jar:/opt/hive/lib/postgresql-42.5.1.jar
      - ./jars/aws-java-sdk-bundle-1.12.367.jar:/opt/hive/lib/aws-java-sdk-bundle-1.12.367.jar
      - ./jars/hadoop-aws-3.3.4.jar:/opt/hive/lib/hadoop-aws-3.3.4.jar
```

## 5. Apache Spark (docker-compose.spark.yml)

```yaml
version: '3.8'

x-spark-common: &spark-common
  image: apache/spark:3.5.0-scala2.12-java11-python3-ubuntu
  environment:
    SPARK_MODE: ${SPARK_MODE:-cluster}
    SPARK_MASTER_URL: spark://spark-master:7077
    SPARK_RPC_AUTHENTICATION_ENABLED: no
    SPARK_RPC_ENCRYPTION_ENABLED: no
    SPARK_LOCAL_STORAGE_ENCRYPTION_ENABLED: no
    SPARK_SSL_ENABLED: no
    AWS_ACCESS_KEY_ID: ${MINIO_ACCESS_KEY:-minioadmin}
    AWS_SECRET_ACCESS_KEY: ${MINIO_SECRET_KEY:-minioadmin123}
    AWS_REGION: us-east-1
  volumes:
    - ./config/spark/spark-defaults.conf:/opt/spark/conf/spark-defaults.conf
    - ./jars/iceberg-spark-runtime-3.5_2.12-1.4.2.jar:/opt/spark/jars/iceberg-spark-runtime.jar
    - ./jars/aws-java-sdk-bundle-1.12.367.jar:/opt/spark/jars/aws-java-sdk-bundle.jar
    - ./jars/hadoop-aws-3.3.4.jar:/opt/spark/jars/hadoop-aws.jar
    - shared-workspace:/opt/workspace
  networks:
    - data-hub

services:
  spark-master:
    <<: *spark-common
    container_name: data-hub-spark-master
    restart: unless-stopped
    command: /opt/spark/bin/spark-class org.apache.spark.deploy.master.Master
    environment:
      <<: *spark-common.environment
      SPARK_MASTER_PORT: 7077
      SPARK_MASTER_WEBUI_PORT: 8080
    ports:
      - "8080:8080"
      - "7077:7077"
    networks:
      data-hub:
        ipv4_address: 172.28.1.10
    healthcheck:
      <<: *healthcheck-defaults
      test: ["CMD", "curl", "-f", "http://localhost:8080"]

  spark-worker-1:
    <<: *spark-common
    container_name: data-hub-spark-worker-1
    restart: unless-stopped
    command: /opt/spark/bin/spark-class org.apache.spark.deploy.worker.Worker spark://spark-master:7077
    depends_on:
      spark-master:
        condition: service_healthy
    environment:
      <<: *spark-common.environment
      SPARK_WORKER_CORES: 2
      SPARK_WORKER_MEMORY: 2g
      SPARK_WORKER_WEBUI_PORT: 8081
    ports:
      - "8081:8081"
    networks:
      data-hub:
        ipv4_address: 172.28.1.11

  spark-worker-2:
    <<: *spark-common
    container_name: data-hub-spark-worker-2
    restart: unless-stopped
    command: /opt/spark/bin/spark-class org.apache.spark.deploy.worker.Worker spark://spark-master:7077
    depends_on:
      spark-master:
        condition: service_healthy
    environment:
      <<: *spark-common.environment
      SPARK_WORKER_CORES: 2
      SPARK_WORKER_MEMORY: 2g
      SPARK_WORKER_WEBUI_PORT: 8082
    ports:
      - "8082:8082"
    networks:
      data-hub:
        ipv4_address: 172.28.1.12

  spark-history-server:
    <<: *spark-common
    container_name: data-hub-spark-history
    restart: unless-stopped
    command: /opt/spark/bin/spark-class org.apache.spark.deploy.history.HistoryServer
    environment:
      <<: *spark-common.environment
      SPARK_HISTORY_OPTS: >
        -Dspark.history.fs.logDirectory=s3a://spark-logs/
        -Dspark.history.ui.port=18080
    ports:
      - "18080:18080"
    depends_on:
      - minio
    networks:
      data-hub:
        ipv4_address: 172.28.1.13
```

## 6. Apache Airflow (docker-compose.airflow.yml)

```yaml
version: '3.8'

x-airflow-common: &airflow-common
  image: apache/airflow:2.8.0-python3.10
  environment: &airflow-common-env
    AIRFLOW__CORE__EXECUTOR: LocalExecutor
    AIRFLOW__DATABASE__SQL_ALCHEMY_CONN: postgresql+psycopg2://${POSTGRES_USER:-admin}:${POSTGRES_PASSWORD:-admin123}@postgres/airflow
    AIRFLOW__CORE__FERNET_KEY: ${AIRFLOW_FERNET_KEY:-12345678901234567890123456789012345678901234}
    AIRFLOW__CORE__DAGS_ARE_PAUSED_AT_CREATION: 'true'
    AIRFLOW__CORE__LOAD_EXAMPLES: 'false'
    AIRFLOW__API__AUTH_BACKENDS: 'airflow.api.auth.backend.basic_auth,airflow.api.auth.backend.session'
    AIRFLOW__WEBSERVER__SECRET_KEY: ${AIRFLOW_SECRET_KEY:-secret12345678901234567890123456789012345678901234}
    AIRFLOW_CONN_SPARK_DEFAULT: spark://spark-master:7077
    AIRFLOW_CONN_S3_DEFAULT: s3://${MINIO_ACCESS_KEY:-minioadmin}:${MINIO_SECRET_KEY:-minioadmin123}@?endpoint_url=http%3A%2F%2Fminio%3A9000
    _AIRFLOW_DB_MIGRATE: 'true'
    _AIRFLOW_WWW_USER_CREATE: 'true'
    _AIRFLOW_WWW_USER_USERNAME: ${AIRFLOW_USER:-admin}
    _AIRFLOW_WWW_USER_PASSWORD: ${AIRFLOW_PASSWORD:-admin}
  volumes:
    - ./dags:/opt/airflow/dags
    - ./plugins:/opt/airflow/plugins
    - airflow-logs:/opt/airflow/logs
    - shared-workspace:/opt/workspace
  user: "${AIRFLOW_UID:-50000}:0"
  depends_on:
    postgres:
      condition: service_healthy
  networks:
    - data-hub

services:
  airflow-init:
    <<: *airflow-common
    container_name: data-hub-airflow-init
    entrypoint: /bin/bash
    command: >
      -c "
      airflow db init &&
      airflow users create
        --username ${AIRFLOW_USER:-admin}
        --password ${AIRFLOW_PASSWORD:-admin}
        --firstname Admin
        --lastname User
        --role Admin
        --email admin@example.com || true
      "
    environment:
      <<: *airflow-common-env
    restart: on-failure

  airflow-webserver:
    <<: *airflow-common
    container_name: data-hub-airflow-webserver
    command: webserver
    ports:
      - "8088:8080"
    healthcheck:
      <<: *healthcheck-defaults
      test: ["CMD", "curl", "--fail", "http://localhost:8080/health"]
    restart: unless-stopped
    depends_on:
      airflow-init:
        condition: service_completed_successfully
    networks:
      data-hub:
        ipv4_address: 172.28.1.20

  airflow-scheduler:
    <<: *airflow-common
    container_name: data-hub-airflow-scheduler
    command: scheduler
    healthcheck:
      <<: *healthcheck-defaults
      test: ["CMD", "curl", "--fail", "http://localhost:8974/health"]
    restart: unless-stopped
    depends_on:
      airflow-init:
        condition: service_completed_successfully
    networks:
      data-hub:
        ipv4_address: 172.28.1.21
```

## 7. Trino (docker-compose.trino.yml)

```yaml
version: '3.8'

services:
  trino:
    image: trinodb/trino:435
    container_name: data-hub-trino
    restart: unless-stopped
    ports:
      - "8089:8080"
    volumes:
      - ./config/trino/catalog:/etc/trino/catalog
      - ./config/trino/config.properties:/etc/trino/config.properties
      - ./config/trino/jvm.config:/etc/trino/jvm.config
    environment:
      TRINO_MEMORY: 2GB
    depends_on:
      - hive-metastore
      - minio
    networks:
      data-hub:
        ipv4_address: 172.28.1.30
    healthcheck:
      <<: *healthcheck-defaults
      test: ["CMD", "trino", "--execute", "SELECT 1"]
```

## 8. Jupyter Lab (docker-compose.jupyter.yml)

```yaml
version: '3.8'

services:
  jupyter:
    image: jupyter/pyspark-notebook:spark-3.5.0
    container_name: data-hub-jupyter
    restart: unless-stopped
    environment:
      JUPYTER_ENABLE_LAB: "yes"
      JUPYTER_TOKEN: ${JUPYTER_TOKEN:-jupyter123}
      SPARK_MASTER: spark://spark-master:7077
      AWS_ACCESS_KEY_ID: ${MINIO_ACCESS_KEY:-minioadmin}
      AWS_SECRET_ACCESS_KEY: ${MINIO_SECRET_KEY:-minioadmin123}
    volumes:
      - jupyter-work:/home/jovyan/work
      - shared-workspace:/home/jovyan/workspace
      - ./notebooks:/home/jovyan/notebooks
    ports:
      - "8888:8888"
      - "4040:4040"
    networks:
      data-hub:
        ipv4_address: 172.28.1.40
    command: start-notebook.sh --NotebookApp.token=${JUPYTER_TOKEN:-jupyter123}
```

## 9. Environment Variables (.env)

```bash
# PostgreSQL
POSTGRES_USER=admin
POSTGRES_PASSWORD=admin123

# MinIO
MINIO_ACCESS_KEY=minioadmin
MINIO_SECRET_KEY=minioadmin123

# Airflow
AIRFLOW_UID=50000
AIRFLOW_USER=admin
AIRFLOW_PASSWORD=admin
AIRFLOW_FERNET_KEY=12345678901234567890123456789012345678901234
AIRFLOW_SECRET_KEY=secret12345678901234567890123456789012345678901234

# Jupyter
JUPYTER_TOKEN=jupyter123

# Spark
SPARK_MODE=cluster
```

## 10. Configuration Files

### config/spark/spark-defaults.conf
```properties
spark.master                     spark://spark-master:7077
spark.eventLog.enabled           true
spark.eventLog.dir               s3a://spark-logs/
spark.history.provider           org.apache.spark.deploy.history.FsHistoryProvider
spark.history.fs.logDirectory    s3a://spark-logs/
spark.history.fs.update.interval 10s
spark.history.ui.port            18080

# Iceberg configurations
spark.sql.extensions                          org.apache.iceberg.spark.extensions.IcebergSparkSessionExtensions
spark.sql.catalog.spark_catalog              org.apache.iceberg.spark.SparkSessionCatalog
spark.sql.catalog.spark_catalog.type         hive
spark.sql.catalog.iceberg                    org.apache.iceberg.spark.SparkCatalog
spark.sql.catalog.iceberg.type               hive
spark.sql.catalog.iceberg.uri                thrift://hive-metastore:9083
spark.sql.catalog.iceberg.warehouse          s3a://warehouse/
spark.sql.defaultCatalog                     iceberg

# S3 configurations
spark.hadoop.fs.s3a.endpoint                 http://minio:9000
spark.hadoop.fs.s3a.access.key              minioadmin
spark.hadoop.fs.s3a.secret.key              minioadmin123
spark.hadoop.fs.s3a.path.style.access       true
spark.hadoop.fs.s3a.impl                    org.apache.hadoop.fs.s3a.S3AFileSystem
spark.hadoop.fs.s3a.connection.ssl.enabled  false
```

### config/trino/catalog/iceberg.properties
```properties
connector.name=iceberg
hive.metastore.uri=thrift://hive-metastore:9083
hive.s3.endpoint=http://minio:9000
hive.s3.path-style-access=true
hive.s3.aws-access-key=minioadmin
hive.s3.aws-secret-key=minioadmin123
hive.s3.ssl.enabled=false
```

### config/trino/catalog/postgres.properties
```properties
connector.name=postgresql
connection-url=jdbc:postgresql://postgres:5432/postgres
connection-user=admin
connection-password=admin123
```

### scripts/init-postgres.sh
```bash
#!/bin/bash
set -e

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" <<-EOSQL
    CREATE DATABASE airflow;
    CREATE DATABASE hive_metastore;
    CREATE DATABASE trino;
    GRANT ALL PRIVILEGES ON DATABASE airflow TO $POSTGRES_USER;
    GRANT ALL PRIVILEGES ON DATABASE hive_metastore TO $POSTGRES_USER;
    GRANT ALL PRIVILEGES ON DATABASE trino TO $POSTGRES_USER;
EOSQL
```

## Usage Commands

### Start all services:
```bash
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
```

### Start specific services:
```bash
# Just the storage layer
docker-compose -f docker-compose.base.yml -f docker-compose.postgres.yml -f docker-compose.minio.yml up -d

# Add Spark
docker-compose -f docker-compose.base.yml -f docker-compose.spark.yml up -d

# Add Airflow
docker-compose -f docker-compose.base.yml -f docker-compose.airflow.yml up -d
```

### Stop all services:
```bash
docker-compose \
  -f docker-compose.base.yml \
  -f docker-compose.postgres.yml \
  -f docker-compose.minio.yml \
  -f docker-compose.hive.yml \
  -f docker-compose.spark.yml \
  -f docker-compose.airflow.yml \
  -f docker-compose.trino.yml \
  -f docker-compose.jupyter.yml \
  down
```

### Create an alias for easier management:
```bash
# Add to ~/.bashrc or ~/.zshrc
alias dc-hub='docker-compose -f docker-compose.base.yml -f docker-compose.postgres.yml -f docker-compose.minio.yml -f docker-compose.hive.yml -f docker-compose.spark.yml -f docker-compose.airflow.yml -f docker-compose.trino.yml -f docker-compose.jupyter.yml'

# Then use:
dc-hub up -d
dc-hub logs -f spark-master
dc-hub down
```

## Service URLs

- **MinIO Console**: http://localhost:9001 (minioadmin/minioadmin123)
- **Spark Master**: http://localhost:8080
- **Spark History Server**: http://localhost:18080
- **Airflow**: http://localhost:8088 (admin/admin)
- **Trino**: http://localhost:8089
- **Jupyter Lab**: http://localhost:8888 (token: jupyter123)
- **PostgreSQL**: localhost:5432 (admin/admin123)

## Additional Services to Add

Consider adding these services based on your needs:

### Kafka (docker-compose.kafka.yml)
```yaml
version: '3.8'

services:
  kafka:
    image: confluentinc/cp-kafka:7.5.0
    container_name: data-hub-kafka
    depends_on:
      - zookeeper
    ports:
      - "9092:9092"
    environment:
      KAFKA_BROKER_ID: 1
      KAFKA_ZOOKEEPER_CONNECT: zookeeper:2181
      KAFKA_ADVERTISED_LISTENERS: PLAINTEXT://localhost:9092
      KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR: 1
    networks:
      - data-hub

  zookeeper:
    image: confluentinc/cp-zookeeper:7.5.0
    container_name: data-hub-zookeeper
    environment:
      ZOOKEEPER_CLIENT_PORT: 2181
      ZOOKEEPER_TICK_TIME: 2000
    networks:
      - data-hub
```

### Superset (docker-compose.superset.yml)
```yaml
version: '3.8'

services:
  superset:
    image: apache/superset:3.0.0
    container_name: data-hub-superset
    depends_on:
      - postgres
    ports:
      - "8090:8088"
    environment:
      SUPERSET_SECRET_KEY: ${SUPERSET_SECRET_KEY:-supersetsecretkey123}
      DATABASE_URL: postgresql://${POSTGRES_USER:-admin}:${POSTGRES_PASSWORD:-admin123}@postgres:5432/superset
    networks:
      - data-hub
```

## Best Practices

1. **Resource Management**: Adjust memory and CPU limits based on your system
2. **Security**: Change all default passwords in production
3. **Monitoring**: Consider adding Prometheus + Grafana for monitoring
4. **Backup**: Implement regular backups for PostgreSQL and MinIO data
5. **Networking**: Use the dedicated network for inter-service communication
6. **Logging**: Centralize logs with ELK stack or similar solution

## Troubleshooting

1. **Check service health**: `docker-compose ps`
2. **View logs**: `docker-compose logs -f [service-name]`
3. **Restart specific service**: `docker-compose restart [service-name]`
4. **Clean volumes**: `docker volume prune` (careful - this removes data!)
5. **Network issues**: `docker network inspect data-hub-network`