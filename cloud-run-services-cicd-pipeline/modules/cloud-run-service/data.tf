data "google_iam_policy" "permission" {
    binding {
        role = "roles/run.invoker"
        members = [
            var.security_type
        ]
    }
}