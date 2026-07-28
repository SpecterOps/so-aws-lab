package workspace

import (
	"bufio"
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

type traversableSnapshot struct {
	SchemaVersion     string   `json:"schema_version"`
	SourceCommit      string   `json:"source_commit"`
	SchemaSHA256      string   `json:"schema_sha256"`
	RelationshipKinds []string `json:"relationship_kinds"`
}

type goAWSHoundSchema struct {
	RelationshipKinds []struct {
		Name          string `json:"name"`
		IsTraversable bool   `json:"is_traversable"`
	} `json:"relationship_kinds"`
}

func TestCapstoneTraversablePathContract(t *testing.T) {
	capstone := readAsset(t, "assets/terraform/workshop/capstone.tf")
	got := pathMarkers(t, capstone)
	want := []string{
		"AWS_CanUpdateLambdaCode",
		"AWS_RunsAs",
		"AWS_CanAssumeRole",
		"AWS_CanExecuteCloudFormationChangeSet",
		"AWS_RunsAs",
		"AWS_SSMCanSendCommand",
		"AWS_RunsAs",
		"AWS_CanAssumeRole",
		"AWS_CanCreateAndAssociateEKSAccessEntry",
		"AWS_CanAssumeRoleViaPodIdentity",
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("capstone path\n got: %v\nwant: %v", got, want)
	}

	rawSnapshot, err := os.ReadFile(filepath.Join("testdata", "goawshound-traversable-relationships-v1.json"))
	if err != nil {
		t.Fatal(err)
	}
	var snapshot traversableSnapshot
	if err := json.Unmarshal(rawSnapshot, &snapshot); err != nil {
		t.Fatalf("decode traversability snapshot: %v", err)
	}
	if snapshot.SchemaVersion == "" || snapshot.SourceCommit == "" || snapshot.SchemaSHA256 == "" {
		t.Fatal("traversability snapshot is missing source provenance")
	}
	traversable := make(map[string]bool, len(snapshot.RelationshipKinds))
	for _, kind := range snapshot.RelationshipKinds {
		traversable[kind] = true
	}
	for _, kind := range got {
		if !traversable[kind] {
			t.Errorf("%s is not traversable in the pinned GoAWSHound schema", kind)
		}
	}
}

func TestCapstoneCompositeEdgesHaveRequiredPermissions(t *testing.T) {
	capstone := readAsset(t, "assets/terraform/workshop/capstone.tf")

	for _, required := range []string{
		`"lambda:UpdateFunctionCode"`,
		`"cloudformation:CreateChangeSet"`,
		`"cloudformation:ExecuteChangeSet"`,
		`"ssm:SendCommand"`,
		`"eks:CreateAccessEntry"`,
		`"eks:AssociateAccessPolicy"`,
		`resource "aws_eks_pod_identity_association" "capstone_evidence_reader"`,
		`resource "aws_s3_bucket_server_side_encryption_configuration" "capstone_evidence"`,
		`kms_master_key_id = aws_kms_key.capstone_evidence[each.key].arn`,
	} {
		if !strings.Contains(capstone, required) {
			t.Errorf("capstone is missing edge constituent %s", required)
		}
	}

	for _, shortcut := range []string{
		`resource "random_id" "capstone_verify_token"`,
		`VerifyScriptShortcut`,
		`"cloudformation:UpdateStack"`,
		`"ssm:StartSession"`,
		`"eks:CreatePodIdentityAssociation"`,
	} {
		if strings.Contains(capstone, shortcut) {
			t.Errorf("capstone contains unintended shortcut %s", shortcut)
		}
	}

	outputs := readAsset(t, "assets/terraform/workshop/outputs.tf")
	for _, secretOutput := range []string{
		`output "capstone_verify_token"`,
		`output "capstone_external_id"`,
		`output "capstone_prod_external_id"`,
		`output "capstone_dev_deployer_access_key_id"`,
		`output "capstone_dev_deployer_secret_access_key"`,
	} {
		if strings.Contains(outputs, secretOutput) {
			t.Errorf("outputs expose capstone bypass material through %s", secretOutput)
		}
	}
	if !strings.Contains(outputs, `entry_role_arn      = aws_iam_role.capstone_dev_deployer["default"].arn`) {
		t.Error("capstone must expose Carl as its managed entry role")
	}
}

func TestCapstoneEntryIsBoundaryConstrainedRole(t *testing.T) {
	capstone := readAsset(t, "assets/terraform/workshop/capstone.tf")
	outputs := readAsset(t, "assets/terraform/workshop/outputs.tf")

	for _, required := range []string{
		`resource "aws_iam_role" "capstone_dev_deployer"`,
		`for_each             = local.capstone_instances`,
		`name                 = "${each.value.prefix}-carl"`,
		`permissions_boundary = aws_iam_policy.capstone_dev_deployer_boundary[each.key].arn`,
		`max_session_duration = 3600`,
		`AWS = each.key == "default" ? local.capstone_dev_account_root : aws_iam_user.capstone_student_bootstrap[each.key].arn`,
		`Kind    = "entry"`,
		`resource "aws_iam_role_policy" "capstone_dev_deployer_inline"`,
		`role     = aws_iam_role.capstone_dev_deployer[each.key].name`,
		`policy   = aws_iam_policy.capstone_dev_deployer_boundary[each.key].policy`,
	} {
		if !strings.Contains(capstone, required) {
			t.Errorf("capstone entry role is missing %s", required)
		}
	}

	for _, legacyArtifact := range []string{
		`resource "aws_iam_user" "capstone_dev_deployer"`,
		`resource "aws_iam_user_policy" "capstone_dev_deployer_inline"`,
		`resource "aws_iam_access_key" "capstone_dev_deployer"`,
		`output "capstone_dev_deployer_user_name"`,
		`output "capstone_dev_deployer_user_arn"`,
	} {
		if strings.Contains(capstone+"\n"+outputs, legacyArtifact) {
			t.Errorf("capstone still contains legacy user artifact %s", legacyArtifact)
		}
	}
}

func TestCapstoneMultiStudentIsolationContract(t *testing.T) {
	capstone := readAsset(t, "assets/terraform/workshop/capstone.tf")
	variables := readAsset(t, "assets/terraform/workshop/variables.tf")
	outputs := readAsset(t, "assets/terraform/workshop/outputs.tf")
	sharedEKS := readAsset(t, "assets/terraform/modules/shared_eks/main.tf")

	for _, required := range []string{
		`variable "capstone_students"`,
		`capstone_workshop_instances`,
		`resource "aws_iam_user" "capstone_student_bootstrap"`,
		`resource "aws_iam_user_policy" "capstone_student_bootstrap"`,
		`resource "aws_iam_policy" "capstone_student_bootstrap_boundary"`,
		`force_destroy        = true`,
		`"cloudshell:PutCredentials"`,
		`Sid      = "AssumeOwnCapstoneEntry"`,
		`Resource = each.value.carl_role_arn`,
		`aws_iam_user.capstone_student_bootstrap[each.key].arn`,
		`resource "aws_ssm_document" "capstone_credential_handoff"`,
		`document_type   = "Command"`,
		`each.value.ssm_document_arn`,
		`"aws:PrincipalTag/Student" = "true"`,
		`"aws:PrincipalTag/Student" = id`,
		`"eks:accessScope"  = "namespace"`,
		`"eks:namespaces" = [each.value.namespace]`,
		`"pod-security.kubernetes.io/enforce" = "restricted"`,
		`resource "kubernetes_resource_quota_v1" "capstone_student"`,
		`resource "kubernetes_limit_range_v1" "capstone_student"`,
		`protect_pod_imds  = true`,
		`http_put_response_hop_limit = 1`,
		`output "capstone_students"`,
	} {
		if !strings.Contains(capstone+"\n"+variables+"\n"+outputs+"\n"+sharedEKS, required) {
			t.Errorf("multi-student capstone is missing isolation control %s", required)
		}
	}

	for _, shared := range []string{
		`module "capstone_staging_vpc"`,
		`resource "aws_instance" "capstone_jumpbox"`,
		`module "capstone_prod_vpc"`,
		`module "capstone_prod_eks"`,
	} {
		i := strings.Index(capstone, shared)
		if i < 0 {
			t.Errorf("shared capstone resource is missing %s", shared)
			continue
		}
		window := capstone[i:min(i+500, len(capstone))]
		if !strings.Contains(window, `count`) || strings.Contains(window, `for_each = local.capstone_instances`) {
			t.Errorf("%s must remain shared rather than per-student", shared)
		}
	}

	for _, unsafe := range []string{
		`resource "aws_iam_access_key" "capstone_student`,
		`resource "aws_iam_user_login_profile" "capstone_student`,
		`resource "aws_ssoadmin_permission_set" "capstone_entry"`,
		`resource "aws_ssoadmin_account_assignment" "capstone_student"`,
		`document/AWS-RunShellScript`,
		`"eks:accessScope" = "cluster"`,
		`"aws:ResourceTag/Lab" = "capstone"
          }
        }
      },`,
	} {
		if strings.Contains(capstone, unsafe) {
			t.Errorf("multi-student capstone contains unsafe shared authorization %s", unsafe)
		}
	}
}

func TestCapstonePathAgainstLocalGoAWSHoundSchema(t *testing.T) {
	schemaPath := os.Getenv("GOAWSHOUND_SCHEMA")
	if schemaPath == "" {
		schemaPath = filepath.Join("..", "..", "..", "..", "GOAWSHound", "schema", "schema.json")
	}
	raw, err := os.ReadFile(schemaPath)
	if os.IsNotExist(err) {
		t.Skip("local GoAWSHound schema not available; pinned snapshot contract still applies")
	}
	if err != nil {
		t.Fatalf("read GoAWSHound schema: %v", err)
	}

	var schema goAWSHoundSchema
	if err := json.Unmarshal(raw, &schema); err != nil {
		t.Fatalf("decode GoAWSHound schema: %v", err)
	}
	current := make(map[string]bool, len(schema.RelationshipKinds))
	for _, relationship := range schema.RelationshipKinds {
		current[relationship.Name] = relationship.IsTraversable
	}

	capstone := readAsset(t, "assets/terraform/workshop/capstone.tf")
	for _, kind := range pathMarkers(t, capstone) {
		if !current[kind] {
			t.Errorf("%s is not traversable in %s", kind, schemaPath)
		}
	}
}

func readAsset(t *testing.T, name string) string {
	t.Helper()
	raw, err := assets.ReadFile(name)
	if err != nil {
		t.Fatal(err)
	}
	return string(raw)
}

func pathMarkers(t *testing.T, terraform string) []string {
	t.Helper()
	const begin = "# CAPSTONE_TRAVERSABLE_PATH_BEGIN"
	const end = "# CAPSTONE_TRAVERSABLE_PATH_END"

	var path []string
	inPath := false
	scanner := bufio.NewScanner(strings.NewReader(terraform))
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		switch line {
		case begin:
			if inPath {
				t.Fatal("duplicate capstone path begin marker")
			}
			inPath = true
		case end:
			if !inPath {
				t.Fatal("capstone path end marker appears before begin marker")
			}
			inPath = false
			return path
		default:
			if inPath {
				path = append(path, strings.TrimSpace(strings.TrimPrefix(line, "#")))
			}
		}
	}
	if err := scanner.Err(); err != nil {
		t.Fatal(err)
	}
	t.Fatal("capstone path markers are incomplete")
	return nil
}
