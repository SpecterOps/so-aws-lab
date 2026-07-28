package runner

import (
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
