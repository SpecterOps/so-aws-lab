# Capstone: 3-account, condition-gated privilege chain. Every resource is
# gated by var.enable_capstone so the file is a no-op when disabled.
#
# Operational chain (10 AWSHound-traversable hops):
#
#   [dev]     capstone-carl (User)
#              -- AWS_CanUpdateLambdaCode -->        [Condition: aws:ResourceTag/Lab=capstone]
#             capstone-gate-golem (Lambda)
#              -- AWS_RunsAs -->
#             capstone-donut (Role)
#              -- AWS_CanAssumeRole (x-acct) -->     [Conditions: PrincipalTag/team=red + SourceAccount]
#   [staging] capstone-signet (Role)
#              -- AWS_CanAssumeRole -->              [Condition: sts:ExternalId]
#             capstone-mordecai (Role)
#              -- AWS_SSMCanSendCommand -->
#             capstone-outpost (EC2 jumpbox)
#              -- AWS_RunsAs -->
#             capstone-katia-role (Role)
#              -- AWS_CanCreateEKSPodIdentityAssociation -->
#             capstone-mongo-role (Role)
#              -- AWS_CanUpdateLambdaCode -->
#             capstone-vault-golem (Lambda)
#              -- AWS_RunsAs -->
#             capstone-grimaldi (Role)
#              -- AWS_CanAssumeRole (x-acct) -->     [Conditions: SourceAccount + sts:ExternalId from KMS decrypt]
#   [prod]    capstone-odette (Role)
#              -- AWS_CanGetParameter -->            (terminal data node)
#             /labs/<prefix>/capstone/flag (SSMParameter)
#
# The KMS decrypt step inside the staging Lambda is gated by
# kms:ViaService=lambda.<region>.amazonaws.com AND
# kms:EncryptionContext:purpose=capstone-handoff. The ciphertext is generated
# at apply time via aws_kms_ciphertext and stored in the decryptor's env.

locals {
  capstone_enabled = var.enable_capstone ? 1 : 0

  capstone_prefix      = "${var.lab_prefix}-capstone"
  capstone_flag_param  = "/labs/${var.lab_prefix}/capstone/flag"
  capstone_hint_param  = "/labs/${var.lab_prefix}/capstone/hint"
  capstone_extid_param = "/labs/${var.lab_prefix}/capstone/external-id"

  # Service principals for cross-account trust.
  capstone_lambda_sp       = "lambda.amazonaws.com"
  capstone_ec2_sp          = "ec2.amazonaws.com"
  capstone_pod_identity_sp = "pods.eks.amazonaws.com"

  capstone_dev_account_root     = "arn:${local.partition}:iam::${local.account_id}:root"
  capstone_staging_account_root = "arn:${local.partition}:iam::${local.staging_account_id}:root"

  # ARNs the chain refers to before each resource is fully created — used in
  # cross-account trust policies + inline allows. They follow the deterministic
  # naming pattern; computing them up front avoids cyclic data flows.
  capstone_entry_role_arn       = "arn:${local.partition}:iam::${local.account_id}:role/${local.capstone_prefix}-donut"
  capstone_bridge_role_arn      = "arn:${local.partition}:iam::${local.staging_account_id}:role/${local.capstone_prefix}-signet"
  capstone_deployer_role_arn    = "arn:${local.partition}:iam::${local.staging_account_id}:role/${local.capstone_prefix}-mordecai"
  capstone_ec2_role_arn         = "arn:${local.partition}:iam::${local.staging_account_id}:role/${local.capstone_prefix}-katia"
  capstone_pod_role_arn         = "arn:${local.partition}:iam::${local.staging_account_id}:role/${local.capstone_prefix}-mongo"
  capstone_lambda_exec_role_arn = "arn:${local.partition}:iam::${local.staging_account_id}:role/${local.capstone_prefix}-grimaldi"
  capstone_prod_reader_role_arn = "arn:${local.partition}:iam::${local.prod_account_id}:role/${local.capstone_prefix}-odette"

  # IAM read/simulate allow-list reused across capstone roles — mirrors the
  # LabSelfEnumeration block we added to lab_common's always_allow.
  capstone_self_enum_actions = [
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
    "ssm:DescribeParameters",
    "sts:GetCallerIdentity",
  ]
}

