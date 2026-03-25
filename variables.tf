variable "aws_region" {
  description = "AWS region for all resources."
  type        = string
  default     = "us-east-1"
}

variable "alert_email" {
  description = "Email endpoint for SNS latency alerts."
  type        = string
  default     = "emailhere@example.com" #Email here uwu :)
}

variable "project_name" {
  description = "Prefix used for resource naming."
  type        = string
  default     = "autonomous-web"
}
