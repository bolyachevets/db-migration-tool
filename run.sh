#! /bin/sh

load_oc_db() {
  local namespace="$1"
  local db="$2"
  pod_name=$(oc -n $namespace get pods --selector=$OC_LABEL -o name)
  prefix="pod/"
  pod_name=${pod_name#"$prefix"}
  date=$(TZ=US/Pacific date +%Y-%m-%d)
  src="${pod_name}://backups/daily/${date}/${POD_NAME}-${OC_ENV}-${db}_${date}_01-00-00.sql.gz"
  db_file="${db}.sql.gz"
  oc -n $namespace cp $src $db_file
  if [ -e $db_file ]
  then
      echo "downloaded successfully from daily backups"
  else
    src="${pod_name}://backups/monthly/${date}/${POD_NAME}-${OC_ENV}-${db}_${date}_01-00-00.sql.gz"
    oc -n $namespace cp $src $db_file
    echo "downloaded successfully from monthly backups"
  fi
  gsutil cp $db_file "gs://${DB_BUCKET}/${db}/"
  gcloud --quiet sql databases delete $DB_NAME --instance=$GCP_SQL_INSTANCE
  gcloud sql databases create $DB_NAME --instance=$GCP_SQL_INSTANCE
  gcloud --quiet sql import sql $GCP_SQL_INSTANCE "gs://${DB_BUCKET}/${db}/${db_file}" --database=$DB_NAME --user=$DB_USER
  gcloud sql operations list --instance=$GCP_SQL_INSTANCE --filter='NOT status:done' --format='value(name)' | xargs -r gcloud sql operations wait --timeout=unlimited
}

cd /opt/app-root
oc login --server=$OC_SERVER --token=$OC_TOKEN

load_oc_db $OC_NAMESPACE $DB_NAME
