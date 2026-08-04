# Preserve the original single-student state addresses after converting the
# inexpensive/mutable capstone resources from count to per-student for_each.
# The "default" key retains every original AWS resource name.

moved {
  from = random_uuid.capstone_prod_external_id[0]
  to   = random_uuid.capstone_prod_external_id["default"]
}

moved {
  from = aws_iam_role.capstone_dev_deployer[0]
  to   = aws_iam_role.capstone_dev_deployer["default"]
}

moved {
  from = aws_iam_policy.capstone_dev_deployer_boundary[0]
  to   = aws_iam_policy.capstone_dev_deployer_boundary["default"]
}

moved {
  from = aws_iam_role_policy.capstone_dev_deployer_inline[0]
  to   = aws_iam_role_policy.capstone_dev_deployer_inline["default"]
}

moved {
  from = aws_iam_role.capstone_entry[0]
  to   = aws_iam_role.capstone_entry["default"]
}

moved {
  from = aws_iam_policy.capstone_entry_boundary[0]
  to   = aws_iam_policy.capstone_entry_boundary["default"]
}

moved {
  from = aws_iam_role_policy.capstone_entry_inline[0]
  to   = aws_iam_role_policy.capstone_entry_inline["default"]
}

moved {
  from = aws_lambda_function.capstone_bootstrap_fn[0]
  to   = aws_lambda_function.capstone_bootstrap_fn["default"]
}

moved {
  from = aws_iam_role.capstone_bridge[0]
  to   = aws_iam_role.capstone_bridge["default"]
}

moved {
  from = aws_iam_role.capstone_deployer[0]
  to   = aws_iam_role.capstone_deployer["default"]
}

moved {
  from = aws_iam_role_policy.capstone_deployer_inline[0]
  to   = aws_iam_role_policy.capstone_deployer_inline["default"]
}

moved {
  from = time_sleep.capstone_deployer_policy_propagation[0]
  to   = time_sleep.capstone_deployer_policy_propagation["default"]
}

moved {
  from = aws_cloudformation_stack.capstone_workflow[0]
  to   = aws_cloudformation_stack.capstone_workflow["default"]
}

moved {
  from = aws_iam_role_policy.capstone_bridge_inline[0]
  to   = aws_iam_role_policy.capstone_bridge_inline["default"]
}

moved {
  from = aws_kms_key.capstone_prod_handoff[0]
  to   = aws_kms_key.capstone_prod_handoff["default"]
}

moved {
  from = aws_kms_alias.capstone_prod_handoff[0]
  to   = aws_kms_alias.capstone_prod_handoff["default"]
}

moved {
  from = aws_ssm_parameter.capstone_external_id[0]
  to   = aws_ssm_parameter.capstone_external_id["default"]
}

moved {
  from = aws_iam_role.capstone_prod_reader[0]
  to   = aws_iam_role.capstone_prod_reader["default"]
}

moved {
  from = aws_iam_role_policy.capstone_prod_reader_inline[0]
  to   = aws_iam_role_policy.capstone_prod_reader_inline["default"]
}

moved {
  from = aws_iam_role.capstone_prod_pod_role["default"]
  to   = aws_iam_role.capstone_prod_pod_role[0]
}

moved {
  from = aws_eks_pod_identity_association.capstone_evidence_reader[0]
  to   = aws_eks_pod_identity_association.capstone_evidence_reader["default"]
}

moved {
  from = aws_kms_key.capstone_evidence[0]
  to   = aws_kms_key.capstone_evidence["default"]
}

moved {
  from = aws_kms_alias.capstone_evidence[0]
  to   = aws_kms_alias.capstone_evidence["default"]
}

moved {
  from = aws_s3_bucket.capstone_evidence[0]
  to   = aws_s3_bucket.capstone_evidence["default"]
}

moved {
  from = aws_s3_bucket_server_side_encryption_configuration.capstone_evidence[0]
  to   = aws_s3_bucket_server_side_encryption_configuration.capstone_evidence["default"]
}

moved {
  from = aws_s3_bucket_public_access_block.capstone_evidence[0]
  to   = aws_s3_bucket_public_access_block.capstone_evidence["default"]
}

moved {
  from = aws_s3_bucket_policy.capstone_evidence[0]
  to   = aws_s3_bucket_policy.capstone_evidence["default"]
}

moved {
  from = aws_s3_object.capstone_flag[0]
  to   = aws_s3_object.capstone_flag["default"]
}

moved {
  from = aws_iam_role_policy.capstone_prod_pod_inline["default"]
  to   = aws_iam_role_policy.capstone_prod_pod_inline[0]
}
