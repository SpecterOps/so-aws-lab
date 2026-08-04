// Command so-aws-lab is a TUI + small CLI for deploying intentionally vulnerable
// AWS labs into the operator's own sandbox account. Inspired by DataDog's
// `plabs` (github.com/DataDog/pathfinding-labs).
package main

import (
	"bufio"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/spf13/cobra"

	"github.com/specterops/so-aws-lab/internal/capstoneaccess"
	"github.com/specterops/so-aws-lab/internal/config"
	"github.com/specterops/so-aws-lab/internal/labs"
	"github.com/specterops/so-aws-lab/internal/runner"
	"github.com/specterops/so-aws-lab/internal/tui"
	"github.com/specterops/so-aws-lab/internal/updater"
	"github.com/specterops/so-aws-lab/internal/workspace"
)

// Build metadata, injected via -ldflags at release time (see .goreleaser.yaml).
// The defaults are what a plain `go build` or `go install` produces.
var (
	version = "dev"
	commit  = "none"
	date    = "unknown"
)

func main() {
	var update bool
	root := &cobra.Command{
		Use:     "so-aws-lab",
		Short:   "Self-hosted AWS privesc lab TUI",
		Version: fmt.Sprintf("%s (commit %s, built %s)", version, commit, date),
		RunE: func(cmd *cobra.Command, args []string) error {
			if !update {
				return runTUI(cmd, args)
			}
			return updater.Update(version)
		},
	}
	// -v is already taken by --verbose, so leave the version shorthand unset.
	root.SetVersionTemplate("so-aws-lab {{.Version}}\n")
	root.PersistentFlags().BoolP("verbose", "v", false, "stream terraform output instead of showing a spinner")
	root.Flags().BoolVar(&update, "update", false, "install the latest release when no labs are deployed")

	root.AddCommand(initCmd(), enableCmd(), disableCmd(), applyCmd(), destroyCmd(), statusCmd(), capstoneCmd())
	if err := root.Execute(); err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(1)
	}
}

// --- root: open the TUI ------------------------------------------------------

func runTUI(cmd *cobra.Command, _ []string) error {
	cfg, err := config.Load()
	if err != nil {
		return err
	}
	// If the config yaml is undetected (or present but missing a usable dev
	// profile / repo path) run the account-setup wizard before opening the
	// TUI. Once settings exist the TUI just reads them — it no longer edits
	// accounts.
	if !config.Exists() || !cfg.Ready() {
		if !config.Exists() {
			fmt.Println("No so-aws-lab config found at", config.Path())
		} else {
			fmt.Println("so-aws-lab config is incomplete — let's finish account setup.")
		}
		if err := runInit(cfg); err != nil {
			return err
		}
		// Reload after setup so we pick up the wizard's writes.
		cfg, err = config.Load()
		if err != nil {
			return err
		}
		if !cfg.Ready() {
			return fmt.Errorf("setup did not complete (no AWS profile set in %s)", config.Path())
		}
	}
	verbose, _ := cmd.Flags().GetBool("verbose")
	ll, err := labs.Load()
	if err != nil {
		return err
	}
	return tui.Run(cfg, ll, verbose)
}

// --- init: wizard ------------------------------------------------------------

func initCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "init",
		Short: "Configure AWS profiles, regions, and lab prefix",
		RunE: func(_ *cobra.Command, _ []string) error {
			cfg, err := config.Load()
			if err != nil {
				return err
			}
			return runInit(cfg)
		},
	}
}

// runInit drives the wizard given an already-loaded config (which may be
// empty / partial). It saves on success.
func runInit(cfg *config.Config) error {
	r := bufio.NewReader(os.Stdin)

	// Configure each named account. dev is required; staging/prod can be
	// skipped (just hit enter to skip). All existing labs deploy to dev.
	cfg.Accounts = configureAccounts(cfg.Accounts, r)

	cfg.LabPrefix = promptText(r, "Lab prefix", cfg.LabPrefix)

	if err := cfg.Save(); err != nil {
		return err
	}

	// Sanity: prove the dev profile works.
	dev := cfg.Primary()
	id := exec.Command("aws", "sts", "get-caller-identity")
	id.Env = append(os.Environ(), "AWS_PROFILE="+dev.Profile, "AWS_REGION="+dev.Region)
	id.Stdout = os.Stdout
	id.Stderr = os.Stderr
	if err := id.Run(); err != nil {
		fmt.Fprintln(os.Stderr, "warning: `aws sts get-caller-identity` failed with dev profile", dev.Profile)
	}
	if _, err := exec.LookPath("terraform"); err != nil {
		fmt.Fprintln(os.Stderr, "warning: `terraform` not found on PATH — install it with `brew install terraform`")
	}
	// Extract the embedded terraform now rather than lazily on first apply, so
	// any permission problem surfaces during setup.
	root, err := workspace.Dir()
	if err == nil {
		err = workspace.Ensure(root)
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "warning: could not prepare workspace:", err)
	} else {
		fmt.Println("workspace ready at", root)
	}

	fmt.Println("config saved to", config.Path())
	return nil
}

