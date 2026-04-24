resource "google_cloudbuild_trigger" "github_trigger" {
    name     = "${var.environment}-${var.project_name}-wb"
    location = var.region

    service_account = var.sa_id

    repository_event_config {
        repository = var.repository_id

        push {
            branch = "^${var.gh_branch}$"
        }
    }

    substitutions = {
        _REGION         = var.region
        _ARTIFACT_REPO  = var.artifact_repo
        _CONTAINER_NAME = var.project_name
        _CONTAINER_PORT = tostring(var.container_port)
        _PIPELINE_NAME  = var.pipeline_name
        _SERVICE_NAME   = var.service_name
        _INGRESS_TYPE   = var.ingress_type
        _SECURITY_TYPE  = var.security_type
        _HEALTH_CHECK   = var.health_check_url
        _LOAD_BALANCER  = var.load_balancer_uri
    }

    filename = "cloudbuild.yaml"
}