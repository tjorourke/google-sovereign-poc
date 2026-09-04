variable "name_prefix" { type = string }
variable "region" { type = string }
variable "rotation_period" {
  description = "Key rotation period. 90 days."
  type        = string
  default     = "7776000s"
}
