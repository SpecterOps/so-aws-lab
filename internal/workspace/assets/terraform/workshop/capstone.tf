# Capstone: a three-account attack path assembled from course primitives.
#
# The path is intentionally a remix rather than a copy of any standalone lab.
# Every relationship below is marked traversable in GoAWSHound schema v1.0.0.
#
# CAPSTONE_TRAVERSABLE_PATH_BEGIN
# AWS_CanUpdateLambdaCode
# AWS_RunsAs
# AWS_CanAssumeRole
# AWS_CanExecuteCloudFormationChangeSet
# AWS_RunsAs
# AWS_SSMCanSendCommand
# AWS_RunsAs
# AWS_CanAssumeRole
# AWS_CanCreateAndAssociateEKSAccessEntry
# AWS_CanAssumeRoleViaPodIdentity
# CAPSTONE_TRAVERSABLE_PATH_END
#
# Operational path:
#
#   [dev]     Carl (IAM role)
#               -> update the tagged gate Lambda
#             gate-golem (Lambda)
#               -> runs as Donut
#             Donut (role)
#               -> assume Signet with a required session tag
#   [staging] Signet (role)
#               -> change-set an existing role-bearing stack
#             workflow stack
#               -> runs as Mordecai through its relay Lambda
#             Mordecai (role)
#               -> SendCommand to the managed outpost
#             outpost (EC2)
#               -> runs as Katia
#             Katia (role)
#               -> read a CMK-protected ExternalId and assume Odette
#   [prod]    Odette (role)
#               -> create and associate its own EKS access entry
#             EKS cluster
#               -> assume Mongo through an existing Pod Identity association
#             Mongo (role)
#               -> repair a narrow S3 bucket policy, create a constrained KMS
#                  grant, and read the encrypted flag object
#
# The SSM/KMS handoff and S3/KMS objective are required substeps, not graph
# transitions. Their relationship kinds are intentionally not part of the path.

locals {
  capstone_enabled = var.enable_capstone ? 1 : 0
  capstone_prefix  = "${var.lab_prefix}-capstone"

  # Empty capstone_students preserves the original one-student resource names.
  # A configured roster adds the stable student ID to every mutable/cheap
  # resource while the VPC, EKS cluster, and EC2 outpost stay shared.
  capstone_student_roster = length(var.capstone_students) > 0 ? var.capstone_students : {
    default = ""
  }
  capstone_student_prefixes = {
    for id, label in local.capstone_student_roster :
    id => id == "default" ? local.capstone_prefix : "${local.capstone_prefix}-${id}"
  }
  capstone_instances = var.enable_capstone ? {
    for id, label in local.capstone_student_roster : id => {
      id                  = id
      student_label       = label
      prefix              = local.capstone_student_prefixes[id]
      namespace           = id == "default" ? "incident-response" : "incident-response-${id}"
      service_account     = "evidence-reader"
      external_id_param   = "/labs/${var.lab_prefix}/capstone/${id}/prod-external-id"
      credential_param    = "/labs/${var.lab_prefix}/capstone/${id}/katia-credentials"
      relay_name          = "${local.capstone_student_prefixes[id]}-relay"
      stack_name          = "${local.capstone_student_prefixes[id]}-workflow"
      evidence_bucket     = "${local.capstone_student_prefixes[id]}-evidence-${local.prod_account_id}"
      evidence_object_key = "incident/flag.txt"

      carl_role_arn        = "arn:${local.partition}:iam::${local.account_id}:role/${local.capstone_student_prefixes[id]}-carl"
      entry_role_arn       = "arn:${local.partition}:iam::${local.account_id}:role/${local.capstone_student_prefixes[id]}-donut"
      bridge_role_arn      = "arn:${local.partition}:iam::${local.staging_account_id}:role/${local.capstone_student_prefixes[id]}-signet"
      cfn_role_arn         = "arn:${local.partition}:iam::${local.staging_account_id}:role/${local.capstone_student_prefixes[id]}-mordecai"
      prod_bridge_role_arn = "arn:${local.partition}:iam::${local.prod_account_id}:role/${local.capstone_student_prefixes[id]}-odette"
      pod_role_arn         = "arn:${local.partition}:iam::${local.prod_account_id}:role/${local.capstone_student_prefixes[id]}-mongo"
      relay_arn            = "arn:${local.partition}:lambda:${local.staging_region}:${local.staging_account_id}:function:${local.capstone_student_prefixes[id]}-relay"
      external_param_arn   = "arn:${local.partition}:ssm:${local.staging_region}:${local.staging_account_id}:parameter/labs/${var.lab_prefix}/capstone/${id}/prod-external-id"
      credential_param_arn = "arn:${local.partition}:ssm:${local.staging_region}:${local.staging_account_id}:parameter/labs/${var.lab_prefix}/capstone/${id}/katia-credentials"
      ssm_document_name    = "${local.capstone_student_prefixes[id]}-credential-handoff"
      ssm_document_arn     = "arn:${local.partition}:ssm:${local.staging_region}:${local.staging_account_id}:document/${local.capstone_student_prefixes[id]}-credential-handoff"
      evidence_bucket_arn  = "arn:${local.partition}:s3:::${local.capstone_student_prefixes[id]}-evidence-${local.prod_account_id}"
      evidence_object_arn  = "arn:${local.partition}:s3:::${local.capstone_student_prefixes[id]}-evidence-${local.prod_account_id}/incident/flag.txt"
    }
  } : {}
  capstone_workshop_instances = {
    for id, instance in local.capstone_instances :
    id => instance if id != "default"
  }

  capstone_lambda_sp         = "lambda.amazonaws.com"
  capstone_cloudformation_sp = "cloudformation.amazonaws.com"
  capstone_ec2_sp            = "ec2.amazonaws.com"
  capstone_pod_identity_sp   = "pods.eks.amazonaws.com"

  capstone_cloudshell_actions = [
    "cloudshell:CreateEnvironment",
    "cloudshell:CreateSession",
    "cloudshell:DescribeEnvironments",
    "cloudshell:GetEnvironmentStatus",
    "cloudshell:PutCredentials",
    "cloudshell:StartEnvironment",
    "cloudshell:StopEnvironment",
  ]

  capstone_dev_account_root     = "arn:${local.partition}:iam::${local.account_id}:root"
  capstone_staging_account_root = "arn:${local.partition}:iam::${local.staging_account_id}:root"
  capstone_prod_account_root    = "arn:${local.partition}:iam::${local.prod_account_id}:root"

  # The shared outpost role is re-assumed by a fixed, per-student SSM document.
  # The resulting session tag selects only that student's downstream resources.
  capstone_ec2_role_arn = "arn:${local.partition}:iam::${local.staging_account_id}:role/${local.capstone_prefix}-katia"

  capstone_self_enum_actions = [
    "iam:Get*",
    "iam:List*",
    "iam:SimulatePrincipalPolicy",
    "iam:SimulateCustomPolicy",
    "kms:DescribeKey",
    "kms:GetKeyPolicy",
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
# DEV account workshop bootstrap: one console-only IAM user per student.
# Each user can open CloudShell and assume only that student's Carl entry role.
# Login profiles are issued separately by `so-aws-lab capstone access-cards`;
# force_destroy removes those profiles when the roster or capstone is removed.
# ============================================================================

resource "aws_iam_policy" "capstone_student_bootstrap_boundary" {
  for_each = local.capstone_workshop_instances

  name        = "${each.value.prefix}-student-boundary"
  description = "Boundary for ${each.key}'s temporary capstone console user."
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "UseCloudShell"
        Effect   = "Allow"
        Action   = local.capstone_cloudshell_actions
        Resource = "*"
      },
      {
        Sid      = "IdentifyBootstrapUser"
        Effect   = "Allow"
        Action   = "sts:GetCallerIdentity"
        Resource = "*"
      },
      {
        Sid      = "AssumeOwnCapstoneEntry"
        Effect   = "Allow"
        Action   = "sts:AssumeRole"
        Resource = each.value.carl_role_arn
      },
    ]
  })

  tags = {
    Lab     = "capstone"
    Student = each.key
  }
}

