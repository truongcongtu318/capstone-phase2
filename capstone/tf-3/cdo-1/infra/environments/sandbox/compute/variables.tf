variable "aws_region" {
  type        = string
  default     = "us-east-1"
  description = "AWS Region"
}

variable "name_prefix" {
  type        = string
  default     = "tf3-cdo1-sandbox"
  description = "Prefix for resources"
}

variable "global_tags" {
  type        = map(string)
  default     = {}
  description = "Global tags to merge"
}
