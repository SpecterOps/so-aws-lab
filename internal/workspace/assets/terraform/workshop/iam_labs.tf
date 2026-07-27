###############################################################################
# IAM labs (6)
###############################################################################

# --- 1. createpolicyversion ---------------------------------------------------

resource "aws_iam_policy" "createpolicyversion_pivot" {
  count       = var.enable_createpolicyversion ? 1 : 0
  name        = "${var.lab_prefix}-createpolicyversion-glyph"
  description = "Sleeper policy used by the createpolicyversion lab."
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "Harmless"
      Effect   = "Allow"
      Action   = ["sts:GetCallerIdentity"]
      Resource = ["*"]
    }]
  })
}

module "lab_createpolicyversion" {
  count      = var.enable_createpolicyversion ? 1 : 0
  source     = "../modules/lab_common"
  lab_prefix = var.lab_prefix
  lab_name   = "createpolicyversion"
  flag_value = var.flag_values["createpolicyversion"]

  entry_boundary_statements = [
    {
      Sid      = "IamRead"
      Effect   = "Allow"
      Action   = ["iam:Get*", "iam:List*"]
      Resource = ["*"]
    },
    {
      Sid      = "PolicyVersion"
      Effect   = "Allow"
      Action   = ["iam:CreatePolicyVersion", "iam:SetDefaultPolicyVersion", "iam:DeletePolicyVersion"]
      Resource = [aws_iam_policy.createpolicyversion_pivot[0].arn]
    },
  ]
}

# --- 2. assumerole ------------------------------------------------------------

module "lab_assumerole" {
  count      = var.enable_assumerole ? 1 : 0
  source     = "../modules/lab_common"
  lab_prefix = var.lab_prefix
  lab_name   = "assumerole"
  flag_value = var.flag_values["assumerole"]

  entry_boundary_statements = [
    {
      Sid      = "IamRead"
      Effect   = "Allow"
      Action   = ["iam:Get*", "iam:List*"]
      Resource = ["*"]
    },
  ]
}

# --- 3. putuserpolicy ---------------------------------------------------------

module "lab_putuserpolicy" {
  count      = var.enable_putuserpolicy ? 1 : 0
  source     = "../modules/lab_with_victim"
  lab_prefix = var.lab_prefix
  lab_name   = "putuserpolicy"
  flag_value = var.flag_values["putuserpolicy"]

  entry_boundary_statements = [
    {
      Sid      = "IamRead"
      Effect   = "Allow"
      Action   = ["iam:Get*", "iam:List*"]
      Resource = ["*"]
    },
    {
      Sid      = "Escalate"
      Effect   = "Allow"
      Action   = ["iam:PutUserPolicy", "iam:DeleteUserPolicy", "iam:CreateAccessKey", "iam:DeleteAccessKey"]
      Resource = ["arn:${local.partition}:iam::${local.account_id}:user/${var.lab_prefix}-putuserpolicy-bopca"]
    },
  ]
}

# --- 4. attachrolepolicy ------------------------------------------------------

resource "aws_iam_policy" "attachrolepolicy_pivot" {
  count       = var.enable_attachrolepolicy ? 1 : 0
  name        = "${var.lab_prefix}-attachrolepolicy-glyph"
  description = "Sleeper policy that grants sts:AssumeRole on the attachrolepolicy lab target."
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "AssumeTarget"
      Effect   = "Allow"
      Action   = "sts:AssumeRole"
      Resource = ["arn:${local.partition}:iam::${local.account_id}:role/${var.lab_prefix}-attachrolepolicy-donut"]
    }]
  })
}

module "lab_attachrolepolicy" {
  count      = var.enable_attachrolepolicy ? 1 : 0
  source     = "../modules/lab_common"
  lab_prefix = var.lab_prefix
  lab_name   = "attachrolepolicy"
  flag_value = var.flag_values["attachrolepolicy"]

  entry_boundary_statements = [
    {
      Sid      = "IamRead"
      Effect   = "Allow"
      Action   = ["iam:Get*", "iam:List*"]
      Resource = ["*"]
    },
    {
      Sid      = "AttachPivot"
      Effect   = "Allow"
      Action   = ["iam:AttachRolePolicy", "iam:DetachRolePolicy"]
      Resource = ["arn:${local.partition}:iam::${local.account_id}:role/${var.lab_prefix}-attachrolepolicy-carl"]
    },
  ]
}

# --- 5. createcredentials -----------------------------------------------------

module "lab_createcredentials" {
  count      = var.enable_createcredentials ? 1 : 0
  source     = "../modules/lab_with_victim"
  lab_prefix = var.lab_prefix
  lab_name   = "createcredentials"
  flag_value = var.flag_values["createcredentials"]

