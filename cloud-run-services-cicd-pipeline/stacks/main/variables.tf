variable "project_name" {
    type = string
}

variable "environment" {
    type = string
}

variable "region" {
    type = string
}

variable "project_id_gcp" {
    type = string
}

variable "owner" {
    type = string
}

variable "gh_repo" {
    type = string
}

variable "container_port" {
    type = number
}

variable "gh_branch" {
    type = string
}

variable "gh_conn_name" {
    type = string
}

variable "ingress_type" {
    type = string
}

variable "security_type" {
    type = string
}

variable "health_check_url" {
    type = string
}

variable "load_balancer_uri" {
    type = string
}