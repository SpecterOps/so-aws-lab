package workspace

import (
	"strings"
	"testing"
)

func TestStandaloneAuthorizationContract(t *testing.T) {
	common := readAsset(t, "assets/terraform/modules/lab_common/main.tf")
	for _, required := range []string{
		`variable "entry_policy_statements"`,
		`variable "entry_target_access"`,
		`variable "target_trusts_entry"`,
		`target_identity = var.entry_target_access == "direct"`,
		`concat(var.target_trusts_entry ? [local.entry_arn] : [], var.extra_target_principals)`,
	} {
		if !strings.Contains(common, required) {
			t.Errorf("standalone lab_common is missing %s", required)
		}
	}

	victim := readAsset(t, "assets/terraform/modules/lab_with_victim/main.tf")
	for _, required := range []string{
		`entry_target_access       = "none"`,
		`target_trusts_entry       = false`,
	} {
		if !strings.Contains(victim, required) {
			t.Errorf("victim labs are missing shortcut guard %s", required)
		}
	}
}

func TestStandaloneCompletionArtifacts(t *testing.T) {
	compute := readAsset(t, "assets/terraform/workshop/compute_labs.tf")
	data := readAsset(t, "assets/terraform/workshop/data_labs.tf")
	eks := readAsset(t, "assets/terraform/workshop/eks_labs.tf")
	iam := readAsset(t, "assets/terraform/workshop/iam_labs.tf")

	for _, required := range []string{
		`"ec2:GetConsoleOutput"`,
		`resource "aws_secretsmanager_secret" "cloudformationcreatestack_source"`,
		`resource "aws_secretsmanager_secret" "cloudformationcreatechangeset_source"`,
		`"lambda:DeleteLayerVersion"`,
	} {
		if !strings.Contains(compute, required) {
			t.Errorf("standalone compute labs are missing %s", required)
		}
	}

	for _, required := range []string{
		`entry_policy_statements = [`,
		`"kms:RevokeGrant"`,
	} {
		if !strings.Contains(data, required) {
			t.Errorf("standalone data labs are missing %s", required)
		}
	}

	for _, required := range []string{
		`resource "kubernetes_secret_v1" "eksaccessentry_db_credentials"`,
		`resource "aws_eks_access_policy_association" "ekspodidentityassociation_namespace_admin"`,
	} {
		if !strings.Contains(eks, required) {
			t.Errorf("standalone EKS labs are missing %s", required)
		}
	}

	if !strings.Contains(iam, `resource "aws_iam_role_policy_attachment" "createpolicyversion_pivot"`) {
		t.Error("CreatePolicyVersion sleeper policy is not attached to the entry role")
	}
}
