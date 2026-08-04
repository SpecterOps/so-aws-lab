package updater

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"crypto/sha256"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/specterops/so-aws-lab/internal/workspace"
)

func TestRunInstallsNewerRelease(t *testing.T) {
	archive := testArchive(t, []byte("new binary"))
	server := testReleaseServer(t, "v1.2.0", archive, false)

	dir := t.TempDir()
	executable := filepath.Join(dir, "so-aws-lab")
	if err := os.WriteFile(executable, []byte("old binary"), 0o755); err != nil {
		t.Fatal(err)
	}
	var output bytes.Buffer
	u := &updater{
		CurrentVersion: "1.1.0",
		LatestURL:      server.URL + "/latest",
		Client:         server.Client(),
		Executable:     executable,
		WorkspaceRoot:  filepath.Join(dir, "workspace"),
		GOOS:           "darwin",
		GOARCH:         "arm64",
		Stdout:         &output,
	}
	if err := u.run(); err != nil {
		t.Fatal(err)
	}
	got, err := os.ReadFile(executable)
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != "new binary" {
		t.Fatalf("installed binary = %q", got)
	}
	if !strings.Contains(output.String(), "1.1.0 -> v1.2.0") {
		t.Fatalf("output = %q", output.String())
	}
}

func TestRunRefusesUpdateWithDeployedLabs(t *testing.T) {
	archive := testArchive(t, []byte("new binary"))
	archiveRequests := 0
	server := testReleaseServerWithArchiveCount(t, "v1.2.0", archive, false, &archiveRequests)

	dir := t.TempDir()
	executable := filepath.Join(dir, "so-aws-lab")
	if err := os.WriteFile(executable, []byte("old binary"), 0o755); err != nil {
		t.Fatal(err)
	}
	tfDir := workspace.TerraformDir(filepath.Join(dir, "workspace"))
	if err := os.MkdirAll(tfDir, 0o700); err != nil {
		t.Fatal(err)
	}
	state := `{"version":4,"resources":[{"mode":"managed","type":"aws_iam_role","name":"entry","instances":[{}]}]}`
	if err := os.WriteFile(filepath.Join(tfDir, "terraform.tfstate"), []byte(state), 0o600); err != nil {
		t.Fatal(err)
	}
	u := &updater{
		CurrentVersion: "1.1.0",
		LatestURL:      server.URL + "/latest",
		Client:         server.Client(),
		Executable:     executable,
		WorkspaceRoot:  filepath.Join(dir, "workspace"),
		GOOS:           "darwin",
		GOARCH:         "arm64",
		Stdout:         ioDiscard{},
	}
	err := u.run()
	if err == nil || !strings.Contains(err.Error(), "deployed labs remain") {
		t.Fatalf("error = %v", err)
	}
	if archiveRequests != 0 {
		t.Fatalf("downloaded %d assets before deployment check", archiveRequests)
	}
	got, err := os.ReadFile(executable)
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != "old binary" {
		t.Fatalf("deployed state did not preserve installed binary: %q", got)
	}
}

func TestRunDoesNotInspectStateWhenAlreadyCurrent(t *testing.T) {
	server := testReleaseServer(t, "v1.1.0", testArchive(t, []byte("unused")), false)
	dir := t.TempDir()
	executable := filepath.Join(dir, "so-aws-lab")
	if err := os.WriteFile(executable, []byte("old binary"), 0o755); err != nil {
		t.Fatal(err)
	}
	u := &updater{
		CurrentVersion: "v1.1.0",
		LatestURL:      server.URL + "/latest",
		Client:         server.Client(),
		Executable:     executable,
		WorkspaceRoot:  filepath.Join(dir, "corrupt-workspace"),
		GOOS:           "darwin",
		GOARCH:         "arm64",
		Stdout:         ioDiscard{},
	}
	if err := u.run(); err != nil {
		t.Fatal(err)
	}
}