// Synthetic picker entries for the profile list.
const (
	pickSkip   = "— skip this account —"
	pickManual = "✎ type a profile name…"
)

// configureAccounts asks the user for one named profile + region per slot using
// an interactive arrow-key selector over the discovered AWS profiles and the
// region list. dev is required; staging and prod are skippable. On a
// non-interactive stdin (or when no profiles are discovered) it falls back to
// the numbered text menu so scripted setup still works.
func configureAccounts(existing map[string]config.Account, r *bufio.Reader) map[string]config.Account {
	if existing == nil {
		existing = map[string]config.Account{}
	}
	regions := config.Regions()
	for _, name := range config.DefaultAccountNames {
		cur := existing[name]
		required := name == config.PrimaryAccount

		profile := pickProfile(r, name, cur.Profile, required)
		if profile == "" {
			if required {
				// Cancelled/blank on the required account. Don't loop forever —
				// leave dev unset and let runInit's Ready() check report the
				// incomplete setup so the user can re-run `so-aws-lab init`.
				fmt.Println("dev profile is required — leaving setup incomplete; re-run `so-aws-lab init` to finish.")
				delete(existing, name)
				return existing
			}
			delete(existing, name)
			fmt.Printf("  %s: (skipped)\n", name)
			continue
		}
		region := pickRegion(r, name, regions, defaultStr(cur.Region, "us-east-1"))
		existing[name] = config.Account{Profile: profile, Region: region}
		fmt.Printf("  %s: profile=%s region=%s\n", name, profile, region)
	}
	return existing
}

// pickProfile returns the chosen AWS profile for an account. Interactive TTYs
// get an arrow-key list (with skip/manual-entry entries); otherwise it falls
// back to the numbered menu. "" means "skip / leave unset".
func pickProfile(r *bufio.Reader, account, current string, required bool) string {
	profiles := config.ListProfiles(current)

	if len(profiles) == 0 || !stdinIsTTY() {
		label := fmt.Sprintf("AWS profile for `%s` account", account)
		if !required {
			label += " (blank to skip)"
		}
		return selectOption(r, label, profiles, current)
	}

	// Build the option list: [skip?] + profiles + [manual].
	options := []string{}
	if !required {
		options = append(options, pickSkip)
	}
	firstProfile := len(options)
	options = append(options, profiles...)
	options = append(options, pickManual)

	initial := firstProfile
	for i, p := range profiles {
		if p == current {
			initial = firstProfile + i
			break
		}
	}

	title := fmt.Sprintf("Select AWS profile for `%s` account", account)
	idx, ok := tui.PickList(title, options, initial)
	if !ok {
		return current // cancelled — keep whatever was already set
	}
	switch options[idx] {
	case pickSkip:
		return ""
	case pickManual:
		return promptText(r, fmt.Sprintf("Profile name for `%s`", account), current)
	default:
		return options[idx]
	}
}

// pickRegion returns the chosen region for an account, arrow-key selectable on
// a TTY and falling back to the numbered menu otherwise.
func pickRegion(r *bufio.Reader, account string, regions []string, current string) string {
	if !stdinIsTTY() {
		return selectOption(r, fmt.Sprintf("Region for `%s`", account), regions, current)
	}
	initial := 0
	for i, rg := range regions {
		if rg == current {
			initial = i
			break
		}
	}
	idx, ok := tui.PickList(fmt.Sprintf("Select region for `%s` account", account), regions, initial)
	if !ok {
		return current
	}
	return regions[idx]
}

// stdinIsTTY reports whether stdin is an interactive terminal. When it isn't
// (piped/scripted input, CI), the interactive pickers can't run so setup falls
// back to the text menu.
func stdinIsTTY() bool {
	fi, err := os.Stdin.Stat()
	if err != nil {
		return false
	}
	return fi.Mode()&os.ModeCharDevice != 0
}

