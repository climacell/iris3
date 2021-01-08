#!/bin/zsh

set -x
set -u
set -e

START=$(date "+%s")

ROLEID=iris

LOGS_TOPIC=iris_logs_topic
REQUESTFULLLABELING_TOPIC=iris_requestfulllabeling_topic
LOG_SINK=iris_log
DO_LABEL_SUBSCRIPTION=do_label
LABEL_ONE_SUBSCRIPTION=label_one
REGION=us-central
REGION_ABBREV=uc

if [[ $# -eq 0 ]]; then
  echo Missing project id argument
  exit
fi

#TODO We list projects and then extract project id from output? This serves
# to check that the project exists and allows us to get projects by name, not just ID,
# but that is error-prone, particularly as one project id can be a substring of another,
# or an id could be a substring of a name.
# Better: Do an existence  check with gcloud projects describe;and only support id, not name;
# then use the $1 (command-line arg directly as our PROJECTID.

PROJECTID=$(gcloud projects list | grep -i "^$1 " | awk '{print $1}')

if [ -z "$PROJECTID" ]; then
  echo "Project $1 Not Found!"
  exit 1
fi

echo "Project ID $PROJECTID"
gcloud config set project "$PROJECTID"

GAE_SVC=$(cat app.yaml | grep "service:" | awk '{print $2}')
PUBSUB_VERIFICATION_TOKEN=$(cat app.yaml | grep " PUBSUB_VERIFICATION_TOKEN:" | awk '{print $2}')
LABEL_ONE_SUBSCRIPTION_ENDPOINT="https://${GAE_SVC}-dot-${PROJECTID}.${REGION_ABBREV}.r.appspot.com/label_one?token=${PUBSUB_VERIFICATION_TOKEN}"
DO_LABEL_SUBSCRIPTION_ENDPOINT="https://${GAE_SVC}-dot-${PROJECTID}.${REGION_ABBREV}.r.appspot.com/do_label?token=${PUBSUB_VERIFICATION_TOKEN}"

declare -A enabled_services
while read -r svc _; do
  enabled_services["$svc"]=yes
done < <(gcloud services list | tail -n +2)

required_svcs=(
  cloudresourcemanager.googleapis.com
  pubsub.googleapis.com
  compute.googleapis.com
  bigtable.googleapis.com
  storage-component.googleapis.com
  sql-component.googleapis.com
  sqladmin.googleapis.com
)

# Enable services if they are not
for svc in "${required_svcs[@]}"; do
  [[ "${enabled_services["$svc"]}" == "yes" ]] || gcloud services enable "$svc"
done

# Get organization id for this project
ORGID=$(curl -X POST -H "Authorization: Bearer \"$(gcloud auth print-access-token)\"" \
  -H "Content-Type: application/json; charset=utf-8" \
  https://cloudresourcemanager.googleapis.com/v1/projects/"${PROJECTID}":getAncestry | grep -A 1 organization |
  tail -n 1 | tr -d ' ' | cut -d'"' -f4)

# Create App Engine app
gcloud app describe >&/dev/null || gcloud app create --region=$REGION

# Create custom role to run iris
gcloud iam roles describe "$ROLEID" --organization "$ORGID" ||
  gcloud iam roles create "$ROLEID" --organization "$ORGID" --file roles.yaml

# Assign default iris app engine service account with role on organization level
gcloud organizations add-iam-policy-binding "$ORGID" \
  --member "serviceAccount:$PROJECTID@appspot.gserviceaccount.com" \
  --role "organizations/$ORGID/roles/$ROLEID"

# Create PubSub topic for receiving logs about new GCP objects
gcloud pubsub topics describe "$LOGS_TOPIC" ||
  gcloud pubsub topics create $LOGS_TOPIC --project="$PROJECTID" --quiet >/dev/null

# Create PubSub subscription for receiving log about new GCP objects
gcloud pubsub subscriptions describe "$LABEL_ONE_SUBSCRIPTION" --project="$PROJECTID" ||
  gcloud pubsub subscriptions create "$LABEL_ONE_SUBSCRIPTION" --topic "$LOGS_TOPIC" --project="$PROJECTID" \
    --push-endpoint "$LABEL_ONE_SUBSCRIPTION_ENDPOINT" \
    --quiet >/dev/null

# Create PubSub topic for receiving commands from the /schedule handler that is triggered from cron
gcloud pubsub topics describe "$REQUESTFULLLABELING_TOPIC" --project="$PROJECTID" ||
  gcloud pubsub topics create "$REQUESTFULLLABELING_TOPIC" --project="$PROJECTID" --quiet >/dev/null

# Create PubSub subscription for receiving log about new GCP objects
gcloud pubsub subscriptions describe "$DO_LABEL_SUBSCRIPTION" --project="$PROJECTID" ||
  gcloud pubsub subscriptions create "$DO_LABEL_SUBSCRIPTION" --topic "$REQUESTFULLLABELING_TOPIC" --project="$PROJECTID" \
    --push-endpoint "$DO_LABEL_SUBSCRIPTION_ENDPOINT" \
    --quiet >/dev/null

log_filter=('protoPayload.methodName:(')
log_filter+=('"storage.buckets.create"' OR '"compute.instances.insert"' OR '"compute.instances.start"' OR '"datasetservice.insert"')
log_filter+=('OR "tableservice.insert"' OR '"google.bigtable.admin.v2.BigtableInstanceAdmin.CreateInstance"')
log_filter+=('OR "cloudsql.instances.create"' OR '"v1.compute.disks.insert"' OR '"v1.compute.disks.createSnapshot"')
log_filter+=('OR "google.pubsub.v1.Subscriber.CreateSubscription"')
log_filter+=(')')

# Create or update a sink at org level
if ! gcloud logging sinks describe --organization="$ORGID" "$LOG_SINK" >&/dev/null; then
  gcloud logging sinks create "$LOG_SINK" \
    pubsub.googleapis.com/projects/"$PROJECTID"/topics/"$LOGS_TOPIC" \
    --organization="$ORGID" --include-children \
    --log-filter="${log_filter[*]}" --quiet
else
  gcloud logging sinks update "$LOG_SINK" \
    pubsub.googleapis.com/projects/"$PROJECTID"/topics/"$LOGS_TOPIC" \
    --organization="$ORGID" \
    --log-filter="${log_filter[*]}" --quiet
fi

# Extract service account from sink configuration
svcaccount=$(gcloud logging sinks describe --organization="$ORGID" "$LOG_SINK" | grep writerIdentity | awk '{print $2}')

# Assign extracted service account to a topic with a publisher role
gcloud projects add-iam-policy-binding "$PROJECTID" \
  --member="$svcaccount" --role=roles/pubsub.publisher --quiet

# Deploy the application
gcloud app deploy -q app.yaml cron.yaml

FINISH=$(date "+%s")
ELAPSED_SEC=$((FINISH - START))
echo "Elapsed time $ELAPSED_SEC s"
