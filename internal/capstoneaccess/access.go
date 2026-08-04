// Package capstoneaccess creates temporary console login profiles and printable
// access cards for the workshop-only, multi-student capstone.
package capstoneaccess

import (
	"bytes"
	"crypto/rand"
	"encoding/json"
	"fmt"
	"html/template"
	"math/big"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

// Shared read-only BloodHound instance handed to every attendee. The same
// credential appears on every card by design: the instance is pre-loaded with
// GoAWSHound data for the capstone accounts and grants no AWS access.
const (
	bloodhoundURL      = "https://bloodhound.stormchaser.cloud"
	bloodhoundUser     = "demo"
	bloodhoundPassword = "BHUSA2026demo!"
)

// Student describes one deployed workshop bootstrap identity. It contains no
// credentials; Generate creates a fresh console password for it.
type Student struct {
	ID               string
	Label            string
	UserName         string
	EntryRoleARN     string
	ConsoleSigninURL string
}

// Result reports the private card artifact written by Generate.
type Result struct {
	Path  string
	Count int
}

type issuer struct {
	profile string
	region  string
}

type loginProfileInput struct {
	UserName              string `json:"UserName"`
	Password              string `json:"Password"`
	PasswordResetRequired bool   `json:"PasswordResetRequired"`
}

type card struct {
	Student
	Password      string
	RoleName      string
	SwitchRoleURL string
}

type cardPage struct {
	GeneratedAt        string
	Region             string
	BloodhoundURL      string
	BloodhoundUser     string
	BloodhoundPassword string
	Cards              []card
}

// Generate verifies all Terraform-managed IAM users, creates or rotates their
// console passwords, and writes a mode-0600 self-contained HTML card sheet.
// Passwords are sent to AWS through a temporary mode-0600 JSON file and are
// never written to stdout or Terraform state.
func Generate(profile, region, outputPath string, students []Student) (Result, error) {
	if profile == "" {
		return Result{}, fmt.Errorf("dev AWS profile is required")
	}
	if region == "" {
		return Result{}, fmt.Errorf("dev AWS region is required")
	}
	if len(students) == 0 {
		return Result{}, fmt.Errorf("the deployed capstone roster is empty")
	}
	if _, err := exec.LookPath("aws"); err != nil {
		return Result{}, fmt.Errorf("find AWS CLI: %w", err)
	}

	sorted := append([]Student(nil), students...)
	sort.Slice(sorted, func(i, j int) bool { return sorted[i].ID < sorted[j].ID })
	for _, student := range sorted {
		if student.ID == "" || student.UserName == "" || student.EntryRoleARN == "" || student.ConsoleSigninURL == "" {
			return Result{}, fmt.Errorf("student %q is missing a deployed bootstrap identifier", student.ID)
		}
	}
	preparedOutput, err := prepareOutputPath(outputPath)
	if err != nil {
		return Result{}, err
	}

	aws := issuer{profile: profile, region: region}
	// Preflight the complete roster before rotating any password. This avoids a
	// predictable partial rotation when access-cards is run before apply.
	for _, student := range sorted {
		if err := aws.verifyUser(student.UserName); err != nil {
			return Result{}, err
		}
	}

	cards := make([]card, 0, len(sorted))
	for _, student := range sorted {
		password, err := generatePassword()
		if err != nil {
			return Result{}, fmt.Errorf("generate password for %s: %w", student.ID, err)
		}
		if err := aws.putLoginProfile(student.UserName, password); err != nil {
			return Result{}, err
		}

		roleName, err := roleName(student.EntryRoleARN)
		if err != nil {
			return Result{}, err
		}
		switchURL := switchRoleURL(student.EntryRoleARN, roleName)
		if student.Label == "" {
			student.Label = student.ID
		}
		cards = append(cards, card{
			Student:       student,
			Password:      password,
			RoleName:      roleName,
			SwitchRoleURL: switchURL,
		})
	}

	path, err := writeCards(preparedOutput, cardPage{
		GeneratedAt:        time.Now().Format(time.RFC3339),
		Region:             region,
		BloodhoundURL:      bloodhoundURL,
		BloodhoundUser:     bloodhoundUser,
		BloodhoundPassword: bloodhoundPassword,
		Cards:              cards,
	})
	if err != nil {
		return Result{}, err
	}
	return Result{Path: path, Count: len(cards)}, nil
}

func (i issuer) verifyUser(userName string) error {
	if output, err := i.run("iam", "get-user", "--user-name", userName); err != nil {
		return fmt.Errorf("verify workshop user %s: %w: %s", userName, err, output)
	}
	return nil
}

func (i issuer) putLoginProfile(userName, password string) error {
	lookupOutput, err := i.run("iam", "get-login-profile", "--user-name", userName)
	action := "update-login-profile"
	if err != nil {
		if !strings.Contains(lookupOutput, "NoSuchEntity") {
			return fmt.Errorf("inspect login profile for %s: %w: %s", userName, err, lookupOutput)
		}
		action = "create-login-profile"
	}

	input, err := json.Marshal(loginProfileInput{
		UserName:              userName,
		Password:              password,
		PasswordResetRequired: false,
	})
	if err != nil {
		return fmt.Errorf("encode login profile for %s: %w", userName, err)
	}
	f, err := os.CreateTemp("", "so-aws-lab-login-profile-*.json")
	if err != nil {
		return fmt.Errorf("create private login profile input: %w", err)
	}
	tempPath := f.Name()
	defer os.Remove(tempPath)
	if err := f.Chmod(0o600); err != nil {
		f.Close()
		return fmt.Errorf("secure login profile input: %w", err)
	}
	if _, err := f.Write(input); err != nil {
		f.Close()
		return fmt.Errorf("write login profile input: %w", err)
	}
	if err := f.Close(); err != nil {
		return fmt.Errorf("close login profile input: %w", err)
	}

	output, err := i.run("iam", action, "--cli-input-json", "file://"+tempPath)
	if err != nil {
		return fmt.Errorf("%s for %s: %w: %s", action, userName, err, output)
	}
	return nil
}

func (i issuer) run(args ...string) (string, error) {
	args = append(args, "--profile", i.profile, "--output", "json", "--no-cli-pager")
	if i.region != "" {
		args = append(args, "--region", i.region)
	}
	cmd := exec.Command("aws", args...)
	var output bytes.Buffer
	cmd.Stdout = &output
	cmd.Stderr = &output
	err := cmd.Run()
	return strings.TrimSpace(output.String()), err
}

func roleName(arn string) (string, error) {
	const marker = ":role/"
	i := strings.Index(arn, marker)
	if i < 0 || i+len(marker) == len(arn) {
		return "", fmt.Errorf("invalid entry role ARN %q", arn)
	}
	name := arn[i+len(marker):]
	if strings.Contains(name, "/") {
		return "", fmt.Errorf("entry role %q uses a path unsupported by console role switching", arn)
	}
	return name, nil
}

func switchRoleURL(roleARN, name string) string {
	parts := strings.Split(roleARN, ":")
	accountID := ""
	if len(parts) > 4 {
		accountID = parts[4]
	}
	u := url.URL{Scheme: "https", Host: "signin.aws.amazon.com", Path: "/switchrole"}
	q := u.Query()
	q.Set("account", accountID)
	q.Set("roleName", name)
	u.RawQuery = q.Encode()
	return u.String()
}

func generatePassword() (string, error) {
	selected := make([]string, 4)
	for i := range selected {
		n, err := rand.Int(rand.Reader, big.NewInt(int64(len(passwordWords))))
		if err != nil {
			return "", err
		}
		selected[i] = passwordWords[n.Int64()]
	}
	n, err := rand.Int(rand.Reader, big.NewInt(90))
	if err != nil {
		return "", err
	}
	selected[0] = strings.ToUpper(selected[0][:1]) + selected[0][1:]
	return fmt.Sprintf("%s-%s-%s-%s-%02d!", selected[0], selected[1], selected[2], selected[3], n.Int64()+10), nil
}

var passwordWords = []string{
	"amber", "apple", "atlas", "baker", "beacon", "birch", "bison", "blue",
	"bravo", "cedar", "chess", "cider", "cloud", "cobalt", "comet", "coral",
	"delta", "ember", "falcon", "fern", "fjord", "forest", "frost", "garden",
	"globe", "granite", "harbor", "hazel", "indigo", "island", "jade", "jupiter",
	"kiwi", "lake", "lemon", "lilac", "lunar", "mango", "maple", "marble",
	"meadow", "mercury", "mint", "nova", "ocean", "olive", "onyx", "orbit",
	"otter", "pearl", "pine", "pixel", "pluto", "quartz", "raven", "river",
	"robin", "sable", "saturn", "silver", "solar", "spruce", "stone", "tango",
	"tiger", "topaz", "ultra", "venus", "violet", "willow", "winter", "zebra",
}

func writeCards(outputPath string, page cardPage) (string, error) {
	absolute, err := prepareOutputPath(outputPath)
	if err != nil {
		return "", err
	}
	dir := filepath.Dir(absolute)

	var rendered bytes.Buffer
	if err := accessCardTemplate.Execute(&rendered, page); err != nil {
		return "", fmt.Errorf("render access cards: %w", err)
	}
	f, err := os.CreateTemp(dir, ".capstone-access-cards-*.html")
	if err != nil {
		return "", fmt.Errorf("create private access-card file: %w", err)
	}
	tempPath := f.Name()
	defer os.Remove(tempPath)
	if err := f.Chmod(0o600); err != nil {
		f.Close()
		return "", fmt.Errorf("secure access-card file: %w", err)
	}
	if _, err := f.Write(rendered.Bytes()); err != nil {
		f.Close()
		return "", fmt.Errorf("write access cards: %w", err)
	}
	if err := f.Close(); err != nil {
		return "", fmt.Errorf("close access cards: %w", err)
	}
	if err := os.Rename(tempPath, absolute); err != nil {
		return "", fmt.Errorf("publish access cards: %w", err)
	}
	return absolute, nil
}

func prepareOutputPath(outputPath string) (string, error) {
	if outputPath == "" {
		return "", fmt.Errorf("access-card output path is required")
	}
	absolute, err := filepath.Abs(outputPath)
	if err != nil {
		return "", fmt.Errorf("resolve access-card output: %w", err)
	}
	dir := filepath.Dir(absolute)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return "", fmt.Errorf("create access-card directory: %w", err)
	}
	f, err := os.CreateTemp(dir, ".capstone-access-cards-preflight-*")
	if err != nil {
		return "", fmt.Errorf("verify access-card output: %w", err)
	}
	tempPath := f.Name()
	if err := f.Close(); err != nil {
		os.Remove(tempPath)
		return "", fmt.Errorf("verify access-card output: %w", err)
	}
	if err := os.Remove(tempPath); err != nil {
		return "", fmt.Errorf("clean access-card output preflight: %w", err)
	}
	return absolute, nil
}

