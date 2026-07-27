###############################################################################
# Data labs: SSM (2), S3 (2), KMS (2)
###############################################################################

# --- ssmgetparameter ---------------------------------------------------------

module "lab_ssmgetparameter" {
  count      = var.enable_ssmgetparameter ? 1 : 0
  source     = "../modules/lab_with_victim"
  lab_prefix = var.lab_prefix
  lab_name   = "ssmgetparameter"
  flag_value = var.flag_values["ssmgetparameter"]

  entry_boundary_statements = [
    {
      # kms:Decrypt is not listed here. lab_common grants it on every entry
      # boundary, scoped by kms:ViaService, because an alias ARN authorizes
      # nothing and this module's statement type cannot carry a Condition.
      Sid      = "ReadCredsParam"
      Effect   = "Allow"
      Action   = ["ssm:GetParameter"]
      Resource = ["arn:${local.partition}:ssm:${local.region}:${local.account_id}:parameter/labs/${var.lab_prefix}/ssmgetparameter/creds"]
    },
  ]
}

resource "aws_iam_access_key" "ssmgetparameter_victim" {
  count = var.enable_ssmgetparameter ? 1 : 0
  user  = module.lab_ssmgetparameter[0].victim_user_name
}

resource "aws_ssm_parameter" "ssmgetparameter_creds" {
  count = var.enable_ssmgetparameter ? 1 : 0
  name  = "/labs/${var.lab_prefix}/ssmgetparameter/creds"
  type  = "SecureString"
  value = jsonencode({
    AccessKeyId     = aws_iam_access_key.ssmgetparameter_victim[0].id
    SecretAccessKey = aws_iam_access_key.ssmgetparameter_victim[0].secret
  })
  tags = { Lab = "ssmgetparameter" }
}

# --- ssmsendcommand ---------------------------------------------------------

module "lab_ssmsendcommand" {
  count      = var.enable_ssmsendcommand ? 1 : 0
  source     = "../modules/lab_common"
  lab_prefix = var.lab_prefix
  lab_name   = "ssmsendcommand"
  flag_value = var.flag_values["ssmsendcommand"]

  extra_target_principals = [
    "arn:${local.partition}:iam::${local.account_id}:role/${var.lab_prefix}-shared-ec2target",
  ]

  entry_boundary_statements = [
    {
      Sid      = "EnumerateSsmEc2"
      Effect   = "Allow"
      Action   = ["ssm:DescribeInstanceInformation", "ec2:Describe*"]
      Resource = ["*"]
    },
    {
      Sid    = "RunCommands"
      Effect = "Allow"
      Action = [
        "ssm:SendCommand", "ssm:GetCommandInvocation",
        "ssm:ListCommandInvocations", "ssm:ListCommands",
      ]
      Resource = ["*"]
    },
    {
      Sid      = "ReadInstanceIdParam"
      Effect   = "Allow"
      Action   = ["ssm:GetParameter"]
      Resource = ["arn:${local.partition}:ssm:${local.region}:${local.account_id}:parameter/labs/${var.lab_prefix}/ssmsendcommand/*"]
    },
  ]
}

# --- S3 lab suffix ----------------------------------------------------------

resource "random_id" "s3_lab_suffix" {
  count       = (var.enable_s3getobject || var.enable_s3putbucketpolicy) ? 1 : 0
  byte_length = 4
}

# --- s3getobject ------------------------------------------------------------

resource "aws_s3_bucket" "s3getobject" {
  count         = var.enable_s3getobject ? 1 : 0
  bucket        = "${var.lab_prefix}-s3getobject-${local.account_id}-${random_id.s3_lab_suffix[0].hex}"
  force_destroy = true
  tags          = { Lab = "s3getobject" }
}

resource "aws_s3_bucket_public_access_block" "s3getobject" {
  count                   = var.enable_s3getobject ? 1 : 0
  bucket                  = aws_s3_bucket.s3getobject[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_policy" "s3getobject" {
  count  = var.enable_s3getobject ? 1 : 0
  bucket = aws_s3_bucket.s3getobject[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowEntryRoleRead"
        Effect    = "Allow"
        Principal = { AWS = "arn:${local.partition}:iam::${local.account_id}:root" }
        Action    = ["s3:GetObject", "s3:ListBucket"]
        Resource = [
          aws_s3_bucket.s3getobject[0].arn,
          "${aws_s3_bucket.s3getobject[0].arn}/*",
        ]
        Condition = {
          ArnEquals = {
            "aws:PrincipalArn" = "arn:${local.partition}:iam::${local.account_id}:role/${var.lab_prefix}-s3getobject-carl"
          }
        }
      },
    ]
  })
}

module "lab_s3getobject" {
  count      = var.enable_s3getobject ? 1 : 0
  source     = "../modules/lab_with_victim"
  lab_prefix = var.lab_prefix
  lab_name   = "s3getobject"
  flag_value = var.flag_values["s3getobject"]

