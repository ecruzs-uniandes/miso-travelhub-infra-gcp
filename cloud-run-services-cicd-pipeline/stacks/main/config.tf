provider "google" {
  project = var.project_id_gcp
  region  = var.region

  default_labels = {
    terraform = "true"
    owner     = var.owner
  }
}

terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5"
    }
  }

  backend "gcs" {}
}