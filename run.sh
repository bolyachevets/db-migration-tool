#!/bin/sh
set -e  # Exit immediately if any command fails

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
  oc -n $namespace cp $src $db_file || { echo "Failed to copy file from pod"; exit 1; }

  if [ -e $db_file ]; then
    echo "Database dump downloaded successfully"
  else
    echo "Failed to download database dump"
    exit 1
  fi

  # Count files before extraction
  count_before=$(ls -1 | wc -l)

  # Extract the database dump
  tar -xzvf $db_file || { echo "Failed to extract file"; exit 1; }

  # Count files after extraction
  count_after=$(ls -1 | wc -l)

  # Calculate the number of new files
  new_files=$((count_after - count_before))
  echo "Number of files extracted: $new_files"

  if [ $new_files -eq 2 ]; then
    db_file="backup.sql"
  fi

  # Upload the database dump to Google Cloud Storage
  gsutil cp $db_file "gs://${DB_BUCKET}/${db}/" || { echo "Failed to upload to GCS"; exit 1; }

  # Delete and recreate the database
  gcloud --quiet sql databases delete $DB_NAME --instance=$GCP_SQL_INSTANCE || { echo "Failed to delete database"; exit 1; }
  gcloud sql databases create $DB_NAME --instance=$GCP_SQL_INSTANCE || { echo "Failed to create database"; exit 1; }

  # Disable foreign key checks
  echo "Disabling foreign key checks..."
  cat <<EOF > disable_fk.sql
SET session_replication_role = replica;
EOF

  gsutil cp disable_fk.sql "gs://${DB_BUCKET}/${db}/" || { echo "Failed to upload disable_fk.sql"; exit 1; }

  gcloud --quiet sql import sql $GCP_SQL_INSTANCE "gs://${DB_BUCKET}/${db}/disable_fk.sql" --database=$DB_NAME --user=postgres || { echo "Failed to disable foreign key checks"; exit 1; }
  gcloud sql operations list --instance=$GCP_SQL_INSTANCE --filter='NOT status:done' --format='value(name)' | xargs -r gcloud sql operations wait --timeout=unlimited

  # Grant permissions to the database user
  cat <<EOF > user.sql
GRANT USAGE, CREATE ON SCHEMA public TO "$DB_USER";
GRANT ALL PRIVILEGES ON DATABASE "$DB_NAME" TO "$DB_USER";
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL PRIVILEGES ON TABLES TO "$DB_USER";
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL PRIVILEGES ON SEQUENCES TO "$DB_USER";
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL PRIVILEGES ON FUNCTIONS TO "$DB_USER";
EOF

  gsutil cp user.sql "gs://${DB_BUCKET}/${db}/" || { echo "Failed to upload user.sql"; exit 1; }

  gcloud --quiet sql import sql $GCP_SQL_INSTANCE "gs://${DB_BUCKET}/${db}/user.sql" --database=$DB_NAME --user=postgres || { echo "Failed to grant user permissions"; exit 1; }
  gcloud sql operations list --instance=$GCP_SQL_INSTANCE --filter='NOT status:done' --format='value(name)' | xargs -r gcloud sql operations wait --timeout=unlimited

  # Import the database dump
  gcloud --quiet sql import sql $GCP_SQL_INSTANCE "gs://${DB_BUCKET}/${db}/${db_file}" --database=$DB_NAME --user=$DB_USER || { echo "Failed to import database"; exit 1; }
  gcloud sql operations list --instance=$GCP_SQL_INSTANCE --filter='NOT status:done' --format='value(name)' | xargs -r gcloud sql operations wait --timeout=unlimited

  # Re-enable foreign key checks
  echo "Re-enabling foreign key checks..."
  cat <<EOF > enable_fk.sql
SET session_replication_role = origin;
EOF

  gsutil cp enable_fk.sql "gs://${DB_BUCKET}/${db}/" || { echo "Failed to upload enable_fk.sql"; exit 1; }

  gcloud --quiet sql import sql $GCP_SQL_INSTANCE "gs://${DB_BUCKET}/${db}/enable_fk.sql" --database=$DB_NAME --user=postgres || { echo "Failed to re-enable foreign key checks"; exit 1; }
  gcloud sql operations list --instance=$GCP_SQL_INSTANCE --filter='NOT status:done' --format='value(name)' | xargs -r gcloud sql operations wait --timeout=unlimited
}

# Change to the working directory
cd /opt/app-root || { echo "Failed to change directory"; exit 1; }

# Log in to OpenShift
oc login --server=$OC_SERVER --token=$OC_TOKEN || { echo "Failed to log in to OpenShift"; exit 1; }

# Load the database
load_oc_db $OC_NAMESPACE $DB_NAME