# ============================================================================
# Random material — external-id (hop 5) and inner external-id (hop 10 puzzle)
# ============================================================================

resource "random_uuid" "capstone_external_id" {
  count = local.capstone_enabled
}

resource "random_uuid" "capstone_prod_external_id" {
  count = local.capstone_enabled
}

resource "random_id" "capstone_verify_token" {
  count       = local.capstone_enabled
  byte_length = 12
}

# ============================================================================
# DEV account — entry surface
# ============================================================================

# The student's starting identity. Long-term access keys are emitted as a
# sensitive terraform output so the student can configure their CLI.
resource "aws_iam_user" "capstone_dev_deployer" {
  count = local.capstone_enabled
  name  = "${local.capstone_prefix}-carl"
  path  = "/"

  permissions_boundary = aws_iam_policy.capstone_dev_deployer_boundary[0].arn

  tags = {
    Lab  = "capstone"
    Kind = "entry-user"
  }
}

resource "aws_iam_policy" "capstone_dev_deployer_boundary" {
  count = local.capstone_enabled
  name  = "${local.capstone_prefix}-carl-boundary"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "DiscoverLambdaTaggedCapstone"
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
        Sid    = "UpdateLambdaOnlyWhenTagged"
        Effect = "Allow"
        Action = ["lambda:UpdateFunctionCode"]
        Resource = [
          "arn:${local.partition}:lambda:${local.region}:${local.account_id}:function:${local.capstone_prefix}-*",
        ]
        Condition = {
          StringEquals = {
            "aws:ResourceTag/Lab" = "capstone"
          }
        }
      },
      {
        Sid      = "ReadCloudWatchLogs"
        Effect   = "Allow"
        Action   = ["logs:GetLogEvents", "logs:DescribeLogStreams", "logs:DescribeLogGroups", "logs:FilterLogEvents"]
        Resource = ["*"]
      },
      {
        Sid      = "SelfEnumeration"
        Effect   = "Allow"
        Action   = local.capstone_self_enum_actions
        Resource = ["*"]
      },
    ]
  })
}

resource "aws_iam_user_policy" "capstone_dev_deployer_inline" {
  count  = local.capstone_enabled
  name   = "${local.capstone_prefix}-carl-policy"
  user   = aws_iam_user.capstone_dev_deployer[0].name
  policy = aws_iam_policy.capstone_dev_deployer_boundary[0].policy
}

resource "aws_iam_access_key" "capstone_dev_deployer" {
  count = local.capstone_enabled
  user  = aws_iam_user.capstone_dev_deployer[0].name
}

# The entry role lives in dev. Trust is locked to lambda.amazonaws.com AND
# specifically aws:SourceArn == capstone-gate-golem — the student MUST go
# through the function (no direct AssumeRole shortcut from a dev shell).
resource "aws_iam_role" "capstone_entry" {
  count = local.capstone_enabled
  name  = "${local.capstone_prefix}-donut"
  path  = "/"

  permissions_boundary = aws_iam_policy.capstone_entry_boundary[0].arn
  max_session_duration = 3600

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = local.capstone_lambda_sp }
        Action    = "sts:AssumeRole"
        Condition = {
          ArnEquals = {
            "aws:SourceArn" = "arn:${local.partition}:lambda:${local.region}:${local.account_id}:function:${local.capstone_prefix}-gate-golem"
          }
        }
      },
    ]
  })

  tags = {
    Lab  = "capstone"
    Kind = "entry"
  }
}

