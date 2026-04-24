###########################################################
# Config Variables
###########################################################
region = "us-central1"
owner = "privera2505" #Github User
project_name = "travelhub-project"
environment = "prod"
project_id_gcp = "secret-lambda-491419-p2"
###########################################################
# Cloud run Variables
###########################################################
ingress_type = "internal-and-cloud-load-balancing"
security_type =  "allUsers"
load_balancer_uri = "test" #Modificar para produccion
###########################################################
# CI/CD Variables
###########################################################
gh_repo = "test-cicd-devop"
gh_branch = "main"
container_port = 8000
gh_conn_name = "gh-conn" #En cloud build v2, se debe conectar a un host en la v2
health_check_url = "/api2/health"