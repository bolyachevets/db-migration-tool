#!/bin/sh

load_oc_db() {
  local namespace="$1"
  echo $namespace
  local db="$2"
  pod_name=$(oc -n $namespace get pods --selector=$OC_LABEL -o name)
  echo $pod_name
  prefix="pod/"
  pod_name=${pod_name#"$prefix"}
  src="${pod_name}:/backups/daily/${DUMP_FILE_PATH}"
  echo $src
  db_file="${db}.sql.gz"
  oc -n $namespace cp $src $db_file
  if [ -e $db_file ]; then
      echo "downloaded successfully from backups"
  else
      echo "failed to successfully download from backups"
  fi

  # Count files before extraction
  count_before=$(ls -1 | wc -l)

  # Extract files
  tar -xzvf $db_file

  # Count files after extraction
  count_after=$(ls -1 | wc -l)

  # Calculate the number of new files
  new_files=$((count_after - count_before))
  echo "Number of files extracted: $new_files"

  if [ $new_files -eq 2 ]; then
    db_file="backup.sql"
  fi

  gsutil cp $db_file "gs://${DB_BUCKET}/${db}/"
  gcloud --quiet sql databases delete $DB_NAME --instance=$GCP_SQL_INSTANCE
  gcloud sql databases create $DB_NAME --instance=$GCP_SQL_INSTANCE

  # Disable triggers on all tables
  echo "Disabling triggers on all tables..."

  touch trigger.sql

  echo "EOF" >> trigger.sql
  echo "DO \$\$" >> trigger.sql
  echo "DECLARE" >> trigger.sql
  echo "r RECORD;" >> trigger.sql
  echo "BEGIN" >> trigger.sql
  echo "FOR r IN (SELECT tablename FROM pg_tables WHERE schemaname = 'public')" >> trigger.sql
  echo "LOOP" >> trigger.sql
  echo "EXECUTE 'ALTER TABLE public.' || r.tablename || ' DISABLE TRIGGER ALL';" >> trigger.sql
  echo "END LOOP;" >> trigger.sql
  echo "END \$\$;" >> trigger.sql
  echo "EOF" >> trigger.sql

  gsutil cp trigger.sql "gs://${DB_BUCKET}/${db}/"

  gcloud --quiet sql import sql $GCP_SQL_INSTANCE "gs://${DB_BUCKET}/${db}/trigger.sql" --database=$DB_NAME --user=postgres
  gcloud sql operations list --instance=$GCP_SQL_INSTANCE --filter='NOT status:done' --format='value(name)' | xargs -r gcloud sql operations wait --timeout=unlimited

  touch user.sql

  echo "GRANT USAGE, CREATE ON SCHEMA public TO \"$DB_USER\";" >> user.sql
  echo "GRANT ALL PRIVILEGES ON DATABASE \"$DB_NAME\" TO \"$DB_USER\";" >> user.sql
  echo "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL PRIVILEGES ON TABLES TO \"$DB_USER\";" >> user.sql
  echo "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL PRIVILEGES ON SEQUENCES TO \"$DB_USER\";" >> user.sql
  echo "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL PRIVILEGES ON FUNCTIONS TO \"$DB_USER\";" >> user.sql

  gsutil cp user.sql "gs://${DB_BUCKET}/${db}/"
  gcloud --quiet sql import sql $GCP_SQL_INSTANCE "gs://${DB_BUCKET}/${db}/user.sql" --database=$DB_NAME --user=postgres
  gcloud sql operations list --instance=$GCP_SQL_INSTANCE --filter='NOT status:done' --format='value(name)' | xargs -r gcloud sql operations wait --timeout=unlimited

  gcloud --quiet sql import sql $GCP_SQL_INSTANCE "gs://${DB_BUCKET}/${db}/${db_file}" --database=$DB_NAME --user=$DB_USER
  gcloud sql operations list --instance=$GCP_SQL_INSTANCE --filter='NOT status:done' --format='value(name)' | xargs -r gcloud sql operations wait --timeout=unlimited


  echo "EOF" > trigger.sql
  echo "DO \$\$" >> trigger.sql
  echo "DECLARE" >> trigger.sql
  echo "r RECORD;" >> trigger.sql
  echo "BEGIN" >> trigger.sql
  echo "FOR r IN (SELECT tablename FROM pg_tables WHERE schemaname = 'public')" >> trigger.sql
  echo "LOOP" >> trigger.sql
  echo "EXECUTE 'ALTER TABLE public.' || r.tablename || ' ENABLE TRIGGER ALL';" >> trigger.sql
  echo "END LOOP;" >> trigger.sql
  echo "END \$\$;" >> trigger.sql
  echo "EOF" >> trigger.sql

  gcloud --quiet sql import sql $GCP_SQL_INSTANCE "gs://${DB_BUCKET}/${db}/trigger.sql" --database=$DB_NAME --user=postgres
  gcloud sql operations list --instance=$GCP_SQL_INSTANCE --filter='NOT status:done' --format='value(name)' | xargs -r gcloud sql operations wait --timeout=unlimited

}

cd /opt/app-root
oc login --server=$OC_SERVER --token=$OC_TOKEN

load_oc_db $OC_NAMESPACE $DB_NAME