resource "aws_iam_policy" "capstone_entry_boundary" {
  count = local.capstone_enabled
  name  = "${local.capstone_prefix}-donut-boundary"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadHint"
        Effect   = "Allow"
        Action   = ["ssm:GetParameter", "ssm:GetParameters"]
        Resource = ["arn:${local.partition}:ssm:${local.region}:${local.account_id}:parameter${local.capstone_hint_param}"]
      },
      {
        # KMS authorizes against a key ARN, never an alias ARN. Scope by
        # kms:ViaService, mirroring the aws/ssm key policy.
        Sid      = "DecryptSSMHint"
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = ["*"]
        Condition = {
          StringEquals = { "kms:ViaService" = "ssm.${local.region}.amazonaws.com" }
        }
      },
      {
        # The bridge's trust requires aws:RequestTag/team=red — set via
        # --tags on the AssumeRole call. sts:TagSession authorizes setting
        # session tags on the target.
        Sid      = "AssumeStagingBridgeWithSessionTag"
        Effect   = "Allow"
        Action   = ["sts:AssumeRole", "sts:TagSession"]
        Resource = [local.capstone_bridge_role_arn]
      },
      {
        Sid      = "SelfEnumeration"
        Effect   = "Allow"
        Action   = local.capstone_self_enum_actions
        Resource = ["*"]
      },
    ]
  })
}

resource "aws_iam_role_policy" "capstone_entry_inline" {
  count  = local.capstone_enabled
  name   = "${local.capstone_prefix}-donut-policy"
  role   = aws_iam_role.capstone_entry[0].name
  policy = aws_iam_policy.capstone_entry_boundary[0].policy
}

# Bootstrap Lambda — the student updates this function's code to exfil
# capstone-donut's session credentials. Initial code is a no-op that returns
# the env so the student can immediately see they have shell.
data "archive_file" "capstone_bootstrap_zip" {
  count       = local.capstone_enabled
  type        = "zip"
  output_path = "${path.module}/.tmp-capstone-bootstrap.zip"

  source {
    filename = "index.py"
    content  = <<-EOT
      # Bootstrap stub for the capstone lab. Replace this code via
      # lambda:UpdateFunctionCode to exfil execution-role creds.
      import os
      def handler(event, context):
          return {"status": "stub", "function": context.function_name}
    EOT
  }
}

resource "aws_lambda_function" "capstone_bootstrap_fn" {
  count = local.capstone_enabled

  function_name    = "${local.capstone_prefix}-gate-golem"
  role             = aws_iam_role.capstone_entry[0].arn
  runtime          = "python3.11"
  handler          = "index.handler"
  filename         = data.archive_file.capstone_bootstrap_zip[0].output_path
  source_code_hash = data.archive_file.capstone_bootstrap_zip[0].output_base64sha256
  timeout          = 30

  tags = {
    Lab  = "capstone"
    Kind = "bootstrap"
  }
}

resource "aws_ssm_parameter" "capstone_hint" {
  count       = local.capstone_enabled
  name        = local.capstone_hint_param
  type        = "SecureString"
  value       = <<-EOT
    capstone hint:
      • the entry role can iam:TagRole on itself only when the role carries
        Lab=capstone (it does — the workshop set that tag at deploy time).
      • the staging bridge's trust policy requires aws:PrincipalTag/team=red
        AND aws:SourceAccount=<dev>.
      • read your own boundary with iam:GetRolePolicy / GetPolicy to confirm.
  EOT
  description = "Capstone — hint for the student starting in dev."

  tags = { Lab = "capstone" }
}

# ============================================================================
# STAGING account — bridge, deployer, EC2 jumpbox, pod role, decryptor
# ============================================================================

# Reuse the shared VPC + EKS modules in the staging account.
module "capstone_staging_vpc" {
  count  = local.capstone_enabled
  source = "../modules/shared_vpc"

  providers = {
    aws = aws.staging
  }

  lab_prefix = "${var.lab_prefix}-cs"
}

