// Package awsconfig writes role-assuming profiles into ~/.aws/config for the
// entry role of each deployed lab, so operators can just run
// `aws --profile <lab>-carl ...` instead of juggling assume-role tokens.
//
// It only ever touches its OWN blocks, delimited by sentinel comments:
//
//	# >>> so-aws-lab managed: <lab> >>>
//	[profile so-aws-lab-<lab>-carl]
//	role_arn = ...
//	source_profile = ...
//	region = ...
//	role_session_name = ...
//	# <<< so-aws-lab managed: <lab> <<<
//
// Everything outside those blocks is preserved byte-for-byte. Sync replaces the
// full managed set in one shot, so disabling/destroying a lab removes its
// profile automatically.
package awsconfig

import (
	"fmt"
	"os"
	"os/user"
	"path/filepath"
	"strings"
)

const (
	startPrefix = "# >>> so-aws-lab managed:"
	endPrefix   = "# <<< so-aws-lab managed:"
)

// Profile is one role-assuming entry to write.
type Profile struct {
	Lab           string // lab slug, used only for the managed-block marker
	Name          string // profile name, e.g. so-aws-lab-createpolicyversion-carl
	RoleARN       string
	SourceProfile string
	Region        string
	SessionName   string
}

// Path returns the AWS config file path, honoring AWS_CONFIG_FILE.
func Path() (string, error) {
	if p := os.Getenv("AWS_CONFIG_FILE"); p != "" {
		return p, nil
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(home, ".aws", "config"), nil
}

// Sync rewrites the so-aws-lab managed blocks in ~/.aws/config to exactly
// `profiles`, leaving all other content untouched. Passing nil/empty removes
// every managed block. Returns the number of profiles written.
func Sync(profiles []Profile) (int, error) {
	p, err := Path()
	if err != nil {
		return 0, err
	}
	var content string
	if b, err := os.ReadFile(p); err == nil {
		content = string(b)
	} else if !os.IsNotExist(err) {
		return 0, err
	}

	base := strings.TrimRight(stripManaged(content), "\n")

	var sb strings.Builder
	sb.WriteString(base)
	if base != "" {
		sb.WriteString("\n")
	}
	for _, pr := range profiles {
		sb.WriteString(renderBlock(pr))
	}

	if err := os.MkdirAll(filepath.Dir(p), 0o700); err != nil {
		return 0, err
	}
	if err := os.WriteFile(p, []byte(sb.String()), 0o600); err != nil {
		return 0, err
	}
	return len(profiles), nil
}

// stripManaged removes every so-aws-lab managed block from content, matching on
// the sentinel comment prefixes so slug/whitespace variations don't matter.
func stripManaged(content string) string {
	if content == "" {
		return ""
	}
	lines := strings.Split(content, "\n")
	out := make([]string, 0, len(lines))
	skipping := false
	for _, ln := range lines {
		t := strings.TrimSpace(ln)
		switch {
		case strings.HasPrefix(t, startPrefix):
			skipping = true
		case strings.HasPrefix(t, endPrefix):
			skipping = false
		case !skipping:
			out = append(out, ln)
		}
	}
	return strings.Join(out, "\n")
}

func renderBlock(p Profile) string {
	var b strings.Builder
	fmt.Fprintf(&b, "\n%s %s >>>\n", startPrefix, p.Lab)
	fmt.Fprintf(&b, "[profile %s]\n", p.Name)
	fmt.Fprintf(&b, "role_arn = %s\n", p.RoleARN)
	fmt.Fprintf(&b, "source_profile = %s\n", p.SourceProfile)
	if p.Region != "" {
		fmt.Fprintf(&b, "region = %s\n", p.Region)
	}
	if p.SessionName != "" {
		fmt.Fprintf(&b, "role_session_name = %s\n", p.SessionName)
	}
	fmt.Fprintf(&b, "%s %s <<<\n", endPrefix, p.Lab)
	return b.String()
}

// CurrentSessionName returns a role_session_name derived from the current OS
// user — the value that shows up in CloudTrail as assumed-role/<role>/<name>,
// so lab activity is attributable. Sanitized to the STS-allowed charset
// ([\w+=,.@-], 2–64 chars); falls back to the numeric UID, then "so-aws-lab".
func CurrentSessionName() string {
	if u, err := user.Current(); err == nil {
		name := u.Username
		// Strip any DOMAIN\user or path-ish prefix.
		if i := strings.LastIndexAny(name, `\/`); i >= 0 {
			name = name[i+1:]
		}
		if s := sanitizeSessionName(name); s != "" {
			return s
		}
		if s := sanitizeSessionName(u.Uid); s != "" {
			return s
		}
	}
	if env := os.Getenv("USER"); env != "" {
		if s := sanitizeSessionName(env); s != "" {
			return s
		}
	}
	return "so-aws-lab"
}

// sanitizeSessionName maps s onto the STS role_session_name charset, collapsing
// runs of disallowed characters to a single '-' and clamping to 2–64 chars.
func sanitizeSessionName(s string) string {
	var b strings.Builder
	lastDash := false
	for _, r := range s {
		ok := (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') ||
			(r >= '0' && r <= '9') || strings.ContainsRune("+=,.@-_", r)
		if ok {
			b.WriteRune(r)
			lastDash = false
		} else if !lastDash {
			b.WriteByte('-')
			lastDash = true
		}
	}
	out := strings.Trim(b.String(), "-")
	if len(out) > 64 {
		out = out[:64]
	}
	if len(out) < 2 {
		return ""
	}
	return out
}