resource "aws_iam_user" "capstone_student_bootstrap" {
  for_each = local.capstone_workshop_instances

  name                 = "${each.value.prefix}-student"
  path                 = "/so-aws-lab/capstone/"
  permissions_boundary = aws_iam_policy.capstone_student_bootstrap_boundary[each.key].arn
  force_destroy        = true

  tags = {
    Lab     = "capstone"
    Kind    = "workshop-bootstrap"
    Student = each.key
  }
}

resource "aws_iam_user_policy" "capstone_student_bootstrap" {
  for_each = local.capstone_workshop_instances

  name   = "${each.value.prefix}-student"
  user   = aws_iam_user.capstone_student_bootstrap[each.key].name
  policy = aws_iam_policy.capstone_student_bootstrap_boundary[each.key].policy
}

resource "random_uuid" "capstone_prod_external_id" {
  for_each = local.capstone_instances
}

# ============================================================================
# DEV account: entry role, writable Lambda, and execution role
# ============================================================================

resource "aws_iam_role" "capstone_dev_deployer" {
  for_each             = local.capstone_instances
  name                 = "${each.value.prefix}-carl"
  path                 = "/"
  permissions_boundary = aws_iam_policy.capstone_dev_deployer_boundary[each.key].arn
  max_session_duration = 3600

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          AWS = each.key == "default" ? local.capstone_dev_account_root : aws_iam_user.capstone_student_bootstrap[each.key].arn
        }
        Action = "sts:AssumeRole"
      },
    ]
  })

  tags = {
    Lab     = "capstone"
    Kind    = "entry"
    Student = each.key
  }

  lifecycle {
    precondition {
      condition = length(toset([
        local.account_id,
        local.staging_account_id,
        local.prod_account_id,
      ])) == 3
      error_message = "The capstone requires three distinct AWS accounts for dev, staging, and prod."
    }
  }
}

resource "aws_iam_policy" "capstone_dev_deployer_boundary" {
  for_each = local.capstone_instances
  name     = "${each.value.prefix}-carl-boundary"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "DiscoverLambda"
        Effect   = "Allow"
        Action   = ["lambda:ListFunctions"]
        Resource = ["*"]
      },
      {
        Sid    = "InspectAndInvokeOwnGate"
        Effect = "Allow"
        Action = [
          "lambda:GetFunction",
          "lambda:GetFunctionConfiguration",
          "lambda:ListTags",
          "lambda:InvokeFunction",
        ]
        Resource = ["arn:${local.partition}:lambda:${local.region}:${local.account_id}:function:${each.value.prefix}-gate-golem"]
      },
      {
        Sid      = "UpdateOnlyTaggedCapstoneFunctions"
        Effect   = "Allow"
        Action   = ["lambda:UpdateFunctionCode"]
        Resource = ["arn:${local.partition}:lambda:${local.region}:${local.account_id}:function:${each.value.prefix}-gate-golem"]
        Condition = {
          StringEquals = {
            "aws:ResourceTag/Lab"     = "capstone"
            "aws:ResourceTag/Student" = each.key
          }
        }
      },
      {
        Sid      = "SelfEnumeration"
        Effect   = "Allow"
        Action   = local.capstone_self_enum_actions
        Resource = ["*"]
      },
      {
        Sid      = "UseCloudShell"
        Effect   = "Allow"
        Action   = local.capstone_cloudshell_actions
        Resource = ["*"]
      },
    ]
  })
}

