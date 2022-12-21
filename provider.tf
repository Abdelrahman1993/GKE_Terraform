provider "google-beta" {
  project = "gke-project"
  region  = "europe-west2"
}
terraform {
#   backend "gcs" {
#     bucket  = "bucket-name-for-gke-terraform"
#     prefix  = "terraform/state"
#   }

  required_providers {
    google-beta = {
      source  = "hashicorp/google"
      version = "~> 4.36"
    }
  }

  required_version = "1.1.7"
}
