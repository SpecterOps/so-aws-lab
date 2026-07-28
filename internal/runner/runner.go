// Package runner shells out to terraform with the enable_<lab> vars set
// from the TUI's enabled set.
package runner

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strings"
	"sync"

	"github.com/specterops/so-aws-lab/internal/awsconfig"
	"github.com/specterops/so-aws-lab/internal/config"
	"github.com/specterops/so-aws-lab/internal/labs"
	"github.com/specterops/so-aws-lab/internal/workspace"
)

// Runner ties a config to the local terraform binary.
type Runner struct {
	Cfg     *config.Config
	Labs    []labs.Lab
	Stdout  io.Writer
	Stderr  io.Writer
	Verbose bool // when false, terraform stdout/stderr is captured silently

	mu         sync.Mutex
	lastOutput bytes.Buffer // captured tf output from the most recent quiet apply/destroy
	streamCh   chan<- string
}

func New(cfg *config.Config, ll []labs.Lab) *Runner {
	return &Runner{Cfg: cfg, Labs: ll, Stdout: os.Stdout, Stderr: os.Stderr}
}

// LastOutput returns the captured terraform output from the most recent quiet
// run. Useful for printing on failure or when the user toggles verbose mode
// after the fact.
func (r *Runner) LastOutput() string {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.lastOutput.String()
}

// SetStream wires a channel that receives one terraform output line per send.
// Pass nil to disable streaming. The runner does NOT close the channel; the
// caller owns its lifecycle. Streaming is best-effort — sends are non-blocking
// so terraform never stalls on a slow consumer.
func (r *Runner) SetStream(ch chan<- string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.streamCh = ch
}

// lineStreamWriter tees writes into a captured buffer AND, when a stream
// channel is configured, emits one fully-formed line at a time to it. ANSI
// sequences are kept intact in the captured buffer (the output viewer strips
// them) and forwarded to the channel as-is.
type lineStreamWriter struct {
	mu       sync.Mutex
	captured *bytes.Buffer
	streamCh chan<- string
	buf      []byte
}

func (w *lineStreamWriter) Write(p []byte) (int, error) {
	w.mu.Lock()
	defer w.mu.Unlock()
	w.captured.Write(p)
	if w.streamCh == nil {
		return len(p), nil
	}
	w.buf = append(w.buf, p...)
	for {
		i := bytes.IndexByte(w.buf, '\n')
		if i < 0 {
			break
		}
		line := string(w.buf[:i])
		w.buf = w.buf[i+1:]
		// Non-blocking send; drop lines the consumer can't keep up with.
		select {
		case w.streamCh <- line:
		default:
		}
	}
	return len(p), nil
}

// workshopDir is where main.tf etc live, inside the extracted workspace.
func (r *Runner) workshopDir() string {
	root, err := workspace.Dir()
	if err != nil {
		return ""
	}
	return workspace.TerraformDir(root)
}

func (r *Runner) tfvarsArgs() []string {
	dev := r.Cfg.Primary()
	staging := r.Cfg.Accounts["staging"]
	prod := r.Cfg.Accounts["prod"]
	students, _ := json.Marshal(r.Cfg.Capstone.Students)

	args := []string{}
	args = append(args, "-var", fmt.Sprintf("lab_prefix=%s", r.Cfg.LabPrefix))
	args = append(args, "-var", fmt.Sprintf("dev_profile=%s", dev.Profile))
	args = append(args, "-var", fmt.Sprintf("dev_region=%s", dev.Region))
	args = append(args, "-var", fmt.Sprintf("staging_profile=%s", staging.Profile))
	args = append(args, "-var", fmt.Sprintf("staging_region=%s", staging.Region))
	args = append(args, "-var", fmt.Sprintf("prod_profile=%s", prod.Profile))
	args = append(args, "-var", fmt.Sprintf("prod_region=%s", prod.Region))
	args = append(args, "-var", fmt.Sprintf("capstone_students=%s", students))
	for _, l := range r.Labs {
		v := "false"
		if r.Cfg.Enabled[l.Slug] {
			v = "true"
		}
		args = append(args, "-var", fmt.Sprintf("enable_%s=%s", l.Slug, v))
	}
	return args
}

