# State lives in a Cloud Storage bucket inside the universe. `storage` is one of
# the 31 available services, and keeping state in-universe is the right answer
# for a sovereign environment — state contains resource names and connection
# details we should not park in a different jurisdiction.
#
# Bootstrap order: the bucket cannot be created by the config that stores its
# own state in it. Create it once by hand, then `tofu init -migrate-state`:
#
#   gcloud storage buckets create "gs://${PROJECT_SHORT}-tofu-state" \
#     --project "$PROJECT_ID" --location "$UNIVERSE_REGION" --uniform-bucket-level-access
#
# Note Cloud Storage in GCD has no default location, so --location is required.
# Values come from -backend-config on `tofu init`, never hardcoded here.
terraform {
  backend "gcs" {}
}
