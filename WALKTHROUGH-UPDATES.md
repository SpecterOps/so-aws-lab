# Standalone walkthrough updates required after the infrastructure changes

This is a handoff for the agent that updates `workshop-od-aws`. It describes
the new standalone-lab contract only. Do not apply any of these changes to the
capstone.

## Shared authorization contract

- Remove statements that call direct `carl -> donut` assumption a grading
  convenience. `lab_common` now keeps that direct path only for the standalone
  AssumeRole lab.
- Victim-based labs require the recovered victim identity. Service-mediated
  labs require credentials or the flag returned by the service runtime.
- After each credential transition, retain `aws sts get-caller-identity` and
  make the captured ARN match the victim, service role, Pod Identity role, or
  `donut` that actually issued the credentials.

## IAM

### `03-identity-and-access-management/06-lab-iam-createpolicyversion.md`

- The `...-createpolicyversion-glyph` policy is now attached to Carl with a
  harmless default version. Baseline target assumption should deny because
  target assumption is only in the permissions-boundary ceiling.
- The new policy version must grant `sts:AssumeRole` on
  `...-createpolicyversion-donut`; after it becomes the default, the same
  assume-role command succeeds.

### `03-identity-and-access-management/07-lab-iam-attachrolepolicy.md`

- Baseline target assumption should deny. After attaching the existing
  `...-attachrolepolicy-glyph` policy to Carl, the target assumption succeeds.

### Victim IAM labs

- In `08-lab-iam-putuserpolicy.md`, baseline assumption as the victim now
  denies. The inline policy planted on the victim must grant
  `sts:AssumeRole` on `...-putuserpolicy-donut`; only then do the minted keys
  reach the target.
- `10-lab-iam-createcredentials.md` must use the victim credentials for the
  target transition. Remove any direct-Carl shortcut prose.

## EC2

### `04-elastic-compute-cloud/04-lab-ec2-runinstances.md`

- Add `ec2:GetConsoleOutput` to the permission enumeration.
- Have controlled user data fetch the instance-profile credentials from IMDSv2
  and write a unique marker plus the credential JSON to `/dev/console`.
- Use `aws ec2 get-console-output --instance-id "$INSTANCE_ID" --latest` to
  recover the instance-role credentials. Use those credentials to assume
  `...-ec2runinstances-donut` and read the flag.
- Remove the direct-Carl flag step. Keep access keys and tokens redacted in
  captured output, and terminate the exercise instance during cleanup.

### `04-elastic-compute-cloud/06-lab-ec2-modifyuserdata.md`

- The replacement user data must write its result or the IMDSv2 credential
  envelope to `/dev/console`, not only `/root/flag.txt`.
- After the stop/modify/start cycle, retrieve the latest console output and use
  the shared instance-role credentials to assume
  `...-ec2modifyuserdata-donut`.
- Remove the direct-Carl flag step. Running `so-aws-lab apply` with the lab
  enabled restores the Terraform-managed baseline instance.

## SSM and Lambda

- `05-aws-systems-manager/03-lab-ssm-getparameter.md` must use `bopca` for the
  final assumption. Remove shortcut prose.
- `05-aws-systems-manager/05-lab-ssm-sendcommand.md` should treat the command
  output from the shared EC2 role as the flag-bearing result; Carl can no longer
  assume the target directly.
- The CreateFunction, UpdateFunctionCode, and UpdateLayer walkthroughs must use
  the credentials returned from their real Lambda execution-role path. Remove
  the direct-Carl shortcut notes.
- UpdateLayer cleanup can now call `lambda:DeleteLayerVersion` as Carl after
  restoring the original function configuration. Remove the administrator
  cleanup caveat if present.

## CloudFormation

### `08-cloudformation/03-lab-cloudformation-createstack.md`

- Enumerate the tagged secret named
  `<prefix>-cloudformationcreatestack-source`. Carl may list and describe it but
  cannot read it.
- Replace the static `written-by-cloudformation-as-mordecai` value with the
  Secrets Manager dynamic reference below in the `AWS::SSM::Parameter`
  resource:

  `{{resolve:secretsmanager:<prefix>-cloudformationcreatestack-source}}`

- Read the flag from `/labs/<prefix>/cloudformationcreatestack/leaked` after
  stack completion. Remove the direct-Carl-to-Donut grading step.
- Stack deletion still removes the leaked parameter.

### `08-cloudformation/05-lab-cloudformation-createchangeset.md`

- Apply the same change using
  `<prefix>-cloudformationcreatechangeset-source`. The dynamic reference is
  resolved by the pre-attached CloudFormation service role when the change set
  executes.
- Read the leaked flag as Carl, then restore the Terraform baseline template:
  one `Placeholder` resource of type
  `AWS::CloudFormation::WaitConditionHandle`. CloudFormation then deletes the
  leaked parameter without needing another SSM write target. Remove the direct
  target step.
- Setup and cost text must mention the approximately `$0.01/day` Secrets
  Manager source while either CloudFormation lab is enabled.

## S3 and KMS

### `09-s3/05-lab-s3-putbucketpolicy.md`

- Replace the successful baseline object read with the expected AccessDenied.
- Read `creds.json` only after the bucket policy names Carl for `s3:GetObject`.
  Use the recovered victim credentials to assume the target.
- Delete the bucket policy and prove GetObject denies again. Carl retains
  `s3:DeleteBucketPolicy` for this cleanup.

### `10-key-management-service/05-lab-kms-creategrant.md`

- Replace the successful baseline decrypt with the expected AccessDenied.
- Capture both `GrantId` and `GrantToken` from `kms create-grant`; pass the
  token through `kms decrypt --grant-tokens` so immediate use does not depend
  on grant propagation.
- Use the recovered victim keys for the target transition. Carl can now run
  `kms revoke-grant` and confirm the baseline decrypt denies again.

- The S3 GetObject and KMS Decrypt labs already contain genuine victim paths;
  only their direct-shortcut prose needs removal.

## EKS

### `07-elastic-kubernetes-service/03-lab-eks-accessentry.md`

- `prod/db-credentials` now exists in the live lab. Its `AccessKeyId` and
  `SecretAccessKey` fields contain the `bopca` credentials.
- After self-associating cluster admin, extract both fields, authenticate as
  `bopca`, and assume `...-eksaccessentry-donut`. Remove the direct-Carl
  grading step.
- Disassociate cluster admin during cleanup. Do not delete the Terraform-owned
  `prod` namespace or secret.

### `07-elastic-kubernetes-service/05-lab-ekspodidentityassociation.md`

- The Terraform baseline now owns namespace `lab`, and this lab's own Carl has
  namespace-scoped `AmazonEKSAdminPolicy`. Remove the dependency on a dirty
  AccessEntry lab or administrator identity.
- Use Carl to create the service account and pod in `lab`; Carl cannot create
  or delete namespaces. Keep `--disable-session-tags` for the intended plain
  onward `sts:AssumeRole` transition.
- Cleanup should delete the exercise pod, service account, and Pod Identity
  association. Do not delete the Terraform-owned namespace or access-policy
  association.

## Profile synchronization

- `11-conditions/04-lab-condition-principaltag.md` remains key-based. Clarify
  that `so-aws-lab apply` intentionally does not create a managed role profile
  for this IAM-user entry principal.
