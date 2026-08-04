###############################################################################
# Compute labs: EC2 (2), Lambda (3), CloudFormation (2)
###############################################################################

# --- ec2runinstances ----------------------------------------------------------

resource "aws_iam_role" "ec2runinstances_privileged" {
  count = var.enable_ec2runinstances ? 1 : 0
  name  = "${var.lab_prefix}-ec2runinstances-mordecai"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = { Lab = "ec2runinstances", Kind = "privileged" }
}

resource "aws_iam_role_policy" "ec2runinstances_privileged_assume_target" {
  count = var.enable_ec2runinstances ? 1 : 0
  name  = "assume-donut"
  role  = aws_iam_role.ec2runinstances_privileged[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "sts:AssumeRole"
      Resource = ["arn:${local.partition}:iam::${local.account_id}:role/${var.lab_prefix}-ec2runinstances-donut"]
    }]
  })
}

resource "aws_iam_instance_profile" "ec2runinstances" {
  count = var.enable_ec2runinstances ? 1 : 0
  name  = "${var.lab_prefix}-ec2runinstances-profile"
  role  = aws_iam_role.ec2runinstances_privileged[0].name
}

module "lab_ec2runinstances" {
  count      = var.enable_ec2runinstances ? 1 : 0
  source     = "../modules/lab_common"
  lab_prefix = var.lab_prefix
  lab_name   = "ec2runinstances"
  flag_value = var.flag_values["ec2runinstances"]

  entry_target_access     = "none"
  target_trusts_entry     = false
  extra_target_principals = [aws_iam_role.ec2runinstances_privileged[0].arn]

  entry_boundary_statements = [
    {
      Sid      = "EnumerateEc2"
      Effect   = "Allow"
      Action   = ["ec2:Describe*", "ec2:GetConsoleOutput", "iam:Get*", "iam:List*", "iam:GetInstanceProfile"]
      Resource = ["*"]
    },
    {
      Sid      = "LaunchAndTerminate"
      Effect   = "Allow"
      Action   = ["ec2:RunInstances", "ec2:TerminateInstances", "ec2:CreateTags"]
      Resource = ["*"]
    },
    {
      Sid      = "PassPrivilegedProfile"
      Effect   = "Allow"
      Action   = ["iam:PassRole"]
      Resource = [aws_iam_role.ec2runinstances_privileged[0].arn]
    },
  ]
}

# --- ec2modifyuserdata --------------------------------------------------------

module "lab_ec2modifyuserdata" {
  count      = var.enable_ec2modifyuserdata ? 1 : 0
  source     = "../modules/lab_common"
  lab_prefix = var.lab_prefix
  lab_name   = "ec2modifyuserdata"
  flag_value = var.flag_values["ec2modifyuserdata"]

  entry_target_access = "none"
  target_trusts_entry = false
  extra_target_principals = [
    "arn:${local.partition}:iam::${local.account_id}:role/${var.lab_prefix}-shared-ec2target",
  ]

  entry_boundary_statements = [
    {
      Sid      = "EnumerateEc2"
      Effect   = "Allow"
      Action   = ["ec2:Describe*", "ec2:GetConsoleOutput"]
      Resource = ["*"]
    },
    {
      Sid    = "MutateTargetInstance"
      Effect = "Allow"
      Action = [
        "ec2:ModifyInstanceAttribute",
        "ec2:StopInstances",
        "ec2:StartInstances",
        "ec2:RebootInstances",
      ]
      Resource = ["*"]
    },
    {
      Sid      = "ReadInstanceIdParam"
      Effect   = "Allow"
      Action   = ["ssm:GetParameter"]
      Resource = ["arn:${local.partition}:ssm:${local.region}:${local.account_id}:parameter/labs/${var.lab_prefix}/ec2modifyuserdata/*"]
    },
  ]
}

# --- lambdacreatefunction -----------------------------------------------------

resource "aws_iam_role" "lambdacreatefunction_service" {
  count = var.enable_lambdacreatefunction ? 1 : 0
  name  = "${var.lab_prefix}-lambdacreatefunction-mordecai"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = { Lab = "lambdacreatefunction", Kind = "service" }
}

