###############################################################################
# EKS labs (2). Shared EKS cluster spins up when either lab is enabled.
###############################################################################

# --- eksaccessentry ---------------------------------------------------------

module "lab_eksaccessentry" {
  count      = var.enable_eksaccessentry ? 1 : 0
  source     = "../modules/lab_with_victim"
  lab_prefix = var.lab_prefix
  lab_name   = "eksaccessentry"
  flag_value = var.flag_values["eksaccessentry"]

  entry_boundary_statements = [
    {
      Sid    = "EnumerateEks"
      Effect = "Allow"
      Action = [
        "eks:DescribeCluster", "eks:ListClusters",
        "eks:ListAccessEntries", "eks:DescribeAccessEntry",
      ]
      Resource = ["*"]
    },
    {
      Sid      = "EscalateClusterAccess"
      Effect   = "Allow"
      Action   = ["eks:AssociateAccessPolicy", "eks:DisassociateAccessPolicy", "eks:UpdateAccessEntry"]
      Resource = ["*"]
    },
  ]
}

resource "aws_iam_access_key" "eksaccessentry_victim" {
  count = var.enable_eksaccessentry ? 1 : 0
  user  = module.lab_eksaccessentry[0].victim_user_name
}

# Hand the entry role a starter access entry on the shared cluster. The lab's
# lesson is escalating from this (default zero policies attached) to admin.
resource "aws_eks_access_entry" "eksaccessentry_starter" {
  count         = var.enable_eksaccessentry ? 1 : 0
  cluster_name  = module.shared_eks[0].cluster_name
  principal_arn = module.lab_eksaccessentry[0].entry_role_arn
  type          = "STANDARD"
}

# --- ekspodidentityassociation ----------------------------------------------

resource "aws_iam_role" "ekspodidentityassociation_pod" {
  count = var.enable_ekspodidentityassociation ? 1 : 0
  name  = "${var.lab_prefix}-ekspodidentityassociation-mongo"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

resource "aws_iam_role_policy" "ekspodidentityassociation_pod_assume_target" {
  count = var.enable_ekspodidentityassociation ? 1 : 0
  name  = "assume-donut"
  role  = aws_iam_role.ekspodidentityassociation_pod[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "sts:AssumeRole"
      Resource = ["arn:${local.partition}:iam::${local.account_id}:role/${var.lab_prefix}-ekspodidentityassociation-donut"]
    }]
  })
}

module "lab_ekspodidentityassociation" {
  count      = var.enable_ekspodidentityassociation ? 1 : 0
  source     = "../modules/lab_common"
  lab_prefix = var.lab_prefix
  lab_name   = "ekspodidentityassociation"
  flag_value = var.flag_values["ekspodidentityassociation"]

  extra_target_principals = [aws_iam_role.ekspodidentityassociation_pod[0].arn]

  entry_boundary_statements = [
    {
      Sid    = "EnumerateEks"
      Effect = "Allow"
      Action = [
        "eks:DescribeCluster", "eks:ListClusters",
        "eks:ListPodIdentityAssociations", "eks:DescribePodIdentityAssociation",
        "iam:GetRole", "iam:ListRoles",
      ]
      Resource = ["*"]
    },
    {
      Sid    = "ManagePodIdentity"
      Effect = "Allow"
      Action = [
        "eks:CreatePodIdentityAssociation",
        "eks:DeletePodIdentityAssociation",
        "eks:UpdatePodIdentityAssociation",
      ]
      Resource = ["*"]
    },
    {
      Sid      = "PassPodRole"
      Effect   = "Allow"
      Action   = ["iam:PassRole"]
      Resource = [aws_iam_role.ekspodidentityassociation_pod[0].arn]
    },
  ]
}

resource "aws_eks_access_entry" "ekspodidentityassociation_starter" {
  count         = var.enable_ekspodidentityassociation ? 1 : 0
  cluster_name  = module.shared_eks[0].cluster_name
  principal_arn = module.lab_ekspodidentityassociation[0].entry_role_arn
  type          = "STANDARD"
}
