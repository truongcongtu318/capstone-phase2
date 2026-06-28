variable "name_prefix" {
  description = "Prefix for sandbox resource names"
  type        = string
  default     = "tf3-cdo1-sandbox"
}

variable "environment" {
  description = "Environment name used for standard resource tags"
  type        = string
  default     = "sandbox"
}

variable "aws_region" {
  description = "AWS region for sandbox networking"
  type        = string
  default     = "us-east-1"
}

variable "vpc_cidr" {
  description = "CIDR block for the sandbox VPC"
  type        = string
  default     = "10.42.0.0/16"
}

variable "azs" {
  description = "Availability zones used by public and private subnets"
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for private subnets, ordered to match var.azs"
  type        = list(string)
  default     = ["10.42.0.0/20", "10.42.16.0/20"]
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for public subnets, ordered to match var.azs"
  type        = list(string)
  default     = ["10.42.32.0/20", "10.42.48.0/20"]
}

variable "tags" {
  description = "Additional tags applied to sandbox networking resources"
  type        = map(string)
  default     = {}
}
