data "google_project" "current" {
  project_id = var.project_id
}

resource "google_firestore_database" "aiops" {
  project     = var.project_id
  name        = "(default)"
  location_id = var.region
  type        = "FIRESTORE_NATIVE"
}

resource "google_service_account" "correlator" {
  account_id   = "correlator"
  display_name = "Alert correlator Cloud Run service"
}

resource "google_project_iam_member" "correlator_firestore" {
  project = var.project_id
  role    = "roles/datastore.user"
  member  = "serviceAccount:${google_service_account.correlator.email}"
}

resource "google_pubsub_topic_iam_member" "correlator_publisher" {
  topic  = google_pubsub_topic.aiops_incidents.name
  role   = "roles/pubsub.publisher"
  member = "serviceAccount:${google_service_account.correlator.email}"
}

resource "google_cloud_run_v2_service" "correlator" {
  name     = "correlator"
  location = var.region

  template {
    service_account = google_service_account.correlator.email

    scaling {
      min_instance_count = 0
      max_instance_count = 2
    }

    containers {
      image = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.images.repository_id}/correlator:latest"

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
        name  = "INCIDENTS_TOPIC"
        value = google_pubsub_topic.aiops_incidents.name
      }
    }
  }

  depends_on = [google_firestore_database.aiops]
}

# Identity Pub/Sub push uses to call the correlator's HTTP endpoint.
resource "google_service_account" "pubsub_push_invoker" {
  account_id   = "pubsub-push-invoker"
  display_name = "Pub/Sub push subscription invoker"
}

resource "google_cloud_run_v2_service_iam_member" "correlator_invoker" {
  name     = google_cloud_run_v2_service.correlator.name
  location = var.region
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.pubsub_push_invoker.email}"
}

# Pub/Sub's own service agent needs permission to mint OIDC tokens as the
# push-invoker identity in order to authenticate push deliveries.
resource "google_service_account_iam_member" "pubsub_push_invoker_token_creator" {
  service_account_id = google_service_account.pubsub_push_invoker.name
  role                = "roles/iam.serviceAccountTokenCreator"
  member              = "serviceAccount:service-${data.google_project.current.number}@gcp-sa-pubsub.iam.gserviceaccount.com"
}

resource "google_pubsub_subscription" "aiops_alerts_to_correlator" {
  name  = "aiops-alerts-to-correlator"
  topic = google_pubsub_topic.aiops_alerts.name

  push_config {
    push_endpoint = "${google_cloud_run_v2_service.correlator.uri}/correlate"

    oidc_token {
      service_account_email = google_service_account.pubsub_push_invoker.email
    }
  }

  ack_deadline_seconds = 30

  dead_letter_policy {
    dead_letter_topic     = google_pubsub_topic.aiops_dead_letter.id
    max_delivery_attempts = 5
  }

  depends_on = [
    google_service_account_iam_member.pubsub_push_invoker_token_creator,
    google_pubsub_topic_iam_member.dead_letter_publisher,
  ]
}

resource "google_pubsub_subscription_iam_member" "alerts_dead_letter_subscriber" {
  subscription = google_pubsub_subscription.aiops_alerts_to_correlator.name
  role         = "roles/pubsub.subscriber"
  member       = "serviceAccount:service-${data.google_project.current.number}@gcp-sa-pubsub.iam.gserviceaccount.com"
}

output "correlator_url" {
  value = google_cloud_run_v2_service.correlator.uri
}
