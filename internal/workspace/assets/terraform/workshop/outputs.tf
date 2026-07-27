output "account_id" {
  description = "AWS account id of the dev account (where labs deploy)."
  value       = local.account_id
}

output "region" {
  description = "Region of the dev account."
  value       = local.region
}

output "accounts" {
  description = "Account id + region for every configured AWS provider."
  value = {
    dev = {
      account_id = local.account_id
      region     = local.region
      profile    = var.dev_profile
    }
    staging = {
      account_id = local.staging_account_id
      region     = local.staging_region
      profile    = local.staging_profile
    }
    prod = {
      account_id = local.prod_account_id
      region     = local.prod_region
      profile    = local.prod_profile
    }
  }
}

output "lab_prefix" {
  value = var.lab_prefix
}

# Per-lab info. Each value is null when the lab is disabled; the CLI reads
# `labs` to populate its status pane.
output "labs" {
  description = "Map of lab_name => { entry_role_arn, target_role_arn, flag_parameter_name } or null."
  value = {
    createpolicyversion = try({
      entry_role_arn      = module.lab_createpolicyversion[0].entry_role_arn
      target_role_arn     = module.lab_createpolicyversion[0].target_role_arn
      flag_parameter_name = module.lab_createpolicyversion[0].flag_parameter_name
    }, null)
    assumerole = try({
      entry_role_arn      = module.lab_assumerole[0].entry_role_arn
      target_role_arn     = module.lab_assumerole[0].target_role_arn
      flag_parameter_name = module.lab_assumerole[0].flag_parameter_name
    }, null)
    putuserpolicy = try({
      entry_role_arn      = module.lab_putuserpolicy[0].entry_role_arn
      target_role_arn     = module.lab_putuserpolicy[0].target_role_arn
      flag_parameter_name = module.lab_putuserpolicy[0].flag_parameter_name
    }, null)
    attachrolepolicy = try({
      entry_role_arn      = module.lab_attachrolepolicy[0].entry_role_arn
      target_role_arn     = module.lab_attachrolepolicy[0].target_role_arn
      flag_parameter_name = module.lab_attachrolepolicy[0].flag_parameter_name
    }, null)
    createcredentials = try({
      entry_role_arn      = module.lab_createcredentials[0].entry_role_arn
      target_role_arn     = module.lab_createcredentials[0].target_role_arn
      flag_parameter_name = module.lab_createcredentials[0].flag_parameter_name
    }, null)
    updateassumerolepolicy = try({
      entry_role_arn      = aws_iam_role.updateassumerolepolicy_entry[0].arn
      target_role_arn     = aws_iam_role.updateassumerolepolicy_target[0].arn
      flag_parameter_name = aws_ssm_parameter.updateassumerolepolicy_flag[0].name
    }, null)
    ec2runinstances = try({
      entry_role_arn      = module.lab_ec2runinstances[0].entry_role_arn
      target_role_arn     = module.lab_ec2runinstances[0].target_role_arn
      flag_parameter_name = module.lab_ec2runinstances[0].flag_parameter_name
    }, null)
    ec2modifyuserdata = try({
      entry_role_arn      = module.lab_ec2modifyuserdata[0].entry_role_arn
      target_role_arn     = module.lab_ec2modifyuserdata[0].target_role_arn
      flag_parameter_name = module.lab_ec2modifyuserdata[0].flag_parameter_name
    }, null)
    lambdacreatefunction = try({
      entry_role_arn      = module.lab_lambdacreatefunction[0].entry_role_arn
      target_role_arn     = module.lab_lambdacreatefunction[0].target_role_arn
      flag_parameter_name = module.lab_lambdacreatefunction[0].flag_parameter_name
    }, null)
    lambdaupdatefunctioncode = try({
      entry_role_arn      = module.lab_lambdaupdatefunctioncode[0].entry_role_arn
      target_role_arn     = module.lab_lambdaupdatefunctioncode[0].target_role_arn
      flag_parameter_name = module.lab_lambdaupdatefunctioncode[0].flag_parameter_name
    }, null)
    lambdaupdatelayer = try({
      entry_role_arn      = module.lab_lambdaupdatelayer[0].entry_role_arn
      target_role_arn     = module.lab_lambdaupdatelayer[0].target_role_arn
      flag_parameter_name = module.lab_lambdaupdatelayer[0].flag_parameter_name
    }, null)
    cloudformationcreatestack = try({
      entry_role_arn      = module.lab_cloudformationcreatestack[0].entry_role_arn
      target_role_arn     = module.lab_cloudformationcreatestack[0].target_role_arn
      flag_parameter_name = module.lab_cloudformationcreatestack[0].flag_parameter_name
    }, null)
    cloudformationcreatechangeset = try({
      entry_role_arn      = module.lab_cloudformationcreatechangeset[0].entry_role_arn
      target_role_arn     = module.lab_cloudformationcreatechangeset[0].target_role_arn
      flag_parameter_name = module.lab_cloudformationcreatechangeset[0].flag_parameter_name
    }, null)
    ssmgetparameter = try({
      entry_role_arn      = module.lab_ssmgetparameter[0].entry_role_arn
      target_role_arn     = module.lab_ssmgetparameter[0].target_role_arn
      flag_parameter_name = module.lab_ssmgetparameter[0].flag_parameter_name
    }, null)
    ssmsendcommand = try({
      entry_role_arn      = module.lab_ssmsendcommand[0].entry_role_arn
      target_role_arn     = module.lab_ssmsendcommand[0].target_role_arn
      flag_parameter_name = module.lab_ssmsendcommand[0].flag_parameter_name
    }, null)
    s3getobject = try({
      entry_role_arn      = module.lab_s3getobject[0].entry_role_arn
      target_role_arn     = module.lab_s3getobject[0].target_role_arn
      flag_parameter_name = module.lab_s3getobject[0].flag_parameter_name
    }, null)
    s3putbucketpolicy = try({
      entry_role_arn      = module.lab_s3putbucketpolicy[0].entry_role_arn
      target_role_arn     = module.lab_s3putbucketpolicy[0].target_role_arn
      flag_parameter_name = module.lab_s3putbucketpolicy[0].flag_parameter_name
    }, null)
    kmsdecrypt = try({
      entry_role_arn      = module.lab_kmsdecrypt[0].entry_role_arn
      target_role_arn     = module.lab_kmsdecrypt[0].target_role_arn
      flag_parameter_name = module.lab_kmsdecrypt[0].flag_parameter_name
    }, null)
    kmscreategrant = try({
      entry_role_arn      = module.lab_kmscreategrant[0].entry_role_arn
      target_role_arn     = module.lab_kmscreategrant[0].target_role_arn
      flag_parameter_name = module.lab_kmscreategrant[0].flag_parameter_name
    }, null)
    eksaccessentry = try({
      entry_role_arn      = module.lab_eksaccessentry[0].entry_role_arn
      target_role_arn     = module.lab_eksaccessentry[0].target_role_arn
      flag_parameter_name = module.lab_eksaccessentry[0].flag_parameter_name
    }, null)
    ekspodidentityassociation = try({
      entry_role_arn      = module.lab_ekspodidentityassociation[0].entry_role_arn
      target_role_arn     = module.lab_ekspodidentityassociation[0].target_role_arn
      flag_parameter_name = module.lab_ekspodidentityassociation[0].flag_parameter_name
    }, null)
    capstone = try({
      entry_role_arn      = aws_iam_role.capstone_entry[0].arn
      target_role_arn     = aws_iam_role.capstone_prod_reader[0].arn
      flag_parameter_name = aws_ssm_parameter.capstone_flag[0].name
    }, null)
    conditionresourcetag = try({
      entry_role_arn      = aws_iam_role.crt_entry[0].arn
      target_role_arn     = aws_iam_role.crt_target[0].arn
      flag_parameter_name = aws_ssm_parameter.crt_flag[0].name
    }, null)
    conditionprincipaltag = try({
      entry_role_arn      = aws_iam_user.cpt_user[0].arn
      target_role_arn     = aws_iam_role.cpt_target[0].arn
      flag_parameter_name = aws_ssm_parameter.cpt_flag[0].name
    }, null)
    conditionexternalid = try({
      entry_role_arn      = aws_iam_role.cei_entry[0].arn
      target_role_arn     = aws_iam_role.cei_target[0].arn
      flag_parameter_name = aws_ssm_parameter.cei_flag[0].name
    }, null)
    kmsencryptioncontext = try({
      entry_role_arn      = aws_iam_role.kec_entry[0].arn
      target_role_arn     = aws_iam_role.kec_lambda_exec[0].arn
      flag_parameter_name = "(kms ciphertext — see capstone-style decrypt)"
    }, null)
  }
}