func TestRunRejectsBadChecksum(t *testing.T) {
	archive := testArchive(t, []byte("new binary"))
	server := testReleaseServer(t, "v1.2.0", archive, true)
	dir := t.TempDir()
	executable := filepath.Join(dir, "so-aws-lab")
	if err := os.WriteFile(executable, []byte("old binary"), 0o755); err != nil {
		t.Fatal(err)
	}
	u := &updater{
		CurrentVersion: "1.1.0",
		LatestURL:      server.URL + "/latest",
		Client:         server.Client(),
		Executable:     executable,
		WorkspaceRoot:  filepath.Join(dir, "workspace"),
		GOOS:           "darwin",
		GOARCH:         "arm64",
		Stdout:         ioDiscard{},
	}
	if err := u.run(); err == nil || !strings.Contains(err.Error(), "checksum mismatch") {
		t.Fatalf("error = %v", err)
	}
	got, err := os.ReadFile(executable)
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != "old binary" {
		t.Fatalf("bad checksum did not preserve installed binary: %q", got)
	}
}

func TestVerifyNoDeployedLabsAllowsDataOnlyState(t *testing.T) {
	root := t.TempDir()
	tfDir := workspace.TerraformDir(root)
	if err := os.MkdirAll(tfDir, 0o700); err != nil {
		t.Fatal(err)
	}
	state := `{"version":4,"resources":[{"mode":"data","type":"aws_caller_identity","name":"current","instances":[{}]}]}`
	if err := os.WriteFile(filepath.Join(tfDir, "terraform.tfstate"), []byte(state), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := verifyNoDeployedLabs(root); err != nil {
		t.Fatal(err)
	}
}

func TestCompareSemver(t *testing.T) {
	for _, tt := range []struct {
		a, b string
		want int
	}{
		{a: "v1.2.3", b: "1.2.2", want: 1},
		{a: "1.2.3", b: "1.2.3-rc.1", want: 1},
		{a: "1.2.3-rc.10", b: "1.2.3-rc.2", want: 1},
		{a: "1.2.3+build.2", b: "v1.2.3+build.1", want: 0},
	} {
		got, err := compareSemver(tt.a, tt.b)
		if err != nil {
			t.Fatal(err)
		}
		if got != tt.want {
			t.Errorf("compareSemver(%q, %q) = %d, want %d", tt.a, tt.b, got, tt.want)
		}
	}
}

type ioDiscard struct{}

func (ioDiscard) Write(p []byte) (int, error) { return len(p), nil }

func testArchive(t *testing.T, binary []byte) []byte {
	t.Helper()
	var archive bytes.Buffer
	zw := gzip.NewWriter(&archive)
	tw := tar.NewWriter(zw)
	if err := tw.WriteHeader(&tar.Header{Name: "so-aws-lab", Typeflag: tar.TypeReg, Mode: 0o755, Size: int64(len(binary))}); err != nil {
		t.Fatal(err)
	}
	if _, err := tw.Write(binary); err != nil {
		t.Fatal(err)
	}
	if err := tw.Close(); err != nil {
		t.Fatal(err)
	}
	if err := zw.Close(); err != nil {
		t.Fatal(err)
	}
	return archive.Bytes()
}

func testReleaseServer(t *testing.T, tag string, archive []byte, badChecksum bool) *httptest.Server {
	t.Helper()
	return testReleaseServerWithArchiveCount(t, tag, archive, badChecksum, nil)
}

func testReleaseServerWithArchiveCount(t *testing.T, tag string, archive []byte, badChecksum bool, archiveRequests *int) *httptest.Server {
	t.Helper()
	var server *httptest.Server
	server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/latest":
			fmt.Fprintf(w, `{"tag_name":%q,"assets":[{"name":"so-aws-lab_darwin_arm64.tar.gz","browser_download_url":%q},{"name":"checksums.txt","browser_download_url":%q}]}`,
				tag, server.URL+"/archive", server.URL+"/checksums")
		case "/archive":
			if archiveRequests != nil {
				(*archiveRequests)++
			}
			w.Write(archive)
		case "/checksums":
			sum := fmt.Sprintf("%x", sha256.Sum256(archive))
			if badChecksum {
				sum = strings.Repeat("0", sha256.Size*2)
			}
			fmt.Fprintf(w, "%s  so-aws-lab_darwin_arm64.tar.gz\n", sum)
		default:
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(server.Close)
	return server
}
