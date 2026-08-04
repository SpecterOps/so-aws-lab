package config

import (
	"os"
	"path/filepath"
	"testing"
)

func TestLoadDefaultsCapstoneRoster(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	cfg, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Capstone.Students == nil {
		t.Fatal("capstone students map is nil")
	}
	if len(cfg.Capstone.Students) != 0 {
		t.Fatalf("default capstone roster has %d users, want single-user mode", len(cfg.Capstone.Students))
	}
}

func TestCapstoneConfigRoundTrip(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	cfg := newDefault()
	cfg.Accounts["dev"] = Account{Profile: "dev-admin", Region: "us-east-1"}
	cfg.Capstone.Students["student01"] = "Alice"
	if err := cfg.Save(); err != nil {
		t.Fatal(err)
	}

	raw, err := os.ReadFile(filepath.Join(home, ".so-aws-lab", "config.yaml"))
	if err != nil {
		t.Fatal(err)
	}
	if len(raw) == 0 {
		t.Fatal("saved config is empty")
	}

	got, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	if got.Capstone.Students["student01"] != "Alice" {
		t.Fatalf("capstone config did not round trip: %#v", got.Capstone)
	}
}
