#Project configuration
PROJECT-ID=secret-lambda-491419-p2
REGION=us-central1
ZONE=us-central1-a
#Terraform configuration
ROOT := $(shell pwd)
S3   := $(ROOT)/stacks/bucket_backend
ENV  := $(ROOT)/environments/pablo
MAIN := $(ROOT)/stacks/main

init-project:
	gcloud config set project $(PROJECT-ID)
	gcloud config set compute/region $(REGION)
	gcloud config set compute/zone $(ZONE)

init-terraform:
	terraform -chdir="$(S3)" init -backend-config="$(ENV)/backend.tfvars"
	terraform -chdir="$(S3)" plan -var-file="$(ENV)/terraform.tfvars" -out="$(S3)/.tfplan"
	terraform -chdir="$(S3)" apply "$(S3)/.tfplan"

reset:
	terraform -chdir="$(S3)" destroy -var-file="$(ENV)/terraform.tfvars"

create-terraform:
	terraform -chdir="$(MAIN)" init -backend-config="$(ENV)/backend.tfvars"
	terraform -chdir="$(MAIN)" plan -var-file="$(ENV)/terraform.tfvars" -out="$(MAIN)/.tfplan"
	terraform -chdir="$(MAIN)" apply "$(MAIN)/.tfplan"

delete:
	terraform -chdir="$(MAIN)" destroy -var-file="$(ENV)/terraform.tfvars"

get-project:
	gcloud config get-value project

get-region:
	gcloud config get-value compute/region

get-zone:
	gcloud config get-value compute/zone

list-projects:
	gcloud projects list