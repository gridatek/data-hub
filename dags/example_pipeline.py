from airflow import DAG
from airflow.providers.apache.spark.operators.spark_submit import SparkSubmitOperator
from datetime import datetime, timedelta

default_args = {
    'owner': 'data-team',
    'depends_on_past': False,
    'start_date': datetime(2024, 1, 1),
    'email_on_failure': False,
    'email_on_retry': False,
    'retries': 1,
    'retry_delay': timedelta(minutes=5),
}

dag = DAG(
    'example_spark_pipeline',
    default_args=default_args,
    description='Example Spark Pipeline',
    schedule_interval=timedelta(days=1),
    catchup=False,
)

spark_job = SparkSubmitOperator(
    task_id='run_spark_job',
    application='/opt/workspace/jobs/etl_job.py',
    conn_id='spark_default',
    conf={
        'spark.sql.catalog.iceberg': 'org.apache.iceberg.spark.SparkCatalog',
        'spark.sql.catalog.iceberg.type': 'hive',
        'spark.sql.catalog.iceberg.uri': 'thrift://hive-metastore:9083',
    },
    dag=dag,
)