  entry_boundary_statements = [
    {
      Sid      = "IamRead"
      Effect   = "Allow"
      Action   = ["iam:Get*", "iam:List*"]
      Resource = ["*"]
    },
    {
      Sid      = "MintKeys"
      Effect   = "Allow"
      Action   = ["iam:CreateAccessKey", "iam:DeleteAccessKey"]
      Resource = ["arn:${local.partition}:iam::${local.account_id}:user/${var.lab_prefix}-createcredentials-bopca"]
    },
  ]
}

# --- 6. updateassumerolepolicy ------------------------------------------------
#
# Bespoke: the target role's INITIAL trust is deny-all. The student rewrites it.
# Can't use lab_common because the target trust is the variable in the lesson.

resource "aws_iam_role" "updateassumerolepolicy_target" {
  count = var.enable_updateassumerolepolicy ? 1 : 0
  name  = "${var.lab_prefix}-updateassumerolepolicy-donut"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Deny"
      Principal = { AWS = "arn:${local.partition}:iam::${local.account_id}:root" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = { Lab = "updateassumerolepolicy", Kind = "target" }
}

resource "aws_ssm_parameter" "updateassumerolepolicy_flag" {
  count = var.enable_updateassumerolepolicy ? 1 : 0
  name  = "/labs/${var.lab_prefix}/updateassumerolepolicy/flag"
  type  = "SecureString"
  value = var.flag_values["updateassumerolepolicy"]
  tags  = { Lab = "updateassumerolepolicy" }
}

resource "aws_iam_role_policy" "updateassumerolepolicy_target_readflag" {
  count = var.enable_updateassumerolepolicy ? 1 : 0
  name  = "read-flag"
  role  = aws_iam_role.updateassumerolepolicy_target[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ssm:GetParameter"]
      Resource = [aws_ssm_parameter.updateassumerolepolicy_flag[0].arn]
      }, {
      Effect   = "Allow"
      Action   = ["kms:Decrypt"]
      Resource = ["*"]
      Condition = {
        StringEquals = { "kms:ViaService" = "ssm.${local.region}.amazonaws.com" }
      }
    }]
  })
}

resource "aws_iam_policy" "updateassumerolepolicy_entry_boundary" {
  count       = var.enable_updateassumerolepolicy ? 1 : 0
  name        = "${var.lab_prefix}-updateassumerolepolicy-carl-boundary"
  description = "Boundary for updateassumerolepolicy entry role."
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Sid = "IamRead", Effect = "Allow", Action = ["iam:Get*", "iam:List*"], Resource = ["*"] },
      { Sid = "RewriteTrust", Effect = "Allow", Action = ["iam:UpdateAssumeRolePolicy"], Resource = aws_iam_role.updateassumerolepolicy_target[0].arn },
      { Sid = "AssumeTarget", Effect = "Allow", Action = ["sts:AssumeRole"], Resource = aws_iam_role.updateassumerolepolicy_target[0].arn },
      { Sid = "Identity", Effect = "Allow", Action = ["sts:GetCallerIdentity"], Resource = ["*"] },
      {
        Sid    = "DenyAllOther"
        Effect = "Deny"
        NotAction = [
          "iam:Get*", "iam:List*", "iam:UpdateAssumeRolePolicy",
          "sts:AssumeRole", "sts:GetCallerIdentity",
        ]
        Resource = ["*"]
      },
    ]
  })
}

resource "aws_iam_role" "updateassumerolepolicy_entry" {
  count                = var.enable_updateassumerolepolicy ? 1 : 0
  name                 = "${var.lab_prefix}-updateassumerolepolicy-carl"
  permissions_boundary = aws_iam_policy.updateassumerolepolicy_entry_boundary[0].arn
  max_session_duration = 3600

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = "arn:${local.partition}:iam::${local.account_id}:root" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = { Lab = "updateassumerolepolicy", Kind = "entry" }
}

resource "aws_iam_role_policy" "updateassumerolepolicy_entry_inline" {
  count = var.enable_updateassumerolepolicy ? 1 : 0
  name  = "${var.lab_prefix}-updateassumerolepolicy-carl-policy"
  role  = aws_iam_role.updateassumerolepolicy_entry[0].name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["iam:Get*", "iam:List*"], Resource = ["*"] },
      { Effect = "Allow", Action = ["iam:UpdateAssumeRolePolicy"], Resource = aws_iam_role.updateassumerolepolicy_target[0].arn },
      { Effect = "Allow", Action = ["sts:AssumeRole"], Resource = aws_iam_role.updateassumerolepolicy_target[0].arn },
      { Effect = "Allow", Action = ["sts:GetCallerIdentity"], Resource = ["*"] },
    ]
  })
}
