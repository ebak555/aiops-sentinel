resource "google_firestore_index" "runbooks_vector" {
  project    = var.project_id
  database   = google_firestore_database.aiops.name
  collection = "runbooks"

  fields {
    field_path = "__name__"
    order      = "ASCENDING"
  }

  fields {
    field_path = "embedding"
    vector_config {
      dimension = 768
      flat {}
    }
  }
}

resource "google_service_account" "runbook_mcp_server" {
  account_id   = "runbook-mcp-server"
  display_name = "Runbook RAG MCP server"
}

resource "google_project_iam_member" "runbook_mcp_server_vertex" {
  project = var.project_id
  role    = "roles/aiplatform.user"
  member  = "serviceAccount:${google_service_account.runbook_mcp_server.email}"
}

resource "google_project_iam_member" "runbook_mcp_server_firestore" {
  project = var.project_id
  role    = "roles/datastore.user"
  member  = "serviceAccount:${google_service_account.runbook_mcp_server.email}"
}

resource "google_cloud_run_v2_service" "runbook_mcp_server" {
  name     = "runbook-mcp-server"
  location = var.region

  template {
    service_account = google_service_account.runbook_mcp_server.email

    scaling {
      min_instance_count = 0
      max_instance_count = 2
    }

    containers {
      image = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.images.repository_id}/runbook-mcp-server:latest"

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
        name  = "GCP_REGION"
        value = var.region
      }
    }
  }

  # Left private (no public/allUsers invoker binding) -- Phase 5's agent
  # will be granted roles/run.invoker explicitly once it exists, same
  # pattern as anomaly-detector and correlator.
}

output "runbook_mcp_server_url" {
  value = google_cloud_run_v2_service.runbook_mcp_server.uri
}