func (r *Runner) tfCmd(args ...string) *exec.Cmd {
	dev := r.Cfg.Primary()
	c := exec.Command("terraform", args...)
	c.Dir = r.workshopDir()
	c.Env = append(os.Environ(),
		// Ambient creds for terraform itself (provider blocks override per
		// alias). Sets the dev account profile/region as a safe default.
		"AWS_PROFILE="+dev.Profile,
		"AWS_REGION="+dev.Region,
		"AWS_DEFAULT_REGION="+dev.Region,
		"TF_IN_AUTOMATION=1",
		"TF_INPUT=0",
	)
	// In TUI mode (stream channel set) we always tee into the captured
	// buffer AND the channel. In CLI mode (no channel, Verbose true) we
	// stream to stdout/stderr directly; in CLI mode (no channel, Verbose
	// false) we capture silently.
	r.mu.Lock()
	r.lastOutput.Reset()
	ch := r.streamCh
	r.mu.Unlock()
	if ch != nil {
		w := &lineStreamWriter{captured: &r.lastOutput, streamCh: ch}
		c.Stdout = w
		c.Stderr = w
	} else if r.Verbose {
		c.Stdout = io.MultiWriter(r.Stdout, &r.lastOutput)
		c.Stderr = io.MultiWriter(r.Stderr, &r.lastOutput)
	} else {
		c.Stdout = &r.lastOutput
		c.Stderr = &r.lastOutput
	}
	return c
}

// ensureWorkspace extracts the embedded terraform + scripts to disk before any
// terraform run. It is idempotent and cheap, so every Init call refreshes the
// workspace — which is also how upgrading the binary upgrades the terraform.
// Failures are written into the captured output; otherwise the user would see
// a silent failure with nothing to read (terraform never ran).
func (r *Runner) ensureWorkspace() error {
	root, err := workspace.Dir()
	if err == nil {
		err = workspace.Ensure(root)
	}
	if err != nil {
		msg := fmt.Sprintf(
			"could not prepare the so-aws-lab workspace\n\n"+
				"%v\n\n"+
				"The terraform ships inside the so-aws-lab binary and is extracted to\n"+
				"%s before each run.\n"+
				"Check that your home directory is writable.\n",
			err, root,
		)
		r.mu.Lock()
		r.lastOutput.Reset()
		r.lastOutput.WriteString(msg)
		r.mu.Unlock()
		return fmt.Errorf("so-aws-lab: %w", err)
	}
	return nil
}

// Init runs `terraform init` for the workshop dir. We always run it: it's
// cheap when there's nothing to do and avoids the "lockfile exists therefore
// .terraform/ is correct" trap (the cached backend state file
// .terraform/terraform.tfstate is what actually drives backend init, and a
// stale one from an earlier S3 backend will leave a lockfile present but
// the backend broken).
//
// If init reports a backend mismatch, we auto-retry with `-reconfigure`.
func (r *Runner) Init() error {
	if err := r.ensureWorkspace(); err != nil {
		return err
	}
	if err := r.tfCmd("init", "-input=false").Run(); err != nil {
		if r.shouldReconfigure() {
			r.mu.Lock()
			r.lastOutput.Reset()
			r.mu.Unlock()
			if err2 := r.tfCmd("init", "-input=false", "-reconfigure").Run(); err2 == nil {
				return nil
			}
		}
		return r.withCapturedOutput("terraform init", err)
	}
	return nil
}

