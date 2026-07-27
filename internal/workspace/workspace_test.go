package workspace

import (
	"io/fs"
	"os"
	"path/filepath"
	"testing"
)

// TestEnsureExtractsLayout pins the on-disk layout the terraform depends on:
// workshop/*.tf reference "../modules/...", so the two trees must stay
// siblings under terraform/.
func TestEnsureExtractsLayout(t *testing.T) {
	root := t.TempDir()
	if err := Ensure(root); err != nil {
		t.Fatalf("Ensure: %v", err)
	}
	for _, rel := range []string{
		"terraform/workshop/main.tf",
		"terraform/workshop/providers.tf",
		"terraform/modules/lab_common/main.tf",
	} {
		if _, err := os.Stat(filepath.Join(root, rel)); err != nil {
			t.Errorf("missing %s: %v", rel, err)
		}
	}
	if got := TerraformDir(root); got != filepath.Join(root, "terraform", "workshop") {
		t.Errorf("TerraformDir = %q", got)
	}
}

// TestNoSolutionScriptsEmbedded guards the deliberate exclusion of the per-lab
// solution scripts — they are the answer key and must not ship in the binary.
func TestNoSolutionScriptsEmbedded(t *testing.T) {
	root := t.TempDir()
	if err := Ensure(root); err != nil {
		t.Fatalf("Ensure: %v", err)
	}
	err := filepath.WalkDir(root, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if !d.IsDir() && filepath.Ext(p) == ".sh" {
			t.Errorf("solution script leaked into the workspace: %s", p)
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(root, "scripts")); !os.IsNotExist(err) {
		t.Errorf("scripts/ directory should not exist: %v", err)
	}
}

// TestEnsureIsIdempotent — Ensure runs on every terraform invocation, so a
// second call must be a no-op rather than an error.
func TestEnsureIsIdempotent(t *testing.T) {
	root := t.TempDir()
	if err := Ensure(root); err != nil {
		t.Fatalf("first Ensure: %v", err)
	}
	if err := Ensure(root); err != nil {
		t.Fatalf("second Ensure: %v", err)
	}
	if _, err := os.Stat(filepath.Join(root, "terraform", "workshop", "main.tf")); err != nil {
		t.Errorf("main.tf gone after re-Ensure: %v", err)
	}
}

// TestEnsurePreservesStateAndCache is the important one: terraform state and
// the provider cache live inside the extracted tree. Losing either orphans
// real AWS resources or forces a multi-hundred-MB re-download.
func TestEnsurePreservesStateAndCache(t *testing.T) {
	root := t.TempDir()
	if err := Ensure(root); err != nil {
		t.Fatalf("Ensure: %v", err)
	}
	ws := TerraformDir(root)
	cacheDir := filepath.Join(ws, ".terraform", "providers")
	if err := os.MkdirAll(cacheDir, 0o700); err != nil {
		t.Fatal(err)
	}
	keep := map[string]string{
		filepath.Join(ws, "terraform.tfstate"):           `{"version":4}`,
		filepath.Join(ws, ".tmp-capstone-bootstrap.zip"): "PK\x03\x04",
		filepath.Join(cacheDir, "provider.tf"):           "# inside the provider cache",
	}
	for p, content := range keep {
		if err := os.WriteFile(p, []byte(content), 0o600); err != nil {
			t.Fatal(err)
		}
	}

	if err := Ensure(root); err != nil {
		t.Fatalf("re-Ensure: %v", err)
	}

	for p, want := range keep {
		got, err := os.ReadFile(p)
		if err != nil {
			t.Errorf("Ensure destroyed %s: %v", p, err)
			continue
		}
		if string(got) != want {
			t.Errorf("Ensure rewrote %s", p)
		}
	}
}

// TestEnsurePrunesStale — a lab removed from a later build must stop being
// applied, so orphaned .tf files from an older binary have to go.
func TestEnsurePrunesStale(t *testing.T) {
	root := t.TempDir()
	if err := Ensure(root); err != nil {
		t.Fatalf("Ensure: %v", err)
	}
	stale := filepath.Join(TerraformDir(root), "removed_lab.tf")
	if err := os.WriteFile(stale, []byte(`resource "aws_iam_role" "gone" {}`), 0o600); err != nil {
		t.Fatal(err)
	}
	staleModule := filepath.Join(root, "terraform", "modules", "gone", "main.tf")
	if err := os.MkdirAll(filepath.Dir(staleModule), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(staleModule, []byte("# removed module\n"), 0o600); err != nil {
		t.Fatal(err)
	}

	if err := Ensure(root); err != nil {
		t.Fatalf("re-Ensure: %v", err)
	}

	if _, err := os.Stat(stale); !os.IsNotExist(err) {
		t.Errorf("stale .tf survived pruning: %v", err)
	}
	if _, err := os.Stat(staleModule); !os.IsNotExist(err) {
		t.Errorf("stale module .tf survived pruning: %v", err)
	}
	if _, err := os.Stat(filepath.Join(TerraformDir(root), "main.tf")); err != nil {
		t.Errorf("prune took a live file: %v", err)
	}
}
