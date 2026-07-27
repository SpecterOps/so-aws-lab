// Package workspace owns the terraform the CLI drives. It is embedded into the
// binary at build time and extracted to a stable directory on disk
// (~/.so-aws-lab/workspace) the first time it's needed.
//
// Terraform has to run against real files on disk, and its state and provider
// cache have to survive across runs — so this is an extract-once-then-reuse
// directory, not a temp dir. The layout mirrors the source tree exactly:
//
//	<workspace>/terraform/modules/    module sources ("../modules/..." refs)
//	<workspace>/terraform/workshop/   root module; state + .terraform live here
//
// That relative layout is load-bearing: workshop/*.tf reference
// "../modules/<name>". Don't flatten it.
//
// Ensure only ever writes the files it embeds, and only ever deletes stale
// .tf files it previously owned. Terraform state, the .terraform provider
// cache, and generated .zip artifacts are never touched.
package workspace

import (
	"embed"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
)

// The all: prefix keeps go:embed from skipping files that begin with '.' or
// '_' — nothing currently vendored needs it, but a dot-file like
// .terraform.lock.hcl would otherwise be dropped silently if added later.
//
//go:embed all:assets
var assets embed.FS

// assetRoot is the embed-relative prefix stripped from each path on extract.
const assetRoot = "assets"

// managedExts are the file types Ensure owns: it writes them, and prunes ones
// that no longer exist in the embedded set. Anything else on disk is left
// alone (state, .terraform/, .tmp-*.zip, user scratch files).
var managedExts = map[string]bool{".tf": true}

// Dir returns the on-disk workspace root, ~/.so-aws-lab/workspace.
func Dir() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(home, ".so-aws-lab", "workspace"), nil
}

// TerraformDir is the root module terraform runs in — where state and the
// .terraform provider cache live.
func TerraformDir(root string) string {
	return filepath.Join(root, "terraform", "workshop")
}

// Ensure extracts the embedded assets into root, creating it if needed. It
// overwrites managed files unconditionally so upgrading the binary upgrades
// the terraform, then prunes managed files that the new build no longer
// ships (a lab removed upstream must stop being applied). Returns the
// workspace root for convenience.
func Ensure(root string) error {
	if err := os.MkdirAll(root, 0o700); err != nil {
		return fmt.Errorf("create workspace %s: %w", root, err)
	}

	written := map[string]bool{}
	err := fs.WalkDir(assets, assetRoot, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, err := filepath.Rel(assetRoot, p)
		if err != nil {
			return err
		}
		if rel == "." {
			return nil
		}
		dest := filepath.Join(root, rel)
		if d.IsDir() {
			return os.MkdirAll(dest, 0o700)
		}
		b, err := assets.ReadFile(p)
		if err != nil {
			return err
		}
		const mode = os.FileMode(0o600)
		if err := os.MkdirAll(filepath.Dir(dest), 0o700); err != nil {
			return err
		}
		if err := os.WriteFile(dest, b, mode); err != nil {
			return err
		}
		// Chmod explicitly: WriteFile only applies mode when creating, so an
		// existing file keeps its old permissions.
		if err := os.Chmod(dest, mode); err != nil {
			return err
		}
		written[dest] = true
		return nil
	})
	if err != nil {
		return fmt.Errorf("extract workspace assets: %w", err)
	}
	return prune(root, written)
}

// prune deletes managed-extension files under the workspace that Ensure did
// not just write — leftovers from an older build. It never descends into
// .terraform (the provider cache holds unrelated .tf fixtures inside provider
// modules, and deleting from it would corrupt the cache).
func prune(root string, written map[string]bool) error {
	for _, sub := range []string{"terraform"} {
		dir := filepath.Join(root, sub)
		if _, err := os.Stat(dir); os.IsNotExist(err) {
			continue
		}
		err := filepath.WalkDir(dir, func(p string, d fs.DirEntry, err error) error {
			if err != nil {
				return err
			}
			if d.IsDir() {
				if d.Name() == ".terraform" {
					return fs.SkipDir
				}
				return nil
			}
			if !managedExts[filepath.Ext(p)] || written[p] {
				return nil
			}
			return os.Remove(p)
		})
		if err != nil {
			return fmt.Errorf("prune stale workspace files in %s: %w", dir, err)
		}
	}
	return nil
}