// selectOption prints a numbered menu of options and reads the user's choice.
// A blank line returns def. A number selects that option. Anything else is
// accepted verbatim so the user can type a profile/region the scan missed.
func selectOption(r *bufio.Reader, label string, options []string, def string) string {
	for i, o := range options {
		marker := "  "
		if o == def {
			marker = "* "
		}
		fmt.Printf("   %s%2d) %s\n", marker, i+1, o)
	}
	if def != "" {
		fmt.Printf("%s [%s]: ", label, def)
	} else {
		fmt.Printf("%s: ", label)
	}
	line, _ := r.ReadString('\n')
	line = strings.TrimSpace(line)
	if line == "" {
		return def
	}
	if n, err := strconv.Atoi(line); err == nil && n >= 1 && n <= len(options) {
		return options[n-1]
	}
	return line
}

// promptText reads a single free-text value, returning def on blank input.
func promptText(r *bufio.Reader, label, def string) string {
	if def == "" {
		fmt.Printf("%s: ", label)
	} else {
		fmt.Printf("%s [%s]: ", label, def)
	}
	line, _ := r.ReadString('\n')
	line = strings.TrimSpace(line)
	if line == "" {
		return def
	}
	return line
}

func defaultStr(s, fallback string) string {
	if s == "" {
		return fallback
	}
	return s
}

// --- enable / disable -------------------------------------------------------

func toggleCmd(want bool) *cobra.Command {
	verb := "enable"
	if !want {
		verb = "disable"
	}
	return &cobra.Command{
		Use:   verb + " <lab>...",
		Short: strings.Title(verb) + " one or more labs without applying",
		Args:  cobra.MinimumNArgs(1),
		RunE: func(_ *cobra.Command, args []string) error {
			cfg, err := config.Load()
			if err != nil {
				return err
			}
			ll, err := labs.Load()
			if err != nil {
				return err
			}
			known := map[string]bool{}
			for _, l := range ll {
				known[l.Slug] = true
			}
			for _, slug := range args {
				if !known[slug] {
					return fmt.Errorf("unknown lab: %s", slug)
				}
				cfg.Enabled[slug] = want
			}
			return cfg.Save()
		},
	}
}

func enableCmd() *cobra.Command  { return toggleCmd(true) }
func disableCmd() *cobra.Command { return toggleCmd(false) }

// --- capstone workshop roster ----------------------------------------------

var (
	capstoneStudentID    = regexp.MustCompile(`^[a-z0-9][a-z0-9-]{0,11}$`)
	capstoneStudentCount = regexp.MustCompile(`^[0-9]+$`)
)

