variable "name_prefix" {
  description = "Prefix cho mọi resource name (convention tf3-cdo1-sandbox)"
  type        = string
  default     = "tf3-cdo1-sandbox"
}

variable "vpc_cidr" {
  description = "CIDR block cho VPC"
  type        = string
  default     = "10.42.0.0/16"
}

variable "azs" {
  description = "Danh sách AZ dùng cho subnet (tối thiểu 2 cho EKS HA)"
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]
}

variable "private_subnet_cidrs" {
  description = "CIDR cho private subnet, theo thứ tự khớp var.azs"
  type        = list(string)
  default     = ["10.42.0.0/20", "10.42.16.0/20"]
}

variable "public_subnet_cidrs" {
  description = "CIDR cho public subnet (chỉ dùng nếu cần NAT/ALB public sau này), theo thứ tự khớp var.azs"
  type        = list(string)
  default     = ["10.42.32.0/20", "10.42.48.0/20"]
}

variable "tags" {
  description = "Common tags — nhận từ environments/sandbox/foundation/variables.tf"
  type        = map(string)
  default     = {}
}
