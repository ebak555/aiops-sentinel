resource "google_service_account" "anomaly_detector" {
  account_id   = "anomaly-detector"
  display_name = "Anomaly detector Cloud Run service"
}

resource "google_project_iam_member" "anomaly_detector_monitoring_viewer" {
  project = var.project_id
  role    = "roles/monitoring.viewer"
  member  = "serviceAccount:${google_service_account.anomaly_detector.email}"
}

resource "google_pubsub_topic_iam_member" "anomaly_detector_publisher" {
  topic  = google_pubsub_topic.aiops_alerts.name
  role   = "roles/pubsub.publisher"
  member = "serviceAccount:${google_service_account.anomaly_detector.email}"
}

resource "google_cloud_run_v2_service" "anomaly_detector" {
  name     = "anomaly-detector"
  location = var.region

  template {
    service_account = google_service_account.anomaly_detector.email

    scaling {
      min_instance_count = 0
      max_instance_count = 2
    }

    containers {
      image = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.images.repository_id}/anomaly-detector:latest"

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
    }
  }
}

# Unlike the alert-receiver (which Cloud Monitoring calls with Basic Auth,
# no IAM support), Cloud Scheduler supports OIDC tokens natively, so this
# service stays private -- only this dedicated invoker identity can call it.
resource "google_service_account" "scheduler_invoker" {
  account_id   = "scheduler-invoker"
  display_name = "Cloud Scheduler invoker for AIOps Cloud Run jobs"
}

resource "google_cloud_run_v2_service_iam_member" "anomaly_detector_invoker" {
  name     = google_cloud_run_v2_service.anomaly_detector.name
  location = var.region
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.scheduler_invoker.email}"
}

resource "google_cloud_scheduler_job" "anomaly_detector_trigger" {
  name      = "anomaly-detector-trigger"
  region    = var.region
  schedule  = "* * * * *"
  time_zone = "UTC"

  http_target {
    http_method = "POST"
    uri         = "${google_cloud_run_v2_service.anomaly_detector.uri}/detect"

    oidc_token {
      service_account_email = google_service_account.scheduler_invoker.email
      audience               = google_cloud_run_v2_service.anomaly_detector.uri
    }
  }
}

output "anomaly_detector_url" {
  value = google_cloud_run_v2_service.anomaly_detector.uri
}