resource "aws_iam_role_policy" "capstone_dev_deployer_inline" {
  for_each = local.capstone_instances
  name     = "${each.value.prefix}-carl-policy"
  role     = aws_iam_role.capstone_dev_deployer[each.key].name
  policy   = aws_iam_policy.capstone_dev_deployer_boundary[each.key].policy
}

resource "aws_iam_role" "capstone_entry" {
  for_each = local.capstone_instances
  name     = "${each.value.prefix}-donut"
  path     = "/"

  permissions_boundary = aws_iam_policy.capstone_entry_boundary[each.key].arn
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
            "aws:SourceArn" = "arn:${local.partition}:lambda:${local.region}:${local.account_id}:function:${each.value.prefix}-gate-golem"
          }
        }
      },
    ]
  })

  tags = {
    Lab     = "capstone"
    Kind    = "lambda-execution"
    Student = each.key
  }
}

resource "aws_iam_policy" "capstone_entry_boundary" {
  for_each = local.capstone_instances
  name     = "${each.value.prefix}-donut-boundary"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "AssumeStagingBridgeWithSessionTag"
        Effect   = "Allow"
        Action   = ["sts:AssumeRole", "sts:TagSession"]
        Resource = [each.value.bridge_role_arn]
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
  for_each = local.capstone_instances
  name     = "${each.value.prefix}-donut-policy"
  role     = aws_iam_role.capstone_entry[each.key].name
  policy   = aws_iam_policy.capstone_entry_boundary[each.key].policy
}

data "archive_file" "capstone_bootstrap_zip" {
  for_each    = local.capstone_instances
  type        = "zip"
  output_path = "${path.module}/.tmp-capstone-${each.key}-bootstrap.zip"

  source {
    filename = "index.py"
    content  = <<-PY
      def handler(event, context):
          return {
              "status": "healthy",
              "component": "gate",
              "request_id": context.aws_request_id,
          }
    PY
  }
}

resource "aws_lambda_function" "capstone_bootstrap_fn" {
  for_each = local.capstone_instances

  function_name                  = "${each.value.prefix}-gate-golem"
  role                           = aws_iam_role.capstone_entry[each.key].arn
  runtime                        = "python3.12"
  handler                        = "index.handler"
  filename                       = data.archive_file.capstone_bootstrap_zip[each.key].output_path
  source_code_hash               = data.archive_file.capstone_bootstrap_zip[each.key].output_base64sha256
  timeout                        = 30
  reserved_concurrent_executions = 2

  tags = {
    Lab     = "capstone"
    Kind    = "gate"
    Student = each.key
  }
}

# ============================================================================
# STAGING account: conditional bridge and role-bearing CloudFormation stack
# ============================================================================

resource "aws_iam_role" "capstone_bridge" {
  for_each = local.capstone_instances
  provider = aws.staging

  name                 = "${each.value.prefix}-signet"
  path                 = "/"
  max_session_duration = 3600

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { AWS = aws_iam_role.capstone_entry[each.key].arn }
        Action    = ["sts:AssumeRole", "sts:TagSession"]
        Condition = {
          StringEquals = {
            "aws:RequestTag/team"  = "red"
            "aws:PrincipalAccount" = local.account_id
          }
        }
      },
    ]
  })

  tags = {
    Lab     = "capstone"
    Kind    = "staging-bridge"
    Student = each.key
  }
}

resource "aws_iam_role" "capstone_deployer" {
  for_each = local.capstone_instances
  provider = aws.staging

  name = "${each.value.prefix}-mordecai"
  path = "/"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "CloudFormationService"
        Effect    = "Allow"
        Principal = { Service = local.capstone_cloudformation_sp }
        Action    = "sts:AssumeRole"
      },
      {
        Sid       = "RelayLambdaRuntime"
        Effect    = "Allow"
        Principal = { Service = local.capstone_lambda_sp }
        Action    = "sts:AssumeRole"
        Condition = {
          ArnEquals = {
            "aws:SourceArn" = each.value.relay_arn
          }
        }
      },
    ]
  })

  tags = {
    Lab     = "capstone"
    Kind    = "cloudformation-service"
    Student = each.key
  }
}

module "capstone_staging_vpc" {
  count  = local.capstone_enabled
  source = "../modules/shared_vpc"

  providers = {
    aws = aws.staging
  }

  lab_prefix = "${var.lab_prefix}-cs"
}

data "aws_ssm_parameter" "capstone_al2023_ami" {
  count    = local.capstone_enabled
  provider = aws.staging

  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

resource "aws_security_group" "capstone_jumpbox" {
  count    = local.capstone_enabled
  provider = aws.staging

  name        = "${local.capstone_prefix}-ward"
  description = "Capstone managed outpost with outbound access only."
  vpc_id      = module.capstone_staging_vpc[0].vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Lab = "capstone" }
}

