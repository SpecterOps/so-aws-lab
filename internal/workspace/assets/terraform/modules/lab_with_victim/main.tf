terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
  }
}

variable "lab_prefix" {
  type = string
}

variable "lab_name" {
  type = string
}

variable "flag_value" {
  type      = string
  sensitive = true
}

variable "entry_boundary_statements" {
  type = list(object({
    Sid      = string
    Effect   = string
    Action   = list(string)
    Resource = list(string)
  }))
  description = "Allow statements granted to the entry role. Resource must be a list."
}

variable "victim_extra_statements" {
  type        = list(any)
  default     = []
  description = "Extra Allow statements baked into the victim user's boundary, beyond the standard sts:AssumeRole-on-donut hop. Used by labs whose exploit makes the victim use a different action."
}

variable "create_victim_access_key" {
  type        = bool
  default     = false
  description = "If true, also creates an aws_iam_access_key for the victim and outputs it. Currently always false; the entry-role inline policy can still be used to mint one via iam:CreateAccessKey if the boundary allows it."
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  account_id  = data.aws_caller_identity.current.account_id
  partition   = data.aws_partition.current.partition
  victim_name = "${var.lab_prefix}-${var.lab_name}-bopca"
  victim_arn  = "arn:${local.partition}:iam::${local.account_id}:user/${local.victim_name}"
  target_arn  = "arn:${local.partition}:iam::${local.account_id}:role/${var.lab_prefix}-${var.lab_name}-donut"

  victim_boundary_statements = concat(
    [
      {
        Sid      = "AssumeLabTarget"
        Effect   = "Allow"
        Action   = ["sts:AssumeRole"]
        Resource = [local.target_arn]
      },
      {
        Sid      = "Identity"
        Effect   = "Allow"
        Action   = ["sts:GetCallerIdentity"]
        Resource = ["*"]
      },
    ],
    var.victim_extra_statements,
  )

  victim_allowed_actions = distinct(flatten([for s in local.victim_boundary_statements : s.Action]))
}

module "base" {
  source                    = "../lab_common"
  lab_prefix                = var.lab_prefix
  lab_name                  = var.lab_name
  flag_value                = var.flag_value
  entry_boundary_statements = var.entry_boundary_statements
  extra_target_principals   = [local.victim_arn]
}

resource "aws_iam_policy" "victim_boundary" {
  name        = "${var.lab_prefix}-${var.lab_name}-bopca-boundary"
  description = "Permissions boundary for the ${var.lab_name} victim user."
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      local.victim_boundary_statements,
      [
        {
          Sid       = "DenyAllOther"
          Effect    = "Deny"
          NotAction = local.victim_allowed_actions
          Resource  = "*"
        },
      ],
    )
  })
}

resource "aws_iam_user" "victim" {
  name                 = local.victim_name
  permissions_boundary = aws_iam_policy.victim_boundary.arn
  force_destroy        = true

  tags = {
    Lab  = var.lab_name
    Kind = "victim"
  }
}

resource "aws_iam_user_policy" "victim_assume_target" {
  name = "assume-lab-donut"
  user = aws_iam_user.victim.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "sts:AssumeRole"
      Resource = local.target_arn
    }]
  })
}

output "entry_boundary_arn" {
  value = module.base.entry_boundary_arn
}

output "entry_role_arn" {
  value = module.base.entry_role_arn
}

output "entry_role_name" {
  value = module.base.entry_role_name
}

output "target_role_arn" {
  value = module.base.target_role_arn
}

output "target_role_name" {
  value = module.base.target_role_name
}

output "flag_parameter_name" {
  value = module.base.flag_parameter_name
}

output "victim_user_name" {
  value = aws_iam_user.victim.name
}

output "victim_user_arn" {
  value = aws_iam_user.victim.arn
}