module "capstone_staging_eks" {
  count  = local.capstone_enabled
  source = "../modules/shared_eks"

  providers = {
    aws = aws.staging
  }

  lab_prefix = "${var.lab_prefix}-cs"
  vpc_id     = module.capstone_staging_vpc[0].vpc_id
  subnet_ids = module.capstone_staging_vpc[0].subnet_ids
}

# --- Hop 3 target: bridge role -----------------------------------------------

resource "aws_iam_role" "capstone_bridge" {
  count    = local.capstone_enabled
  provider = aws.staging

  name = "${local.capstone_prefix}-signet"
  path = "/"

  max_session_duration = 3600

  # Trust requires the caller to set session tag team=red at AssumeRole time
  # (aws:RequestTag), AND to be coming from the dev account. Role tags on the
  # caller (iam:TagRole) do NOT propagate to session tags, so the satisfaction
  # path is `aws sts assume-role --tags Key=team,Value=red`. The entry role's
  # boundary grants sts:TagSession on this role to make that legal.
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { AWS = local.capstone_dev_account_root }
        Action    = ["sts:AssumeRole", "sts:TagSession"]
        Condition = {
          StringEquals = {
            "aws:RequestTag/team" = "red"
            # aws:PrincipalAccount (not aws:SourceAccount) is the key populated on
            # a direct sts:AssumeRole; it equals the calling principal's account.
            "aws:PrincipalAccount" = local.account_id
          }
        }
      },
    ]
  })

  tags = {
    Lab  = "capstone"
    Kind = "bridge"
  }
}

resource "aws_iam_role_policy" "capstone_bridge_inline" {
  count    = local.capstone_enabled
  provider = aws.staging

  name = "${local.capstone_prefix}-signet-policy"
  role = aws_iam_role.capstone_bridge[0].name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ReadExternalIdParam"
        Effect = "Allow"
        Action = ["ssm:GetParameter", "ssm:GetParameters"]
        Resource = [
          "arn:${local.partition}:ssm:${local.staging_region}:${local.staging_account_id}:parameter${local.capstone_extid_param}",
        ]
      },
      {
        # KMS authorizes against a key ARN, never an alias ARN. Scope by
        # kms:ViaService in the staging region, mirroring its aws/ssm key policy.
        Sid      = "DecryptSSMExternalId"
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = ["*"]
        Condition = {
          StringEquals = { "kms:ViaService" = "ssm.${local.staging_region}.amazonaws.com" }
        }
      },
      {
        Sid      = "AssumeDeployer"
        Effect   = "Allow"
        Action   = ["sts:AssumeRole"]
        Resource = [local.capstone_deployer_role_arn]
      },
      {
        Sid      = "SelfEnumeration"
        Effect   = "Allow"
        Action   = local.capstone_self_enum_actions
        Resource = ["*"]
      },
    ]
  })
}

# --- Hop 4 target: deployer role gated by sts:ExternalId ---------------------

resource "aws_ssm_parameter" "capstone_external_id" {
  count    = local.capstone_enabled
  provider = aws.staging

  name        = local.capstone_extid_param
  type        = "SecureString"
  value       = random_uuid.capstone_external_id[0].result
  description = "Capstone — external ID required to assume the deployer role."

  tags = { Lab = "capstone" }
}

resource "aws_iam_role" "capstone_deployer" {
  count    = local.capstone_enabled
  provider = aws.staging

  name = "${local.capstone_prefix}-mordecai"
  path = "/"

  max_session_duration = 3600

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { AWS = aws_iam_role.capstone_bridge[0].arn }
        Action    = "sts:AssumeRole"
        Condition = {
          StringEquals = {
            "sts:ExternalId" = random_uuid.capstone_external_id[0].result
          }
        }
      },
    ]
  })

  tags = {
    Lab  = "capstone"
    Kind = "deployer"
  }
}