var accessCardTemplate = template.Must(template.New("cards").Parse(`<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>AWS capstone access cards</title>
<style>
  :root { color-scheme: light; font-family: Arial, Helvetica, sans-serif; }
  body { margin: 0; color: #111827; background: #f3f4f6; }
  .notice { max-width: 8in; margin: .25in auto; padding: .15in .2in; border: 2px solid #991b1b; background: #fff; }
  .notice strong { color: #991b1b; }
  .sheet { display: grid; grid-template-columns: 1fr 1fr; gap: .18in; max-width: 8in; margin: .2in auto; }
  .card { break-inside: avoid; min-height: 4.25in; border: 2px solid #111827; border-radius: 10px; padding: .18in; background: #fff; }
  h1 { margin: 0 0 .04in; font-size: 20px; }
  h2 { margin: 0 0 .14in; font-size: 14px; font-weight: normal; color: #4b5563; }
  .field { margin: .08in 0; }
  .field span { display: block; color: #4b5563; font-size: 10px; text-transform: uppercase; letter-spacing: .04em; }
  code { font-family: "SFMono-Regular", Consolas, monospace; font-size: 12px; overflow-wrap: anywhere; }
  a { color: inherit; }
  .password code { font-size: 16px; font-weight: bold; }
  .bloodhound { margin-top: .12in; border: 1px solid #111827; border-radius: 6px; padding: .08in .1in; background: #f9fafb; }
  .bloodhound h3 { margin: 0 0 .04in; font-size: 11px; text-transform: uppercase; letter-spacing: .04em; }
  .bloodhound .field { margin: .04in 0; }
  ol { margin: .12in 0 0 .2in; padding: 0; font-size: 11px; line-height: 1.35; }
  .footer { margin-top: .12in; border-top: 1px solid #d1d5db; padding-top: .08in; font-size: 9px; color: #4b5563; }
  @media print {
    @page { size: letter; margin: .3in; }
    body { background: #fff; }
    .notice { margin: 0 auto .15in; }
    .sheet { margin: 0 auto; }
  }
</style>
</head>
<body>
<section class="notice">
  <strong>Instructor secret:</strong> this file contains active console passwords.
  Print it, distribute one card per attendee, and securely delete it after the workshop.
  Running <code>access-cards</code> again rotates every password and invalidates older cards.
</section>
<main class="sheet">
{{range .Cards}}
<article class="card">
  <h1>AWS for Red Teamers</h1>
  <h2>Capstone access card: {{.Label}}</h2>
  <div class="field"><span>Student ID</span><code>{{.ID}}</code></div>
  <div class="field"><span>IAM username</span><code>{{.UserName}}</code></div>
  <div class="field password"><span>Workshop password</span><code>{{.Password}}</code></div>
  <div class="bloodhound">
    <h3>BloodHound (read-only, shared)</h3>
    <div class="field"><span>URL</span><a href="{{$.BloodhoundURL}}"><code>{{$.BloodhoundURL}}</code></a></div>
    <div class="field"><span>Username</span><code>{{$.BloodhoundUser}}</code></div>
    <div class="field"><span>Password</span><code>{{$.BloodhoundPassword}}</code></div>
  </div>
  <ol>
    <li>Open the sign-in URL below and enter the username and password above.</li>
    <li>Open the role-switch URL below. It is prefilled for <code>{{.RoleName}}</code>.</li>
    <li>Choose <strong>Switch Role</strong>, then open AWS CloudShell in <code>{{$.Region}}</code>.</li>
    <li>Run <code>aws sts get-caller-identity</code>. The ARN must contain <code>assumed-role/{{.RoleName}}/</code>.</li>
  </ol>
  <div class="footer">
    Sign in: <a href="{{.ConsoleSigninURL}}"><code>{{.ConsoleSigninURL}}</code></a><br>
    Switch role: <a href="{{.SwitchRoleURL}}"><code>{{.SwitchRoleURL}}</code></a>
  </div>
</article>
{{end}}
</main>
<!-- Generated {{.GeneratedAt}}. Treat this file as a credential artifact. -->
</body>
</html>
`))
