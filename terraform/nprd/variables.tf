variable "environment" {
  description = "Environment name"
  type        = string
  default     = "nprd"
}

variable "location" {
  description = "Azure region"
  type        = string
  default     = "brazilsouth"
}

variable "project" {
  description = "Project name"
  type        = string
  default     = "poc-migration"
}
