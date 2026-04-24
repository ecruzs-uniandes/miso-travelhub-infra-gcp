resource "google_service_account" "clouddeploya_sa" {
    account_id   = "${var.environment}-${var.project_name}-cda-sa"
    display_name = "Cloud deploy Automation Service Account para ${var.project_name}"
}

resource "google_project_iam_member" "clouddeploy_sa_roles" {
    for_each = toset([
    "roles/clouddeploy.releaser",
    "roles/clouddeploy.serviceAgent",
    "roles/iam.serviceAccountUser"
    ])
    project = var.project_id_gcp
    role    = each.value
    member  = "serviceAccount:${google_service_account.clouddeploya_sa.email}"
}