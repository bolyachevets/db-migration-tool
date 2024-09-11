#!/bin/bash

# DEV
ENV="dev"
TAAG="dev"
HOST_PROJECT_ID="c4hnrd"
TARGET_PROJECT_ID="gtksf3"
TARGET_PROJECT_CLOUD_RUN_SERVICE_AGENT=""
CLOUD_RUN_NAME="auth-api"
SHARED_VPC_NAME="bcr-vpc"
SHARED_VPC_SUBNET="bcr-common-${ENV}-montreal"
REGION="northamerica-northeast1"
SHARED_VPC_CONNECTOR="bcr-vpc-${ENV}-montreal-con"
HOST_PROJECT_ID="${HOST_PROJECT_ID}-${ENV}"
TARGET_PROJECT_ID="${TARGET_PROJECT_ID}-${ENV}"
CLOUD_RUN_NAME="${CLOUD_RUN_NAME}-${ENV}"
SHARED_VPC_NAME="${SHARED_VPC_NAME}-${ENV}"
TARGET_PROJECT_CLOUD_RUN_SERVICE_ACCOUNT="sa-api@${TARGET_PROJECT_ID}-${ENV}.iam.gserviceaccount.com"
DATABASE_UNIX_SOCKET="cloudsql/${TARGET_PROJECT_ID}:${REGION}:auth-db-${ENV}"

gcloud config set project $HOST_PROJECT_ID

# enable Host APIS

gcloud services enable vpcaccess.googleapis.com --project=$HOST_PROJECT_ID
# gcloud services enable connectivity.googleapis.com --project=$HOST_PROJECT_ID


# Shared VPC - manual

# set up VPC
gcloud compute networks create $SHARED_VPC_NAME --project=$HOST_PROJECT_ID --description=BC\ Registries\ shared\ VPC --subnet-mode=custom --mtu=1460 --enable-ula-internal-ipv6 --bgp-routing-mode=regional

# create subnets
gcloud compute networks subnets create $SHARED_VPC_SUBNET --project=$HOST_PROJECT_ID --description=common\ services\ -\ montreal\ region --range=10.0.1.0/28 --stack-type=IPV4_IPV6 --ipv6-access-type=INTERNAL --network=$SHARED_VPC_NAME --region=$REGION --enable-private-ip-google-access

# create connectors
gcloud compute networks vpc-access connectors create $SHARED_VPC_CONNECTOR \
  --subnet $SHARED_VPC_SUBNET \
  --region $REGION

# create an allocated IP range for the Private Service Connection (PSC)
gcloud compute addresses create "${SHARED_VPC_NAME}-psc-range" \
    --global \
    --purpose=VPC_PEERING \
    --addresses=10.5.0.0 \
    --prefix-length=24 \
    --description="Allocated range for PSC" \
    --network=$SHARED_VPC_NAME \
    --project=$HOST_PROJECT_ID

# bigquery dataset for the log sink
bq --location=$REGION mk \
--dataset \
--default_table_expiration=31536000 \
${HOST_PROJECT_ID}:cloud_run_logs_${TAG}


gcloud config set project $TARGET_PROJECT_ID

command line attach project to VPC
gcloud compute $SHARED_VPC_NAME associated-projects add $TARGET_PROJECT_ID \
    --host-project=$HOST_PROJECT_ID

# Enable attached Service APIs
gcloud services enable compute.googleapis.com --project=$TARGET_PROJECT_ID
gcloud services enable networkservices.googleapis.com --project=$TARGET_PROJECT_ID

gcloud services vpc-peerings connect \
    --service=servicenetworking.googleapis.com \
    --ranges="${SHARED_VPC_NAME}-psc-range" \
    --network=${SHARED_VPC_NAME} \
    --project=${HOST_PROJECT_ID}

# permissions

gcloud projects add-iam-policy-binding $TARGET_PROJECT_ID \
    --member="serviceAccount:${HOST_PROJECT_CLOUD_RUN_SERVICE_AGENT}" \
    --role="roles/compute.viewer" --condition=None

gcloud projects add-iam-policy-binding $HOST_PROJECT_ID \
    --member="serviceAccount:${TARGET_PROJECT_CLOUD_RUN_SERVICE_AGENT}" \
   --role="roles/vpcaccess.user" --condition=None
gcloud projects add-iam-policy-binding $HOST_PROJECT_ID \
   --member="serviceAccount:${TARGET_PROJECT_CLOUD_RUN_SERVICE_AGENT}" \
   --role="roles/compute.viewer" --condition=None



gcloud projects add-iam-policy-binding $HOST_PROJECT_ID \
    --member="serviceAccount:${TARGET_PROJECT_CLOUD_RUN_SERVICE_AGENT}" \
    --role="roles/vpcaccess.user" --condition=None
gcloud projects add-iam-policy-binding $TARGET_PROJECT_ID \
  --member="serviceAccount:${TARGET_PROJECT_CLOUD_RUN_SERVICE_AGENT}" \
  --role="roles/compute.networkUser" --condition=None
gcloud projects add-iam-policy-binding $TARGET_PROJECT_ID \
    --member="serviceAccount:${TARGET_PROJECT_CLOUD_RUN_SERVICE_AGENT}" \
    --role="roles/vpcaccess.user" --condition=None


# Creat Cloud Run
gcloud run deploy auth-api-$TAG \
  --image="northamerica-northeast1-docker.pkg.dev/${ARTIFACTORY_PROJECT_ID}-tools/cloud-run-repo/auth-api:${TAG}" \
  --region=northamerica-northeast1 \
  --platform=managed \
  --vpc-connector="projects/${HOST_PROJECT_ID}/locations/northamerica-northeast1/connectors/$SHARED_VPC_CONNECTOR" \
  --vpc-egress=private-ranges-only \
  --allow-unauthenticated \
  --service-account=$TARGET_PROJECT_CLOUD_RUN_SERVICE_ACCOUNT \
  --cpu=1 \
  --memory=512Mi \
  --timeout=600s \
  --concurrency=7 \
  --max-instances=7 \
  --port=8080 \
  --set-env-vars=DEPLOYMENT_PLATFORM=GCP,DEPLOYMENT_ENV=development,DATABASE_USERNAME=auth,DATABASE_PORT=5432,DATABASE_NAME=auth-db,DATABASE_UNIX_SOCKET=$DATABASE_UNIX_SOCKET,DEPLOYMENT_PROJECT=$TARGET_PROJECT_ID \
  --add-cloudsql-instances="auth-db-${TAG}" \
  --cpu-boost

# Create log sink
gcloud logging sinks create cloud_run_errors_${TAG} \
bigquery.googleapis.com/projects/${HOST_PROJECT_ID}/datasets/cloud_run_logs_${TAG} \
--log-filter='resource.type="cloud_run_revision" AND severity="ERROR"' \
--use-partitioned-tables

export CLOUD_RUN_NAME

ALERT_POLICIES_DIR="alert_policies"

for policy_file in "$ALERT_POLICIES_DIR"/*.yml; do
  policy_name=$(basename "$policy_file")

  echo "Processing $policy_name..."

  envsubst < "$policy_file" > alert_policy.yml
  gcloud alpha monitoring policies create --policy-from-file=alert_policy.yml

  if [ $? -eq 0 ]; then
    echo "Successfully created alert policy from $policy_name."
  else
    echo "Failed to create alert policy from $policy_name."
  fi

  rm -f alert_policy.yml

done