resource "aws_iam_role_policy" "lambdacreatefunction_service_basic" {
  count = var.enable_lambdacreatefunction ? 1 : 0
  name  = "basic"
  role  = aws_iam_role.lambdacreatefunction_service[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = ["*"]
      },
      {
        Effect   = "Allow"
        Action   = "sts:AssumeRole"
        Resource = ["arn:${local.partition}:iam::${local.account_id}:role/${var.lab_prefix}-lambdacreatefunction-donut"]
      },
    ]
  })
}

module "lab_lambdacreatefunction" {
  count      = var.enable_lambdacreatefunction ? 1 : 0
  source     = "../modules/lab_common"
  lab_prefix = var.lab_prefix
  lab_name   = "lambdacreatefunction"
  flag_value = var.flag_values["lambdacreatefunction"]

  entry_target_access     = "none"
  target_trusts_entry     = false
  extra_target_principals = [aws_iam_role.lambdacreatefunction_service[0].arn]

  entry_boundary_statements = [
    {
      Sid      = "EnumerateLambda"
      Effect   = "Allow"
      Action   = ["lambda:List*", "lambda:Get*", "iam:Get*", "iam:List*"]
      Resource = ["*"]
    },
    {
      Sid      = "CreateInvokeFunction"
      Effect   = "Allow"
      Action   = ["lambda:CreateFunction", "lambda:InvokeFunction", "lambda:DeleteFunction", "lambda:UpdateFunctionCode"]
      Resource = ["arn:${local.partition}:lambda:${local.region}:${local.account_id}:function:${var.lab_prefix}-*"]
    },
    {
      Sid      = "PassServiceRole"
      Effect   = "Allow"
      Action   = ["iam:PassRole"]
      Resource = [aws_iam_role.lambdacreatefunction_service[0].arn]
    },
  ]
}

# --- lambdaupdatefunctioncode -------------------------------------------------

resource "aws_iam_role" "lambdaupdatefunctioncode_service" {
  count = var.enable_lambdaupdatefunctioncode ? 1 : 0
  name  = "${var.lab_prefix}-lambdaupdatefunctioncode-mordecai"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "lambdaupdatefunctioncode_service_logs" {
  count = var.enable_lambdaupdatefunctioncode ? 1 : 0
  name  = "logs"
  role  = aws_iam_role.lambdaupdatefunctioncode_service[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = ["*"]
      },
      {
        Effect   = "Allow"
        Action   = "sts:AssumeRole"
        Resource = ["arn:${local.partition}:iam::${local.account_id}:role/${var.lab_prefix}-lambdaupdatefunctioncode-donut"]
      },
    ]
  })
}

data "archive_file" "noop_lambda" {
  count       = var.enable_lambdaupdatefunctioncode ? 1 : 0
  type        = "zip"
  output_path = "${path.module}/.terraform/tmp/noop-lambda.zip"

  source {
    filename = "index.py"
    content  = "def handler(event, context):\n    return {'ok': True}\n"
  }
}

resource "aws_lambda_function" "lambdaupdatefunctioncode_target" {
  count            = var.enable_lambdaupdatefunctioncode ? 1 : 0
  function_name    = "${var.lab_prefix}-lambdaupdatefunctioncode-golem"
  role             = aws_iam_role.lambdaupdatefunctioncode_service[0].arn
  runtime          = "python3.12"
  handler          = "index.handler"
  filename         = data.archive_file.noop_lambda[0].output_path
  source_code_hash = data.archive_file.noop_lambda[0].output_base64sha256
  timeout          = 30
}

module "lab_lambdaupdatefunctioncode" {
  count      = var.enable_lambdaupdatefunctioncode ? 1 : 0
  source     = "../modules/lab_common"
  lab_prefix = var.lab_prefix
  lab_name   = "lambdaupdatefunctioncode"
  flag_value = var.flag_values["lambdaupdatefunctioncode"]

  entry_target_access     = "none"
  target_trusts_entry     = false
  extra_target_principals = [aws_iam_role.lambdaupdatefunctioncode_service[0].arn]

  entry_boundary_statements = [
    {
      Sid      = "EnumerateLambda"
      Effect   = "Allow"
      Action   = ["lambda:List*", "lambda:Get*"]
      Resource = ["*"]
    },
    {
      Sid      = "UpdateInvoke"
      Effect   = "Allow"
      Action   = ["lambda:UpdateFunctionCode", "lambda:InvokeFunction"]
      Resource = [aws_lambda_function.lambdaupdatefunctioncode_target[0].arn]
    },
  ]
}

# --- lambdaupdatelayer --------------------------------------------------------

