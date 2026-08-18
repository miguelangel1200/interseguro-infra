variable "project_id" {
  description = "ID del proyecto de Google Cloud."
  type        = string
}

variable "github_owner" {
  description = "Propietario de los repositorios de GitHub (usuario u organización)."
  type        = string
}

variable "region" {
  description = "Región de despliegue."
  type        = string
  default     = "us-central1"
}

variable "auth_user" {
  description = "Usuario de autenticación del API Node."
  type        = string
}

variable "auth_password" {
  description = "Contraseña de autenticación del API Node. Solo para la prueba técnica."
  type        = string
  sensitive   = true
}

variable "jwt_secret" {
  description = "Secreto compartido JWT entre go-api y node-api."
  type        = string
  sensitive   = true
}

variable "jwt_issuer" {
  description = "Issuer del JWT."
  type        = string
  default     = "interseguro"
}

variable "jwt_audience" {
  description = "Audience del JWT."
  type        = string
  default     = "interseguro-api"
}

variable "jwt_expires_in" {
  description = "Duración del token (ej. 2h)."
  type        = string
  default     = "2h"
}

variable "cors_origin" {
  description = "Origen permitido por CORS (* en la prueba técnica)."
  type        = string
  default     = "*"
}