resource "aws_iam_role_policy" "capstone_deployer_inline" {
  count    = local.capstone_enabled
  provider = aws.staging

  name = "${local.capstone_prefix}-mordecai-policy"
  role = aws_iam_role.capstone_deployer[0].name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "SendCommandToJumpbox"
        Effect = "Allow"
        Action = ["ssm:SendCommand", "ssm:GetCommandInvocation", "ssm:ListCommandInvocations", "ssm:DescribeInstanceInformation"]
        Resource = [
          aws_instance.capstone_jumpbox[0].arn,
          "arn:${local.partition}:ssm:${local.staging_region}::document/AWS-RunShellScript",
          "arn:${local.partition}:ssm:${local.staging_region}:${local.staging_account_id}:*",
        ]
      },
      {
        Sid      = "PassEC2Role"
        Effect   = "Allow"
        Action   = ["iam:PassRole"]
        Resource = [local.capstone_ec2_role_arn]
      },
      {
        Sid      = "SelfEnumeration"
        Effect   = "Allow"
        Action   = local.capstone_self_enum_actions
        Resource = ["*"]
      },
    ]
  })
}

# --- Hop 5 target: jumpbox EC2 instance --------------------------------------

resource "aws_iam_role" "capstone_ec2_role" {
  count    = local.capstone_enabled
  provider = aws.staging

  name = "${local.capstone_prefix}-katia"
  path = "/"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = local.capstone_ec2_sp }
        Action    = "sts:AssumeRole"
      },
    ]
  })

  tags = {
    Lab  = "capstone"
    Kind = "ec2"
  }
}

resource "aws_iam_role_policy" "capstone_ec2_inline" {
  count    = local.capstone_enabled
  provider = aws.staging

  name = "${local.capstone_prefix}-katia-policy"
  role = aws_iam_role.capstone_ec2_role[0].name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "EKSEnumeration"
        Effect = "Allow"
        Action = [
          "eks:DescribeCluster",
          "eks:ListClusters",
          "eks:ListPodIdentityAssociations",
          "eks:DescribePodIdentityAssociation",
        ]
        Resource = ["*"]
      },
      {
        Sid    = "CreatePodIdentityAssociation"
        Effect = "Allow"
        Action = [
          "eks:CreatePodIdentityAssociation",
        ]
        Resource = [
          "arn:${local.partition}:eks:${local.staging_region}:${local.staging_account_id}:cluster/${module.capstone_staging_eks[0].cluster_name}",
          local.capstone_pod_role_arn,
        ]
      },
      {
        Sid      = "PassPodRole"
        Effect   = "Allow"
        Action   = ["iam:PassRole"]
        Resource = [local.capstone_pod_role_arn]
      },
      {
        Sid    = "SSMManagedInstanceCore"
        Effect = "Allow"
        Action = [
          "ssm:UpdateInstanceInformation",
          "ssm:ListInstanceAssociations",
          "ssm:DescribeAssociation",
          "ssm:DescribeDocument",
          "ssm:GetDocument",
          "ssm:ListAssociations",
          "ssm:PutInventory",
          "ssm:PutComplianceItems",
          "ssm:PutConfigurePackageResult",
          "ssm:UpdateAssociationStatus",
          "ssm:UpdateInstanceAssociationStatus",
          "ssmmessages:CreateControlChannel",
          "ssmmessages:CreateDataChannel",
          "ssmmessages:OpenControlChannel",
          "ssmmessages:OpenDataChannel",
          "ec2messages:AcknowledgeMessage",
          "ec2messages:DeleteMessage",
          "ec2messages:FailMessage",
          "ec2messages:GetEndpoint",
          "ec2messages:GetMessages",
          "ec2messages:SendReply",
        ]
        Resource = ["*"]
      },
      {
        Sid      = "SelfEnumeration"
        Effect   = "Allow"
        Action   = local.capstone_self_enum_actions
        Resource = ["*"]
      },
    ]
  })
}

