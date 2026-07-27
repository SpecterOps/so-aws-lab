# Conditions lab — sts:ExternalId
#
# Teaches the vendor-style external-id pattern. The target role's trust policy
# requires sts:ExternalId equal to a UUID stored in SSM. The entry role can
# read that SSM parameter, then must pass the value via --external-id when
# calling AssumeRole.
#
# Mirrors capstone hops 4 and 10 (deployer + prod-reader).

locals {
  cei_enabled     = var.enable_conditionexternalid ? 1 : 0
  cei_prefix      = "${var.lab_prefix}-conditionexternalid"
  cei_flag_param  = "/labs/${var.lab_prefix}/conditionexternalid/flag"
  cei_extid_param = "/labs/${var.lab_prefix}/conditionexternalid/external-id"
  cei_entry_arn   = "arn:${local.partition}:iam::${local.account_id}:role/${local.cei_prefix}-carl"
  cei_target_arn  = "arn:${local.partition}:iam::${local.account_id}:role/${local.cei_prefix}-donut"
}

resource "random_uuid" "cei_external_id" {
  count = local.cei_enabled
}

# --- Flag + external-id SSM params ------------------------------------------

resource "aws_ssm_parameter" "cei_flag" {
  count = local.cei_enabled
  name  = local.cei_flag_param
  type  = "SecureString"
  value = lookup(var.flag_values, "conditionexternalid", "BORANT:conditionexternalid-flag-missing")
  tags  = { Lab = "conditionexternalid" }
}

resource "aws_ssm_parameter" "cei_extid" {
  count       = local.cei_enabled
  name        = local.cei_extid_param
  type        = "SecureString"
  value       = random_uuid.cei_external_id[0].result
  description = "External ID required to assume the conditionexternalid target."
  tags        = { Lab = "conditionexternalid" }
}

# --- Entry role -------------------------------------------------------------

resource "aws_iam_role" "cei_entry" {
  count                = local.cei_enabled
  name                 = "${local.cei_prefix}-carl"
  permissions_boundary = aws_iam_policy.cei_entry_boundary[0].arn
  max_session_duration = 3600

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = "arn:${local.partition}:iam::${local.account_id}:root" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = { Lab = "conditionexternalid", Kind = "entry" }
}

resource "aws_iam_policy" "cei_entry_boundary" {
  count = local.cei_enabled
  name  = "${local.cei_prefix}-carl-boundary"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadExternalIdParam"
        Effect   = "Allow"
        Action   = ["ssm:GetParameter", "ssm:GetParameters"]
        Resource = ["arn:${local.partition}:ssm:${local.region}:${local.account_id}:parameter${local.cei_extid_param}"]
      },
      {
        Sid      = "DecryptSSM"
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = ["arn:${local.partition}:kms:${local.region}:${local.account_id}:alias/aws/ssm"]
      },
      {
        Sid      = "AssumeTarget"
        Effect   = "Allow"
        Action   = ["sts:AssumeRole"]
        Resource = [local.cei_target_arn]
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

resource "aws_iam_role_policy" "cei_entry_inline" {
  count  = local.cei_enabled
  name   = "${local.cei_prefix}-carl-policy"
  role   = aws_iam_role.cei_entry[0].name
  policy = aws_iam_policy.cei_entry_boundary[0].policy
}

# --- Target role (trust gated by sts:ExternalId) ----------------------------

resource "aws_iam_role" "cei_target" {
  count = local.cei_enabled
  name  = "${local.cei_prefix}-donut"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = local.cei_entry_arn }
      Action    = "sts:AssumeRole"
      Condition = {
        StringEquals = {
          "sts:ExternalId" = random_uuid.cei_external_id[0].result
        }
      }
    }]
  })

  tags = { Lab = "conditionexternalid", Kind = "target" }
}

resource "aws_iam_role_policy" "cei_target_inline" {
  count = local.cei_enabled
  name  = "${local.cei_prefix}-donut-policy"
  role  = aws_iam_role.cei_target[0].name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "ReadFlag"
      Effect = "Allow"
      Action = ["ssm:GetParameter", "kms:Decrypt"]
      Resource = [
        "arn:${local.partition}:ssm:${local.region}:${local.account_id}:parameter${local.cei_flag_param}",
        "arn:${local.partition}:kms:${local.region}:${local.account_id}:alias/aws/ssm",
      ]
    }]
  })
}