output "eks_cluster_name" {
  value = try(module.shared_eks[0].cluster_name, null)
}

# ----------------------------------------------------------------------------
# Capstone — extra outputs the verify script and docs depend on. Everything is
# wrapped in `try(...)` so the outputs simply report null when the capstone is
# disabled.
# ----------------------------------------------------------------------------

output "capstone_dev_deployer_user_name" {
  value = try(aws_iam_user.capstone_dev_deployer[0].name, null)
}

output "capstone_dev_deployer_access_key_id" {
  value     = try(aws_iam_access_key.capstone_dev_deployer[0].id, null)
  sensitive = true
}

output "capstone_dev_deployer_secret_access_key" {
  value     = try(aws_iam_access_key.capstone_dev_deployer[0].secret, null)
  sensitive = true
}

output "capstone_bootstrap_function_name" {
  value = try(aws_lambda_function.capstone_bootstrap_fn[0].function_name, null)
}

output "capstone_bridge_role_arn" {
  value = try(aws_iam_role.capstone_bridge[0].arn, null)
}

output "capstone_deployer_role_arn" {
  value = try(aws_iam_role.capstone_deployer[0].arn, null)
}

output "capstone_jumpbox_id" {
  value = try(aws_instance.capstone_jumpbox[0].id, null)
}

