resource "google_compute_region_network_endpoint_group" "neg" {
    name = "${var.environment}-${var.project_name}-neg"
    region = var.region
    network_endpoint_type = var.endpoint_type

    cloud_run {
        service = var.service_name
    }
}