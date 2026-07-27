terraform {
  required_version = ">= 1.6.0"

  # Local backend by default. The `aws-lab` CLI keeps state inside the cloned
  # repo (one state per AWS account). No S3 backend needed for self-host.
  backend "local" {}
}
