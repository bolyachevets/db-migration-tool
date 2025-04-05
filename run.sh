#!/bin/sh

load_oc_db() {
  local namespace="$1"
  echo "Namespace: $namespace"
  local db="$2"
  echo "Database: $db"

  # Get the pod name
  pod_name=$(oc -n $namespace get pods --selector=$OC_LABEL -o name)
  echo "Pod name: $pod_name"

  # Remove the 'pod/' prefix from the pod name
  prefix="pod/"
  pod_name=${pod_name#"$prefix"}
  src="${pod_name}:/backups/daily/${DUMP_FILE_PATH}"
  echo "Source path: $src"

  # Download the database dump file
  db_file="${db}.sql.gz"
  oc -n $namespace cp $src $db_file

  if [ -e $db_file ]; then
    echo "Database dump downloaded successfully"
  else
    echo "Failed to download database dump"
    exit 1
  fi

  # Count files before extraction
  count_before=$(ls -1 | wc -l)

  # Detect if the file is a tar archive or a gzip-compressed file
  if tar -tf "$db_file" >/dev/null 2>&1; then
    echo "Extracting TAR.GZ archive..."
    tar -xzvf "$db_file"
  fi

  # Count files after extraction
  count_after=$(ls -1 | wc -l)

  # Calculate the number of new files
  new_files=$((count_after - count_before))
  echo "Number of files extracted: $new_files"

  if [ $new_files -eq 2 ]; then
    db_file="backup.sql"
  fi

  # Upload the database dump to Google Cloud Storage
  gsutil cp $db_file "gs://${DB_BUCKET}/${db}/"

  # Delete and recreate the database
  gcloud --quiet sql databases delete $DB_NAME --instance=$GCP_SQL_INSTANCE
  gcloud --quiet sql databases create $DB_NAME --instance=$GCP_SQL_INSTANCE

  # Grant permissions to the database user
  cat <<EOF > user.sql
GRANT USAGE, CREATE ON SCHEMA public TO "$DB_USER";
GRANT ALL PRIVILEGES ON DATABASE "$DB_NAME" TO "$DB_USER";
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL PRIVILEGES ON TABLES TO "$DB_USER";
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL PRIVILEGES ON SEQUENCES TO "$DB_USER";
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL PRIVILEGES ON FUNCTIONS TO "$DB_USER";
EOF

  gsutil cp user.sql "gs://${DB_BUCKET}/${db}/"

  gcloud --quiet sql import sql $GCP_SQL_INSTANCE "gs://${DB_BUCKET}/${db}/user.sql" --database=postgres
  gcloud sql operations list --instance=$GCP_SQL_INSTANCE --filter='status!=DONE' --format='value(name)' | xargs -r gcloud sql operations wait --timeout=unlimited

  # Import the database dump
  gcloud --quiet sql import sql $GCP_SQL_INSTANCE "gs://${DB_BUCKET}/${db}/${db_file}" --database=$DB_NAME
  gcloud sql operations list --instance=$GCP_SQL_INSTANCE --filter='status!=DONE' --format='value(name)' | xargs -r gcloud sql operations wait --timeout=unlimited
}

# Change to the working directory
cd /opt/app-root

# Log in to OpenShift
oc login --server=$OC_SERVER --token=$OC_TOKEN

# Load the database
load_oc_db $OC_NAMESPACE $DB_NAME
