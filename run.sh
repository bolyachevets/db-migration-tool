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

#set user permissions
cat <<EOF > user.sql
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '$NEW_DB_OWNER') THEN
    CREATE USER "$NEW_DB_OWNER" WITH PASSWORD '$TEMP_PASSWORD';
  END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '$OLD_DB_OWNER') THEN
    CREATE USER "$OLD_DB_OWNER" WITH PASSWORD '$TEMP_PASSWORD';
  END IF;
END
\$\$;
GRANT "$NEW_DB_OWNER" TO postgres;
GRANT "$OLD_DB_OWNER" TO postgres;
GRANT USAGE, CREATE ON SCHEMA public TO "$OLD_DB_OWNER";
EOF

  gsutil cp user.sql "gs://${DB_BUCKET}/${db}/"

  gcloud --quiet sql import sql $GCP_SQL_INSTANCE "gs://${DB_BUCKET}/${db}/user.sql" --database=$DB_NAME --user=postgres
  gcloud sql operations list --instance=$GCP_SQL_INSTANCE --filter='NOT status:done' --format='value(name)' | xargs -r gcloud sql operations wait --timeout=unlimited


  echo "Importing data..."
  gcloud --quiet sql import sql $GCP_SQL_INSTANCE "gs://${DB_BUCKET}/${db}/${db_file}" --database="$db" --user=postgres
  gcloud sql operations list --instance=$GCP_SQL_INSTANCE --filter='NOT status:done' --format='value(name)' | xargs -r gcloud sql operations wait --timeout=unlimited


# reassign ownership and cleanup automatic roles
cat <<EOF > user.sql
GRANT USAGE, CREATE ON SCHEMA public TO "$NEW_DB_OWNER";
REASSIGN OWNED BY "$OLD_DB_OWNER" TO "$NEW_DB_OWNER";
REVOKE cloudsqlsuperuser FROM "$OLD_DB_OWNER";
REVOKE cloudsqlsuperuser FROM "$NEW_DB_OWNER";
REVOKE "$OLD_DB_OWNER" FROM postgres;
EOF

  gsutil cp user.sql "gs://${DB_BUCKET}/${db}/"

  gcloud --quiet sql import sql $GCP_SQL_INSTANCE "gs://${DB_BUCKET}/${db}/user.sql" --database=$DB_NAME --user=postgres
  gcloud sql operations list --instance=$GCP_SQL_INSTANCE --filter='NOT status:done' --format='value(name)' | xargs -r gcloud sql operations wait --timeout=unlimited

  echo "Database load completed successfully"
}

# Main execution
if [ -d "/opt/app-root" ]; then
  cd /opt/app-root || exit 1
fi

if [ -n "$GCP_ENV" ]; then
  echo "Setting gcloud project to $GCP_ENV"
  gcloud config set project "$GCP_ENV" || { echo "Failed to set gcloud project"; exit 1; }
fi

oc login --server="$OC_SERVER" --token="$OC_TOKEN" || { echo "OC login failed"; exit 1; }
load_oc_db "$OC_NAMESPACE" "$DB_NAME"
