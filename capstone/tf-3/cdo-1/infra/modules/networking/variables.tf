variable "name_prefix" {
  description = "Prefix cho moi resource name (convention tf3-cdo1-sandbox)"
  type        = string
  default     = "tf3-cdo1-sandbox"
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "sandbox"
}

variable "vpc_cidr" {
  description = "CIDR block cho VPC"
  type        = string
  default     = "10.42.0.0/16"
}

variable "azs" {
  description = "Danh sach AZ dung cho subnet (toi thieu 2 cho EKS HA)"
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]
}

variable "private_subnet_cidrs" {
  description = "CIDR cho private subnet, theo thu tu khop var.azs"
  type        = list(string)
  default     = ["10.42.0.0/20", "10.42.16.0/20"]
}

variable "public_subnet_cidrs" {
  description = "CIDR cho public subnet (chi dung neu can NAT/ALB public sau nay), theo thu tu khop var.azs"
  type        = list(string)
  default     = ["10.42.32.0/20", "10.42.48.0/20"]
}

variable "sg_vpc_endpoint_id" {
  description = "Security group ID cho Interface VPC endpoints (tu module security)"
  type        = string
  default     = null
}

variable "create_vpc_endpoints" {
  description = "Bat tao VPC endpoints trong module nay neu da co sg_vpc_endpoint_id"
  type        = bool
  default     = false
}

variable "github_repo" {
  description = "org/repo duoc phep assume GitHub Actions OIDC roles"
  type        = string
  default     = "truongcongtu318/capstone-phase2"
}

variable "tags" {
  description = "Common tags"
  type        = map(string)
  default     = {}
}
