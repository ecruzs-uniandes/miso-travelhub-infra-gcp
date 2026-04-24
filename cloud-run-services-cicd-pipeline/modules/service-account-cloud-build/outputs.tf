output "sa_id" {
    value = google_service_account.cloudbuild_sa.id
}

output "sa_email" {
    value = google_service_account.cloudbuild_sa.email
}