// shouldReconfigure inspects the captured init/apply output for the
// well-known backend-mismatch cues. Used for the retry loop in Init,
// Apply, and Destroy.
func (r *Runner) shouldReconfigure() bool {
	out := r.LastOutput()
	if out == "" {
		return false
	}
	for _, marker := range []string{
		"Backend configuration changed",
		"backend type has changed",
		"backend has changed",
		"Backend initialization required",
		"-reconfigure",
		"-migrate-state",
	} {
		if strings.Contains(out, marker) {
			return true
		}
	}
	return false
}

// reinitAndRetry runs `terraform init -reconfigure` then re-runs the given
// terraform args. Used by Apply/Destroy when the first attempt errors with a
// backend cue.
func (r *Runner) reinitAndRetry(args []string) error {
	r.mu.Lock()
	r.lastOutput.Reset()
	r.mu.Unlock()
	if err := r.tfCmd("init", "-input=false", "-reconfigure").Run(); err != nil {
		return err
	}
	return r.tfCmd(args...).Run()
}

// Apply applies the current enabled set.
func (r *Runner) Apply() error {
	if err := r.Init(); err != nil {
		return err
	}
	args := append([]string{"apply", "-auto-approve", "-parallelism=10"}, r.tfvarsArgs()...)
	if err := r.tfCmd(args...).Run(); err != nil {
		if r.shouldReconfigure() {
			if err2 := r.reinitAndRetry(args); err2 == nil {
				r.syncEntryProfiles()
				return nil
			}
		}
		return r.withCapturedOutput("terraform apply", err)
	}
	r.syncEntryProfiles()
	return nil
}

// syncEntryProfiles writes a role-assuming profile into ~/.aws/config for each
// enabled lab's entry role, and removes profiles for labs no longer enabled.
// Best-effort: a failure is reported into the captured output but never fails
// the apply. Entry roles only — reaching the target role is the exercise.
func (r *Runner) syncEntryProfiles() {
	profs, err := r.buildEntryProfiles()
	if err != nil {
		r.appendOutput(fmt.Sprintf("\nso-aws-lab: could not read terraform outputs to update ~/.aws/config profiles: %v\n", err))
		return
	}
	n, err := awsconfig.Sync(profs)
	if err != nil {
		r.appendOutput(fmt.Sprintf("\nso-aws-lab: could not write ~/.aws/config profiles: %v\n", err))
		return
	}
	if n > 0 {
		r.appendOutput(fmt.Sprintf("\nso-aws-lab: wrote %d entry-role profile(s) to ~/.aws/config (use `aws --profile %s-<lab>-carl ...`)\n", n, r.Cfg.LabPrefix))
	}
}

// buildEntryProfiles turns the deployed labs' terraform outputs into the set of
// entry-role profiles to write. The source_profile is chosen by matching the
// entry ARN's account to a configured account, so multi-account labs still get
// a source profile that can actually assume the role.
func (r *Runner) buildEntryProfiles() ([]awsconfig.Profile, error) {
	out, _, accountIDs, _, err := r.Outputs()
	if err != nil {
		return nil, err
	}
	dev := r.Cfg.Primary()
	sess := awsconfig.CurrentSessionName()
	profs := []awsconfig.Profile{}
	for _, l := range r.Labs {
		if !r.Cfg.Enabled[l.Slug] {
			continue
		}
		st := out[l.Slug]
		if st == nil || st.EntryRoleARN == "" {
			continue
		}
		srcProfile, srcRegion := dev.Profile, dev.Region
		if acct := arnAccountID(st.EntryRoleARN); acct != "" {
			for name, id := range accountIDs {
				if id == acct {
					a := r.Cfg.AccountOr(name)
					srcProfile, srcRegion = a.Profile, a.Region
					break
				}
			}
		}
		profs = append(profs, awsconfig.Profile{
			Lab:           l.Slug,
			Name:          fmt.Sprintf("%s-%s-carl", r.Cfg.LabPrefix, l.Slug),
			RoleARN:       st.EntryRoleARN,
			SourceProfile: srcProfile,
			Region:        srcRegion,
			SessionName:   sess,
		})
	}
	return profs, nil
}

