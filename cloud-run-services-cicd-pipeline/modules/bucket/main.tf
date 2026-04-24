resource "google_storage_bucket" "backend_terraform_bucket" {
    name = "${var.environment}-${var.project_name}-terraform-bucket"
    location = var.region

    versioning {
        enabled = false
    }
}