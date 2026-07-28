variable "dev_profile" {
  type        = string
  description = "AWS named profile for the dev account (where every lab deploys by default)."
}

variable "dev_region" {
  type        = string
  default     = "us-east-1"
  description = "AWS region for the dev account."
}

variable "staging_profile" {
  type        = string
  default     = ""
  description = "Optional named profile for the staging account. Falls back to dev_profile."
}

variable "staging_region" {
  type        = string
  default     = ""
  description = "Optional region for the staging account. Falls back to dev_region."
}

variable "prod_profile" {
  type        = string
  default     = ""
  description = "Optional named profile for the prod account. Falls back to dev_profile."
}

variable "prod_region" {
  type        = string
  default     = ""
  description = "Optional region for the prod account. Falls back to dev_region."
}

variable "lab_prefix" {
  type        = string
  default     = "aws-lab"
  description = "Prefix for all lab-owned resource names."

  validation {
    condition     = can(regex("^[a-z0-9-]{3,16}$", var.lab_prefix))
    error_message = "lab_prefix must be 3-16 lowercase alphanumeric or hyphen characters."
  }
}

# ----------------------------------------------------------------------------
# Per-lab enable flags. Toggled by the `aws-lab` CLI; default off so a fresh
# `terraform apply` creates nothing.
# ----------------------------------------------------------------------------

variable "enable_createpolicyversion" {
  type    = bool
  default = false
}
variable "enable_assumerole" {
  type    = bool
  default = false
}
variable "enable_putuserpolicy" {
  type    = bool
  default = false
}
variable "enable_attachrolepolicy" {
  type    = bool
  default = false
}
variable "enable_createcredentials" {
  type    = bool
  default = false
}
variable "enable_updateassumerolepolicy" {
  type    = bool
  default = false
}
variable "enable_ec2runinstances" {
  type    = bool
  default = false
}
variable "enable_ec2modifyuserdata" {
  type    = bool
  default = false
}
variable "enable_lambdacreatefunction" {
  type    = bool
  default = false
}
variable "enable_lambdaupdatefunctioncode" {
  type    = bool
  default = false
}
variable "enable_lambdaupdatelayer" {
  type    = bool
  default = false
}
variable "enable_cloudformationcreatestack" {
  type    = bool
  default = false
}
variable "enable_cloudformationcreatechangeset" {
  type    = bool
  default = false
}
variable "enable_ssmgetparameter" {
  type    = bool
  default = false
}
variable "enable_ssmsendcommand" {
  type    = bool
  default = false
}
variable "enable_s3getobject" {
  type    = bool
  default = false
}
variable "enable_s3putbucketpolicy" {
  type    = bool
  default = false
}
variable "enable_kmsdecrypt" {
  type    = bool
  default = false
}
variable "enable_kmscreategrant" {
  type    = bool
  default = false
}
variable "enable_eksaccessentry" {
  type    = bool
  default = false
}
variable "enable_ekspodidentityassociation" {
  type    = bool
  default = false
}
variable "enable_capstone" {
  type        = bool
  default     = false
  description = "Capstone: 3-account, condition-gated privilege chain. Requires valid staging + prod profiles."
}

variable "capstone_students" {
  type        = map(string)
  default     = {}
  description = "Optional map of short student ID to printable display label. Empty preserves single-student mode."

  validation {
    condition = length(var.capstone_students) <= 50 && alltrue([
      for id, label in var.capstone_students :
      id != "default" &&
      can(regex("^[a-z0-9][a-z0-9-]{0,11}$", id)) &&
      trimspace(label) != "" &&
      length(label) <= 80
    ])
    error_message = "capstone_students accepts at most 50 entries; keys must be unique 1-12 character lowercase IDs (default is reserved), and each display label must contain 1-80 characters."
  }
}

# The CLI populates these only while disabling or destroying an existing
# capstone. The Kubernetes provider needs the live cluster connection long
# enough to remove namespaced resources before Terraform deletes the EKS
# module. First-time enables use the module outputs directly.
variable "capstone_existing_eks_name" {
  type        = string
  default     = ""
  description = "Existing capstone EKS cluster name used during teardown."
}

variable "capstone_existing_eks_endpoint" {
  type        = string
  default     = ""
  description = "Existing capstone EKS endpoint used during teardown."
}

