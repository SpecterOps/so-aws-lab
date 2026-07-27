# Conditions lab — aws:PrincipalTag via iam:TagUser
#
# Teaches the "self-tag to satisfy a trust condition" pattern. The student
# starts with long-term IAM user credentials. The target role's trust policy
# requires aws:PrincipalTag/access = admin. The user can iam:TagUser ON ITSELF
# (gated by iam:ResourceTag/Lab = conditionprincipaltag, which the workshop
# sets at deploy time), satisfying the condition for the next AssumeRole.
#
# Pedagogy: aws:PrincipalTag evaluates against the CALLER's tags. For an IAM
# user, tagging the user updates the value. The capstone teaches the more
# advanced role→role variant via aws:RequestTag + sts:TagSession.

locals {
  cpt_enabled    = var.enable_conditionprincipaltag ? 1 : 0
  cpt_prefix     = "${var.lab_prefix}-conditionprincipaltag"
  cpt_flag_param = "/labs/${var.lab_prefix}/conditionprincipaltag/flag"
  cpt_user_arn   = "arn:${local.partition}:iam::${local.account_id}:user/${local.cpt_prefix}-carl"
  cpt_target_arn = "arn:${local.partition}:iam::${local.account_id}:role/${local.cpt_prefix}-donut"
}

# --- Flag SSM ---------------------------------------------------------------

resource "aws_ssm_parameter" "cpt_flag" {
  count = local.cpt_enabled
  name  = local.cpt_flag_param
  type  = "SecureString"
  value = lookup(var.flag_values, "conditionprincipaltag", "BORANT:conditionprincipaltag-flag-missing")
  tags  = { Lab = "conditionprincipaltag" }
}

# --- IAM user (entry point) -------------------------------------------------

resource "aws_iam_user" "cpt_user" {
  count                = local.cpt_enabled
  name                 = "${local.cpt_prefix}-carl"
  permissions_boundary = aws_iam_policy.cpt_user_boundary[0].arn

  # The lab tag is what enables self-tagging — iam:TagUser is gated on
  # iam:ResourceTag/Lab, which the boundary checks.
  tags = { Lab = "conditionprincipaltag", Kind = "entry-user" }
}

resource "aws_iam_policy" "cpt_user_boundary" {
  count = local.cpt_enabled
  name  = "${local.cpt_prefix}-carl-boundary"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "TagSelfOnly"
        Effect   = "Allow"
        Action   = ["iam:TagUser", "iam:UntagUser"]
        Resource = [local.cpt_user_arn]
        Condition = {
          StringEquals = {
            "iam:ResourceTag/Lab" = "conditionprincipaltag"
          }
        }
      },
      {
        Sid      = "AssumeTarget"
        Effect   = "Allow"
        Action   = ["sts:AssumeRole"]
        Resource = [local.cpt_target_arn]
      },
      {
        Sid      = "LabSelfEnumeration"
        Effect   = "Allow"
        Action   = ["iam:Get*", "iam:List*", "iam:SimulatePrincipalPolicy", "iam:SimulateCustomPolicy", "sts:GetCallerIdentity"]
        Resource = ["*"]
      },
    ]
  })
}

resource "aws_iam_user_policy" "cpt_user_inline" {
  count  = local.cpt_enabled
  name   = "${local.cpt_prefix}-carl-policy"
  user   = aws_iam_user.cpt_user[0].name
  policy = aws_iam_policy.cpt_user_boundary[0].policy
}

resource "aws_iam_access_key" "cpt_user" {
  count = local.cpt_enabled
  user  = aws_iam_user.cpt_user[0].name
}

# --- Target role (trust gated by aws:PrincipalTag) --------------------------

resource "aws_iam_role" "cpt_target" {
  count = local.cpt_enabled
  name  = "${local.cpt_prefix}-donut"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = local.cpt_user_arn }
      Action    = "sts:AssumeRole"
      Condition = {
        StringEquals = {
          "aws:PrincipalTag/access" = "admin"
        }
      }
    }]
  })

  tags = { Lab = "conditionprincipaltag", Kind = "target" }
}

resource "aws_iam_role_policy" "cpt_target_inline" {
  count = local.cpt_enabled
  name  = "${local.cpt_prefix}-donut-policy"
  role  = aws_iam_role.cpt_target[0].name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "ReadFlag"
      Effect = "Allow"
      Action = ["ssm:GetParameter", "kms:Decrypt"]
      Resource = [
        "arn:${local.partition}:ssm:${local.region}:${local.account_id}:parameter${local.cpt_flag_param}",
        "arn:${local.partition}:kms:${local.region}:${local.account_id}:alias/aws/ssm",
      ]
    }]
  })
}
