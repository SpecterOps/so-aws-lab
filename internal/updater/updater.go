// Package updater replaces a released so-aws-lab binary with a newer GitHub
// release. It refuses to cross an infrastructure-version boundary while the
// durable Terraform state still contains managed lab resources.
package updater

import (
	"archive/tar"
	"archive/zip"
	"bytes"
	"compress/gzip"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"time"

	"github.com/specterops/so-aws-lab/internal/workspace"
)

const (
	latestReleaseURL = "https://api.github.com/repos/specterops/so-aws-lab/releases/latest"
	maxMetadataSize  = 4 << 20
	maxArchiveSize   = 256 << 20
	maxBinarySize    = 128 << 20
)

type release struct {
	TagName string         `json:"tag_name"`
	Assets  []releaseAsset `json:"assets"`
}

type releaseAsset struct {
	Name               string `json:"name"`
	BrowserDownloadURL string `json:"browser_download_url"`
}

type updater struct {
	CurrentVersion string
	LatestURL      string
	Client         *http.Client
	Executable     string
	WorkspaceRoot  string
	GOOS           string
	GOARCH         string
	Stdout         io.Writer
}

// Update checks for and installs a newer release of the running executable.
func Update(currentVersion string) error {
	executable, err := os.Executable()
	if err != nil {
		return fmt.Errorf("find running executable: %w", err)
	}
	root, err := workspace.Dir()
	if err != nil {
		return err
	}
	return (&updater{
		CurrentVersion: currentVersion,
		LatestURL:      latestReleaseURL,
		Client:         &http.Client{Timeout: 30 * time.Second},
		Executable:     executable,
		WorkspaceRoot:  root,
		GOOS:           runtime.GOOS,
		GOARCH:         runtime.GOARCH,
		Stdout:         os.Stdout,
	}).run()
}

func (u *updater) run() error {
	if _, err := parseSemver(u.CurrentVersion); err != nil {
		return fmt.Errorf("cannot update non-release build %q; reinstall a released version with install.sh", u.CurrentVersion)
	}

	var rel release
	if err := u.getJSON(u.LatestURL, &rel); err != nil {
		return fmt.Errorf("check latest release: %w", err)
	}
	cmp, err := compareSemver(rel.TagName, u.CurrentVersion)
	if err != nil {
		return fmt.Errorf("latest release has invalid tag %q: %w", rel.TagName, err)
	}
	if cmp <= 0 {
		fmt.Fprintf(u.Stdout, "so-aws-lab %s is already up to date (latest: %s)\n", u.CurrentVersion, rel.TagName)
		return nil
	}

	if err := verifyNoDeployedLabs(u.WorkspaceRoot); err != nil {
		return err
	}

	archiveName, err := releaseArchiveName(u.GOOS, u.GOARCH)
	if err != nil {
		return err
	}
	archiveURL, err := assetURL(rel.Assets, archiveName)
	if err != nil {
		return err
	}
	checksumsURL, err := assetURL(rel.Assets, "checksums.txt")
	if err != nil {
		return err
	}

	archive, err := u.get(archiveURL, maxArchiveSize)
	if err != nil {
		return fmt.Errorf("download %s: %w", archiveName, err)
	}
	checksums, err := u.get(checksumsURL, maxMetadataSize)
	if err != nil {
		return fmt.Errorf("download checksums.txt: %w", err)
	}
	if err := verifyChecksum(archiveName, archive, checksums); err != nil {
		return err
	}
	binary, err := extractBinary(archiveName, archive)
	if err != nil {
		return err
	}

	// Recheck after the downloads. If an apply started while the update was
	// being fetched, preserve the old executable and leave its Terraform assets
	// paired with the state it created.
	if err := verifyNoDeployedLabs(u.WorkspaceRoot); err != nil {
		return err
	}

	path, err := filepath.EvalSymlinks(u.Executable)
	if err != nil {
		return fmt.Errorf("resolve running executable %s: %w", u.Executable, err)
	}
	if err := replaceExecutable(path, binary); err != nil {
		return fmt.Errorf("install %s: %w", rel.TagName, err)
	}
	fmt.Fprintf(u.Stdout, "updated so-aws-lab %s -> %s\n", u.CurrentVersion, rel.TagName)
	return nil
}

