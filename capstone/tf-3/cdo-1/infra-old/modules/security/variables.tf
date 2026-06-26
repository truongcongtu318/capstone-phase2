variable "name_prefix" {
  description = "Prefix cho resource name"
  type        = string
  default     = "tf3-cdo1-sandbox"
}

variable "vpc_id" {
  description = "Từ module.networking.vpc_id"
  type        = string
}

variable "vpc_cidr" {
  description = "Từ module.networking.vpc_cidr"
  type        = string
}

variable "tags" {
  description = "Common tags"
  type        = map(string)
  default     = {}
}
