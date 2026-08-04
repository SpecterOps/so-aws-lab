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
		"AWS_CanAssumeRole",
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

func TestCapstoneBridgeDoesNotRequireSessionTag(t *testing.T) {
	capstone := readAsset(t, "assets/terraform/workshop/capstone.tf")
	start := strings.Index(capstone, `resource "aws_iam_policy" "capstone_entry_boundary"`)
	end := strings.Index(capstone, `resource "aws_iam_role_policy" "capstone_entry_inline"`)
	if start < 0 || end <= start {
		t.Fatal("capstone Donut boundary could not be isolated")
	}
	boundary := capstone[start:end]
	for _, required := range []string{
		`Sid      = "AssumeStagingBridge"`,
		`Action   = ["sts:AssumeRole"]`,
	} {
		if !strings.Contains(boundary, required) {
			t.Errorf("capstone Donut boundary does not expose untagged Signet hop through %s", required)
		}
	}

	start = strings.Index(capstone, `resource "aws_iam_role" "capstone_bridge"`)
	end = strings.Index(capstone, `resource "aws_iam_role" "capstone_deployer"`)
	if start < 0 || end <= start {
		t.Fatal("capstone Signet trust policy could not be isolated")
	}
	bridge := capstone[start:end]
	if strings.Contains(boundary+bridge, `aws:RequestTag/team`) || strings.Contains(boundary+bridge, `sts:TagSession`) {
		t.Error("capstone Donut-to-Signet hop still requires or permits a tagged session")
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
		`resource "aws_iam_role" "capstone_katia"`,
		`name                 = "${each.value.prefix}-katia"`,
		`Student = each.key`,
		`Resource = [each.value.external_param_arn]`,
		`Resource = [each.value.prod_bridge_role_arn]`,
		`"eks:accessScope"  = "namespace"`,
		`"eks:namespaces" = [each.value.namespace]`,
		`"pod-security.kubernetes.io/enforce" = "restricted"`,
		`resource "kubernetes_resource_quota_v1" "capstone_student"`,
		`resource "kubernetes_limit_range_v1" "capstone_student"`,
		`protect_pod_imds  = true`,
		`http_put_response_hop_limit = 1`,
		`output "capstone_students"`,
		`katia_role_arn`,
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

func TestCapstoneDefaultsToSingleUser(t *testing.T) {
	capstone := readAsset(t, "assets/terraform/workshop/capstone.tf")
	variables := readAsset(t, "assets/terraform/workshop/variables.tf")

	for _, required := range []string{
		`variable "capstone_students"`,
		`default     = {}`,
		`capstone_student_roster = length(var.capstone_students) > 0 ? var.capstone_students : {`,
		`default = ""`,
	} {
		if !strings.Contains(capstone+"\n"+variables, required) {
			t.Errorf("single-user capstone default is missing %s", required)
		}
	}
}

func TestCapstoneSharedMongoPodIdentityABACContract(t *testing.T) {
	capstone := readAsset(t, "assets/terraform/workshop/capstone.tf")
	outputs := readAsset(t, "assets/terraform/workshop/outputs.tf")

	if got := strings.Count(capstone, `resource "aws_iam_role" "capstone_prod_pod_role"`); got != 1 {
		t.Fatalf("capstone must define one shared Mongo role, found %d", got)
	}

	roleStart := strings.Index(capstone, `resource "aws_iam_role" "capstone_prod_pod_role"`)
	associationStart := strings.Index(capstone, `resource "aws_eks_pod_identity_association" "capstone_evidence_reader"`)
	if roleStart < 0 || associationStart <= roleStart {
		t.Fatal("shared Mongo role and Pod Identity association could not be isolated")
	}
	role := capstone[roleStart:associationStart]
	for _, required := range []string{
		`count    = local.capstone_enabled`,
		`name                 = "${local.capstone_prefix}-mongo"`,
		`permissions_boundary = aws_iam_policy.capstone_prod_pod_boundary[0].arn`,
		`Principal = { Service = local.capstone_pod_identity_sp }`,
		`Action    = ["sts:AssumeRole", "sts:TagSession"]`,
	} {
		if !strings.Contains(role, required) {
			t.Errorf("shared Mongo role is missing %s", required)
		}
	}
	if strings.Contains(role, `for_each = local.capstone_instances`) {
		t.Error("Mongo must not fan out into one role per student")
	}

	associationEnd := strings.Index(capstone[associationStart:], `# ============================================================================`)
	if associationEnd < 0 {
		t.Fatal("Pod Identity association could not be isolated")
	}
	association := capstone[associationStart : associationStart+associationEnd]
	for _, required := range []string{
		`for_each = local.capstone_instances`,
		`namespace       = each.value.namespace`,
		`service_account = each.value.service_account`,
		`role_arn        = aws_iam_role.capstone_prod_pod_role[0].arn`,
	} {
		if !strings.Contains(association, required) {
			t.Errorf("Pod Identity association is missing %s", required)
		}
	}
	if strings.Contains(association, `disable_session_tags`) {
		t.Error("Pod Identity association disables the automatic isolation tags")
	}

	for _, required := range []string{
		`service_account     = local.capstone_student_prefixes[id]`,
		`pod_role_arn         = local.capstone_shared_mongo_role_arn`,
		`resource "aws_iam_policy" "capstone_prod_pod_boundary"`,
		`capstone_mongo_evidence_bucket_arn = "arn:${local.partition}:s3:::$${aws:PrincipalTag/kubernetes-service-account}-evidence-${local.prod_account_id}"`,
		`"aws:PrincipalTag/eks-cluster-name"`,
		`"aws:PrincipalTag/kubernetes-namespace"`,
		`"aws:PrincipalTag/kubernetes-service-account"`,
		`"aws:ResourceTag/Student" = "$${aws:PrincipalTag/kubernetes-service-account}"`,
		`Student = each.value.service_account`,
	} {
		if !strings.Contains(capstone, required) {
			t.Errorf("shared Mongo ABAC contract is missing %s", required)
		}
	}

	boundaryStart := strings.Index(capstone, `resource "aws_iam_policy" "capstone_prod_pod_boundary"`)
	if boundaryStart < 0 || roleStart <= boundaryStart {
		t.Fatal("Mongo permissions boundary could not be isolated")
	}
	boundary := capstone[boundaryStart:roleStart]
	inlineStart := strings.Index(capstone, `resource "aws_iam_role_policy" "capstone_prod_pod_inline"`)
	if inlineStart < 0 {
		t.Fatal("Mongo inline policy could not be isolated")
	}
	inline := capstone[inlineStart:]
	if !strings.Contains(boundary, `"kms:Decrypt"`) {
		t.Error("Mongo boundary must leave room for the constrained KMS decrypt grant")
	}
	if strings.Contains(inline, `"kms:Decrypt"`) {
		t.Error("Mongo inline policy bypasses the KMS CreateGrant challenge")
	}

	keyStart := strings.Index(capstone, `resource "aws_kms_key" "capstone_evidence"`)
	keyEnd := strings.Index(capstone, `resource "aws_kms_alias" "capstone_evidence"`)
	if keyStart < 0 || keyEnd <= keyStart {
		t.Fatal("student evidence key policy could not be isolated")
	}
	key := capstone[keyStart:keyEnd]
	for _, required := range []string{
		`Principal = { AWS = aws_iam_role.capstone_prod_pod_role[0].arn }`,
		`"aws:PrincipalTag/eks-cluster-name"           = module.capstone_prod_eks[0].cluster_name`,
		`"aws:PrincipalTag/kubernetes-namespace"       = each.value.namespace`,
		`"aws:PrincipalTag/kubernetes-service-account" = each.value.service_account`,
		`"kms:EncryptionContext:aws:s3:arn" = each.value.evidence_object_arn`,
	} {
		if !strings.Contains(key, required) {
			t.Errorf("evidence key policy is missing shared-session isolation control %s", required)
		}
	}

	for _, required := range []string{
		`target_role_arn     = aws_iam_role.capstone_prod_pod_role[0].arn`,
		`target_role_arn         = aws_iam_role.capstone_prod_pod_role[0].arn`,
		`pod_role_arn            = aws_iam_role.capstone_prod_pod_role[0].arn`,
	} {
		if !strings.Contains(outputs, required) {
			t.Errorf("capstone output does not report shared Mongo through %s", required)
		}
	}
	if strings.Contains(outputs, `aws_iam_role.capstone_prod_pod_role[id]`) {
		t.Error("per-student outputs still fan out to per-student Mongo roles")
	}
}

func TestCapstoneWorkshopPoliciesScaleOnFreshAccounts(t *testing.T) {
	capstone := readAsset(t, "assets/terraform/workshop/capstone.tf")

	for _, required := range []string{
		`on_failure   = "DELETE"`,
		`capstone_ec2_inline_policy = jsonencode({`,
		`resource "aws_iam_role_policy" "capstone_katia_inline"`,
		`policy = local.capstone_ec2_inline_policy`,
		`condition     = length(local.capstone_ec2_inline_policy) <= 10240`,
	} {
		if !strings.Contains(capstone, required) {
			t.Errorf("capstone is missing scalable workshop policy control %s", required)
		}
	}

	for _, unsupportedReservation := range []string{
		`reserved_concurrent_executions`,
		`ReservedConcurrentExecutions`,
		`"lambda:GetFunctionConcurrency"`,
		`"lambda:PutFunctionConcurrency"`,
		`"lambda:DeleteFunctionConcurrency"`,
	} {
		if strings.Contains(capstone, unsupportedReservation) {
			t.Errorf("capstone reserves Lambda concurrency that fresh workshop accounts cannot provide: %s", unsupportedReservation)
		}
	}

	for _, rosterSizedStatement := range []string{
		`for id, instance in local.capstone_instances : {
        Sid      = "ReadProdFederationToken`,
		`for id, instance in local.capstone_instances : {
        Sid      = "DecryptOnlyThroughParameterStore`,
		`for id, instance in local.capstone_instances : {
        Sid      = "AssumeProdIncidentBridge`,
	} {
		if strings.Contains(capstone, rosterSizedStatement) {
			t.Errorf("shared Katia role still expands one statement per student: %s", rosterSizedStatement)
		}
	}
}

func TestCapstoneKatiaHandoffUsesPersistentRolesWithoutSessionTags(t *testing.T) {
	capstone := readAsset(t, "assets/terraform/workshop/capstone.tf")
	start := strings.Index(capstone, `resource "aws_iam_role" "capstone_ec2_role"`)
	end := strings.Index(capstone, `# ============================================================================
# PROD account: access-entry pivot`)
	if start < 0 || end <= start {
		t.Fatal("capstone Ward-to-Katia-to-Odette chain could not be isolated")
	}
	chain := capstone[start:end]
	for _, required := range []string{
		`resource "aws_iam_role" "capstone_katia"`,
		`Principal = { AWS = aws_iam_role.capstone_deployer[each.key].arn }`,
		`"sts:ExternalId"       = random_uuid.capstone_katia_external_id[each.key].result`,
		`"aws:SourceIp" = "${aws_eip.capstone_jumpbox[0].public_ip}/32"`,
		`resource "aws_eip" "capstone_jumpbox"`,
		`Sid      = "PublishOwnMordecaiCredentialHandoff"`,
		`Sid      = "AssumeOwnKatiaAfterSSMHandoff"`,
		`Resource = [each.value.katia_role_arn]`,
		`AWS_SHARED_CREDENTIALS_FILE=\"$MORDECAI_FILE\"`,
		`--external-id '${random_uuid.capstone_katia_external_id[each.key].result}'`,
	} {
		if !strings.Contains(chain, required) {
			t.Errorf("capstone SSM Mordecai handoff is missing %s", required)
		}
	}

	wardPolicyStart := strings.Index(chain, `resource "aws_iam_role_policy" "capstone_ec2_inline"`)
	katiaPolicyStart := strings.Index(chain, `resource "aws_iam_role_policy" "capstone_katia_inline"`)
	if wardPolicyStart < 0 || katiaPolicyStart <= wardPolicyStart {
		t.Fatal("capstone Ward inline policy could not be isolated")
	}
	wardPolicy := chain[wardPolicyStart:katiaPolicyStart]
	if strings.Contains(wardPolicy, `sts:AssumeRole`) || strings.Contains(wardPolicy, `katia_role_arn`) {
		t.Error("shared Ward policy still fans out to student Katia roles")
	}

	for _, forbidden := range []string{
		`CreateStudentTaggedSession`,
		`CreateKnownStudentSessionFromUntaggedInstance`,
		`sts:TagSession`,
		`aws:RequestTag/Student`,
		`aws:TagKeys`,
		`aws:PrincipalTag/Student`,
		`$${aws:PrincipalTag/Student}`,
		`--tags 'Key=Student`,
	} {
		if strings.Contains(chain, forbidden) {
			t.Errorf("capstone handoff still depends on session tagging through %s", forbidden)
		}
	}
}

func TestCapstoneKubernetesProviderUsesRealClusterEndpoint(t *testing.T) {
	providers := readAsset(t, "assets/terraform/workshop/providers.tf")
	variables := readAsset(t, "assets/terraform/workshop/variables.tf")

	for _, required := range []string{
		`variable "capstone_existing_eks_endpoint"`,
		`variable "capstone_existing_eks_ca"`,
		`variable "capstone_existing_eks_name"`,
		`var.capstone_existing_eks_endpoint != "" ? var.capstone_existing_eks_endpoint`,
		`module.capstone_prod_eks[0].cluster_ca`,
		`var.capstone_existing_eks_name != "" ? var.capstone_existing_eks_name`,
	} {
		if !strings.Contains(providers+"\n"+variables, required) {
			t.Errorf("capstone Kubernetes provider is missing real-cluster dependency %s", required)
		}
	}

	if strings.Contains(providers, `"https://127.0.0.1"`) {
		t.Error("capstone Kubernetes provider must not fall back to localhost")
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
