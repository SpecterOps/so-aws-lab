package labs

import (
	"reflect"
	"testing"
)

func TestCapstoneCatalogContract(t *testing.T) {
	catalog, err := Load()
	if err != nil {
		t.Fatal(err)
	}

	var capstone *Lab
	for i := range catalog {
		if catalog[i].Slug == "capstone" {
			capstone = &catalog[i]
			break
		}
	}
	if capstone == nil {
		t.Fatal("capstone is missing from the lab catalog")
	}

	if want := []string{"dev", "staging", "prod"}; !reflect.DeepEqual(capstone.Accounts, want) {
		t.Errorf("capstone accounts = %v, want %v", capstone.Accounts, want)
	}
	for _, service := range []string{"lambda", "cloudformation", "ssm", "kms", "ec2", "eks", "s3"} {
		if !contains(capstone.Services, service) {
			t.Errorf("capstone services are missing %q", service)
		}
	}
	if capstone.SharedResource != "" {
		t.Errorf("capstone has dedicated infrastructure and must not dedupe cost as %q", capstone.SharedResource)
	}
}

func contains(values []string, want string) bool {
	for _, value := range values {
		if value == want {
			return true
		}
	}
	return false
}