resource "aws_iam_instance_profile" "capstone_ec2" {
  count    = local.capstone_enabled
  provider = aws.staging

  name = "${local.capstone_prefix}-katia"
  role = aws_iam_role.capstone_ec2_role[0].name
}

# Cluster admin access for the EC2 role so the student, after assuming it via
# IMDS on the jumpbox, can configure kubectl + create a pod with the Pod
# Identity service account (the actual hop 7 satisfaction path).
resource "aws_eks_access_entry" "capstone_ec2" {
  count    = local.capstone_enabled
  provider = aws.staging

  cluster_name  = module.capstone_staging_eks[0].cluster_name
  principal_arn = aws_iam_role.capstone_ec2_role[0].arn
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "capstone_ec2_admin" {
  count    = local.capstone_enabled
  provider = aws.staging

  cluster_name  = module.capstone_staging_eks[0].cluster_name
  principal_arn = aws_iam_role.capstone_ec2_role[0].arn
  policy_arn    = "arn:${local.partition}:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.capstone_ec2]
}

data "aws_ami" "capstone_amazon_linux" {
  count    = local.capstone_enabled
  provider = aws.staging

  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
}

resource "aws_security_group" "capstone_jumpbox" {
  count    = local.capstone_enabled
  provider = aws.staging

  name        = "${local.capstone_prefix}-ward"
  description = "Capstone jumpbox - outbound only."
  vpc_id      = module.capstone_staging_vpc[0].vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Lab = "capstone" }
}

resource "aws_instance" "capstone_jumpbox" {
  count    = local.capstone_enabled
  provider = aws.staging

  ami                    = data.aws_ami.capstone_amazon_linux[0].id
  instance_type          = "t3.micro"
  iam_instance_profile   = aws_iam_instance_profile.capstone_ec2[0].name
  subnet_id              = module.capstone_staging_vpc[0].primary_subnet_id
  vpc_security_group_ids = [aws_security_group.capstone_jumpbox[0].id]

  metadata_options {
    http_tokens   = "required"
    http_endpoint = "enabled"
  }

  user_data = <<-EOT
    #!/bin/bash
    set -e
    dnf install -y awscli jq
    # kubectl for hop 8 (Pod Identity assume). Students who follow the full
    # chain will use this to exec into a pod and obtain capstone-mongo-role creds.
    curl -sLo /usr/local/bin/kubectl https://dl.k8s.io/release/v1.30.0/bin/linux/amd64/kubectl
    chmod +x /usr/local/bin/kubectl
  EOT

  tags = {
    Name = "${local.capstone_prefix}-outpost"
    Lab  = "capstone"
    Kind = "jumpbox"
  }
}

# --- Hop 7 target: pod-identity role -----------------------------------------
#
# Trust policy includes the EKS Pod Identity service principal (production
# path) AND a verify-only escape hatch: capstone-mordecai assumes when it
# presents the verify_token in a tag. The script header documents the trade.
resource "aws_iam_role" "capstone_pod_role" {
  count    = local.capstone_enabled
  provider = aws.staging

  name = "${local.capstone_prefix}-mongo"
  path = "/"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "EKSPodIdentity"
        Effect    = "Allow"
        Principal = { Service = local.capstone_pod_identity_sp }
        Action    = ["sts:AssumeRole", "sts:TagSession"]
      },
      {
        Sid       = "VerifyScriptShortcut"
        Effect    = "Allow"
        Principal = { AWS = local.capstone_deployer_role_arn }
        Action    = "sts:AssumeRole"
        Condition = {
          StringEquals = {
            "sts:RoleSessionName" = "capstone-verify-${random_id.capstone_verify_token[0].hex}"
          }
        }
      },
    ]
  })

  tags = {
    Lab  = "capstone"
    Kind = "pod"
  }
}

