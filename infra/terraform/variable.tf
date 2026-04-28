variable "aws_region" {
  description = "AWS region for all resources"
  default     = "us-east-1"
}

variable "project_name" {
  description = "Prefix for all resource names"
  default     = "pavan_mlops"
}

variable "db_password" {
  description = "Password for RDS PostgreSQL"
  sensitive   = true   # Terraform won't print this in logs
}

variable "terraform_state_bucket" {
  description = "S3 bucket name for Terraform state"
  type        = string
}