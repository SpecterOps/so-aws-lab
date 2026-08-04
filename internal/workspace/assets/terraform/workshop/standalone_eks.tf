###############################################################################
# Standalone EKS provider lifecycle. Capstone uses a separate prod provider.
###############################################################################

variable "standalone_existing_eks_name" {
  type        = string
  default     = ""
  description = "Existing standalone EKS cluster name used during teardown."
}

variable "standalone_existing_eks_endpoint" {
  type        = string
  default     = ""
  description = "Existing standalone EKS endpoint used during teardown."
}

variable "standalone_existing_eks_ca" {
  type        = string
  default     = ""
  description = "Base64-encoded CA for the existing standalone EKS cluster used during teardown."
}

provider "kubernetes" {
  alias = "dev"

  host = var.standalone_existing_eks_endpoint != "" ? var.standalone_existing_eks_endpoint : (
    local.needs_eks ? module.shared_eks[0].cluster_endpoint : null
  )
  cluster_ca_certificate = var.standalone_existing_eks_ca != "" ? base64decode(
    var.standalone_existing_eks_ca
    ) : (
    local.needs_eks ? base64decode(module.shared_eks[0].cluster_ca) : null
  )

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args = [
      "eks",
      "get-token",
      "--cluster-name",
      var.standalone_existing_eks_name != "" ? var.standalone_existing_eks_name : (
        local.needs_eks ? module.shared_eks[0].cluster_name : "disabled"
      ),
      "--region",
      var.dev_region,
      "--profile",
      var.dev_profile,
    ]
  }
}
