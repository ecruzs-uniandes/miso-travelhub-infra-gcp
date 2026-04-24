resource "google_cloudbuildv2_repository" "repo" {
    name              = var.gh_repo
    location          = var.region
    parent_connection = var.gh_conn_name

    remote_uri = "https://github.com/${var.owner}/${var.gh_repo}.git"
}