func (u *updater) getJSON(url string, dst any) error {
	b, err := u.get(url, maxMetadataSize)
	if err != nil {
		return err
	}
	if err := json.Unmarshal(b, dst); err != nil {
		return fmt.Errorf("decode response: %w", err)
	}
	return nil
}

func (u *updater) get(url string, maxBytes int64) ([]byte, error) {
	req, err := http.NewRequest(http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Accept", "application/vnd.github+json")
	req.Header.Set("User-Agent", "so-aws-lab-updater/"+u.CurrentVersion)
	resp, err := u.Client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 2048))
		return nil, fmt.Errorf("%s: %s", resp.Status, strings.TrimSpace(string(body)))
	}
	b, err := io.ReadAll(io.LimitReader(resp.Body, maxBytes+1))
	if err != nil {
		return nil, err
	}
	if int64(len(b)) > maxBytes {
		return nil, fmt.Errorf("response exceeds %d bytes", maxBytes)
	}
	return b, nil
}

func assetURL(assets []releaseAsset, name string) (string, error) {
	for _, a := range assets {
		if a.Name == name && a.BrowserDownloadURL != "" {
			return a.BrowserDownloadURL, nil
		}
	}
	return "", fmt.Errorf("release does not contain %s", name)
}

func releaseArchiveName(goos, goarch string) (string, error) {
	if goarch != "amd64" && goarch != "arm64" {
		return "", fmt.Errorf("automatic updates are not supported on %s/%s", goos, goarch)
	}
	switch goos {
	case "darwin", "linux":
		return fmt.Sprintf("so-aws-lab_%s_%s.tar.gz", goos, goarch), nil
	case "windows":
		return fmt.Sprintf("so-aws-lab_%s_%s.zip", goos, goarch), nil
	default:
		return "", fmt.Errorf("automatic updates are not supported on %s/%s", goos, goarch)
	}
}

func verifyChecksum(name string, archive, checksums []byte) error {
	expected := ""
	for _, line := range strings.Split(string(checksums), "\n") {
		fields := strings.Fields(line)
		if len(fields) >= 2 && strings.TrimPrefix(fields[1], "*") == name {
			expected = strings.ToLower(fields[0])
			break
		}
	}
	if len(expected) != sha256.Size*2 {
		return fmt.Errorf("checksums.txt does not contain a valid checksum for %s", name)
	}
	if _, err := hex.DecodeString(expected); err != nil {
		return fmt.Errorf("invalid checksum for %s: %w", name, err)
	}
	actual := fmt.Sprintf("%x", sha256.Sum256(archive))
	if actual != expected {
		return fmt.Errorf("checksum mismatch for %s", name)
	}
	return nil
}

func extractBinary(archiveName string, archive []byte) ([]byte, error) {
	if strings.HasSuffix(archiveName, ".tar.gz") {
		zr, err := gzip.NewReader(bytes.NewReader(archive))
		if err != nil {
			return nil, fmt.Errorf("open %s: %w", archiveName, err)
		}
		defer zr.Close()
		tr := tar.NewReader(zr)
		for {
			h, err := tr.Next()
			if err == io.EOF {
				break
			}
			if err != nil {
				return nil, fmt.Errorf("read %s: %w", archiveName, err)
			}
			if h.Typeflag != tar.TypeReg || filepath.Base(h.Name) != "so-aws-lab" {
				continue
			}
			if h.Size > maxBinarySize {
				return nil, fmt.Errorf("so-aws-lab binary exceeds %d bytes", maxBinarySize)
			}
			b, err := io.ReadAll(io.LimitReader(tr, maxBinarySize+1))
			if err != nil {
				return nil, err
			}
			if len(b) == 0 || len(b) > maxBinarySize {
				return nil, fmt.Errorf("invalid so-aws-lab binary size in %s", archiveName)
			}
			return b, nil
		}
	} else if strings.HasSuffix(archiveName, ".zip") {
		zr, err := zip.NewReader(bytes.NewReader(archive), int64(len(archive)))
		if err != nil {
			return nil, fmt.Errorf("open %s: %w", archiveName, err)
		}
		for _, f := range zr.File {
			if filepath.Base(f.Name) != "so-aws-lab.exe" || f.FileInfo().IsDir() {
				continue
			}
			if f.UncompressedSize64 > maxBinarySize {
				return nil, fmt.Errorf("so-aws-lab binary exceeds %d bytes", maxBinarySize)
			}
			r, err := f.Open()
			if err != nil {
				return nil, err
			}
			b, readErr := io.ReadAll(io.LimitReader(r, maxBinarySize+1))
			r.Close()
			if readErr != nil {
				return nil, readErr
			}
			if len(b) == 0 || len(b) > maxBinarySize {
				return nil, fmt.Errorf("invalid so-aws-lab binary size in %s", archiveName)
			}
			return b, nil
		}
	}
	return nil, fmt.Errorf("so-aws-lab binary is missing from %s", archiveName)
}

