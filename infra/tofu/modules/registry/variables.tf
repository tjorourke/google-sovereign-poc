variable "repo_name" { type = string }
variable "region" { type = string }
variable "labels" { type = map(string) }

variable "kms_key_id" {
  description = "CMEK key. The AR service agent must already hold cryptoKeyEncrypterDecrypter on it — agents are JIT-provisioned in GCD."
  type        = string
}