resource "aws_iam_role_policy" "capstone_pod_inline" {
  count    = local.capstone_enabled
  provider = aws.staging

  name = "${local.capstone_prefix}-mongo-policy"
  role = aws_iam_role.capstone_pod_role[0].name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "UpdateDecryptorLambda"
        Effect = "Allow"
        Action = [
          "lambda:UpdateFunctionCode",
          "lambda:UpdateFunctionConfiguration",
          "lambda:GetFunction",
          "lambda:InvokeFunction",
        ]
        Resource = [aws_lambda_function.capstone_decryptor[0].arn]
      },
      {
        Sid    = "ReadDecryptorContext"
        Effect = "Allow"
        Action = [
          "kms:DescribeKey",
          "kms:GetKeyPolicy",
        ]
        Resource = [aws_kms_key.capstone_prod_handoff[0].arn]
      },
      {
        Sid      = "SelfEnumeration"
        Effect   = "Allow"
        Action   = local.capstone_self_enum_actions
        Resource = ["*"]
      },
    ]
  })
}

# --- Hops 8-9: decryptor Lambda + lambda-exec role ---------------------------

data "archive_file" "capstone_decryptor_zip" {
  count       = local.capstone_enabled
  type        = "zip"
  output_path = "${path.module}/.tmp-capstone-vault-golem.zip"

  source {
    filename = "index.py"
    content  = <<-EOT
      # Decryptor stub for the capstone lab. Replace via lambda:UpdateFunctionCode.
      # Read os.environ for the ciphertext, KMS key, prod reader ARN, etc.
      import os
      def handler(event, context):
          return {
              "status": "stub",
              "hint": "decrypt CIPHERTEXT_B64 with EncryptionContext={purpose: capstone-handoff}",
          }
    EOT
  }
}

resource "aws_iam_role" "capstone_lambda_exec" {
  count    = local.capstone_enabled
  provider = aws.staging

  name = "${local.capstone_prefix}-grimaldi"
  path = "/"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = local.capstone_lambda_sp }
        Action    = "sts:AssumeRole"
      },
    ]
  })

  tags = {
    Lab  = "capstone"
    Kind = "lambda-exec"
  }
}

resource "aws_iam_role_policy" "capstone_lambda_exec_inline" {
  count    = local.capstone_enabled
  provider = aws.staging

  name = "${local.capstone_prefix}-grimaldi-policy"
  role = aws_iam_role.capstone_lambda_exec[0].name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "DecryptHandoff"
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:DescribeKey"]
        Resource = [aws_kms_key.capstone_prod_handoff[0].arn]
      },
      {
        Sid      = "AssumeProdReader"
        Effect   = "Allow"
        Action   = ["sts:AssumeRole"]
        Resource = [local.capstone_prod_reader_role_arn]
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

resource "aws_lambda_function" "capstone_decryptor" {
  count    = local.capstone_enabled
  provider = aws.staging

  function_name    = "${local.capstone_prefix}-vault-golem"
  role             = aws_iam_role.capstone_lambda_exec[0].arn
  runtime          = "python3.11"
  handler          = "index.handler"
  filename         = data.archive_file.capstone_decryptor_zip[0].output_path
  source_code_hash = data.archive_file.capstone_decryptor_zip[0].output_base64sha256
  timeout          = 30

  environment {
    variables = {
      CIPHERTEXT_B64       = aws_kms_ciphertext.capstone_handoff[0].ciphertext_blob
      KMS_KEY_ID           = aws_kms_key.capstone_prod_handoff[0].key_id
      PROD_READER_ARN      = local.capstone_prod_reader_role_arn
      PROD_REGION          = local.prod_region
      FLAG_PARAMETER_NAME  = local.capstone_flag_param
      ENCRYPTION_CONTEXT_K = "purpose"
      ENCRYPTION_CONTEXT_V = "capstone-handoff"
    }
  }

  tags = {
    Lab  = "capstone"
    Kind = "decryptor"
  }
}

# --- KMS key for the staging→prod handoff ------------------------------------

resource "aws_kms_key" "capstone_prod_handoff" {
  count    = local.capstone_enabled
  provider = aws.staging

  description             = "Capstone — prod handoff key. Decrypt gated by ViaService=lambda + EncryptionContext."
  deletion_window_in_days = 7

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "RootAdmin"
        Effect    = "Allow"
        Principal = { AWS = local.capstone_staging_account_root }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        Sid       = "AllowDecryptOnlyViaLambdaWithContext"
        Effect    = "Allow"
        Principal = { AWS = local.capstone_lambda_exec_role_arn }
        Action    = ["kms:Decrypt", "kms:DescribeKey"]
        Resource  = ["*"]
        Condition = {
          StringEquals = {
            "kms:ViaService"                = "lambda.${local.staging_region}.amazonaws.com"
            "kms:EncryptionContext:purpose" = "capstone-handoff"
          }
        }
      },
    ]
  })

  tags = {
    Lab  = "capstone"
    Kind = "prod-handoff"
  }
}

