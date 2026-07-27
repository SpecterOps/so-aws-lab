package awsconfig

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func setTempConfig(t *testing.T, initial string) string {
	t.Helper()
	dir := t.TempDir()
	p := filepath.Join(dir, "config")
	if initial != "" {
		if err := os.WriteFile(p, []byte(initial), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	t.Setenv("AWS_CONFIG_FILE", p)
	return p
}

func read(t *testing.T, p string) string {
	t.Helper()
	b, err := os.ReadFile(p)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

func sampleProfile(lab string) Profile {
	return Profile{
		Lab:           lab,
		Name:          "so-aws-lab-" + lab + "-carl",
		RoleARN:       "arn:aws:iam::123456789012:role/so-aws-lab-" + lab + "-carl",
		SourceProfile: "workshop",
		Region:        "us-east-1",
		SessionName:   "tester",
	}
}

func TestSyncPreservesExistingContent(t *testing.T) {
	existing := "[profile workshop]\naws_access_key_id = AKIA\nregion = us-west-2\n"
	p := setTempConfig(t, existing)

	if _, err := Sync([]Profile{sampleProfile("assumerole")}); err != nil {
		t.Fatal(err)
	}
	got := read(t, p)

	if !strings.Contains(got, "[profile workshop]") || !strings.Contains(got, "AKIA") {
		t.Fatalf("existing profile clobbered:\n%s", got)
	}
	if !strings.Contains(got, "[profile so-aws-lab-assumerole-carl]") {
		t.Fatalf("managed profile not written:\n%s", got)
	}
	if !strings.Contains(got, "role_session_name = tester") {
		t.Fatalf("session name missing:\n%s", got)
	}
}

func TestSyncIsIdempotentAndReplaces(t *testing.T) {
	p := setTempConfig(t, "[profile workshop]\nregion = us-east-1\n")

	// First sync: two labs.
	if _, err := Sync([]Profile{sampleProfile("a"), sampleProfile("b")}); err != nil {
		t.Fatal(err)
	}
	// Second sync: drop b, add c. b must disappear, no dupes of a.
	if _, err := Sync([]Profile{sampleProfile("a"), sampleProfile("c")}); err != nil {
		t.Fatal(err)
	}
	got := read(t, p)

	if strings.Contains(got, "so-aws-lab-b-carl") {
		t.Fatalf("stale profile b not removed:\n%s", got)
	}
	if n := strings.Count(got, "[profile so-aws-lab-a-carl]"); n != 1 {
		t.Fatalf("profile a written %d times, want 1:\n%s", n, got)
	}
	if !strings.Contains(got, "so-aws-lab-c-carl") {
		t.Fatalf("profile c missing:\n%s", got)
	}
	if n := strings.Count(got, startPrefix); n != 2 {
		t.Fatalf("got %d managed blocks, want 2:\n%s", n, got)
	}
}

func TestSyncNilRemovesAllManagedButKeepsRest(t *testing.T) {
	existing := "[profile workshop]\nregion = us-east-1\n"
	p := setTempConfig(t, existing)

	if _, err := Sync([]Profile{sampleProfile("a")}); err != nil {
		t.Fatal(err)
	}
	if _, err := Sync(nil); err != nil {
		t.Fatal(err)
	}
	got := read(t, p)

	if strings.Contains(got, "so-aws-lab-") || strings.Contains(got, startPrefix) {
		t.Fatalf("managed content remained after Sync(nil):\n%s", got)
	}
	if !strings.Contains(got, "[profile workshop]") {
		t.Fatalf("user content lost:\n%s", got)
	}
}

func TestSyncCreatesFileWhenMissing(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "nested", "config")
	t.Setenv("AWS_CONFIG_FILE", p)

	if _, err := Sync([]Profile{sampleProfile("a")}); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(read(t, p), "so-aws-lab-a-carl") {
		t.Fatal("file not created with profile")
	}
}

func TestSanitizeSessionName(t *testing.T) {
	cases := map[string]string{
		"jcatrambone":           "jcatrambone",
		"a b c":                 "a-b-c",
		"weird$$$name":          "weird-name",
		"--trim--":              "trim",
		"x":                     "", // too short
		"user.name@corp":        "user.name@corp",
		strings.Repeat("a", 80): strings.Repeat("a", 64),
	}
	for in, want := range cases {
		if got := sanitizeSessionName(in); got != want {
			t.Errorf("sanitizeSessionName(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestCurrentSessionNameNonEmpty(t *testing.T) {
	if s := CurrentSessionName(); s == "" {
		t.Fatal("CurrentSessionName returned empty")
	}
}
