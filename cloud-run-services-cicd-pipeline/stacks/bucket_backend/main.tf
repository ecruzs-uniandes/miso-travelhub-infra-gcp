module "bucket" {
    source = "../../modules/bucket"
    project_name = var.project_name
    environment = var.environment
    region = var.region
}