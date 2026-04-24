output "sa_id" {
    value = google_service_account.clouddeploya_sa.id
}

output "sa_email" {
    value = google_service_account.clouddeploya_sa.email
}