resource "aws_iam_role" "capstone_ec2_role" {
  count    = local.capstone_enabled
  provider = aws.staging

  name = "${local.capstone_prefix}-katia"
  path = "/"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "EC2Runtime"
        Effect    = "Allow"
        Principal = { Service = local.capstone_ec2_sp }
        Action    = "sts:AssumeRole"
      },
      {
        Sid       = "CreateStudentTaggedSession"
        Effect    = "Allow"
        Principal = { AWS = local.capstone_staging_account_root }
        Action    = ["sts:AssumeRole", "sts:TagSession"]
        Condition = {
          ArnEquals = {
            "aws:PrincipalArn" = local.capstone_ec2_role_arn
          }
        }
      },
    ]
  })

  tags = {
    Lab  = "capstone"
    Kind = "shared-ec2-instance"
  }
}

resource "aws_iam_role_policy_attachment" "capstone_ec2_ssm_core" {
  count    = local.capstone_enabled
  provider = aws.staging

  role       = aws_iam_role.capstone_ec2_role[0].name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "capstone_ec2" {
  count    = local.capstone_enabled
  provider = aws.staging

  name = "${local.capstone_prefix}-katia"
  role = aws_iam_role.capstone_ec2_role[0].name
}

resource "aws_instance" "capstone_jumpbox" {
  count    = local.capstone_enabled
  provider = aws.staging

  ami                         = data.aws_ssm_parameter.capstone_al2023_ami[0].value
  instance_type               = "t3.micro"
  iam_instance_profile        = aws_iam_instance_profile.capstone_ec2[0].name
  subnet_id                   = module.capstone_staging_vpc[0].primary_subnet_id
  vpc_security_group_ids      = [aws_security_group.capstone_jumpbox[0].id]
  associate_public_ip_address = true
  user_data_replace_on_change = true

  metadata_options {
    http_tokens   = "required"
    http_endpoint = "enabled"
  }

  user_data = <<-SH
    #!/bin/bash
    set -euxo pipefail
    if ! command -v amazon-ssm-agent >/dev/null 2>&1; then
      dnf install -y amazon-ssm-agent
    fi
    if ! command -v aws >/dev/null 2>&1; then
      dnf install -y awscli2
    fi
    systemctl enable --now amazon-ssm-agent
  SH

  tags = {
    Name = "${local.capstone_prefix}-outpost"
    Lab  = "capstone"
    Kind = "managed-outpost"
  }

  depends_on = [aws_iam_role_policy_attachment.capstone_ec2_ssm_core]
}

resource "aws_ssm_parameter" "capstone_katia_credentials" {
  for_each = local.capstone_instances
  provider = aws.staging

  name        = each.value.credential_param
  type        = "SecureString"
  value       = jsonencode({ status = "not-issued" })
  description = "Short-lived Katia credentials issued by the fixed capstone handoff document."

  tags = {
    Lab     = "capstone"
    Kind    = "credential-handoff"
    Student = each.key
  }

  lifecycle {
    ignore_changes = [value]
  }
}

# Students may run only their fixed document. It accepts no parameters, so
# ssm:SendCommand cannot be converted into arbitrary root shell access on the
# shared outpost. The document re-assumes Katia with a student session tag and
# stores the temporary result in that student's private SecureString.
resource "aws_ssm_document" "capstone_credential_handoff" {
  for_each = local.capstone_instances
  provider = aws.staging

  name            = each.value.ssm_document_name
  document_type   = "Command"
  document_format = "JSON"
  content = jsonencode({
    schemaVersion = "2.2"
    description   = "Issue an isolated Katia session for capstone student ${each.key}."
    mainSteps = [
      {
        action = "aws:runShellScript"
        name   = "issueStudentSession"
        inputs = {
          timeoutSeconds = "60"
          runCommand = [
            "set -eu",
            "CREDS=\"$(aws sts assume-role --role-arn '${local.capstone_ec2_role_arn}' --role-session-name 'capstone-${each.key}' --duration-seconds 3600 --tags 'Key=Student,Value=${each.key}' --query Credentials --output json)\"",
            "aws ssm put-parameter --name '${each.value.credential_param}' --type SecureString --value \"$CREDS\" --overwrite >/dev/null",
            "echo '{\"status\":\"ready\",\"student\":\"${each.key}\"}'",
          ]
        }
      },
    ]
  })

  tags = {
    Lab     = "capstone"
    Kind    = "fixed-credential-handoff"
    Student = each.key
  }
}

resource "aws_iam_role_policy" "capstone_deployer_inline" {
  for_each = local.capstone_instances
  provider = aws.staging

  name = "${each.value.prefix}-mordecai-policy"
  role = aws_iam_role.capstone_deployer[each.key].name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ManageOnlyWorkflowRelay"
        Effect = "Allow"
        Action = [
          "lambda:CreateFunction",
          "lambda:DeleteFunctionConcurrency",
          "lambda:DeleteFunction",
          "lambda:GetFunction",
          "lambda:GetFunctionConfiguration",
          "lambda:GetFunctionConcurrency",
          "lambda:PutFunctionConcurrency",
          "lambda:TagResource",
          "lambda:UntagResource",
          "lambda:UpdateFunctionCode",
          "lambda:UpdateFunctionConfiguration",
        ]
        Resource = [each.value.relay_arn]
      },
      {
        Sid      = "PassSelfOnlyToLambda"
        Effect   = "Allow"
        Action   = ["iam:PassRole"]
        Resource = [each.value.cfn_role_arn]
        Condition = {
          StringEquals = {
            "iam:PassedToService" = local.capstone_lambda_sp
          }
        }
      },
      {
        Sid    = "SendCommandOnlyToOutpost"
        Effect = "Allow"
        Action = ["ssm:SendCommand"]
        Resource = [
          aws_instance.capstone_jumpbox[0].arn,
          each.value.ssm_document_arn,
        ]
      },
      {
        Sid      = "ReadOwnKatiaCredentialHandoff"
        Effect   = "Allow"
        Action   = ["ssm:GetParameter"]
        Resource = [each.value.credential_param_arn]
      },
      {
        Sid      = "DecryptOwnKatiaCredentialHandoffThroughParameterStore"
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = ["*"]
        Condition = {
          StringEquals = {
            "kms:ViaService"                      = "ssm.${local.staging_region}.amazonaws.com"
            "kms:EncryptionContext:PARAMETER_ARN" = each.value.credential_param_arn
          }
        }
      },
      {
        Sid    = "InspectCommandResults"
        Effect = "Allow"
        Action = [
          "ssm:GetCommandInvocation",
          "ssm:ListCommandInvocations",
          "ssm:DescribeInstanceInformation",
          "ssm:GetDocument",
          "ssm:DescribeDocument",
        ]
        Resource = ["*"]
      },
      {
        Sid    = "RelayLogs"
        Effect = "Allow"
        Action = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = [
          "arn:${local.partition}:logs:${local.staging_region}:${local.staging_account_id}:log-group:/aws/lambda/${each.value.relay_name}",
          "arn:${local.partition}:logs:${local.staging_region}:${local.staging_account_id}:log-group:/aws/lambda/${each.value.relay_name}:*",
        ]
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

resource "time_sleep" "capstone_deployer_policy_propagation" {
  for_each = local.capstone_instances

  create_duration = "20s"

  depends_on = [aws_iam_role_policy.capstone_deployer_inline]
}

resource "aws_cloudformation_stack" "capstone_workflow" {
  for_each = local.capstone_instances
  provider = aws.staging

  name         = each.value.stack_name
  iam_role_arn = aws_iam_role.capstone_deployer[each.key].arn
  on_failure   = "DELETE"

  template_body = jsonencode({
    AWSTemplateFormatVersion = "2010-09-09"
    Description              = "Capstone staging workflow relay"
    Resources = {
      WorkflowRelay = {
        Type = "AWS::Lambda::Function"
        Properties = {
          FunctionName                 = each.value.relay_name
          Role                         = aws_iam_role.capstone_deployer[each.key].arn
          Runtime                      = "python3.12"
          Handler                      = "index.handler"
          Timeout                      = 30
          ReservedConcurrentExecutions = 2
          Code = {
            ZipFile = <<-PY
              def handler(event, context):
                  return {
                      "status": "queued",
                      "workflow": "staging-audit",
                      "request_id": context.aws_request_id,
                  }
            PY
          }
          Tags = [
            { Key = "Lab", Value = "capstone" },
            { Key = "Kind", Value = "workflow-relay" },
            { Key = "Student", Value = each.key },
          ]
        }
      }
    }
  })

  tags = {
    Lab     = "capstone"
    Kind    = "workflow"
    Student = each.key
  }

  depends_on = [time_sleep.capstone_deployer_policy_propagation]
}

resource "aws_iam_role_policy" "capstone_bridge_inline" {
  for_each = local.capstone_instances
  provider = aws.staging

  name = "${each.value.prefix}-signet-policy"
  role = aws_iam_role.capstone_bridge[each.key].name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "InspectWorkflow"
        Effect = "Allow"
        Action = [
          "cloudformation:DescribeStacks",
          "cloudformation:DescribeStackEvents",
          "cloudformation:DescribeChangeSet",
          "cloudformation:ListChangeSets",
          "cloudformation:GetTemplate",
        ]
        Resource = [aws_cloudformation_stack.capstone_workflow[each.key].id]
      },
      {
        Sid    = "StageAndExecuteWorkflowChanges"
        Effect = "Allow"
        Action = [
          "cloudformation:CreateChangeSet",
          "cloudformation:ExecuteChangeSet",
          "cloudformation:DeleteChangeSet",
        ]
        Resource = [aws_cloudformation_stack.capstone_workflow[each.key].id]
      },
      {
        Sid      = "ListStacks"
        Effect   = "Allow"
        Action   = ["cloudformation:ListStacks"]
        Resource = ["*"]
      },
      {
        Sid      = "InvokeWorkflowRelay"
        Effect   = "Allow"
        Action   = ["lambda:GetFunction", "lambda:InvokeFunction"]
        Resource = [each.value.relay_arn]
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

# ============================================================================
# STAGING account: encrypted prod handoff
# ============================================================================

resource "aws_kms_key" "capstone_prod_handoff" {
  for_each = local.capstone_instances
  provider = aws.staging

  description             = "Capstone prod handoff key for student ${each.key}, restricted to one SSM parameter."
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
        Sid       = "KatiaDecryptsOnlyThroughParameterStore"
        Effect    = "Allow"
        Principal = { AWS = aws_iam_role.capstone_ec2_role[0].arn }
        Action    = ["kms:Decrypt", "kms:DescribeKey"]
        Resource  = "*"
        Condition = {
          StringEquals = {
            "aws:PrincipalTag/Student"            = each.key
            "kms:ViaService"                      = "ssm.${local.staging_region}.amazonaws.com"
            "kms:EncryptionContext:PARAMETER_ARN" = each.value.external_param_arn
          }
        }
      },
    ]
  })

  tags = {
    Lab     = "capstone"
    Kind    = "prod-handoff"
    Student = each.key
  }
}

