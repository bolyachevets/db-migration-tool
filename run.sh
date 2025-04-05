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

  # Upload to GCS
  echo "Uploading to GCS..."
  gsutil cp "$db_file" "gs://${DB_BUCKET}/${db}/" || { echo "Failed to upload to GCS"; exit 1; }

  # Database operations
  echo "Recreating database $db on instance $GCP_SQL_INSTANCE"
  gcloud sql databases delete "$db" --instance="$GCP_SQL_INSTANCE" --quiet || echo "Database may not exist yet"
  gcloud sql databases create "$db" --instance="$GCP_SQL_INSTANCE" --quiet || { echo "Failed to create database"; exit 1; }

  # Import data (using the admin user)
  echo "Importing data..."
  gcloud sql import sql "$GCP_SQL_INSTANCE" "gs://${DB_BUCKET}/${db}/${db_file}" \
    --database="$db" --user=$DB_USER \
    --quiet || { echo "Failed to import data"; exit 1; }

  # Wait for operation to complete
  operation=$(gcloud sql operations list --instance="$GCP_SQL_INSTANCE" \
    --filter='status!=DONE' --format='value(name)' --limit=1)
  [ -n "$operation" ] && gcloud sql operations wait "$operation" --timeout=unlimited

  # Set permissions using direct SQL connection (better approach)
  echo "Setting permissions for user $DB_USER"
  gcloud sql connect "$GCP_SQL_INSTANCE" --user=postgres --quiet <<EOF
  \c $db;
  GRANT USAGE, CREATE ON SCHEMA public TO "$DB_USER";
  GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO "$DB_USER";
  GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO "$DB_USER";
  GRANT ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA public TO "$DB_USER";
  ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL PRIVILEGES ON TABLES TO "$DB_USER";
  ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL PRIVILEGES ON SEQUENCES TO "$DB_USER";
  ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL PRIVILEGES ON FUNCTIONS TO "$DB_USER";
EOF

  echo "Database load completed successfully"
}

# Main execution
cd /opt/app-root || exit 1
oc login --server="$OC_SERVER" --token="$OC_TOKEN" || { echo "OC login failed"; exit 1; }
load_oc_db "$OC_NAMESPACE" "$DB_NAME"
