variable "name_prefix" { type = string }
variable "project_id" { type = string }
variable "region" { type = string }
variable "kms_key_id" { type = string }
variable "labels" { type = map(string) }
variable "retention_days" {
  description = "Log bucket retention. 400 days is a common regulated-sector floor."
  type        = number
  default     = 400
}