resource "aws_kms_alias" "capstone_prod_handoff" {
  for_each = local.capstone_instances
  provider = aws.staging

  name          = "alias/${each.value.prefix}-handoff"
  target_key_id = aws_kms_key.capstone_prod_handoff[each.key].key_id
}

resource "aws_ssm_parameter" "capstone_external_id" {
  for_each = local.capstone_instances
  provider = aws.staging

  name        = each.value.external_id_param
  type        = "SecureString"
  key_id      = aws_kms_key.capstone_prod_handoff[each.key].arn
  value       = random_uuid.capstone_prod_external_id[each.key].result
  description = "Prod federation token for the incident-response bridge."

  tags = {
    Lab     = "capstone"
    Kind    = "prod-handoff"
    Student = each.key
  }
}

locals {
  # Keep the shared Katia policy well below IAM's role quota as the roster
  # grows. Principal tag policy variables select the current student's paths
  # and role at request time; the per-student KMS key and Odette trust policies
  # independently enforce the same Student tag.
  capstone_ec2_inline_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "CreateKnownStudentSessionFromUntaggedInstance"
        Effect   = "Allow"
        Action   = ["sts:AssumeRole", "sts:TagSession"]
        Resource = [local.capstone_ec2_role_arn]
        Condition = {
          Null = {
            "aws:PrincipalTag/Student" = "true"
          }
          StringEquals = {
            "aws:RequestTag/Student" = keys(local.capstone_instances)
          }
          "ForAllValues:StringEquals" = {
            "aws:TagKeys" = ["Student"]
          }
        }
      },
      {
        Sid      = "PublishCredentialHandoffs"
        Effect   = "Allow"
        Action   = ["ssm:PutParameter"]
        Resource = ["arn:${local.partition}:ssm:${local.staging_region}:${local.staging_account_id}:parameter/labs/${var.lab_prefix}/capstone/*/katia-credentials"]
        Condition = {
          Null = {
            "aws:PrincipalTag/Student" = "true"
          }
        }
      },
      {
        Sid      = "SelfEnumeration"
        Effect   = "Allow"
        Action   = local.capstone_self_enum_actions
        Resource = ["*"]
      },
      {
        Sid      = "ReadOwnProdFederationToken"
        Effect   = "Allow"
        Action   = ["ssm:GetParameter", "ssm:GetParameters"]
        Resource = ["arn:${local.partition}:ssm:${local.staging_region}:${local.staging_account_id}:parameter/labs/${var.lab_prefix}/capstone/$${aws:PrincipalTag/Student}/prod-external-id"]
        Condition = {
          StringEquals = {
            "aws:PrincipalTag/Student" = keys(local.capstone_instances)
          }
        }
      },
      {
        Sid      = "DecryptOwnTokenOnlyThroughParameterStore"
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = ["arn:${local.partition}:kms:${local.staging_region}:${local.staging_account_id}:key/*"]
        Condition = {
          StringEquals = {
            "aws:PrincipalTag/Student"            = keys(local.capstone_instances)
            "kms:ViaService"                      = "ssm.${local.staging_region}.amazonaws.com"
            "kms:EncryptionContext:PARAMETER_ARN" = "arn:${local.partition}:ssm:${local.staging_region}:${local.staging_account_id}:parameter/labs/${var.lab_prefix}/capstone/$${aws:PrincipalTag/Student}/prod-external-id"
          }
        }
      },
      {
        Sid    = "AssumeOwnProdIncidentBridge"
        Effect = "Allow"
        Action = ["sts:AssumeRole"]
        Resource = [
          "arn:${local.partition}:iam::${local.prod_account_id}:role/${local.capstone_prefix}-odette",
          "arn:${local.partition}:iam::${local.prod_account_id}:role/${local.capstone_prefix}-$${aws:PrincipalTag/Student}-odette",
        ]
        Condition = {
          StringEquals = {
            "aws:PrincipalTag/Student" = keys(local.capstone_instances)
          }
        }
      },
    ]
  })
}

