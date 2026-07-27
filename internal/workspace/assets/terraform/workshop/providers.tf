terraform {
  required_providers {
    aws = {
      source                = "hashicorp/aws"
      version               = "~> 5.60"
      configuration_aliases = [aws.staging, aws.prod]
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

# Default provider — every existing lab deploys here. Wired to var.dev_profile
# / var.dev_region. The `aws.staging` and `aws.prod` aliases are available for
# future cross-account labs to opt into via `providers = { aws = aws.staging }`.

provider "aws" {
  profile = var.dev_profile
  region  = var.dev_region

  default_tags {
    tags = {
      Project   = "AWS-Labs"
      ManagedBy = "Terraform"
      Account   = "dev"
    }
  }
}

provider "aws" {
  alias   = "staging"
  profile = local.staging_profile
  region  = local.staging_region

  default_tags {
    tags = {
      Project   = "AWS-Labs"
      ManagedBy = "Terraform"
      Account   = "staging"
    }
  }
}

provider "aws" {
  alias   = "prod"
  profile = local.prod_profile
  region  = local.prod_region

  default_tags {
    tags = {
      Project   = "AWS-Labs"
      ManagedBy = "Terraform"
      Account   = "prod"
    }
  }
}
