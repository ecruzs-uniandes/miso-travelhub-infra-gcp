resource "google_clouddeploy_automation" "travelhub_rollback" {
    provider          = google-beta
    project           = var.project_id_gcp
    name              = "${var.environment}-${var.project_name}-rba"
    location          = var.region
    delivery_pipeline = var.pipeline_name
    service_account   = var.service_account_id

    selector {
        targets {
        id = var.cloud_deploy_target
        }
    }

    rules {
        repair_rollout_rule {
        id = "rollback-on-failure"
        repair_phases {
            rollback {} 
        }
        }
    }
}