output "capstone_pod_role_arn" {
  value = try(aws_iam_role.capstone_pod_role[0].arn, null)
}

output "capstone_decryptor_function_name" {
  value = try(aws_lambda_function.capstone_decryptor[0].function_name, null)
}

output "capstone_lambda_exec_role_arn" {
  value = try(aws_iam_role.capstone_lambda_exec[0].arn, null)
}

output "capstone_eks_cluster_name" {
  value = try(module.capstone_staging_eks[0].cluster_name, null)
}

output "capstone_verify_token" {
  value     = try("capstone-verify-${random_id.capstone_verify_token[0].hex}", null)
  sensitive = true
}

output "capstone_external_id" {
  value     = try(random_uuid.capstone_external_id[0].result, null)
  sensitive = true
}

output "capstone_prod_external_id" {
  value     = try(random_uuid.capstone_prod_external_id[0].result, null)
  sensitive = true
}

# ----------------------------------------------------------------------------
# Condition labs — extra outputs the verify scripts need.
# ----------------------------------------------------------------------------

output "conditionprincipaltag_user_name" {
  value = try(aws_iam_user.cpt_user[0].name, null)
}

output "conditionprincipaltag_access_key_id" {
  value     = try(aws_iam_access_key.cpt_user[0].id, null)
  sensitive = true
}

output "conditionprincipaltag_secret_access_key" {
  value     = try(aws_iam_access_key.cpt_user[0].secret, null)
  sensitive = true
}

output "conditionexternalid_external_id" {
  value     = try(random_uuid.cei_external_id[0].result, null)
  sensitive = true
}

output "kmsencryptioncontext_function_name" {
  value = try(aws_lambda_function.kec_decryptor[0].function_name, null)
}

output "kmsencryptioncontext_key_id" {
  value = try(aws_kms_key.kec_key[0].key_id, null)
}
