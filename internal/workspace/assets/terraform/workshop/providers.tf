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
    time = {
      source  = "hashicorp/time"
      version = "~> 0.13"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.36"
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

# The prod account deployment principal is the EKS cluster creator and has
# bootstrap admin. Terraform uses that access only to pre-create isolated
# namespaces; students receive namespace-scoped access later in the exercise.
provider "kubernetes" {
  host = try(
    module.capstone_prod_eks[0].cluster_endpoint,
    "https://127.0.0.1",
  )
  cluster_ca_certificate = base64decode(try(
    module.capstone_prod_eks[0].cluster_ca,
    base64encode(""),
  ))

  # EKS creation plus its managed node group can exceed the 15-minute lifetime
  # of a static get-token result. Exec obtains a fresh prod token whenever the
  # Kubernetes provider connects.
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args = [
      "eks",
      "get-token",
      "--cluster-name",
      try(module.capstone_prod_eks[0].cluster_name, "disabled"),
      "--region",
      local.prod_region,
      "--profile",
      local.prod_profile,
    ]
  }
}
