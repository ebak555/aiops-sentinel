resource "random_password" "alert_webhook_password" {
  length  = 24
  special = false
}

resource "google_service_account" "alert_receiver" {
  account_id   = "alert-receiver"
  display_name = "Alert receiver Cloud Run service"
}

resource "google_pubsub_topic_iam_member" "alert_receiver_publisher" {
  topic  = google_pubsub_topic.aiops_alerts.name
  role   = "roles/pubsub.publisher"
  member = "serviceAccount:${google_service_account.alert_receiver.email}"
}

resource "google_cloud_run_v2_service" "alert_receiver" {
  name     = "alert-receiver"
  location = var.region
  ingress  = "INGRESS_TRAFFIC_ALL"

  template {
    service_account = google_service_account.alert_receiver.email

    scaling {
      min_instance_count = 0
      max_instance_count = 2
    }

    containers {
      image = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.images.repository_id}/alert-receiver:latest"

      resources {
        limits = {
          cpu    = "1"
          memory = "512Mi"
        }
      }

      env {
        name  = "GCP_PROJECT"
        value = var.project_id
      }
      env {
        name  = "PUBSUB_TOPIC"
        value = google_pubsub_topic.aiops_alerts.name
      }
      env {
        name  = "WEBHOOK_USERNAME"
        value = "aiops"
      }
      env {
        name  = "WEBHOOK_PASSWORD"
        value = random_password.alert_webhook_password.result
      }
    }
  }
}

# Cloud Monitoring's webhook notification channel calls this endpoint
# directly over HTTP with Basic Auth (no GCP IAM token support), so the
# service must allow unauthenticated invocations and check credentials
# in application code instead.
resource "google_cloud_run_v2_service_iam_member" "alert_receiver_public" {
  name     = google_cloud_run_v2_service.alert_receiver.name
  location = var.region
  role     = "roles/run.invoker"
  member   = "allUsers"
}

output "alert_receiver_url" {
  value = google_cloud_run_v2_service.alert_receiver.uri
}

output "alert_webhook_password" {
  value     = random_password.alert_webhook_password.result
  sensitive = true
}