resource "aws_iam_role" "lambdaupdatelayer_service" {
  count = var.enable_lambdaupdatelayer ? 1 : 0
  name  = "${var.lab_prefix}-lambdaupdatelayer-mordecai"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "lambdaupdatelayer_service_logs" {
  count = var.enable_lambdaupdatelayer ? 1 : 0
  name  = "logs"
  role  = aws_iam_role.lambdaupdatelayer_service[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = ["*"]
      },
      {
        Effect   = "Allow"
        Action   = "sts:AssumeRole"
        Resource = ["arn:${local.partition}:iam::${local.account_id}:role/${var.lab_prefix}-lambdaupdatelayer-donut"]
      },
    ]
  })
}

data "archive_file" "noop_layer" {
  count       = var.enable_lambdaupdatelayer ? 1 : 0
  type        = "zip"
  output_path = "${path.module}/.terraform/tmp/noop-layer.zip"
  source {
    filename = "python/noop.py"
    content  = "VALUE = 'noop'\n"
  }
}

resource "aws_lambda_layer_version" "lambdaupdatelayer_base" {
  count               = var.enable_lambdaupdatelayer ? 1 : 0
  layer_name          = "${var.lab_prefix}-lambdaupdatelayer-base"
  filename            = data.archive_file.noop_layer[0].output_path
  source_code_hash    = data.archive_file.noop_layer[0].output_base64sha256
  compatible_runtimes = ["python3.12"]
}

data "archive_file" "layer_loader_lambda" {
  count       = var.enable_lambdaupdatelayer ? 1 : 0
  type        = "zip"
  output_path = "${path.module}/.terraform/tmp/layer-loader.zip"
  source {
    filename = "index.py"
    content  = "import noop\ndef handler(event, context):\n    return {'value': noop.VALUE}\n"
  }
}

resource "aws_lambda_function" "lambdaupdatelayer_target" {
  count            = var.enable_lambdaupdatelayer ? 1 : 0
  function_name    = "${var.lab_prefix}-lambdaupdatelayer-golem"
  role             = aws_iam_role.lambdaupdatelayer_service[0].arn
  runtime          = "python3.12"
  handler          = "index.handler"
  filename         = data.archive_file.layer_loader_lambda[0].output_path
  source_code_hash = data.archive_file.layer_loader_lambda[0].output_base64sha256
  layers           = [aws_lambda_layer_version.lambdaupdatelayer_base[0].arn]
  timeout          = 30
}

module "lab_lambdaupdatelayer" {
  count      = var.enable_lambdaupdatelayer ? 1 : 0
  source     = "../modules/lab_common"
  lab_prefix = var.lab_prefix
  lab_name   = "lambdaupdatelayer"
  flag_value = var.flag_values["lambdaupdatelayer"]

  entry_target_access     = "none"
  target_trusts_entry     = false
  extra_target_principals = [aws_iam_role.lambdaupdatelayer_service[0].arn]

  entry_boundary_statements = [
    {
      Sid      = "EnumerateLambda"
      Effect   = "Allow"
      Action   = ["lambda:List*", "lambda:Get*"]
      Resource = ["*"]
    },
    {
      Sid    = "LayerSwap"
      Effect = "Allow"
      Action = [
        "lambda:PublishLayerVersion",
        "lambda:UpdateFunctionConfiguration",
        "lambda:InvokeFunction",
        "lambda:GetLayerVersion",
        "lambda:DeleteLayerVersion",
      ]
      Resource = ["*"]
    },
  ]
}

# --- cloudformationcreatestack ------------------------------------------------

resource "aws_secretsmanager_secret" "cloudformationcreatestack_source" {
  count                   = var.enable_cloudformationcreatestack ? 1 : 0
  name                    = "${var.lab_prefix}-cloudformationcreatestack-source"
  description             = "Flag readable only through the cloudformationcreatestack service-role path."
  recovery_window_in_days = 0

  tags = { Lab = "cloudformationcreatestack", Kind = "service-role-source" }
}

resource "aws_secretsmanager_secret_version" "cloudformationcreatestack_source" {
  count         = var.enable_cloudformationcreatestack ? 1 : 0
  secret_id     = aws_secretsmanager_secret.cloudformationcreatestack_source[0].id
  secret_string = var.flag_values["cloudformationcreatestack"]
}

