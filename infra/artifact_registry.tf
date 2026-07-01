resource "google_artifact_registry_repository" "images" {
  location      = var.region
  repository_id = "${var.cluster_name}-images"
  format        = "DOCKER"
  description   = "Container images for the AIOps agent and MCP tool servers"
}