resource "aws_iam_role_policy" "capstone_ec2_inline" {
  count    = local.capstone_enabled
  provider = aws.staging

  name   = "${local.capstone_prefix}-katia-policy"
  role   = aws_iam_role.capstone_ec2_role[0].name
  policy = local.capstone_ec2_inline_policy

  lifecycle {
    precondition {
      condition     = length(local.capstone_ec2_inline_policy) <= 10240
      error_message = "The shared Katia inline policy exceeds IAM's 10,240-character role policy quota."
    }
  }
}

# ============================================================================
# PROD account: access-entry pivot and existing Pod Identity association
# ============================================================================

module "capstone_prod_vpc" {
  count  = local.capstone_enabled
  source = "../modules/shared_vpc"

  providers = {
    aws = aws.prod
  }

  lab_prefix = "${var.lab_prefix}-cs"
}

module "capstone_prod_eks" {
  count  = local.capstone_enabled
  source = "../modules/shared_eks"

  providers = {
    aws = aws.prod
  }

  lab_prefix = "${var.lab_prefix}-cs"
  vpc_id     = module.capstone_prod_vpc[0].vpc_id
  subnet_ids = module.capstone_prod_vpc[0].subnet_ids

  # One shared node pool scales sublinearly with the roster. Namespace quotas
  # below cap each student at 500m requested CPU and 512 MiB requested memory.
  node_desired_size = max(2, ceil(length(local.capstone_instances) / 5))
  protect_pod_imds  = true
}

