package capstoneaccess

import (
	"encoding/json"
	"html/template"
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"testing"
)

func TestGeneratePasswordMeetsWorkshopShape(t *testing.T) {
	seen := map[string]bool{}
	shape := regexp.MustCompile(`^[A-Z][a-z]+-[a-z]+-[a-z]+-[a-z]+-[0-9]{2}!$`)
	for range 100 {
		password, err := generatePassword()
		if err != nil {
			t.Fatal(err)
		}
		if !shape.MatchString(password) {
			t.Fatalf("password %q does not match the printable workshop shape", password)
		}
		if seen[password] {
			t.Fatalf("generated duplicate password %q", password)
		}
		seen[password] = true
	}
}

func TestRoleNameAndSwitchURL(t *testing.T) {
	arn := "arn:aws:iam::111122223333:role/so-aws-lab-capstone-student01-carl"
	name, err := roleName(arn)
	if err != nil {
		t.Fatal(err)
	}
	if name != "so-aws-lab-capstone-student01-carl" {
		t.Fatalf("role name = %q", name)
	}
	got := switchRoleURL(arn, name)
	for _, want := range []string{
		"https://signin.aws.amazon.com/switchrole?",
		"account=111122223333",
		"roleName=so-aws-lab-capstone-student01-carl",
	} {
		if !strings.Contains(got, want) {
			t.Fatalf("switch role URL %q is missing %q", got, want)
		}
	}
}

func TestWriteCardsIsPrivateAndEscapesLabels(t *testing.T) {
	path := filepath.Join(t.TempDir(), "cards.html")
	got, err := writeCards(path, cardPage{
		GeneratedAt: "2026-07-27T12:00:00Z",
		Cards: []card{{
			Student: Student{
				ID:               "student01",
				Label:            "<script>alert(1)</script>",
				UserName:         "workshop-capstone-student01-student",
				EntryRoleARN:     "arn:aws:iam::111122223333:role/workshop-capstone-student01-carl",
				ConsoleSigninURL: "https://111122223333.signin.aws.amazon.com/console/",
			},
			Password:      "Amber-river-cobalt-mango-42!",
			RoleName:      "workshop-capstone-student01-carl",
			SwitchRoleURL: "https://signin.aws.amazon.com/switchrole?account=111122223333&roleName=workshop-capstone-student01-carl",
			SigninQR:      template.URL("data:image/png;base64,AA=="),
			SwitchRoleQR:  template.URL("data:image/png;base64,AA=="),
		}},
	})
	if err != nil {
		t.Fatal(err)
	}
	if got != path {
		t.Fatalf("path = %q, want %q", got, path)
	}
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("mode = %o, want 600", info.Mode().Perm())
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	html := string(raw)
	if strings.Contains(html, "<script>alert(1)</script>") {
		t.Fatal("student label was not HTML escaped")
	}
	for _, want := range []string{
		"&lt;script&gt;alert(1)&lt;/script&gt;",
		"Amber-river-cobalt-mango-42!",
		"workshop-capstone-student01-carl",
		`src="data:image/png;base64,AA=="`,
	} {
		if !strings.Contains(html, want) {
			t.Errorf("card HTML is missing %q", want)
		}
	}
}

func TestGenerateCreatesLoginProfileAndCardsWithoutTerraformSecrets(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("fake AWS CLI uses a POSIX shell")
	}
	temp := t.TempDir()
	fakeAWS := filepath.Join(temp, "aws")
	capture := filepath.Join(temp, "login-profile.json")
	script := `#!/bin/sh
case "$2" in
  get-user)
    exit 0
    ;;
  get-login-profile)
    echo "An error occurred (NoSuchEntity)" >&2
    exit 254
    ;;
  create-login-profile)
    for arg in "$@"; do
      case "$arg" in
        file://*) cp "${arg#file://}" "$AWS_FAKE_CAPTURE" ;;
      esac
    done
    exit 0
    ;;
esac
echo "unexpected fake AWS CLI command: $*" >&2
exit 2
`
	if err := os.WriteFile(fakeAWS, []byte(script), 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", temp+string(os.PathListSeparator)+os.Getenv("PATH"))
	t.Setenv("AWS_FAKE_CAPTURE", capture)

	output := filepath.Join(temp, "cards.html")
	result, err := Generate("dev-admin", "us-east-1", output, []Student{{
		ID:               "student01",
		Label:            "Alice",
		UserName:         "workshop-capstone-student01-student",
		EntryRoleARN:     "arn:aws:iam::111122223333:role/workshop-capstone-student01-carl",
		ConsoleSigninURL: "https://111122223333.signin.aws.amazon.com/console/",
	}})
	if err != nil {
		t.Fatal(err)
	}
	if result.Path != output || result.Count != 1 {
		t.Fatalf("result = %#v", result)
	}

	raw, err := os.ReadFile(capture)
	if err != nil {
		t.Fatal(err)
	}
	var input loginProfileInput
	if err := json.Unmarshal(raw, &input); err != nil {
		t.Fatal(err)
	}
	if input.UserName != "workshop-capstone-student01-student" {
		t.Fatalf("user name = %q", input.UserName)
	}
	if input.PasswordResetRequired {
		t.Fatal("workshop password unexpectedly requires an in-session reset")
	}
	if !regexp.MustCompile(`^[A-Z][a-z]+-.+[0-9]{2}!$`).MatchString(input.Password) {
		t.Fatalf("generated password has unexpected shape: %q", input.Password)
	}
	cardHTML, err := os.ReadFile(output)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(cardHTML), input.Password) {
		t.Fatal("access card is missing the issued password")
	}
}
