resource "google_service_account" "gmp_frontend" {
  account_id   = "gmp-frontend"
  display_name = "GMP query frontend (Grafana datasource)"
}

resource "google_project_iam_member" "gmp_frontend_viewer" {
  project = var.project_id
  role    = "roles/monitoring.viewer"
  member  = "serviceAccount:${google_service_account.gmp_frontend.email}"
}

resource "google_service_account_iam_member" "gmp_frontend_workload_identity" {
  service_account_id = google_service_account.gmp_frontend.name
  role                = "roles/iam.workloadIdentityUser"
  member              = "serviceAccount:${var.project_id}.svc.id.goog[gmp-public/frontend]"
}

output "gmp_frontend_gsa_email" {
  value = google_service_account.gmp_frontend.email
}
