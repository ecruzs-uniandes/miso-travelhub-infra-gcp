resource "google_artifact_registry_repository" "repo" {
    location      = var.region
    repository_id = "${var.environment}-${var.project_name}-arti-repo"
    format        = "DOCKER"
}