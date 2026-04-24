resource "google_clouddeploy_target" "target" {
    name     = "${var.environment}-${var.canary_environment}-${var.project_name}-cdt"
    location = var.region

    run {
        location = "projects/${var.project_id_gcp}/locations/${var.region}"
    }
}