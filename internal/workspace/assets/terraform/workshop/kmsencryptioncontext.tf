# Conditions lab — kms:ViaService + kms:EncryptionContext
#
# Teaches the two KMS gates that make a key usable ONLY through a specific
# service and ONLY when the caller supplies an exact encryption-context map.
# A pre-deployed Lambda is the only entity allowed to decrypt the lab's
# ciphertext. The student updates that Lambda's code to call kms:Decrypt with
# the right EncryptionContext; the plaintext is the flag.
#
# This is exactly capstone hop 8 in microcosm.

locals {
  kec_enabled    = var.enable_kmsencryptioncontext ? 1 : 0
  kec_prefix     = "${var.lab_prefix}-kmsencryptioncontext"
  kec_lambda_arn = "arn:${local.partition}:lambda:${local.region}:${local.account_id}:function:${local.kec_prefix}-golem"
}

# --- KMS key (gated by ViaService + EncryptionContext) ----------------------

resource "aws_kms_key" "kec_key" {
  count                   = local.kec_enabled
  description             = "Lab key — decrypt only via Lambda with purpose=lab-flag EncryptionContext."
  deletion_window_in_days = 7

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "RootAdmin"
        Effect    = "Allow"
        Principal = { AWS = "arn:${local.partition}:iam::${local.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        Sid       = "DecryptOnlyViaLambdaWithContext"
        Effect    = "Allow"
        Principal = { AWS = aws_iam_role.kec_lambda_exec[0].arn }
        Action    = ["kms:Decrypt", "kms:DescribeKey"]
        Resource  = "*"
        Condition = {
          StringEquals = {
            "kms:ViaService"                = "lambda.${local.region}.amazonaws.com"
            "kms:EncryptionContext:purpose" = "lab-flag"
          }
        }
      },
    ]
  })

  tags = { Lab = "kmsencryptioncontext" }
}

resource "aws_kms_alias" "kec_key" {
  count         = local.kec_enabled
  name          = "alias/${local.kec_prefix}-vault"
  target_key_id = aws_kms_key.kec_key[0].key_id
}

# Encrypt the flag at apply time. The EncryptionContext set here must match
# what the student passes at decrypt time — get either part wrong and KMS
# returns InvalidCiphertextException.
resource "aws_kms_ciphertext" "kec_payload" {
  count     = local.kec_enabled
  key_id    = aws_kms_key.kec_key[0].key_id
  plaintext = lookup(var.flag_values, "kmsencryptioncontext", "BORANT:kmsencryptioncontext-flag-missing")
  context = {
    purpose = "lab-flag"
  }
}

# --- Lambda + execution role (the only path to decrypt) ---------------------

resource "aws_iam_role" "kec_lambda_exec" {
  count = local.kec_enabled
  name  = "${local.kec_prefix}-grimaldi"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = { Lab = "kmsencryptioncontext", Kind = "lambda-exec" }
}

resource "aws_iam_role_policy" "kec_lambda_exec_inline" {
  count = local.kec_enabled
  name  = "${local.kec_prefix}-grimaldi-policy"
  role  = aws_iam_role.kec_lambda_exec[0].name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "Decrypt"
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:DescribeKey"]
        Resource = [aws_kms_key.kec_key[0].arn]
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

data "archive_file" "kec_stub_zip" {
  count       = local.kec_enabled
  type        = "zip"
  output_path = "${path.module}/.tmp-kmsencryptioncontext-stub.zip"

  source {
    filename = "index.py"
    content  = <<-EOT
      # Stub. Replace via lambda:UpdateFunctionCode. Read the env for ciphertext
      # + key id; call kms.decrypt with the correct EncryptionContext.
      def handler(event, context):
          return {"status": "stub", "hint": "EncryptionContext={purpose: lab-flag}"}
    EOT
  }
}

resource "aws_lambda_function" "kec_decryptor" {
  count            = local.kec_enabled
  function_name    = "${local.kec_prefix}-golem"
  role             = aws_iam_role.kec_lambda_exec[0].arn
  runtime          = "python3.11"
  handler          = "index.handler"
  filename         = data.archive_file.kec_stub_zip[0].output_path
  source_code_hash = data.archive_file.kec_stub_zip[0].output_base64sha256
  timeout          = 30

  environment {
    variables = {
      CIPHERTEXT_B64       = aws_kms_ciphertext.kec_payload[0].ciphertext_blob
      KMS_KEY_ID           = aws_kms_key.kec_key[0].key_id
      ENCRYPTION_CONTEXT_K = "purpose"
      ENCRYPTION_CONTEXT_V = "lab-flag"
    }
  }

  tags = { Lab = "kmsencryptioncontext", Kind = "decryptor" }
}

# --- Entry role -------------------------------------------------------------

resource "aws_iam_role" "kec_entry" {
  count                = local.kec_enabled
  name                 = "${local.kec_prefix}-carl"
  permissions_boundary = aws_iam_policy.kec_entry_boundary[0].arn
  max_session_duration = 3600

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = "arn:${local.partition}:iam::${local.account_id}:root" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = { Lab = "kmsencryptioncontext", Kind = "entry" }
}

resource "aws_iam_policy" "kec_entry_boundary" {
  count = local.kec_enabled
  name  = "${local.kec_prefix}-carl-boundary"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "UpdateAndInvokeDecryptor"
        Effect   = "Allow"
        Action   = ["lambda:UpdateFunctionCode", "lambda:GetFunction", "lambda:GetFunctionConfiguration", "lambda:InvokeFunction"]
        Resource = [local.kec_lambda_arn]
      },
      {
        Sid      = "ReadKeyMetadata"
        Effect   = "Allow"
        Action   = ["kms:DescribeKey", "kms:GetKeyPolicy", "kms:ListAliases"]
        Resource = [aws_kms_key.kec_key[0].arn]
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

resource "aws_iam_role_policy" "kec_entry_inline" {
  count  = local.kec_enabled
  name   = "${local.kec_prefix}-carl-policy"
  role   = aws_iam_role.kec_entry[0].name
  policy = aws_iam_policy.kec_entry_boundary[0].policy
}
