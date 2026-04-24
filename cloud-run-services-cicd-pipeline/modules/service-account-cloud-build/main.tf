resource "google_service_account" "cloudbuild_sa" {
    account_id   = "${var.environment}-${var.project_name}-cb-sa"
    display_name = "Cloud Build Service Account para ${var.project_name}"
}

resource "google_project_iam_member" "cloudbuild_sa_roles" {
    for_each = toset([
        "roles/run.admin",
        "roles/cloudbuild.builds.builder",
        "roles/artifactregistry.writer",
        "roles/clouddeploy.operator",
        "roles/iam.serviceAccountUser"
    ])
    project = var.project_id_gcp
    role    = each.value
    member  = "serviceAccount:${google_service_account.cloudbuild_sa.email}"
}

resource "google_cloud_run_service_iam_member" "cloudbuild_sa_roles" {
    project = var.project_id_gcp
    service = var.service_name
    role    = "roles/run.invoker"
    member  = "serviceAccount:${google_service_account.cloudbuild_sa.email}"
}