  entry_boundary_statements = [
    {
      Sid    = "ListAndRead"
      Effect = "Allow"
      Action = ["s3:GetObject", "s3:ListBucket"]
      Resource = [
        aws_s3_bucket.s3getobject[0].arn,
        "${aws_s3_bucket.s3getobject[0].arn}/*",
      ]
    },
    {
      Sid      = "ReadBucketHint"
      Effect   = "Allow"
      Action   = ["ssm:GetParameter"]
      Resource = ["arn:${local.partition}:ssm:${local.region}:${local.account_id}:parameter/labs/${var.lab_prefix}/s3getobject/bucket"]
    },
  ]
}

resource "aws_ssm_parameter" "s3getobject_bucket" {
  count = var.enable_s3getobject ? 1 : 0
  name  = "/labs/${var.lab_prefix}/s3getobject/bucket"
  type  = "String"
  value = aws_s3_bucket.s3getobject[0].id
  tags  = { Lab = "s3getobject" }
}

resource "aws_iam_access_key" "s3getobject_victim" {
  count = var.enable_s3getobject ? 1 : 0
  user  = module.lab_s3getobject[0].victim_user_name
}

resource "aws_s3_object" "s3getobject_creds" {
  count  = var.enable_s3getobject ? 1 : 0
  bucket = aws_s3_bucket.s3getobject[0].id
  key    = "creds.json"
  content = jsonencode({
    AccessKeyId     = aws_iam_access_key.s3getobject_victim[0].id
    SecretAccessKey = aws_iam_access_key.s3getobject_victim[0].secret
  })
  content_type = "application/json"
}

# --- s3putbucketpolicy ------------------------------------------------------

resource "aws_s3_bucket" "s3putbucketpolicy" {
  count         = var.enable_s3putbucketpolicy ? 1 : 0
  bucket        = "${var.lab_prefix}-s3putbucketpolicy-${local.account_id}-${random_id.s3_lab_suffix[0].hex}"
  force_destroy = true
  tags          = { Lab = "s3putbucketpolicy" }
}

resource "aws_s3_bucket_public_access_block" "s3putbucketpolicy" {
  count                   = var.enable_s3putbucketpolicy ? 1 : 0
  bucket                  = aws_s3_bucket.s3putbucketpolicy[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

module "lab_s3putbucketpolicy" {
  count      = var.enable_s3putbucketpolicy ? 1 : 0
  source     = "../modules/lab_with_victim"
  lab_prefix = var.lab_prefix
  lab_name   = "s3putbucketpolicy"
  flag_value = var.flag_values["s3putbucketpolicy"]

  entry_boundary_statements = [
    {
      Sid    = "ManageBucketPolicy"
      Effect = "Allow"
      Action = ["s3:PutBucketPolicy", "s3:GetBucketPolicy", "s3:DeleteBucketPolicy", "s3:ListBucket", "s3:GetObject"]
      Resource = [
        aws_s3_bucket.s3putbucketpolicy[0].arn,
        "${aws_s3_bucket.s3putbucketpolicy[0].arn}/*",
      ]
    },
    {
      Sid      = "ReadBucketHint"
      Effect   = "Allow"
      Action   = ["ssm:GetParameter"]
      Resource = ["arn:${local.partition}:ssm:${local.region}:${local.account_id}:parameter/labs/${var.lab_prefix}/s3putbucketpolicy/bucket"]
    },
  ]
}

resource "aws_ssm_parameter" "s3putbucketpolicy_bucket" {
  count = var.enable_s3putbucketpolicy ? 1 : 0
  name  = "/labs/${var.lab_prefix}/s3putbucketpolicy/bucket"
  type  = "String"
  value = aws_s3_bucket.s3putbucketpolicy[0].id
  tags  = { Lab = "s3putbucketpolicy" }
}

resource "aws_iam_access_key" "s3putbucketpolicy_victim" {
  count = var.enable_s3putbucketpolicy ? 1 : 0
  user  = module.lab_s3putbucketpolicy[0].victim_user_name
}

resource "aws_s3_object" "s3putbucketpolicy_creds" {
  count  = var.enable_s3putbucketpolicy ? 1 : 0
  bucket = aws_s3_bucket.s3putbucketpolicy[0].id
  key    = "creds.json"
  content = jsonencode({
    AccessKeyId     = aws_iam_access_key.s3putbucketpolicy_victim[0].id
    SecretAccessKey = aws_iam_access_key.s3putbucketpolicy_victim[0].secret
  })
  content_type = "application/json"
}

# --- kmsdecrypt -------------------------------------------------------------

resource "aws_kms_key" "kmsdecrypt" {
  count                   = var.enable_kmsdecrypt ? 1 : 0
  description             = "${var.lab_prefix} kmsdecrypt lab key"
  deletion_window_in_days = 7

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "RootAdmin"
      Effect    = "Allow"
      Principal = { AWS = "arn:${local.partition}:iam::${local.account_id}:root" }
      Action    = "kms:*"
      Resource  = ["*"]
    }]
  })
}