func capstoneCmd() *cobra.Command {
	root := &cobra.Command{
		Use:   "capstone",
		Short: "Configure the optional multi-student capstone deployment",
	}

	var singleUser bool
	configure := &cobra.Command{
		Use:   "configure <student-count|student-id[=display-name]...>",
		Short: "Replace the workshop capstone roster",
		Example: "  so-aws-lab capstone configure 30\n" +
			"  so-aws-lab capstone configure student01=Alice student02=Bob",
		Args: func(_ *cobra.Command, args []string) error {
			if singleUser && len(args) > 0 {
				return fmt.Errorf("--single-user cannot be combined with a student roster")
			}
			if !singleUser && len(args) == 0 {
				return fmt.Errorf("provide a student count, at least one student ID, or use --single-user")
			}
			return nil
		},
		RunE: func(_ *cobra.Command, args []string) error {
			cfg, err := config.Load()
			if err != nil {
				return err
			}
			students := map[string]string{}
			if !singleUser {
				students, err = parseCapstoneStudents(args)
				if err != nil {
					return err
				}
			}
			cfg.Capstone.Students = students
			if err := cfg.Save(); err != nil {
				return err
			}
			printCapstoneConfig(cfg)
			return nil
		},
	}
	configure.Flags().BoolVar(&singleUser, "single-user", false, "clear the roster and use the original single-student deployment")

	show := &cobra.Command{
		Use:   "show",
		Short: "Show the configured capstone roster",
		Args:  cobra.NoArgs,
		RunE: func(_ *cobra.Command, _ []string) error {
			cfg, err := config.Load()
			if err != nil {
				return err
			}
			printCapstoneConfig(cfg)
			return nil
		},
	}

	var cardsOutput string
	accessCards := &cobra.Command{
		Use:   "access-cards",
		Short: "Create or rotate console passwords and write printable access cards",
		Args:  cobra.NoArgs,
		RunE: func(_ *cobra.Command, _ []string) error {
			cfg, err := config.Load()
			if err != nil {
				return err
			}
			if len(cfg.Capstone.Students) == 0 {
				return fmt.Errorf("access cards require a multi-student roster")
			}
			if !cfg.Enabled["capstone"] {
				return fmt.Errorf("enable and apply the capstone before issuing access cards")
			}
			ll, err := labs.Load()
			if err != nil {
				return err
			}
			rn := runner.New(cfg, ll)
			_, _, _, deployed, err := rn.Outputs()
			if err != nil {
				return fmt.Errorf("read deployed capstone roster: %w", err)
			}
			if len(deployed) != len(cfg.Capstone.Students) {
				return fmt.Errorf("configured and deployed rosters differ; run `so-aws-lab apply` before issuing cards")
			}

			students := make([]capstoneaccess.Student, 0, len(cfg.Capstone.Students))
			for id, label := range cfg.Capstone.Students {
				status := deployed[id]
				if status == nil || status.BootstrapUserName == "" {
					return fmt.Errorf("student %s has no deployed bootstrap user; run `so-aws-lab apply`", id)
				}
				students = append(students, capstoneaccess.Student{
					ID:               id,
					Label:            label,
					UserName:         status.BootstrapUserName,
					EntryRoleARN:     status.EntryRoleARN,
					ConsoleSigninURL: status.ConsoleSigninURL,
				})
			}

			output := cardsOutput
			if output == "" {
				home, err := os.UserHomeDir()
				if err != nil {
					return fmt.Errorf("resolve access-card output: %w", err)
				}
				output = filepath.Join(home, ".so-aws-lab", "capstone-access-cards.html")
			}
			dev := cfg.Primary()
			result, err := capstoneaccess.Generate(dev.Profile, dev.Region, output, students)
			if err != nil {
				return err
			}
			fmt.Printf("wrote %d private access card(s) to %s (mode 0600)\n", result.Count, result.Path)
			fmt.Println("This file contains active passwords. Print it, then securely delete it after distribution.")
			fmt.Println("Running access-cards again rotates every workshop password and invalidates older cards.")
			return nil
		},
	}
	accessCards.Flags().StringVar(&cardsOutput, "output", "", "private HTML output path (default: ~/.so-aws-lab/capstone-access-cards.html)")

	root.AddCommand(configure, show, accessCards)
	return root
}

func parseCapstoneStudents(args []string) (map[string]string, error) {
	if len(args) == 1 && capstoneStudentCount.MatchString(args[0]) {
		count, err := strconv.Atoi(args[0])
		if err != nil || count < 1 || count > 50 {
			return nil, fmt.Errorf("student count must be between 1 and 50")
		}
		students := make(map[string]string, count)
		for i := 1; i <= count; i++ {
			id := fmt.Sprintf("student%02d", i)
			students[id] = id
		}
		return students, nil
	}
	if len(args) > 50 {
		return nil, fmt.Errorf("capstone roster supports at most 50 students")
	}
	students := make(map[string]string, len(args))
	for _, arg := range args {
		id, label, hasLabel := strings.Cut(arg, "=")
		id = strings.TrimSpace(id)
		label = strings.TrimSpace(label)
		if id == "" || (hasLabel && label == "") {
			return nil, fmt.Errorf("invalid student %q: use student-id or student-id=display-name", arg)
		}
		if id == "default" || !capstoneStudentID.MatchString(id) {
			return nil, fmt.Errorf("invalid student ID %q: use 1-12 lowercase letters, digits, or hyphens; \"default\" is reserved", id)
		}
		if !hasLabel {
			label = id
		}
		if len(label) > 80 {
			return nil, fmt.Errorf("display name for %q exceeds 80 characters", id)
		}
		if _, exists := students[id]; exists {
			return nil, fmt.Errorf("duplicate student ID %q", id)
		}
		students[id] = label
	}
	return students, nil
}