// arnAccountID pulls the 12-digit account ID out of an IAM role ARN
// (arn:aws:iam::<account>:role/<name>), or "" if it doesn't parse.
func arnAccountID(arn string) string {
	parts := strings.Split(arn, ":")
	if len(parts) < 5 {
		return ""
	}
	return parts[4]
}

// appendOutput appends s to the captured output buffer and, when streaming is
// active, forwards it line-by-line so the TUI shows it live.
func (r *Runner) appendOutput(s string) {
	r.mu.Lock()
	r.lastOutput.WriteString(s)
	ch := r.streamCh
	r.mu.Unlock()
	if ch != nil {
		for _, line := range strings.Split(strings.TrimRight(s, "\n"), "\n") {
			select {
			case ch <- line:
			default:
			}
		}
	}
}

// Destroy destroys everything (all enable vars passed as false).
func (r *Runner) Destroy() error {
	if err := r.Init(); err != nil {
		return err
	}
	dev := r.Cfg.Primary()
	staging := r.Cfg.Accounts["staging"]
	prod := r.Cfg.Accounts["prod"]
	students, _ := json.Marshal(r.Cfg.Capstone.Students)
	args := []string{"destroy", "-auto-approve", "-parallelism=10",
		fmt.Sprintf("-var=lab_prefix=%s", r.Cfg.LabPrefix),
		fmt.Sprintf("-var=dev_profile=%s", dev.Profile),
		fmt.Sprintf("-var=dev_region=%s", dev.Region),
		fmt.Sprintf("-var=staging_profile=%s", staging.Profile),
		fmt.Sprintf("-var=staging_region=%s", staging.Region),
		fmt.Sprintf("-var=prod_profile=%s", prod.Profile),
		fmt.Sprintf("-var=prod_region=%s", prod.Region),
		fmt.Sprintf("-var=capstone_students=%s", students),
	}
	for _, l := range r.Labs {
		args = append(args, "-var", fmt.Sprintf("enable_%s=false", l.Slug))
	}
	if err := r.tfCmd(args...).Run(); err != nil {
		if r.shouldReconfigure() {
			if err2 := r.reinitAndRetry(args); err2 == nil {
				r.removeEntryProfiles()
				return nil
			}
		}
		return r.withCapturedOutput("terraform destroy", err)
	}
	r.removeEntryProfiles()
	return nil
}

// removeEntryProfiles strips every so-aws-lab managed profile from ~/.aws/config.
// Best-effort — reported into captured output, never fails the destroy.
func (r *Runner) removeEntryProfiles() {
	if _, err := awsconfig.Sync(nil); err != nil {
		r.appendOutput(fmt.Sprintf("\nso-aws-lab: could not clean ~/.aws/config profiles: %v\n", err))
		return
	}
	r.appendOutput("\nso-aws-lab: removed managed entry-role profiles from ~/.aws/config\n")
}

// withCapturedOutput wraps a terraform error with the tail of captured output
// (the last ~30 lines) so callers see something meaningful even in quiet mode.
func (r *Runner) withCapturedOutput(op string, base error) error {
	if r.Verbose {
		return fmt.Errorf("%s: %w", op, base)
	}
	tail := tailLines(r.LastOutput(), 30)
	if tail == "" {
		return fmt.Errorf("%s: %w", op, base)
	}
	return fmt.Errorf("%s: %w\n--- terraform output (tail) ---\n%s", op, base, tail)
}

func tailLines(s string, n int) string {
	if s == "" {
		return ""
	}
	lines := []string{}
	start := 0
	for i, c := range s {
		if c == '\n' {
			lines = append(lines, s[start:i])
			start = i + 1
		}
	}
	if start < len(s) {
		lines = append(lines, s[start:])
	}
	if len(lines) <= n {
		return s
	}
	out := ""
	for _, l := range lines[len(lines)-n:] {
		out += l + "\n"
	}
	return out
}

