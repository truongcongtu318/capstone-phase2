variable "name_prefix" {
  description = "Prefix cho resource names"
  type        = string
  default     = "tf3-cdo1-sandbox"
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "sandbox"
}

variable "aws_region" {
  description = "AWS region cho sandbox networking"
  type        = string
  default     = "us-east-1"
}

variable "github_repo" {
  description = "org/repo duoc phep assume GitHub Actions OIDC roles"
  type        = string
  default     = "truongcongtu318/capstone-phase2"
}

variable "vpc_cidr" {
  description = "CIDR block cho Sandbox VPC"
  type        = string
  default     = "10.42.0.0/16"
}

variable "azs" {
  description = "Availability Zones cho subnet"
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]
}

variable "private_subnet_cidrs" {
  description = "Private subnet CIDRs"
  type        = list(string)
  default     = ["10.42.0.0/20", "10.42.16.0/20"]
}

variable "public_subnet_cidrs" {
  description = "Public subnet CIDRs"
  type        = list(string)
  default     = ["10.42.32.0/20", "10.42.48.0/20"]
}

variable "tags" {
  description = "Common tags"
  type        = map(string)
  default     = {}
}
