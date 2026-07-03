# Secret containers only -- the actual secret values are never set via
# Terraform (would land in state in plaintext). Populate them with:
#
#   echo -n "$ANTHROPIC_API_KEY" | gcloud secrets versions add anthropic-api-key --project=aiops-sentinel-16768 --data-file=-
#   echo -n "$GITHUB_TOKEN"      | gcloud secrets versions add github-token      --project=aiops-sentinel-16768 --data-file=-

resource "google_secret_manager_secret" "anthropic_api_key" {
  project   = var.project_id
  secret_id = "anthropic-api-key"

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret" "github_token" {
  project   = var.project_id
  secret_id = "github-token"

  replication {
    auto {}
  }
}
