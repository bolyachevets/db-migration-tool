#!/bin/sh

load_oc_db() {
  local namespace="$1"
  local db="$2"
  echo "Loading database $db in namespace $namespace"

  # Get the pod name
  pod_name=$(oc -n $namespace get pods --selector=$OC_LABEL -o name | sed 's/pod\///')
  [ -z "$pod_name" ] && { echo "Error: Pod not found"; exit 1; }
  echo "Using pod: $pod_name"

  # Download the database dump
  src_path="${pod_name}:/backups/daily/${DUMP_FILE_PATH}"
  db_file="${db}.sql.gz"
  echo "Downloading dump file from $src_path"
  oc -n $namespace cp "$src_path" "$db_file" || { echo "Failed to download dump"; exit 1; }

  # Extract if needed
  if tar -tf "$db_file" >/dev/null 2>&1; then
    echo "Extracting archive..."
    tar -xzvf "$db_file"
    # Look for the actual SQL file
    [ -f "backup.sql" ] && db_file="backup.sql"
  fi

  echo "Uploading to GCS..."
  gsutil cp "$db_file" "gs://${DB_BUCKET}/${db}/" || { echo "Failed to upload to GCS"; exit 1; }

  echo "Recreating database $db on instance $GCP_SQL_INSTANCE"
  gcloud sql databases delete "$db" --instance="$GCP_SQL_INSTANCE" --quiet || echo "Database may not exist yet"
  gcloud sql databases create "$db" --instance="$GCP_SQL_INSTANCE" --quiet || { echo "Failed to create database"; exit 1; }

  echo "Importing data..."
  gcloud --quiet sql import sql $GCP_SQL_INSTANCE "gs://${DB_BUCKET}/${db}/${db_file}" --database="$db" --user=$DB_USER
  gcloud sql operations list --instance=$GCP_SQL_INSTANCE --filter='NOT status:done' --format='value(name)' | xargs -r gcloud sql operations wait --timeout=unlimited

  # Grant permissions to the database user
  cat <<EOF > user.sql
GRANT USAGE, CREATE ON SCHEMA public TO "$DB_USER";
GRANT ALL PRIVILEGES ON DATABASE "$DB_NAME" TO "$DB_USER";
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL PRIVILEGES ON TABLES TO "$DB_USER";
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL PRIVILEGES ON SEQUENCES TO "$DB_USER";
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL PRIVILEGES ON FUNCTIONS TO "$DB_USER";
EOF

  gsutil cp user.sql "gs://${DB_BUCKET}/${db}/"

  gcloud --quiet sql import sql $GCP_SQL_INSTANCE "gs://${DB_BUCKET}/${db}/user.sql" --database=$DB_NAME --user=postgres
  gcloud sql operations list --instance=$GCP_SQL_INSTANCE --filter='NOT status:done' --format='value(name)' | xargs -r gcloud sql operations wait --timeout=unlimited

  echo "Database load completed successfully"
}

# Main execution
cd /opt/app-root || exit 1
oc login --server="$OC_SERVER" --token="$OC_TOKEN" || { echo "OC login failed"; exit 1; }
load_oc_db "$OC_NAMESPACE" "$DB_NAME"
