variable "aws_region" {
  description = "AWS region for all resources (matches the state bucket region)"
  type        = string
  default     = "us-east-1"
}

variable "project" {
  type    = string
  default = "plainjon-ecs"
}

variable "image_tag" {
  description = "Image tag the task definitions point to. The app repo CD pushes :latest and forces a new deployment."
  type        = string
  default     = "latest"
}

variable "desired_count" {
  type    = number
  default = 1
}

variable "upload_port" {
  type    = number
  default = 5000
}

variable "message_port" {
  type    = number
  default = 5001
}