func printCapstoneConfig(cfg *config.Config) {
	if len(cfg.Capstone.Students) == 0 {
		fmt.Println("mode:              single student")
		return
	}
	fmt.Printf("mode:              multi-student (%d)\n", len(cfg.Capstone.Students))
	ids := make([]string, 0, len(cfg.Capstone.Students))
	for id := range cfg.Capstone.Students {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	for _, id := range ids {
		fmt.Printf("  %-12s %s\n", id, cfg.Capstone.Students[id])
	}
}

// --- apply / destroy --------------------------------------------------------

func applyCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "apply",
		Short: "Run terraform apply with the current enabled set",
		RunE: func(c *cobra.Command, _ []string) error {
			cfg, err := config.Load()
			if err != nil {
				return err
			}
			ll, err := labs.Load()
			if err != nil {
				return err
			}
			verbose, _ := c.Flags().GetBool("verbose")
			rn := runner.New(cfg, ll)
			rn.Verbose = verbose
			return withSpinner("Applying", verbose, rn.Apply)
		},
	}
}

func destroyCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "destroy",
		Short: "Disable everything and run terraform destroy",
		RunE: func(c *cobra.Command, _ []string) error {
			cfg, err := config.Load()
			if err != nil {
				return err
			}
			ll, err := labs.Load()
			if err != nil {
				return err
			}
			verbose, _ := c.Flags().GetBool("verbose")
			rn := runner.New(cfg, ll)
			rn.Verbose = verbose
			return withSpinner("Destroying", verbose, rn.Destroy)
		},
	}
}

// withSpinner runs fn synchronously. In non-verbose mode it shows a simple
// rotating spinner on stderr until fn returns. In verbose mode it just runs.
func withSpinner(label string, verbose bool, fn func() error) error {
	if verbose {
		return fn()
	}
	done := make(chan struct{})
	go spinner(label, done)
	err := fn()
	close(done)
	// Give the spinner one tick to clear its line.
	time.Sleep(60 * time.Millisecond)
	if err != nil {
		fmt.Fprintln(os.Stderr, "✗", label, "failed")
		return err
	}
	fmt.Fprintln(os.Stderr, "✓", label, "complete")
	return nil
}

func spinner(label string, done <-chan struct{}) {
	frames := []rune{'⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'}
	start := time.Now()
	t := time.NewTicker(80 * time.Millisecond)
	defer t.Stop()
	i := 0
	for {
		select {
		case <-done:
			fmt.Fprint(os.Stderr, "\r\033[K")
			return
		case <-t.C:
			elapsed := time.Since(start).Round(time.Second)
			fmt.Fprintf(os.Stderr, "\r%c %s... %s", frames[i%len(frames)], label, elapsed)
			i++
		}
	}
}

// --- status -----------------------------------------------------------------

func statusCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "status",
		Short: "List enabled labs and their entry/target/flag info",
		RunE: func(_ *cobra.Command, _ []string) error {
			cfg, err := config.Load()
			if err != nil {
				return err
			}
			ll, err := labs.Load()
			if err != nil {
				return err
			}
			rn := runner.New(cfg, ll)
			out, accountID, _, capstoneStudents, err := rn.Outputs()
			if err != nil {
				return err
			}
			fmt.Println("dev account:", accountID)
			fmt.Println("dev region: ", cfg.Primary().Region)
			fmt.Println()
			for _, l := range ll {
				st := out[l.Slug]
				if st == nil {
					continue
				}
				fmt.Printf("%-32s entry=%s\n", l.Slug, st.EntryRoleARN)
				fmt.Printf("%-32s target=%s\n", "", st.TargetRoleARN)
				fmt.Printf("%-32s flag=%s\n", "", st.FlagParameterName)
			}
			if len(capstoneStudents) > 0 {
				fmt.Println()
				fmt.Println("capstone students:")
				ids := make([]string, 0, len(capstoneStudents))
				for id := range capstoneStudents {
					ids = append(ids, id)
				}
				sort.Strings(ids)
				for _, id := range ids {
					st := capstoneStudents[id]
					if st.BootstrapUserName != "" {
						fmt.Printf("  %-12s label=%s bootstrap-user=%s\n", id, st.Label, st.BootstrapUserName)
					} else {
						fmt.Printf("  %-12s single-student mode\n", id)
					}
					fmt.Printf("  %-12s entry=%s\n", "", st.EntryRoleARN)
					fmt.Printf("  %-12s target=%s\n", "", st.TargetRoleARN)
					fmt.Printf("  %-12s namespace=%s flag=%s\n", "", st.Namespace, st.FlagLocation)
				}
			}
			return nil
		},
	}
}
