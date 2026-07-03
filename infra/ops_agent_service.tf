resource "google_cloud_run_v2_service" "ops_agent" {
  name                = "ops-agent"
  location            = var.region
  deletion_protection = false

  template {
    service_account = google_service_account.ops_agent.email
    timeout         = "540s"

    scaling {
      min_instance_count = 0
      max_instance_count = 2
    }

    containers {
      image = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.images.repository_id}/ops-agent:latest"

      resources {
        limits = {
          cpu    = "2"
          memory = "1Gi"
        }
      }

      env {
        name  = "GCP_PROJECT"
        value = var.project_id
      }
      env {
        name  = "GCP_REGION"
        value = var.region
      }
      env {
        name  = "CLUSTER_ENDPOINT"
        value = google_container_cluster.primary.endpoint
      }
      env {
        name  = "CLUSTER_CA_CERT"
        value = google_container_cluster.primary.master_auth[0].cluster_ca_certificate
      }
      env {
        name  = "RUNBOOK_MCP_URL"
        value = google_cloud_run_v2_service.runbook_mcp_server.uri
      }
      env {
        name  = "GITHUB_REPO"
        value = "ebak555/aiops-sentinel"
      }
      env {
        name = "ANTHROPIC_API_KEY"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.anthropic_api_key.secret_id
            version = "latest"
          }
        }
      }
      env {
        name = "GITHUB_TOKEN"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.github_token.secret_id
            version = "latest"
          }
        }
      }
    }
  }
}

resource "google_cloud_run_v2_service_iam_member" "ops_agent_pubsub_invoker" {
  name     = google_cloud_run_v2_service.ops_agent.name
  location = var.region
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.pubsub_push_invoker.email}"
}

resource "google_pubsub_subscription" "aiops_incidents_to_agent" {
  name  = "aiops-incidents-to-agent"
  topic = google_pubsub_topic.aiops_incidents.name

  push_config {
    push_endpoint = "${google_cloud_run_v2_service.ops_agent.uri}/investigate"

    oidc_token {
      service_account_email = google_service_account.pubsub_push_invoker.email
    }
  }

  # Multi-turn agent investigations can run long; a short ack deadline
  # would cause Pub/Sub to redeliver (and double-investigate) before the
  # agent finishes. 600s is Pub/Sub's own maximum.
  ack_deadline_seconds = 600

  # Without this, a failing investigation (e.g. the Anthropic account
  # running out of credit) gets redelivered every few seconds forever --
  # each retry is a real Claude API call. 5 is Pub/Sub's own minimum.
  dead_letter_policy {
    dead_letter_topic     = google_pubsub_topic.aiops_dead_letter.id
    max_delivery_attempts = 5
  }

  depends_on = [
    google_service_account_iam_member.pubsub_push_invoker_token_creator,
    google_pubsub_topic_iam_member.dead_letter_publisher,
  ]
}

resource "google_pubsub_subscription_iam_member" "incidents_dead_letter_subscriber" {
  subscription = google_pubsub_subscription.aiops_incidents_to_agent.name
  role         = "roles/pubsub.subscriber"
  member       = "serviceAccount:service-${data.google_project.current.number}@gcp-sa-pubsub.iam.gserviceaccount.com"
}

output "ops_agent_url" {
  value = google_cloud_run_v2_service.ops_agent.uri
}
