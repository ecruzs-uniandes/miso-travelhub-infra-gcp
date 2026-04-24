resource "google_service_account" "cloud_build_sa" {
    account_id   = "cloud-build-sa"
    display_name = "Service Account for Cloud Build"
}