func replaceExecutable(path string, binary []byte) error {
	info, err := os.Stat(path)
	if err != nil {
		return err
	}
	if !info.Mode().IsRegular() {
		return fmt.Errorf("running executable is not a regular file")
	}
	tmp, err := os.CreateTemp(filepath.Dir(path), ".so-aws-lab-update-*")
	if err != nil {
		return fmt.Errorf("create replacement beside executable: %w", err)
	}
	tmpName := tmp.Name()
	defer os.Remove(tmpName)
	if _, err := tmp.Write(binary); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Chmod(info.Mode().Perm()); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	if err := os.Rename(tmpName, path); err != nil {
		return fmt.Errorf("replace %s atomically: %w", path, err)
	}
	return nil
}

// verifyNoDeployedLabs checks the durable state without extracting the
// running binary's embedded Terraform. Extraction before this check could
// itself overwrite the configuration paired with a deployed state.
func verifyNoDeployedLabs(root string) error {
	tfDir := workspace.TerraformDir(root)
	if _, err := os.Stat(filepath.Join(tfDir, ".terraform.tfstate.lock.info")); err == nil {
		return fmt.Errorf("refusing update while Terraform has locked the lab state")
	} else if !os.IsNotExist(err) {
		return fmt.Errorf("check Terraform state lock: %w", err)
	}

	states, err := filepath.Glob(filepath.Join(tfDir, "*.tfstate"))
	if err != nil {
		return fmt.Errorf("find Terraform state: %w", err)
	}
	for _, statePath := range states {
		b, err := os.ReadFile(statePath)
		if err != nil {
			return fmt.Errorf("read Terraform state %s: %w", statePath, err)
		}
		deployed, err := managedResources(b)
		if err != nil {
			return fmt.Errorf("inspect Terraform state %s: %w", statePath, err)
		}
		if len(deployed) > 0 {
			return deployedLabsError(deployed)
		}
	}

	backendPath := filepath.Join(tfDir, ".terraform", "terraform.tfstate")
	b, err := os.ReadFile(backendPath)
	if os.IsNotExist(err) {
		return nil
	}
	if err != nil {
		return fmt.Errorf("read Terraform backend metadata: %w", err)
	}
	var metadata struct {
		Backend *struct {
			Type string `json:"type"`
		} `json:"backend"`
	}
	if err := json.Unmarshal(b, &metadata); err != nil {
		return fmt.Errorf("inspect Terraform backend metadata: %w", err)
	}
	if metadata.Backend == nil || metadata.Backend.Type == "" || metadata.Backend.Type == "local" {
		return nil
	}

	// Older installations may still point at a non-local backend. Ask
	// Terraform for that authoritative state rather than assuming it is empty.
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, "terraform", "state", "pull")
	cmd.Dir = tfDir
	cmd.Env = append(os.Environ(), "TF_IN_AUTOMATION=1", "TF_INPUT=0")
	var output bytes.Buffer
	cmd.Stdout = &output
	cmd.Stderr = &output
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("cannot verify deployed labs in %s backend: %w: %s", metadata.Backend.Type, err, strings.TrimSpace(output.String()))
	}
	deployed, err := managedResources(output.Bytes())
	if err != nil {
		return fmt.Errorf("inspect Terraform state from %s backend: %w", metadata.Backend.Type, err)
	}
	if len(deployed) > 0 {
		return deployedLabsError(deployed)
	}
	return nil
}

func managedResources(b []byte) ([]string, error) {
	if len(bytes.TrimSpace(b)) == 0 {
		return nil, fmt.Errorf("state is empty")
	}
	var state struct {
		Version   int `json:"version"`
		Resources []struct {
			Module    string            `json:"module"`
			Mode      string            `json:"mode"`
			Type      string            `json:"type"`
			Name      string            `json:"name"`
			Instances []json.RawMessage `json:"instances"`
		} `json:"resources"`
	}
	if err := json.Unmarshal(b, &state); err != nil {
		return nil, err
	}
	if state.Version == 0 {
		return nil, fmt.Errorf("unrecognized state format")
	}
	var deployed []string
	for _, r := range state.Resources {
		if r.Mode == "data" || len(r.Instances) == 0 {
			continue
		}
		address := r.Type + "." + r.Name
		if r.Module != "" {
			address = r.Module + "." + address
		}
		deployed = append(deployed, address)
	}
	sort.Strings(deployed)
	return deployed, nil
}

