package runner

import (
	"reflect"
	"slices"
	"testing"

	"github.com/specterops/so-aws-lab/internal/config"
)

func TestTFVarsArgsIncludesCapstoneRoster(t *testing.T) {
	r := &Runner{Cfg: &config.Config{
		Accounts: map[string]config.Account{
			"dev":     {Profile: "dev-admin", Region: "us-east-1"},
			"staging": {Profile: "staging-admin", Region: "us-east-1"},
			"prod":    {Profile: "prod-admin", Region: "us-east-1"},
		},
		LabPrefix: "workshop",
		Enabled:   map[string]bool{"capstone": true},
		Capstone: config.CapstoneConfig{
			Students: map[string]string{
				"student02": "Bob",
				"student01": "Alice",
			},
		},
	}}

	args := r.tfvarsArgs()
	for _, want := range []string{
		`capstone_students={"student01":"Alice","student02":"Bob"}`,
	} {
		if !slices.Contains(args, want) {
			t.Errorf("tfvars args are missing %q: %#v", want, args)
		}
	}
}

func TestTFVarsArgsDefaultsCapstoneToSingleUser(t *testing.T) {
	r := &Runner{Cfg: &config.Config{
		Accounts: map[string]config.Account{},
		Enabled:  map[string]bool{"capstone": true},
		Capstone: config.CapstoneConfig{
			Students: map[string]string{},
		},
	}}

	if !slices.Contains(r.tfvarsArgs(), `capstone_students={}`) {
		t.Fatalf("default capstone deployment did not pass an empty roster: %#v", r.tfvarsArgs())
	}
}

func TestExistingCapstoneEKSVarArgs(t *testing.T) {
	got, err := existingCapstoneEKSVarArgs([]byte(`{
		"cluster": {
			"name": "workshop-cs-eks",
			"endpoint": "https://example.eks.amazonaws.com",
			"certificateAuthority": {"data": "Q0E="}
		}
	}`))
	if err != nil {
		t.Fatal(err)
	}
	want := []string{
		"-var", "capstone_existing_eks_name=workshop-cs-eks",
		"-var", "capstone_existing_eks_endpoint=https://example.eks.amazonaws.com",
		"-var", "capstone_existing_eks_ca=Q0E=",
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("existing EKS args\n got: %#v\nwant: %#v", got, want)
	}
}

func TestExistingCapstoneEKSVarArgsRequiresConnectionData(t *testing.T) {
	if _, err := existingCapstoneEKSVarArgs([]byte(`{"cluster":{"name":"workshop-cs-eks"}}`)); err == nil {
		t.Fatal("expected missing EKS connection data to fail")
	}
}