resource "aws_iam_role" "cloudformationcreatestack_service" {
  count = var.enable_cloudformationcreatestack ? 1 : 0
  name  = "${var.lab_prefix}-cloudformationcreatestack-mordecai"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "cloudformation.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "cloudformationcreatestack_service_perms" {
  count = var.enable_cloudformationcreatestack ? 1 : 0
  name  = "service-perms"
  role  = aws_iam_role.cloudformationcreatestack_service[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "sts:AssumeRole"
        Resource = ["arn:${local.partition}:iam::${local.account_id}:role/${var.lab_prefix}-cloudformationcreatestack-donut"]
      },
      {
        Effect   = "Allow"
        Action   = ["ssm:GetParameter"]
        Resource = ["arn:${local.partition}:ssm:${local.region}:${local.account_id}:parameter/labs/${var.lab_prefix}/cloudformationcreatestack/flag"]
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = ["*"]
        Condition = {
          StringEquals = { "kms:ViaService" = "ssm.${local.region}.amazonaws.com" }
        }
      },
      {
        Effect   = "Allow"
        Action   = ["ssm:PutParameter", "ssm:DeleteParameter", "ssm:AddTagsToResource"]
        Resource = ["arn:${local.partition}:ssm:${local.region}:${local.account_id}:parameter/labs/${var.lab_prefix}/cloudformationcreatestack/leaked"]
      },
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = [aws_secretsmanager_secret.cloudformationcreatestack_source[0].arn]
      },
    ]
  })
}

module "lab_cloudformationcreatestack" {
  count      = var.enable_cloudformationcreatestack ? 1 : 0
  source     = "../modules/lab_common"
  lab_prefix = var.lab_prefix
  lab_name   = "cloudformationcreatestack"
  flag_value = var.flag_values["cloudformationcreatestack"]

  entry_target_access     = "none"
  target_trusts_entry     = false
  extra_target_principals = [aws_iam_role.cloudformationcreatestack_service[0].arn]

  entry_boundary_statements = [
    {
      Sid      = "EnumerateCfn"
      Effect   = "Allow"
      Action   = ["cloudformation:List*", "cloudformation:Describe*", "cloudformation:GetTemplate", "iam:Get*", "iam:List*"]
      Resource = ["*"]
    },
    {
      Sid    = "ManageStacks"
      Effect = "Allow"
      Action = [
        "cloudformation:CreateStack",
        "cloudformation:UpdateStack",
        "cloudformation:DeleteStack",
      ]
      Resource = ["arn:${local.partition}:cloudformation:${local.region}:${local.account_id}:stack/${var.lab_prefix}-student-*"]
    },
    {
      Sid      = "PassServiceRole"
      Effect   = "Allow"
      Action   = ["iam:PassRole"]
      Resource = [aws_iam_role.cloudformationcreatestack_service[0].arn]
    },
    {
      Sid      = "ReadLeakedParam"
      Effect   = "Allow"
      Action   = ["ssm:GetParameter"]
      Resource = ["arn:${local.partition}:ssm:${local.region}:${local.account_id}:parameter/labs/${var.lab_prefix}/cloudformationcreatestack/leaked"]
    },
    {
      Sid      = "DiscoverSourceSecret"
      Effect   = "Allow"
      Action   = ["secretsmanager:ListSecrets", "secretsmanager:DescribeSecret"]
      Resource = ["*"]
    },
  ]
}

# --- cloudformationcreatechangeset --------------------------------------------

resource "aws_secretsmanager_secret" "cloudformationcreatechangeset_source" {
  count                   = var.enable_cloudformationcreatechangeset ? 1 : 0
  name                    = "${var.lab_prefix}-cloudformationcreatechangeset-source"
  description             = "Flag readable only through the cloudformationcreatechangeset service-role path."
  recovery_window_in_days = 0

  tags = { Lab = "cloudformationcreatechangeset", Kind = "service-role-source" }
}

resource "aws_secretsmanager_secret_version" "cloudformationcreatechangeset_source" {
  count         = var.enable_cloudformationcreatechangeset ? 1 : 0
  secret_id     = aws_secretsmanager_secret.cloudformationcreatechangeset_source[0].id
  secret_string = var.flag_values["cloudformationcreatechangeset"]
}

