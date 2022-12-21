# GCP APi
resource "google_project_service" "compute" {
  service = "compute.googleapis.com"
}

resource "google_project_service" "container" {
  service = "container.googleapis.com"
}

# VPC network
resource "google_compute_network" "vpc" {
  name                    = "gke-vpc"
  auto_create_subnetworks = "false"
  routing_mode            = "REGIONAL"
  depends_on = [
      google_project_service.compute,
      google_project_service.container
    ]
}

# private subnet
resource "google_compute_subnetwork" "private_subnet" {
  name                     = "gke-private-subnet"
  region                   = "europe-west2"
  network                  = google_compute_network.vpc.name
  private_ip_google_access = true
  ip_cidr_range            = "10.0.0.0/16"
}

# cloud router
resource "google_compute_router" "router" {
  name         = "gke-vpc-router"
  region       = "europe-west2"
  network      = google_compute_network.vpc.name
}

#static IP
resource "google_compute_address" "address" {
  name         = "gke-nat-static-ip"
  address_type = "EXTERNAL"
  region       = "europe-west2"
}

locals {
  private_subnets_names = [google_compute_subnetwork.private_subnet.id]
}

# cloud nat
resource "google_compute_router_nat" "mist_nat" {
  name                               = "gke-vpc-nat-gateway"
  router                             = google_compute_router.router.name
  region                             = "europe-west2"
  nat_ip_allocate_option             = "MANUAL_ONLY"
  nat_ips                            = [google_compute_address.address.self_link]
  source_subnetwork_ip_ranges_to_nat = "LIST_OF_SUBNETWORKS"

  dynamic "subnetwork" {
    for_each = local.private_subnets_names
    content {
      name    = subnetwork.value
      source_ip_ranges_to_nat = ["ALL_IP_RANGES"]
    }
  }
}

#GKE control plane
resource "google_container_cluster" "primary" {
  name                      = "gke-cluster"
  location                  = "europe-west2"
  remove_default_node_pool  = true
  initial_node_count        = 1
  network                   = google_compute_network.vpc.name
  subnetwork                = google_compute_subnetwork.private_subnet.name
  networking_mode           = "VPC_NATIVE"
  min_master_version        = "1.24.5"
  enable_l4_ilb_subsetting  = true

  release_channel {
    channel = "REGULAR"
  }

  ip_allocation_policy {
    cluster_ipv4_cidr_block  = "10.10.0.0/16"
    services_ipv4_cidr_block = "172.18.0.0/16"
  }
  
  master_authorized_networks_config {
     cidr_blocks {
       cidr_block = "0.0.0.0/0"
       display_name = "allowed_cidrs"
     }
  }
  private_cluster_config {
    enable_private_nodes = true
    enable_private_endpoint = false
    master_ipv4_cidr_block = "172.19.0.0/28"
  }
  addons_config {
    http_load_balancing {
      disabled = false
    }
    horizontal_pod_autoscaling {
      disabled = false
    }
    gcp_filestore_csi_driver_config {
      enabled = true
    }
  }
  monitoring_config {
    enable_components = ["SYSTEM_COMPONENTS", "APISERVER", "CONTROLLER_MANAGER", "SCHEDULER"]
    managed_prometheus {
      enabled = true
    }
  }
  logging_config {
    enable_components = ["SYSTEM_COMPONENTS", "APISERVER", "CONTROLLER_MANAGER", "SCHEDULER"]
  }
  binary_authorization {
      evaluation_mode = "PROJECT_SINGLETON_POLICY_ENFORCE"
  }

}

# kubernetes node pool service account
resource "google_service_account" "gke-prod" {
  account_id   = "gke-cluster-service-account"
  display_name = "gke-cluster-service-account"
}

resource "google_project_iam_member" "logWriter" {
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.gke-prod.email}"
  project = "gke-project"
}

resource "google_project_iam_member" "metricWriter" {
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${google_service_account.gke-prod.email}"
  project = "gke-project"
}

resource "google_project_iam_member" "resourceMetadata-write" {
  role    = "roles/stackdriver.resourceMetadata.writer"
  member  = "serviceAccount:${google_service_account.gke-prod.email}"
  project = "gke-project"
}

# kubernetes node pool
resource "google_container_node_pool" "primary_nodes" {
  name       = "gke-cluster-primary-nodepool"
  location   = "europe-west2"
  cluster    = google_container_cluster.primary.name

  autoscaling {
    min_node_count  = 0
    max_node_count  = 2
    location_policy = "BALANCED"
  }
  
   management {
    auto_repair  = true
    auto_upgrade = true
  }

  node_config {
    service_account = google_service_account.gke-prod.email
    
    labels = {
      node = "primary"
    }
    machine_type = "e2-medium"
    disk_size_gb = 100
    disk_type = "pd-standard"
    tags         = ["gke-node","private-node","primary-node"]
    metadata = {
      disable-legacy-endpoints = "true"
    }
  }

}
