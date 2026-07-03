resource "google_service_account" "ops_agent" {
  account_id   = "ops-agent"
  display_name = "AI Ops Agent Cloud Run service"
}

# The agent calls the GKE API server directly with a Google OAuth2 access
# token as its bearer token -- GKE authenticates that token and maps the
# identity to this RBAC subject, no VPC connector or kubeconfig needed
# since the cluster has a public control-plane endpoint. Scoped to a
# custom read-only Role (not the built-in "view") so it's explicit about
# covering pods/log, which isn't guaranteed across "view" role versions.
resource "kubernetes_role" "ops_agent_reader" {
  metadata {
    name      = "ops-agent-reader"
    namespace = "online-boutique"
  }

  rule {
    api_groups = [""]
    resources  = ["pods", "events"]
    verbs      = ["get", "list"]
  }

  rule {
    api_groups = [""]
    resources  = ["pods/log"]
    verbs      = ["get"]
  }
}

resource "kubernetes_role_binding" "ops_agent_reader" {
  metadata {
    name      = "ops-agent-reader"
    namespace = "online-boutique"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.ops_agent_reader.metadata[0].name
  }

  subject {
    kind      = "User"
    name      = google_service_account.ops_agent.email
    api_group = "rbac.authorization.k8s.io"
  }
}

resource "google_project_iam_member" "ops_agent_monitoring_viewer" {
  project = var.project_id
  role    = "roles/monitoring.viewer"
  member  = "serviceAccount:${google_service_account.ops_agent.email}"
}

# GKE authorizes API server requests in two layers: this project-level IAM
# role is the outer gate (permission to talk to the cluster at all); the
# kubernetes_role_binding above is the inner RBAC gate (permission for the
# specific resources/verbs). Both are required -- the RBAC binding alone
# isn't sufficient, which is what caused the agent's first real run to get
# 403s on get_pod_status/get_pod_events.
resource "google_project_iam_member" "ops_agent_container_viewer" {
  project = var.project_id
  role    = "roles/container.viewer"
  member  = "serviceAccount:${google_service_account.ops_agent.email}"
}

resource "google_project_iam_member" "ops_agent_firestore" {
  project = var.project_id
  role    = "roles/datastore.user"
  member  = "serviceAccount:${google_service_account.ops_agent.email}"
}

resource "google_secret_manager_secret_iam_member" "ops_agent_anthropic_key" {
  secret_id = google_secret_manager_secret.anthropic_api_key.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.ops_agent.email}"
}

resource "google_secret_manager_secret_iam_member" "ops_agent_github_token" {
  secret_id = google_secret_manager_secret.github_token.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.ops_agent.email}"
}

# The agent needs to call the runbook-mcp-server (private Cloud Run
# service from Phase 4) as an authenticated MCP client.
resource "google_cloud_run_v2_service_iam_member" "ops_agent_runbook_mcp_invoker" {
  name     = google_cloud_run_v2_service.runbook_mcp_server.name
  location = var.region
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.ops_agent.email}"
}
