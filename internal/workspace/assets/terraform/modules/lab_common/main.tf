terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
  }
}

variable "lab_prefix" {
  type        = string
  description = "Resource name prefix."
}

variable "lab_name" {
  type        = string
  description = "Lab module name (lowercase, no separators)."
}

variable "flag_value" {
  type        = string
  sensitive   = true
  description = "Flag string stored as a SecureString SSM parameter."
}

variable "entry_boundary_statements" {
  type = list(object({
    Sid      = string
    Effect   = string
    Action   = list(string)
    Resource = list(string)
  }))
  description = "Allow statements for the entry-role boundary. Resource must be a list; wrap a single value in []. Wrap a wildcard as [\"*\"]."
}

variable "entry_policy_statements" {
  type        = list(any)
  default     = null
  description = "Optional initial identity-policy statements. Null preserves the legacy behavior of copying entry_boundary_statements. Use an explicit list when a resource policy, grant, or later mutation must add effective permission."
}

variable "entry_target_access" {
  type        = string
  default     = "none"
  description = "Initial entry-role access to the target: direct, ceiling-only, or none."

  validation {
    condition     = contains(["direct", "ceiling-only", "none"], var.entry_target_access)
    error_message = "entry_target_access must be direct, ceiling-only, or none."
  }
}

variable "target_trusts_entry" {
  type        = bool
  default     = false
  description = "Whether the target trust policy names the entry role. Disable for victim and service-mediated paths."
}

variable "extra_target_principals" {
  type        = list(string)
  default     = []
  description = "Additional principal ARNs allowed to assume the lab's target role."
}

variable "target_extra_statements" {
  type    = list(any)
  default = []
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  region     = data.aws_region.current.name

  flag_param_name = "/labs/${var.lab_prefix}/${var.lab_name}/flag"
  entry_arn       = "arn:${local.partition}:iam::${local.account_id}:role/${var.lab_prefix}-${var.lab_name}-carl"
  target_arn      = "arn:${local.partition}:iam::${local.account_id}:role/${var.lab_prefix}-${var.lab_name}-donut"

  target_assume = {
    Sid      = "AssumeLabTarget"
    Effect   = "Allow"
    Action   = ["sts:AssumeRole"]
    Resource = [local.target_arn]
  }

  target_ceiling  = var.entry_target_access == "none" ? [] : [local.target_assume]
  target_identity = var.entry_target_access == "direct" ? [local.target_assume] : []

  # Statements shared by the entry boundary and initial inline policy.
  common_allow = [
    {
      Sid      = "Identity"
      Effect   = "Allow"
      Action   = ["sts:GetCallerIdentity"]
      Resource = ["*"]
    },
    {
      # Every lab flag is a SecureString on the aws/ssm managed key. KMS
      # authorizes against a key ARN, never an alias ARN, so the old
      # alias-scoped grant matched nothing. Scope by kms:ViaService instead,
      # which mirrors the aws/ssm key policy and keeps this from becoming a
      # decrypt grant on other labs' customer-managed keys.
      Sid      = "DecryptSSMParams"
      Effect   = "Allow"
      Action   = ["kms:Decrypt"]
      Resource = ["*"]
      Condition = {
        StringEquals = { "kms:ViaService" = "ssm.${local.region}.amazonaws.com" }
      }
    },
    {
      Sid    = "LabSelfEnumeration"
      Effect = "Allow"
      Action = [
        "iam:Get*",
        "iam:List*",
        "iam:SimulatePrincipalPolicy",
        "iam:SimulateCustomPolicy",
        "kms:GetKeyPolicy",
        "kms:DescribeKey",
        "kms:ListAliases",
        "kms:ListGrants",
        "lambda:GetFunction",
        "lambda:GetFunctionConfiguration",
        "lambda:ListFunctions",
        "lambda:ListTags",
      ]
      Resource = ["*"]
    },
  ]

  initial_statements = var.entry_policy_statements == null ? var.entry_boundary_statements : var.entry_policy_statements

  # Collect every ceiling action so the Deny NotAction is correct.
  allowed_actions = distinct(flatten(concat(
    [for s in var.entry_boundary_statements : s.Action],
    [for s in local.target_ceiling : s.Action],
    [for s in local.common_allow : s.Action],
  )))

  entry_policy_doc = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      local.initial_statements,
      local.target_identity,
      local.common_allow,
    )
  })
}

