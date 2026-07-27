data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

# Per-account identity. The dev one drives ARN construction for every existing
# lab; staging/prod are exposed so future cross-account labs can target them.
data "aws_caller_identity" "staging" {
  provider = aws.staging
}

data "aws_caller_identity" "prod" {
  provider = aws.prod
}

locals {
  account_id         = data.aws_caller_identity.current.account_id
  partition          = data.aws_partition.current.partition
  region             = data.aws_region.current.name
  staging_account_id = data.aws_caller_identity.staging.account_id
  prod_account_id    = data.aws_caller_identity.prod.account_id
}

module "shared_vpc" {
  count      = local.needs_vpc ? 1 : 0
  source     = "../modules/shared_vpc"
  lab_prefix = var.lab_prefix
}

module "shared_eks" {
  count      = local.needs_eks ? 1 : 0
  source     = "../modules/shared_eks"
  lab_prefix = var.lab_prefix
  vpc_id     = module.shared_vpc[0].vpc_id
  subnet_ids = module.shared_vpc[0].subnet_ids
}

module "shared_ec2_targets" {
  count      = local.needs_ec2_targets ? 1 : 0
  source     = "../modules/shared_ec2_targets"
  lab_prefix = var.lab_prefix
  vpc_id     = module.shared_vpc[0].vpc_id
  subnet_id  = module.shared_vpc[0].primary_subnet_id
  labs = compact([
    var.enable_ec2modifyuserdata ? "ec2modifyuserdata" : "",
    var.enable_ssmsendcommand ? "ssmsendcommand" : "",
  ])

  # Slugs only. flag_values is sensitive because of its values, but the keys are
  # just lab names, and they are what the flag-deny list is built from.
  all_lab_slugs = nonsensitive(keys(var.flag_values))
}