resource "aws_kms_alias" "capstone_prod_handoff" {
  count    = local.capstone_enabled
  provider = aws.staging

  name          = "alias/${local.capstone_prefix}-vault"
  target_key_id = aws_kms_key.capstone_prod_handoff[0].key_id
}

# Generate the handoff ciphertext at apply time. Plaintext is a JSON payload
# carrying the sts:ExternalId required for hop 10.
resource "aws_kms_ciphertext" "capstone_handoff" {
  count    = local.capstone_enabled
  provider = aws.staging

  key_id = aws_kms_key.capstone_prod_handoff[0].key_id
  plaintext = jsonencode({
    external_id = random_uuid.capstone_prod_external_id[0].result
    issued      = "capstone-handoff"
  })
  context = {
    purpose = "capstone-handoff"
  }
}

# ============================================================================
# PROD account — prod-reader + flag
# ============================================================================

resource "aws_iam_role" "capstone_prod_reader" {
  count    = local.capstone_enabled
  provider = aws.prod

  name = "${local.capstone_prefix}-odette"
  path = "/"

  max_session_duration = 3600

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { AWS = local.capstone_lambda_exec_role_arn }
        Action    = "sts:AssumeRole"
        Condition = {
          StringEquals = {
            # aws:PrincipalAccount (not aws:SourceAccount) is the key populated on
            # a direct sts:AssumeRole; it equals the calling principal's account.
            "aws:PrincipalAccount" = local.staging_account_id
            "sts:ExternalId"       = random_uuid.capstone_prod_external_id[0].result
          }
        }
      },
    ]
  })

  tags = {
    Lab  = "capstone"
    Kind = "prod-reader"
  }
}

resource "aws_iam_role_policy" "capstone_prod_reader_inline" {
  count    = local.capstone_enabled
  provider = aws.prod

  name = "${local.capstone_prefix}-odette-policy"
  role = aws_iam_role.capstone_prod_reader[0].name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadFlag"
        Effect   = "Allow"
        Action   = ["ssm:GetParameter", "ssm:GetParameters"]
        Resource = ["arn:${local.partition}:ssm:${local.prod_region}:${local.prod_account_id}:parameter${local.capstone_flag_param}"]
      },
      {
        Sid      = "DecryptSSMFlag"
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = ["*"]
        Condition = {
          StringEquals = { "kms:ViaService" = "ssm.${local.prod_region}.amazonaws.com" }
        }
      },
    ]
  })
}

resource "aws_ssm_parameter" "capstone_flag" {
  count    = local.capstone_enabled
  provider = aws.prod

  name        = local.capstone_flag_param
  type        = "SecureString"
  value       = lookup(var.flag_values, "capstone", "BORANT:capstone-flag-missing")
  description = "Capstone flag — readable by capstone-odette."

  tags = { Lab = "capstone" }
}