func deployedLabsError(deployed []string) error {
	display := deployed
	if len(display) > 3 {
		display = display[:3]
	}
	message := strings.Join(display, ", ")
	if len(deployed) > len(display) {
		message += fmt.Sprintf(" (and %d more)", len(deployed)-len(display))
	}
	return fmt.Errorf("refusing update: deployed labs remain in Terraform state: %s; run `so-aws-lab destroy` first", message)
}

type semver struct {
	major string
	minor string
	patch string
	pre   []string
}

func compareSemver(a, b string) (int, error) {
	av, err := parseSemver(a)
	if err != nil {
		return 0, err
	}
	bv, err := parseSemver(b)
	if err != nil {
		return 0, err
	}
	for _, pair := range [][2]string{{av.major, bv.major}, {av.minor, bv.minor}, {av.patch, bv.patch}} {
		if cmp := compareNumeric(pair[0], pair[1]); cmp != 0 {
			return cmp, nil
		}
	}
	if len(av.pre) == 0 && len(bv.pre) > 0 {
		return 1, nil
	}
	if len(av.pre) > 0 && len(bv.pre) == 0 {
		return -1, nil
	}
	for i := 0; i < len(av.pre) && i < len(bv.pre); i++ {
		aNumeric := allDigits(av.pre[i])
		bNumeric := allDigits(bv.pre[i])
		switch {
		case aNumeric && bNumeric:
			if cmp := compareNumeric(av.pre[i], bv.pre[i]); cmp != 0 {
				return cmp, nil
			}
		case aNumeric:
			return -1, nil
		case bNumeric:
			return 1, nil
		default:
			if av.pre[i] < bv.pre[i] {
				return -1, nil
			}
			if av.pre[i] > bv.pre[i] {
				return 1, nil
			}
		}
	}
	if len(av.pre) < len(bv.pre) {
		return -1, nil
	}
	if len(av.pre) > len(bv.pre) {
		return 1, nil
	}
	return 0, nil
}

func parseSemver(s string) (semver, error) {
	s = strings.TrimPrefix(strings.TrimSpace(s), "v")
	s, build, hasBuild := strings.Cut(s, "+")
	if hasBuild {
		if build == "" || strings.Contains(build, "+") {
			return semver{}, fmt.Errorf("invalid build metadata")
		}
		for _, p := range strings.Split(build, ".") {
			if p == "" || !allSemverIdentifier(p) {
				return semver{}, fmt.Errorf("invalid build metadata")
			}
		}
	}
	core, pre, _ := strings.Cut(s, "-")
	parts := strings.Split(core, ".")
	if len(parts) != 3 {
		return semver{}, fmt.Errorf("expected major.minor.patch")
	}
	for _, p := range parts {
		if p == "" || (len(p) > 1 && p[0] == '0') || !allDigits(p) {
			return semver{}, fmt.Errorf("invalid numeric component")
		}
	}
	v := semver{major: parts[0], minor: parts[1], patch: parts[2]}
	if pre == "" {
		if strings.Contains(s, "-") {
			return semver{}, fmt.Errorf("empty prerelease")
		}
		return v, nil
	}
	v.pre = strings.Split(pre, ".")
	for _, p := range v.pre {
		if p == "" || !allSemverIdentifier(p) || (len(p) > 1 && p[0] == '0' && allDigits(p)) {
			return semver{}, fmt.Errorf("invalid prerelease identifier")
		}
	}
	return v, nil
}

func compareNumeric(a, b string) int {
	if len(a) < len(b) {
		return -1
	}
	if len(a) > len(b) {
		return 1
	}
	return strings.Compare(a, b)
}

func allDigits(s string) bool {
	for _, c := range s {
		if c < '0' || c > '9' {
			return false
		}
	}
	return true
}

func allSemverIdentifier(s string) bool {
	for _, c := range s {
		if !((c >= '0' && c <= '9') || (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || c == '-') {
			return false
		}
	}
	return true
}
