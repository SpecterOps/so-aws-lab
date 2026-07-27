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

variable "all_lab_slugs" {
  type        = list(string)
  default     = []
  description = "Every lab slug that publishes a flag parameter. Used to deny this instance role direct reads of flags it has no business reading."
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

  # The ec2modifyuserdata lab turns on replacing a stopped instance's user data
  # and starting it so the replacement runs. That does not happen on a default
  # image. cloud-init's scripts-user module is once-per-instance, and the
  # semaphore at /var/lib/cloud/instances/<instance-id>/sem/config_scripts_user
  # survives a stop/start because the instance id does not change, so the new
  # script is staged and then skipped.
  #
  # The shellscript part handler is PER_ALWAYS, so the replacement user data is
  # re-staged to .../scripts/part-001 on every boot. Only the module frequency
  # blocks execution. This drop-in flips scripts-user to run on every boot,
  # which is the precondition the lab depends on and should teach students to
  # look for.
  per_boot_user_data = <<-EOT
    #cloud-config
    write_files:
      - path: /etc/cloud/cloud.cfg.d/99-rerun-user-data.cfg
        permissions: '0644'
        content: |
          # Re-run user-data on every boot, not just first launch.
          cloud_final_modules:
            - [scripts-user, always]
      - path: /etc/lab.env
        permissions: '0644'
        content: |
          lab=ec2modifyuserdata
  EOT
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

locals {
  # ssmsendcommand's lesson is that SendCommand runs code as the instance role,
  # so that role reading the flag directly is the intended finish.
  #
  # ec2modifyuserdata is a different lesson: boot code as the instance role,
  # then assume the lab target from there. Leaving this lab's flag readable by
  # the instance role short-circuits that final hop, so it is excluded here and
  # the instance role is granted sts:AssumeRole on the target instead.
  direct_flag_labs = [for lab in var.labs : lab if lab != "ec2modifyuserdata"]

  # Built as two single-element conditionals rather than one two-element
  # ternary: the statements carry different attribute sets (only the KMS one has
  # a Condition), so Terraform cannot unify them into a list and a 2-vs-0 ternary
  # fails type checking.
  read_flag_statements = concat(
    length(local.direct_flag_labs) == 0 ? [] : [{
      Sid      = "ReadFlagForEc2TargetLabs"
      Effect   = "Allow"
      Action   = ["ssm:GetParameter"]
      Resource = [for lab in local.direct_flag_labs : "arn:${local.partition}:ssm:${data.aws_region.current.name}:${local.account_id}:parameter/labs/${var.lab_prefix}/${lab}/flag"]
    }],
    # KMS authorizes against a key ARN, never an alias ARN. Scope by
    # kms:ViaService, mirroring the aws/ssm key policy.
    length(local.direct_flag_labs) == 0 ? [] : [{
      Sid      = "DecryptSSMFlag"
      Effect   = "Allow"
      Action   = ["kms:Decrypt"]
      Resource = ["*"]
      Condition = {
        StringEquals = { "kms:ViaService" = "ssm.${data.aws_region.current.name}.amazonaws.com" }
      }
    }],
  )

  # The target's trust policy already names this role. Without the identity-side
  # allow, only one of the two doors is open and the documented hop fails.
  assume_target_statements = contains(var.labs, "ec2modifyuserdata") ? [{
    Sid      = "AssumeEc2ModifyUserDataTarget"
    Effect   = "Allow"
    Action   = "sts:AssumeRole"
    Resource = "arn:${local.partition}:iam::${local.account_id}:role/${var.lab_prefix}-ec2modifyuserdata-donut"
  }] : []

  # Dropping a flag from the Allow above accomplishes nothing on its own. The
  # AmazonSSMManagedInstanceCore managed policy attached to this role grants
  # ssm:GetParameter and ssm:GetParameters on Resource "*", and the aws/ssm key
  # policy authorizes the matching decrypt for any principal in the account
  # calling through SSM. Left alone, whoever reaches this instance role can read
  # every lab's flag, which both short-circuits ec2modifyuserdata and makes
  # flags from unrelated labs harvestable from either EC2 box.
  #
  # An explicit Deny is what actually closes it, since Deny beats the managed
  # policy's Allow. IAM has no way to Deny a wildcard and carve one ARN back
  # out, so the denied set is enumerated: every lab flag except the ones this
  # role legitimately needs.
  #
  # Deliberately scoped to the /labs/<prefix>/*/flag namespace rather than a
  # NotResource form, which would also deny the parameters the SSM agent reads
  # and break Run Command on the instance.
  denied_flag_labs = [for slug in var.all_lab_slugs : slug if !contains(local.direct_flag_labs, slug)]

  deny_flag_statements = length(local.denied_flag_labs) == 0 ? [] : [{
    Sid      = "DenyDirectFlagReads"
    Effect   = "Deny"
    Action   = ["ssm:GetParameter", "ssm:GetParameters"]
    Resource = [for slug in local.denied_flag_labs : "arn:${local.partition}:ssm:${data.aws_region.current.name}:${local.account_id}:parameter/labs/${var.lab_prefix}/${slug}/flag"]
  }]
}

resource "aws_iam_role_policy" "read_flag_targets" {
  name = "${var.lab_prefix}-shared-ec2target-readflag"
  role = aws_iam_role.target.id
  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = concat(local.read_flag_statements, local.assume_target_statements, local.deny_flag_statements)
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

  # Only the user-data lab needs the per-boot precondition. The ssmsendcommand
  # target reaches its instance through SendCommand and keeps the plain script.
  user_data = each.key == "ec2modifyuserdata" ? local.per_boot_user_data : "#!/bin/bash\necho \"lab=${each.key}\" > /etc/lab.env\n"

  # Replace rather than update in place. The baseline user data installs the
  # per-boot drop-in via write_files, which is a once-per-instance module, so an
  # in-place user_data change on an existing instance is silently skipped and
  # the lab stays broken. Forcing replacement gives the new baseline a genuine
  # first boot. It also resets the instance after a student overwrites the user
  # data during the exercise.
  user_data_replace_on_change = true

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