// LabStatus captures one lab's TF output entry.
type LabStatus struct {
	EntryRoleARN      string `json:"entry_role_arn"`
	TargetRoleARN     string `json:"target_role_arn"`
	FlagParameterName string `json:"flag_parameter_name"`
}

// CapstoneStudentStatus contains the non-secret identifiers an instructor
// needs to distribute and validate one isolated workshop instance.
type CapstoneStudentStatus struct {
	Label             string
	BootstrapUserName string
	ConsoleSigninURL  string
	EntryRoleARN      string
	TargetRoleARN     string
	Namespace         string
	FlagLocation      string
}

// Outputs parses `terraform output -json` and returns per-lab info, the dev
// account ID, every configured account's ID, and the optional per-student
// capstone identifiers.
func (r *Runner) Outputs() (map[string]*LabStatus, string, map[string]string, map[string]*CapstoneStudentStatus, error) {
	if err := r.Init(); err != nil {
		return nil, "", nil, nil, err
	}
	var buf bytes.Buffer
	cmd := exec.Command("terraform", "output", "-json")
	cmd.Dir = r.workshopDir()
	cmd.Env = append(os.Environ(), "AWS_PROFILE="+r.Cfg.Primary().Profile)
	cmd.Stdout = &buf
	cmd.Stderr = io.Discard
	if err := cmd.Run(); err != nil {
		return nil, "", nil, nil, err
	}
	var raw map[string]struct {
		Value any `json:"value"`
	}
	if err := json.Unmarshal(buf.Bytes(), &raw); err != nil {
		return nil, "", nil, nil, err
	}
	out := map[string]*LabStatus{}
	if labsOut, ok := raw["labs"]; ok {
		if m, ok := labsOut.Value.(map[string]any); ok {
			for slug, v := range m {
				if v == nil {
					out[slug] = nil
					continue
				}
				inner, ok := v.(map[string]any)
				if !ok {
					continue
				}
				out[slug] = &LabStatus{
					EntryRoleARN:      str(inner["entry_role_arn"]),
					TargetRoleARN:     str(inner["target_role_arn"]),
					FlagParameterName: str(inner["flag_parameter_name"]),
				}
			}
		}
	}
	accountID := ""
	if v, ok := raw["account_id"]; ok {
		accountID = str(v.Value)
	}
	accountIDs := map[string]string{}
	if v, ok := raw["accounts"]; ok {
		if m, ok := v.Value.(map[string]any); ok {
			for name, entry := range m {
				inner, ok := entry.(map[string]any)
				if !ok {
					continue
				}
				if id := str(inner["account_id"]); id != "" {
					accountIDs[name] = id
				}
			}
		}
	}
	if accountIDs["dev"] == "" && accountID != "" {
		accountIDs["dev"] = accountID
	}

	capstoneStudents := map[string]*CapstoneStudentStatus{}
	if v, ok := raw["capstone_students"]; ok {
		if m, ok := v.Value.(map[string]any); ok {
			for id, entry := range m {
				inner, ok := entry.(map[string]any)
				if !ok {
					continue
				}
				bucket := str(inner["flag_bucket_name"])
				key := str(inner["flag_object_key"])
				flagLocation := ""
				if bucket != "" && key != "" {
					flagLocation = "s3://" + bucket + "/" + key
				}
				capstoneStudents[id] = &CapstoneStudentStatus{
					Label:             str(inner["student_label"]),
					BootstrapUserName: str(inner["bootstrap_user_name"]),
					ConsoleSigninURL:  str(inner["console_signin_url"]),
					EntryRoleARN:      str(inner["entry_role_arn"]),
					TargetRoleARN:     str(inner["target_role_arn"]),
					Namespace:         str(inner["kubernetes_namespace"]),
					FlagLocation:      flagLocation,
				}
			}
		}
	}
	return out, accountID, accountIDs, capstoneStudents, nil
}

func str(v any) string {
	if s, ok := v.(string); ok {
		return s
	}
	return ""
}
