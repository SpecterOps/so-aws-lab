terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
  }
}

variable "lab_prefix" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "subnet_id" {
  type = string
}

variable "labs" {
  type        = list(string)
  default     = ["ec2modifyuserdata", "ssmsendcommand"]
  description = "Subset of [ec2modifyuserdata, ssmsendcommand] to provision target instances for."
}

variable "instance_type" {
  type    = string
  default = "t3.micro"
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-2023*-x86_64"]
  }
}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
}

resource "aws_iam_role" "target" {
  name = "${var.lab_prefix}-shared-ec2target"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm_managed" {
  role       = aws_iam_role.target.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "read_flag_targets" {
  name = "${var.lab_prefix}-shared-ec2target-readflag"
  role = aws_iam_role.target.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "ReadFlagForEc2TargetLabs"
      Effect = "Allow"
      Action = ["ssm:GetParameter", "kms:Decrypt"]
      Resource = concat(
        [for lab in var.labs : "arn:${local.partition}:ssm:${data.aws_region.current.name}:${local.account_id}:parameter/labs/${var.lab_prefix}/${lab}/flag"],
        ["arn:${local.partition}:kms:${data.aws_region.current.name}:${local.account_id}:alias/aws/ssm"],
      )
    }]
  })
}

resource "aws_iam_instance_profile" "target" {
  name = "${var.lab_prefix}-shared-ec2target"
  role = aws_iam_role.target.name
}

resource "aws_security_group" "target" {
  name        = "${var.lab_prefix}-shared-ec2target"
  description = "Shared EC2 target instance security group (egress only)."
  vpc_id      = var.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_instance" "target" {
  for_each = toset(var.labs)

  ami                    = data.aws_ami.al2023.id
  instance_type          = var.instance_type
  subnet_id              = var.subnet_id
  iam_instance_profile   = aws_iam_instance_profile.target.name
  vpc_security_group_ids = [aws_security_group.target.id]

  user_data = "#!/bin/bash\necho \"lab=${each.key}\" > /etc/lab.env\n"

  tags = {
    Name      = "${var.lab_prefix}-${each.key}-target"
    Lab       = each.key
    LabPrefix = var.lab_prefix
  }
}

resource "aws_ssm_parameter" "instance_id" {
  for_each = toset(var.labs)

  name  = "/labs/${var.lab_prefix}/${each.key}/instance-id"
  type  = "String"
  value = aws_instance.target[each.key].id

  tags = {
    Lab = each.key
  }
}

output "instance_ids_by_lab" {
  value = { for lab in var.labs : lab => aws_instance.target[lab].id }
}