resource "aws_iam_role" "cloudformationcreatechangeset_service" {
  count = var.enable_cloudformationcreatechangeset ? 1 : 0
  name  = "${var.lab_prefix}-cloudformationcreatechangeset-mordecai"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "cloudformation.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "cloudformationcreatechangeset_service_perms" {
  count = var.enable_cloudformationcreatechangeset ? 1 : 0
  name  = "service-perms"
  role  = aws_iam_role.cloudformationcreatechangeset_service[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "sts:AssumeRole"
        Resource = ["arn:${local.partition}:iam::${local.account_id}:role/${var.lab_prefix}-cloudformationcreatechangeset-donut"]
      },
      {
        Effect   = "Allow"
        Action   = ["ssm:GetParameter"]
        Resource = ["arn:${local.partition}:ssm:${local.region}:${local.account_id}:parameter/labs/${var.lab_prefix}/cloudformationcreatechangeset/flag"]
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = ["*"]
        Condition = {
          StringEquals = { "kms:ViaService" = "ssm.${local.region}.amazonaws.com" }
        }
      },
      {
        Effect = "Allow"
        Action = ["ssm:PutParameter", "ssm:DeleteParameter", "ssm:AddTagsToResource"]
        Resource = [
          "arn:${local.partition}:ssm:${local.region}:${local.account_id}:parameter/labs/${var.lab_prefix}/cloudformationcreatechangeset/leaked",
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = [aws_secretsmanager_secret.cloudformationcreatechangeset_source[0].arn]
      },
    ]
  })
}

resource "aws_cloudformation_stack" "cloudformationcreatechangeset_stack" {
  count = var.enable_cloudformationcreatechangeset ? 1 : 0
  name  = "${var.lab_prefix}-cloudformationcreatechangeset-stack"

  # The stack is deployed WITH its privileged service role already attached.
  # That is what makes this lab the strong form of the primitive: a change set
  # executed against this stack reuses this role, so the student never needs
  # iam:PassRole and never chooses the role. They inherit one someone else
  # already blessed the stack with. Contrast the CreateStack lab, where the
  # student stands up a new stack and must pass the role themselves.
  iam_role_arn = aws_iam_role.cloudformationcreatechangeset_service[0].arn

  template_body = jsonencode({
    AWSTemplateFormatVersion = "2010-09-09"
    Description              = "Empty starter stack for the cloudformationcreatechangeset lab"
    Resources = {
      Placeholder = { Type = "AWS::CloudFormation::WaitConditionHandle" }
    }
  })

  tags = { Lab = "cloudformationcreatechangeset" }
}

module "lab_cloudformationcreatechangeset" {
  count      = var.enable_cloudformationcreatechangeset ? 1 : 0
  source     = "../modules/lab_common"
  lab_prefix = var.lab_prefix
  lab_name   = "cloudformationcreatechangeset"
  flag_value = var.flag_values["cloudformationcreatechangeset"]

  entry_target_access     = "none"
  target_trusts_entry     = false
  extra_target_principals = [aws_iam_role.cloudformationcreatechangeset_service[0].arn]

  entry_boundary_statements = [
    {
      Sid      = "EnumerateCfn"
      Effect   = "Allow"
      Action   = ["cloudformation:List*", "cloudformation:Describe*", "cloudformation:GetTemplate", "iam:Get*", "iam:List*"]
      Resource = ["*"]
    },
    {
      Sid    = "ManageChangeSets"
      Effect = "Allow"
      Action = [
        "cloudformation:CreateChangeSet",
        "cloudformation:ExecuteChangeSet",
        "cloudformation:DeleteChangeSet",
        "cloudformation:DescribeChangeSet",
      ]
      Resource = [aws_cloudformation_stack.cloudformationcreatechangeset_stack[0].id]
    },
    # No iam:PassRole. The stack already carries its service role, so the change
    # set reuses it and the student never passes a role. That absence is the
    # whole lesson: CreateChangeSet on a role-bearing stack escalates without
    # the PassRole grant that CreateStack requires.
    {
      Sid      = "ReadLeakedParam"
      Effect   = "Allow"
      Action   = ["ssm:GetParameter"]
      Resource = ["arn:${local.partition}:ssm:${local.region}:${local.account_id}:parameter/labs/${var.lab_prefix}/cloudformationcreatechangeset/leaked"]
    },
    {
      Sid      = "DiscoverSourceSecret"
      Effect   = "Allow"
      Action   = ["secretsmanager:ListSecrets", "secretsmanager:DescribeSecret"]
      Resource = ["*"]
    },
  ]
}
