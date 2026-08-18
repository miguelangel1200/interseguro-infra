# Infraestructura del Reto Interseguro — Google Cloud Run
#
# Despliega los dos microservicios (go-api y node-api) en Cloud Run con
# imágenes desde Artifact Registry. Los valores sensibles (JWT, credenciales)
# se pasan desde terraform.tfvars.

terraform {
  required_version = ">= 1.5"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# --- Repositorios de imágenes (Artifact Registry) ---
resource "google_artifact_registry_repository" "images" {
  for_each = toset(["go-api", "node-api"])

  location      = var.region
  project       = var.project_id
  repository_id = "interseguro-${each.value}"
  format        = "DOCKER"
}

# --- API Node.js (auth + estadísticas) ---
resource "google_cloud_run_v2_service" "node_api" {
  name     = "interseguro-node-api"
  location = var.region
  project  = var.project_id
  ingress  = "INGRESS_TRAFFIC_ALL"

  template {
    max_instance_request_concurrency = 80
    timeout                         = "300s"

    containers {
      image = "${var.region}-docker.pkg.dev/${var.project_id}/interseguro-node-api/interseguro-node-api:latest"

      resources {
        limits = {
          cpu    = "1"
          memory = "512Mi"
        }
      }

      env {
        name  = "AUTH_USER"
        value = var.auth_user
      }
      env {
        name  = "AUTH_PASSWORD"
        value = var.auth_password
      }
      env {
        name  = "JWT_SECRET"
        value = var.jwt_secret
      }
      env {
        name  = "JWT_ISSUER"
        value = var.jwt_issuer
      }
      env {
        name  = "JWT_AUDIENCE"
        value = var.jwt_audience
      }
      env {
        name  = "JWT_EXPIRES_IN"
        value = var.jwt_expires_in
      }
      env {
        name  = "CORS_ORIGIN"
        value = var.cors_origin
      }
    }
  }
}

# --- API Go (procesamiento de matrices) ---
resource "google_cloud_run_v2_service" "go_api" {
  name     = "interseguro-go-api"
  location = var.region
  project  = var.project_id
  ingress  = "INGRESS_TRAFFIC_ALL"

  template {
    max_instance_request_concurrency = 80
    timeout                         = "300s"

    containers {
      image = "${var.region}-docker.pkg.dev/${var.project_id}/interseguro-go-api/interseguro-go-api:latest"

      resources {
        limits = {
          cpu    = "1"
          memory = "512Mi"
        }
      }

      env {
        name  = "NODE_API_URL"
        value = google_cloud_run_v2_service.node_api.uri
      }
      env {
        name  = "JWT_SECRET"
        value = var.jwt_secret
      }
      env {
        name  = "JWT_ISSUER"
        value = var.jwt_issuer
      }
      env {
        name  = "JWT_AUDIENCE"
        value = var.jwt_audience
      }
    }
  }
}

# --- Acceso público (la autenticación real es vía JWT) ---
resource "google_cloud_run_v2_service_iam_member" "node_public" {
  location = google_cloud_run_v2_service.node_api.location
  project  = google_cloud_run_v2_service.node_api.project
  name     = google_cloud_run_v2_service.node_api.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}

resource "google_cloud_run_v2_service_iam_member" "go_public" {
  location = google_cloud_run_v2_service.go_api.location
  project  = google_cloud_run_v2_service.go_api.project
  name     = google_cloud_run_v2_service.go_api.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}

# --- Workload Identity Federation para GitHub Actions ---
# Permite que los workflows de los repos de servicios se autentiquen en GCP
# sin credenciales de larga duración (solo go-api y node-api necesitan GCP).
resource "google_iam_workload_identity_pool" "github_actions" {
  project                  = var.project_id
  workload_identity_pool_id = "github-actions"
  display_name             = "GitHub Actions"
  description              = "Pool de identidad para los workflows de GitHub Actions."
}

resource "google_iam_workload_identity_pool_provider" "github_actions" {
  project                            = var.project_id
  workload_identity_pool_id          = google_iam_workload_identity_pool.github_actions.workload_identity_pool_id
  workload_identity_pool_provider_id = "github-actions"
  display_name                       = "GitHub Actions"
  description                        = "Proveedor OIDC de GitHub Actions."
  attribute_condition = format(
    "attribute.repository_owner == %q && (attribute.repository == %q || attribute.repository == %q)",
    var.github_owner,
    "${var.github_owner}/interseguro-go-api",
    "${var.github_owner}/interseguro-node-api",
  )
  attribute_mapping = {
    "google.subject"             = "assertion.sub"
    "attribute.actor"            = "assertion.actor"
    "attribute.repository"       = "assertion.repository"
    "attribute.repository_owner" = "assertion.repository_owner"
  }
  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

resource "google_service_account" "github_actions" {
  project      = var.project_id
  account_id   = "github-actions"
  display_name = "GitHub Actions deploy"
  description  = "Service Account impersonada por GitHub Actions (WIF)."
}

resource "google_service_account_iam_member" "github_actions_impersonation" {
  service_account_id = google_service_account.github_actions.name
  role               = "roles/iam.workloadIdentityUser"
  member = format(
    "principalSet://iam.googleapis.com/%s/attribute.repository/%s/*",
    google_iam_workload_identity_pool.github_actions.name,
    var.github_owner,
  )
}

# El SA debe poder emitir su propio access token: gcloud (vía la sesión WIF)
# lo impersona para obtener el token con el que sube el source y crea el build.
resource "google_service_account_iam_member" "github_actions_self_token" {
  service_account_id = google_service_account.github_actions.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "serviceAccount:${google_service_account.github_actions.email}"
}

# La sesión federada también necesita emitir access token sobre el SA en
# algunos flujos de gcloud (getAccessToken/generateAccessToken).
resource "google_service_account_iam_member" "github_actions_principal_token" {
  service_account_id = google_service_account.github_actions.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member = format(
    "principalSet://iam.googleapis.com/%s/attribute.repository/%s/*",
    google_iam_workload_identity_pool.github_actions.name,
    var.github_owner,
  )
}

# El SA de WIF sube el tarball fuente al bucket por defecto de Cloud Build.
resource "google_storage_bucket_iam_member" "github_actions_cloudbuild_bucket" {
  bucket = "${var.project_id}_cloudbuild"
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.github_actions.email}"
}