resource "aws_kms_alias" "kmsdecrypt" {
  count         = var.enable_kmsdecrypt ? 1 : 0
  name          = "alias/${var.lab_prefix}-kmsdecrypt-vault"
  target_key_id = aws_kms_key.kmsdecrypt[0].id
}

module "lab_kmsdecrypt" {
  count      = var.enable_kmsdecrypt ? 1 : 0
  source     = "../modules/lab_with_victim"
  lab_prefix = var.lab_prefix
  lab_name   = "kmsdecrypt"
  flag_value = var.flag_values["kmsdecrypt"]

  entry_boundary_statements = [
    {
      Sid      = "ReadCiphertext"
      Effect   = "Allow"
      Action   = ["ssm:GetParameter"]
      Resource = ["arn:${local.partition}:ssm:${local.region}:${local.account_id}:parameter/labs/${var.lab_prefix}/kmsdecrypt/ciphertext"]
    },
    {
      Sid      = "DecryptKey"
      Effect   = "Allow"
      Action   = ["kms:Decrypt"]
      Resource = [aws_kms_key.kmsdecrypt[0].arn]
    },
  ]
}

resource "aws_iam_access_key" "kmsdecrypt_victim" {
  count = var.enable_kmsdecrypt ? 1 : 0
  user  = module.lab_kmsdecrypt[0].victim_user_name
}

resource "aws_kms_ciphertext" "kmsdecrypt_creds" {
  count  = var.enable_kmsdecrypt ? 1 : 0
  key_id = aws_kms_key.kmsdecrypt[0].id
  plaintext = jsonencode({
    AccessKeyId     = aws_iam_access_key.kmsdecrypt_victim[0].id
    SecretAccessKey = aws_iam_access_key.kmsdecrypt_victim[0].secret
  })
}

resource "aws_ssm_parameter" "kmsdecrypt_ciphertext" {
  count = var.enable_kmsdecrypt ? 1 : 0
  name  = "/labs/${var.lab_prefix}/kmsdecrypt/ciphertext"
  type  = "String"
  value = aws_kms_ciphertext.kmsdecrypt_creds[0].ciphertext_blob
  tags  = { Lab = "kmsdecrypt" }
}

# --- kmscreategrant ---------------------------------------------------------

resource "aws_kms_key" "kmscreategrant" {
  count                   = var.enable_kmscreategrant ? 1 : 0
  description             = "${var.lab_prefix} kmscreategrant lab key"
  deletion_window_in_days = 7

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "RootAdmin"
      Effect    = "Allow"
      Principal = { AWS = "arn:${local.partition}:iam::${local.account_id}:root" }
      Action    = "kms:*"
      Resource  = ["*"]
    }]
  })
}

resource "aws_kms_alias" "kmscreategrant" {
  count         = var.enable_kmscreategrant ? 1 : 0
  name          = "alias/${var.lab_prefix}-kmscreategrant-vault"
  target_key_id = aws_kms_key.kmscreategrant[0].id
}

module "lab_kmscreategrant" {
  count      = var.enable_kmscreategrant ? 1 : 0
  source     = "../modules/lab_with_victim"
  lab_prefix = var.lab_prefix
  lab_name   = "kmscreategrant"
  flag_value = var.flag_values["kmscreategrant"]

  entry_boundary_statements = [
    {
      Sid      = "ReadCiphertext"
      Effect   = "Allow"
      Action   = ["ssm:GetParameter"]
      Resource = ["arn:${local.partition}:ssm:${local.region}:${local.account_id}:parameter/labs/${var.lab_prefix}/kmscreategrant/ciphertext"]
    },
    {
      Sid      = "GrantThenDecrypt"
      Effect   = "Allow"
      Action   = ["kms:CreateGrant", "kms:Decrypt", "kms:DescribeKey", "kms:ListGrants"]
      Resource = [aws_kms_key.kmscreategrant[0].arn]
    },
  ]
}

resource "aws_iam_access_key" "kmscreategrant_victim" {
  count = var.enable_kmscreategrant ? 1 : 0
  user  = module.lab_kmscreategrant[0].victim_user_name
}

resource "aws_kms_ciphertext" "kmscreategrant_creds" {
  count  = var.enable_kmscreategrant ? 1 : 0
  key_id = aws_kms_key.kmscreategrant[0].id
  plaintext = jsonencode({
    AccessKeyId     = aws_iam_access_key.kmscreategrant_victim[0].id
    SecretAccessKey = aws_iam_access_key.kmscreategrant_victim[0].secret
  })
}

resource "aws_ssm_parameter" "kmscreategrant_ciphertext" {
  count = var.enable_kmscreategrant ? 1 : 0
  name  = "/labs/${var.lab_prefix}/kmscreategrant/ciphertext"
  type  = "String"
  value = aws_kms_ciphertext.kmscreategrant_creds[0].ciphertext_blob
  tags  = { Lab = "kmscreategrant" }
}