variable "capstone_existing_eks_ca" {
  type        = string
  default     = ""
  description = "Base64-encoded CA for the existing capstone EKS cluster used during teardown."
}

variable "enable_conditionresourcetag" {
  type    = bool
  default = false
}
variable "enable_conditionprincipaltag" {
  type    = bool
  default = false
}
variable "enable_conditionexternalid" {
  type    = bool
  default = false
}
variable "enable_kmsencryptioncontext" {
  type    = bool
  default = false
}

variable "flag_values" {
  type        = map(string)
  sensitive   = true
  description = "Map of lab_name => flag value. Used as SecureString SSM parameter values."
  default = {
    createpolicyversion           = "BORANT:cr34t3_p0l1cy_v3rs10n_pwn3d"
    assumerole                    = "BORANT:4ssum3_r0l3_trust_p0l1cy_pwn3d"
    putuserpolicy                 = "BORANT:put_us3r_p0l1cy_3sc4l4t10n"
    attachrolepolicy              = "BORANT:4tt4ch_r0l3_p0l1cy_3xpl01t"
    createcredentials             = "BORANT:cr34t3_cr3d3nt14ls_h4ck3d"
    updateassumerolepolicy        = "BORANT:upd4t3_trust_p0l1cy_pwn3d"
    ec2runinstances               = "BORANT:ec2_run_inst4nc3s_pwn3d"
    ec2modifyuserdata             = "BORANT:ec2_m0d1fy_us3rd4t4_pwn3d"
    lambdacreatefunction          = "BORANT:l4mbd4_cr34t3_func_pwn3d"
    lambdaupdatefunctioncode      = "BORANT:l4mbd4_upd4t3_c0d3_pwn3d"
    lambdaupdatelayer             = "BORANT:l4mbd4_upd4t3_l4y3r_pwn3d"
    cloudformationcreatestack     = "BORANT:cfn_cr34t3_st4ck_pwn3d"
    cloudformationcreatechangeset = "BORANT:cfn_ch4ng3s3t_pwn3d"
    ssmgetparameter               = "BORANT:ssm_g3t_p4r4m_pwn3d"
    ssmsendcommand                = "BORANT:ssm_s3nd_cmd_pwn3d"
    s3getobject                   = "BORANT:s3_g3t_0bj_pwn3d"
    s3putbucketpolicy             = "BORANT:s3_put_buck3t_p0l_pwn3d"
    kmsdecrypt                    = "BORANT:kms_d3crypt_pwn3d"
    kmscreategrant                = "BORANT:kms_gr4nt_pwn3d"
    eksaccessentry                = "BORANT:eks_4cc3ss_3ntry_pwn3d"
    ekspodidentityassociation     = "BORANT:eks_p0d_1d3nt1ty_pwn3d"
    capstone                      = "BORANT:c4pst0n3_cr0ss_4cc0unt_pwn3d"
    conditionresourcetag          = "BORANT:c0nd_r3s0urc3t4g_pwn3d"
    conditionprincipaltag         = "BORANT:c0nd_pr1nc1p4lt4g_pwn3d"
    conditionexternalid           = "BORANT:c0nd_3xt3rn4l1d_pwn3d"
    kmsencryptioncontext          = "BORANT:kms_3ncrypt10n_c0nt3xt_pwn3d"
  }
}

locals {
  # Aggregated flags for shared-infra gating. The dev-side shared VPC + EKS
  # are NOT extended to capstone — capstone provisions its own VPC + EKS in
  # the staging account (different account, can't share).
  needs_vpc         = var.enable_ec2runinstances || var.enable_ec2modifyuserdata || var.enable_ssmsendcommand || var.enable_eksaccessentry || var.enable_ekspodidentityassociation
  needs_eks         = var.enable_eksaccessentry || var.enable_ekspodidentityassociation
  needs_ec2_targets = var.enable_ec2modifyuserdata || var.enable_ssmsendcommand

  # Staging/prod profile + region defaults: empty string falls through to dev.
  staging_profile = var.staging_profile != "" ? var.staging_profile : var.dev_profile
  staging_region  = var.staging_region != "" ? var.staging_region : var.dev_region
  prod_profile    = var.prod_profile != "" ? var.prod_profile : var.dev_profile
  prod_region     = var.prod_region != "" ? var.prod_region : var.dev_region
}