resource "kubernetes_namespace_v1" "capstone_student" {
  for_each = local.capstone_instances

  metadata {
    name = each.value.namespace
    labels = {
      "app.kubernetes.io/managed-by"       = "terraform"
      "pod-security.kubernetes.io/audit"   = "restricted"
      "pod-security.kubernetes.io/enforce" = "restricted"
      "pod-security.kubernetes.io/warn"    = "restricted"
      "workshop.specterops.io/lab"         = "capstone"
      "workshop.specterops.io/student"     = each.key
    }
  }

  depends_on = [module.capstone_prod_eks]
}

resource "kubernetes_limit_range_v1" "capstone_student" {
  for_each = local.capstone_instances

  metadata {
    name      = "student-defaults"
    namespace = kubernetes_namespace_v1.capstone_student[each.key].metadata[0].name
  }

  spec {
    limit {
      type = "Container"
      default = {
        cpu    = "500m"
        memory = "512Mi"
      }
      default_request = {
        cpu    = "100m"
        memory = "128Mi"
      }
      max = {
        cpu    = "1"
        memory = "1Gi"
      }
    }
  }
}

resource "kubernetes_resource_quota_v1" "capstone_student" {
  for_each = local.capstone_instances

  metadata {
    name      = "student-quota"
    namespace = kubernetes_namespace_v1.capstone_student[each.key].metadata[0].name
  }

  spec {
    hard = {
      "limits.cpu"             = "1"
      "limits.memory"          = "1Gi"
      "pods"                   = "3"
      "requests.cpu"           = "500m"
      "requests.memory"        = "512Mi"
      "services.loadbalancers" = "0"
      "services.nodeports"     = "0"
    }
  }
}

resource "aws_iam_role" "capstone_prod_reader" {
  for_each = local.capstone_instances
  provider = aws.prod

  name                 = "${each.value.prefix}-odette"
  path                 = "/"
  max_session_duration = 3600

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { AWS = aws_iam_role.capstone_ec2_role[0].arn }
        Action    = "sts:AssumeRole"
        Condition = {
          StringEquals = {
            "aws:PrincipalAccount"     = local.staging_account_id
            "aws:PrincipalTag/Student" = each.key
            "sts:ExternalId"           = random_uuid.capstone_prod_external_id[each.key].result
          }
        }
      },
    ]
  })

  tags = {
    Lab     = "capstone"
    Kind    = "prod-bridge"
    Student = each.key
  }
}

resource "aws_iam_role_policy" "capstone_prod_reader_inline" {
  for_each = local.capstone_instances
  provider = aws.prod

  name = "${each.value.prefix}-odette-policy"
  role = aws_iam_role.capstone_prod_reader[each.key].name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "DiscoverIncidentCluster"
        Effect = "Allow"
        Action = [
          "eks:DescribeCluster",
          "eks:ListClusters",
          "eks:ListAccessEntries",
          "eks:DescribeAccessEntry",
          "eks:ListAssociatedAccessPolicies",
          "eks:ListPodIdentityAssociations",
          "eks:DescribePodIdentityAssociation",
        ]
        Resource = ["*"]
      },
      {
        Sid      = "CreateOwnAccessEntry"
        Effect   = "Allow"
        Action   = ["eks:CreateAccessEntry"]
        Resource = ["arn:${local.partition}:eks:${local.prod_region}:${local.prod_account_id}:cluster/${module.capstone_prod_eks[0].cluster_name}"]
        Condition = {
          StringEquals = {
            "eks:accessEntryType" = "STANDARD"
            "eks:principalArn"    = each.value.prod_bridge_role_arn
          }
        }
      },
      {
        Sid      = "AssociateOwnNamespacePolicy"
        Effect   = "Allow"
        Action   = ["eks:AssociateAccessPolicy"]
        Resource = ["arn:${local.partition}:eks:${local.prod_region}:${local.prod_account_id}:access-entry/${module.capstone_prod_eks[0].cluster_name}/*"]
        Condition = {
          StringEquals = {
            "eks:accessScope"  = "namespace"
            "eks:policyArn"    = "arn:${local.partition}:eks::aws:cluster-access-policy/AmazonEKSAdminPolicy"
            "eks:principalArn" = each.value.prod_bridge_role_arn
          }
          "ForAllValues:StringEquals" = {
            "eks:namespaces" = [each.value.namespace]
          }
        }
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

resource "aws_iam_role" "capstone_prod_pod_role" {
  for_each = local.capstone_instances
  provider = aws.prod

  name = "${each.value.prefix}-mongo"
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
    ]
  })

  tags = {
    Lab     = "capstone"
    Kind    = "pod-identity"
    Student = each.key
  }
}

resource "aws_eks_pod_identity_association" "capstone_evidence_reader" {
  for_each = local.capstone_instances
  provider = aws.prod

  cluster_name    = module.capstone_prod_eks[0].cluster_name
  namespace       = each.value.namespace
  service_account = each.value.service_account
  role_arn        = aws_iam_role.capstone_prod_pod_role[each.key].arn

  depends_on = [
    module.capstone_prod_eks,
    kubernetes_namespace_v1.capstone_student,
  ]
}

# ============================================================================
# PROD account: S3 policy and KMS grant objective
# ============================================================================

