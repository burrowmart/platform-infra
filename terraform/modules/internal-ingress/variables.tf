variable "namespace" {
  description = "Namespace ingress-nginx is installed into."
  type        = string
  default     = "ingress"
}

variable "ingress_class_name" {
  description = "IngressClass name every service's per-service Ingress resource targets (base-service Helm chart hardcodes this)."
  type        = string
  default     = "nginx-internal"
}

variable "chart_version" {
  description = "ingress-nginx chart version."
  type        = string
  default     = "4.15.1"
}

variable "resources" {
  description = "Resource requests/limits for the controller pod."
  type = object({
    requests = object({ cpu = string, memory = string })
    limits   = object({ cpu = string, memory = string })
  })
  default = {
    requests = { cpu = "100m", memory = "128Mi" }
    limits   = { cpu = "500m", memory = "512Mi" }
  }
}

variable "replica_count" {
  description = "Controller replica count."
  type        = number
  default     = 2
}