# --- Flag ---

resource "aws_ssm_parameter" "flag" {
  name        = local.flag_param_name
  type        = "SecureString"
  value       = var.flag_value
  description = "Flag for the ${var.lab_name} lab."

  tags = {
    Lab = var.lab_name
  }
}

# --- Entry-role boundary (deny-by-default + NotAction allowlist) ---

resource "aws_iam_policy" "entry_boundary" {
  name        = "${var.lab_prefix}-${var.lab_name}-carl-boundary"
  description = "Permissions boundary for the ${var.lab_name} entry role."

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      var.entry_boundary_statements,
      local.target_ceiling,
      local.common_allow,
      [
        {
          Sid       = "DenyAllOther"
          Effect    = "Deny"
          NotAction = local.allowed_actions
          Resource  = "*"
        },
      ],
    )
  })
}

# --- Entry role (one per lab, no student fan-out) ---
#
# Trust is wide-open to the deploying account's root; in the self-host model
# the student IS admin in their own account, so they can sts:AssumeRole into
# this role. The boundary limits what the role can then do.

resource "aws_iam_role" "entry" {
  name                 = "${var.lab_prefix}-${var.lab_name}-carl"
  path                 = "/"
  permissions_boundary = aws_iam_policy.entry_boundary.arn
  max_session_duration = 3600

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          AWS = "arn:${local.partition}:iam::${local.account_id}:root"
        }
        Action = "sts:AssumeRole"
      },
    ]
  })

  tags = {
    Lab  = var.lab_name
    Kind = "entry"
  }
}

resource "aws_iam_role_policy" "entry_inline" {
  name   = "${var.lab_prefix}-${var.lab_name}-carl-policy"
  role   = aws_iam_role.entry.name
  policy = local.entry_policy_doc
}

# --- Target role ---

resource "aws_iam_role" "target" {
  name = "${var.lab_prefix}-${var.lab_name}-donut"
  path = "/"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          AWS = "arn:${local.partition}:iam::${local.account_id}:root"
        }
        Action = "sts:AssumeRole"
        Condition = {
          ArnEquals = {
            "aws:PrincipalArn" = concat(var.target_trusts_entry ? [local.entry_arn] : [], var.extra_target_principals)
          }
        }
      },
    ]
  })

  tags = {
    Lab  = var.lab_name
    Kind = "target"
  }
}

resource "aws_iam_role_policy" "target_read_flag" {
  name = "${var.lab_prefix}-${var.lab_name}-donut-readflag"
  role = aws_iam_role.target.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [
        {
          Sid      = "ReadFlag"
          Effect   = "Allow"
          Action   = ["ssm:GetParameter"]
          Resource = ["arn:${local.partition}:ssm:${local.region}:${local.account_id}:parameter${local.flag_param_name}"]
        },
        {
          # KMS authorizes against a key ARN, never an alias ARN. Scope by
          # kms:ViaService, mirroring the aws/ssm key policy.
          Sid      = "DecryptSSMFlag"
          Effect   = "Allow"
          Action   = ["kms:Decrypt"]
          Resource = ["*"]
          Condition = {
            StringEquals = { "kms:ViaService" = "ssm.${local.region}.amazonaws.com" }
          }
        },
      ],
      var.target_extra_statements,
    )
  })
}

# --- Outputs ---

output "entry_boundary_arn" {
  value = aws_iam_policy.entry_boundary.arn
}

output "entry_role_arn" {
  value = aws_iam_role.entry.arn
}

output "entry_role_name" {
  value = aws_iam_role.entry.name
}

output "target_role_arn" {
  value = aws_iam_role.target.arn
}

output "target_role_name" {
  value = aws_iam_role.target.name
}

output "flag_parameter_name" {
  value = aws_ssm_parameter.flag.name
}