resource "aws_kms_key" "capstone_evidence" {
  for_each = local.capstone_instances
  provider = aws.prod

  description             = "Capstone evidence key for student ${each.key}. Decrypt must flow through S3 for the exact flag object."
  deletion_window_in_days = 7

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "RootAdmin"
        Effect    = "Allow"
        Principal = { AWS = local.capstone_prod_account_root }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        Sid       = "MongoCanInspectAndRevokeGrants"
        Effect    = "Allow"
        Principal = { AWS = aws_iam_role.capstone_prod_pod_role[each.key].arn }
        Action    = ["kms:DescribeKey", "kms:ListGrants", "kms:RevokeGrant", "kms:RetireGrant"]
        Resource  = "*"
      },
      {
        Sid       = "MongoCanCreateOnlyItsDecryptGrant"
        Effect    = "Allow"
        Principal = { AWS = aws_iam_role.capstone_prod_pod_role[each.key].arn }
        Action    = ["kms:CreateGrant"]
        Resource  = "*"
        Condition = {
          StringEquals = {
            "kms:GranteePrincipal" = aws_iam_role.capstone_prod_pod_role[each.key].arn
          }
          "ForAllValues:StringEquals" = {
            "kms:GrantOperations" = ["Decrypt"]
          }
        }
      },
      {
        Sid       = "DenyDecryptOutsideS3"
        Effect    = "Deny"
        Principal = "*"
        Action    = ["kms:Decrypt"]
        Resource  = "*"
        Condition = {
          StringNotEquals = {
            "kms:ViaService" = "s3.${local.prod_region}.amazonaws.com"
          }
        }
      },
      {
        Sid       = "DenyDecryptForOtherObjects"
        Effect    = "Deny"
        Principal = "*"
        Action    = ["kms:Decrypt"]
        Resource  = "*"
        Condition = {
          StringNotEquals = {
            "kms:EncryptionContext:aws:s3:arn" = each.value.evidence_object_arn
          }
        }
      },
    ]
  })

  tags = {
    Lab     = "capstone"
    Kind    = "evidence"
    Student = each.key
  }
}

resource "aws_kms_alias" "capstone_evidence" {
  for_each = local.capstone_instances
  provider = aws.prod

  name          = "alias/${each.value.prefix}-evidence"
  target_key_id = aws_kms_key.capstone_evidence[each.key].key_id
}

resource "aws_s3_bucket" "capstone_evidence" {
  for_each = local.capstone_instances
  provider = aws.prod

  bucket = each.value.evidence_bucket

  tags = {
    Lab     = "capstone"
    Kind    = "evidence"
    Student = each.key
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "capstone_evidence" {
  for_each = local.capstone_instances
  provider = aws.prod

  bucket = aws_s3_bucket.capstone_evidence[each.key].id

  rule {
    apply_server_side_encryption_by_default {
      kms_master_key_id = aws_kms_key.capstone_evidence[each.key].arn
      sse_algorithm     = "aws:kms"
    }

    bucket_key_enabled = false
  }
}

resource "aws_s3_bucket_public_access_block" "capstone_evidence" {
  for_each = local.capstone_instances
  provider = aws.prod

  bucket = aws_s3_bucket.capstone_evidence[each.key].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_policy" "capstone_evidence" {
  for_each = local.capstone_instances
  provider = aws.prod

  bucket = aws_s3_bucket.capstone_evidence[each.key].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          each.value.evidence_bucket_arn,
          "${each.value.evidence_bucket_arn}/*",
        ]
        Condition = {
          Bool = {
            "aws:SecureTransport" = "false"
          }
        }
      },
    ]
  })

  depends_on = [aws_s3_bucket_public_access_block.capstone_evidence]
}

resource "aws_s3_object" "capstone_flag" {
  for_each = local.capstone_instances
  provider = aws.prod

  bucket                 = aws_s3_bucket.capstone_evidence[each.key].id
  key                    = each.value.evidence_object_key
  content                = lookup(var.flag_values, "capstone", "BORANT:capstone-flag-missing")
  content_type           = "text/plain"
  server_side_encryption = "aws:kms"
  kms_key_id             = aws_kms_key.capstone_evidence[each.key].arn
  bucket_key_enabled     = false

  tags = {
    Lab     = "capstone"
    Kind    = "flag"
    Student = each.key
  }
}

resource "aws_iam_role_policy" "capstone_prod_pod_inline" {
  for_each = local.capstone_instances
  provider = aws.prod

  name = "${each.value.prefix}-mongo-policy"
  role = aws_iam_role.capstone_prod_pod_role[each.key].name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "DiscoverEvidenceBuckets"
        Effect   = "Allow"
        Action   = ["s3:ListAllMyBuckets", "s3:GetBucketLocation"]
        Resource = ["*"]
      },
      {
        Sid      = "InspectAndRepairEvidencePolicy"
        Effect   = "Allow"
        Action   = ["s3:GetBucketPolicy", "s3:GetEncryptionConfiguration", "s3:ListBucket", "s3:PutBucketPolicy"]
        Resource = [each.value.evidence_bucket_arn]
      },
      {
        Sid      = "InspectEvidenceKey"
        Effect   = "Allow"
        Action   = ["kms:DescribeKey", "kms:GetKeyPolicy", "kms:ListGrants", "kms:RevokeGrant", "kms:RetireGrant"]
        Resource = [aws_kms_key.capstone_evidence[each.key].arn]
      },
      {
        Sid      = "CreateOnlySelfDecryptGrant"
        Effect   = "Allow"
        Action   = ["kms:CreateGrant"]
        Resource = [aws_kms_key.capstone_evidence[each.key].arn]
        Condition = {
          StringEquals = {
            "kms:GranteePrincipal" = aws_iam_role.capstone_prod_pod_role[each.key].arn
          }
          "ForAllValues:StringEquals" = {
            "kms:GrantOperations" = ["Decrypt"]
          }
        }
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
