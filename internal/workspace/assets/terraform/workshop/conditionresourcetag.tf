# Conditions lab — aws:ResourceTag
#
# Teaches the most common defensive scoping primitive: an IAM allow statement
# whose Condition restricts the action to resources carrying a specific tag.
# The entry role can lambda:UpdateFunctionCode on ANY Lambda matching its
# resource pattern, but ONLY if the function carries Lab=conditionresourcetag.
# Three functions are deployed (one correctly tagged, two decoys) so the
# student must enumerate + read tags to find the one they can actually update.
#
# Mirrors the gate the capstone uses on hop 1 (dev-deployer → bootstrap-fn).

locals {
  crt_enabled    = var.enable_conditionresourcetag ? 1 : 0
  crt_prefix     = "${var.lab_prefix}-conditionresourcetag"
  crt_flag_param = "/labs/${var.lab_prefix}/conditionresourcetag/flag"
}

# --- Flag + target role (the Lambda execution role for the tagged function) -

resource "aws_ssm_parameter" "crt_flag" {
  count = local.crt_enabled
  name  = local.crt_flag_param
  type  = "SecureString"
  value = lookup(var.flag_values, "conditionresourcetag", "BORANT:conditionresourcetag-flag-missing")
  tags  = { Lab = "conditionresourcetag" }
}

resource "aws_iam_role" "crt_target" {
  count = local.crt_enabled
  name  = "${local.crt_prefix}-donut"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = { Lab = "conditionresourcetag", Kind = "target" }
}

resource "aws_iam_role_policy" "crt_target_inline" {
  count = local.crt_enabled
  name  = "${local.crt_prefix}-donut-policy"
  role  = aws_iam_role.crt_target[0].name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadFlag"
        Effect   = "Allow"
        Action   = ["ssm:GetParameter"]
        Resource = ["arn:${local.partition}:ssm:${local.region}:${local.account_id}:parameter${local.crt_flag_param}"]
      },
      {
        Sid      = "DecryptSSMFlag"
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = ["*"]
        Condition = {
          StringEquals = { "kms:ViaService" = "ssm.${local.region}.amazonaws.com" }
        }
      },
      {
        Sid      = "Logs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = ["*"]
      },
    ]
  })
}

# --- Decoy execution role (used by both decoy functions; flag-less) ---------

resource "aws_iam_role" "crt_decoy_exec" {
  count = local.crt_enabled
  name  = "${local.crt_prefix}-mordecai"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = { Lab = "conditionresourcetag", Kind = "decoy-exec" }
}

resource "aws_iam_role_policy" "crt_decoy_exec_inline" {
  count = local.crt_enabled
  name  = "${local.crt_prefix}-mordecai-policy"
  role  = aws_iam_role.crt_decoy_exec[0].name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "Logs"
      Effect   = "Allow"
      Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
      Resource = ["*"]
    }]
  })
}

# --- Lambda functions: 1 tagged correctly, 2 decoys -------------------------

data "archive_file" "crt_stub_zip" {
  count       = local.crt_enabled
  type        = "zip"
  output_path = "${path.module}/.tmp-conditionresourcetag-stub.zip"

  source {
    filename = "index.py"
    content  = <<-EOT
      # Stub. Replace via lambda:UpdateFunctionCode to exfil execution-role creds.
      def handler(event, context):
          return {"status": "stub", "function": context.function_name}
    EOT
  }
}

resource "aws_lambda_function" "crt_target_fn" {
  count            = local.crt_enabled
  function_name    = "${local.crt_prefix}-golem"
  role             = aws_iam_role.crt_target[0].arn
  runtime          = "python3.11"
  handler          = "index.handler"
  filename         = data.archive_file.crt_stub_zip[0].output_path
  source_code_hash = data.archive_file.crt_stub_zip[0].output_base64sha256
  timeout          = 30

  tags = { Lab = "conditionresourcetag", Kind = "target" }
}

resource "aws_lambda_function" "crt_decoy_other_fn" {
  count            = local.crt_enabled
  function_name    = "${local.crt_prefix}-mimic-a"
  role             = aws_iam_role.crt_decoy_exec[0].arn
  runtime          = "python3.11"
  handler          = "index.handler"
  filename         = data.archive_file.crt_stub_zip[0].output_path
  source_code_hash = data.archive_file.crt_stub_zip[0].output_base64sha256
  timeout          = 30

  # Tagged Lab=other — same prefix, wrong value. AccessDenied on UpdateFunctionCode.
  tags = { Lab = "other", Kind = "decoy" }
}

resource "aws_lambda_function" "crt_decoy_untagged_fn" {
  count            = local.crt_enabled
  function_name    = "${local.crt_prefix}-mimic-b"
  role             = aws_iam_role.crt_decoy_exec[0].arn
  runtime          = "python3.11"
  handler          = "index.handler"
  filename         = data.archive_file.crt_stub_zip[0].output_path
  source_code_hash = data.archive_file.crt_stub_zip[0].output_base64sha256
  timeout          = 30

  # No Lab tag at all. AccessDenied on UpdateFunctionCode (Condition unmet).
  tags = { Kind = "decoy" }
}

# --- Entry role + boundary --------------------------------------------------

resource "aws_iam_role" "crt_entry" {
  count                = local.crt_enabled
  name                 = "${local.crt_prefix}-carl"
  permissions_boundary = aws_iam_policy.crt_entry_boundary[0].arn
  max_session_duration = 3600

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = "arn:${local.partition}:iam::${local.account_id}:root" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = { Lab = "conditionresourcetag", Kind = "entry" }
}

resource "aws_iam_policy" "crt_entry_boundary" {
  count = local.crt_enabled
  name  = "${local.crt_prefix}-carl-boundary"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "DiscoverLambda"
        Effect = "Allow"
        Action = [
          "lambda:ListFunctions",
          "lambda:GetFunction",
          "lambda:GetFunctionConfiguration",
          "lambda:ListTags",
          "lambda:InvokeFunction",
        ]
        Resource = ["*"]
      },
      {
        Sid    = "UpdateOnlyTaggedFunctions"
        Effect = "Allow"
        Action = ["lambda:UpdateFunctionCode"]
        Resource = [
          "arn:${local.partition}:lambda:${local.region}:${local.account_id}:function:${local.crt_prefix}-*",
        ]
        Condition = {
          StringEquals = {
            "aws:ResourceTag/Lab" = "conditionresourcetag"
          }
        }
      },
      {
        Sid    = "LabSelfEnumeration"
        Effect = "Allow"
        Action = [
          "iam:Get*", "iam:List*", "iam:SimulatePrincipalPolicy", "iam:SimulateCustomPolicy",
          "sts:GetCallerIdentity",
        ]
        Resource = ["*"]
      },
    ]
  })
}

resource "aws_iam_role_policy" "crt_entry_inline" {
  count  = local.crt_enabled
  name   = "${local.crt_prefix}-carl-policy"
  role   = aws_iam_role.crt_entry[0].name
  policy = aws_iam_policy.crt_entry_boundary[0].policy
}
