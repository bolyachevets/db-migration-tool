# Variables
TARGET_PROJECT_ID=""
INSTANCE_NAME="auth-db"
ENV="dev"
REGION="northamerica-northeast1"
BUCKET_NAME="auth-db-dump"
OC_NAMESPACE=""
DUMP_FILE="2024-07-26/postgresql-prod-auth-db_2024-07-26_01-00-00.sql.gz"
POSTGRES_VERSION="POSTGRES_15"

gcloud config set project "${TARGET_PROJECT_ID}-${ENV}"

gcloud sql instances create "${INSTANCE_NAME}-${ENV}" \
    --database-version=$POSTGRES_VERSION \
    --region=$REGION \
    --storage-type=SSD \
    --storage-auto-increase \
    --backup-start-time=00:00 \
    --enable-point-in-time-recovery \
    --retained-backups-count=7 \
    --retained-transaction-log-days=7 \
    --availability-type=zonal \
    --tier=db-custom-4-16384 \
    --storage-size=100GB \
    --project="${TARGET_PROJECT_ID}-${ENV}" \
    --maintenance-window-day=MON \
    --maintenance-window-hour=4 \
    --backup-start-time=08:00

gsutil mb -l $REGION "gs://${BUCKET_NAME}-${ENV}/"
gsutil cp /dev/null -l $REGION "gs://${BUCKET_NAME}-${ENV}/${INSTANCE_NAME}"

gcloud run jobs create db-migration-tool \
    --project="${TARGET_PROJECT_ID}-${ENV}" \
    --region=$REGION \
    --image=northamerica-northeast1-docker.pkg.dev/new-project-id/job-repo/db-migration-tool:dev \
    --cpu=8000m \
    --memory=32Gi \
    --max-retries=3 \
    --task-timeout=600s \
    --set-env-vars=OC_SERVER=https://api.silver.devops.gov.bc.ca:6443 \
    --set-env-vars=OC_NAMESPACE="${OC_NAMESPACE}-${ENV}" \
    --set-env-vars=DB_NAME=auth-db \
    --set-env-vars=GCP_SQL_INSTANCE="${INSTANCE_NAME}-${ENV}" \
    --set-env-vars=DB_BUCKET="${BUCKET_NAME}-${ENV}" \
    --set-env-vars=DB_USER=postgres \
    --set-env-vars=OC_LABEL=name=backup \
    --set-env-vars=DUMP_FILE_PATH=$DUMP_FILE \
    --set-secrets=OC_TOKEN="OC_TOKEN_${OC_NAMESPACE}-${ENV}:latest" \
    --execution-environment=gen2 \
    --labels=cloud.googleapis.com/location=$REGION \
    --labels=run.googleapis.com/lastUpdatedTime=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
