variable "name_prefix" {
  description = "Prefix cho resource name"
  type        = string
  default     = "tf3-cdo1-sandbox"
}

variable "environment" {
  description = "Environment name used for standard resource tags"
  type        = string
  default     = "sandbox"
}

variable "vpc_id" {
  description = "Tu module.networking.vpc_id"
  type        = string
}

variable "vpc_cidr" {
  description = "Tu module.networking.vpc_cidr"
  type        = string
}

variable "tags" {
  description = "Common tags"
  type        = map(string)
  default     = {}
}
