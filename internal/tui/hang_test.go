package tui

import (
	"regexp"
	"strings"
	"testing"

	"github.com/charmbracelet/lipgloss"
	"github.com/muesli/reflow/ansi"
	"github.com/muesli/termenv"

	"github.com/specterops/so-aws-lab/internal/labs"
)

var ansiRE = regexp.MustCompile(`\x1b\[[0-9;]*m`)

func plainOf(s string) string { return ansiRE.ReplaceAllString(s, "") }

// checkHung asserts every line fits the pane and every continuation line starts
// at wantIndent — the whole point of hang().
func checkHung(t *testing.T, got string, width, wantIndent int) {
	t.Helper()
	lines := strings.Split(got, "\n")
	if len(lines) < 2 {
		t.Fatalf("expected the line to wrap, got one line: %q", plainOf(got))
	}
	for i, ln := range lines {
		plain := plainOf(ln)
		if n := ansi.PrintableRuneWidth(ln); n > width {
			t.Errorf("line %d exceeds width %d (got %d): %q", i, width, n, plain)
		}
		if i == 0 {
			continue
		}
		indent := len(plain) - len(strings.TrimLeft(plain, " "))
		if indent != wantIndent {
			t.Errorf("line %d indent = %d, want %d: %q", i, indent, wantIndent, plain)
		}
	}
}

// A long ARN has no spaces, so it only wraps if hang() hard-breaks it. Without
// that it would overflow and get soft-wrapped back to column 0 by lipgloss.
func TestHangAlignsARNContinuation(t *testing.T) {
	const w = 46
	prefix := "  " + detailKey.Render("entry  ") // 2 + 7 = 9 columns
	got := hang(prefix,
		detailVal.Render("arn:aws:iam::123456789012:role/so-aws-lab-createpolicyversion-carl"), w)
	checkHung(t, got, w, 9)
	t.Logf("\n%s", plainOf(got))
}

// The lab list wraps under the title column, keeping the "[ ]" gutter intact.
func TestHangLabsRow(t *testing.T) {
	const w = 40
	prefix := "  " + disabledStyle.Render("[ ]") + " " // 2 + 3 + 1 = 6 columns
	body := disabledStyle.Render("EKS CreatePodIdentityAssociation + PassRole") +
		costBadge(labs.Lab{DailyUSD: 4.40})
	checkHung(t, hang(prefix, body, w), w, 6)
	t.Logf("\n%s", plainOf(hang(prefix, body, w)))
}

// Rows that already fit must come back byte-identical. Wrapping them at the
// narrower body width would introduce breaks that were never needed.
func TestHangLeavesFittingLinesAlone(t *testing.T) {
	prefix := "  " + detailKey.Render("flag   ")
	body := detailVal.Render("/labs/x/y/flag")
	got := hang(prefix, body, 80)
	if got != prefix+body {
		t.Errorf("fitting line was modified:\n got %q\nwant %q", plainOf(got), plainOf(prefix+body))
	}
	if strings.Contains(got, "\n") {
		t.Error("fitting line gained a newline")
	}
}

// Shell commands are hard-wrapped. Word wrapping breaks at spaces, which
// strands the trailing "\" line-continuation marker alone on its own line and
// splits a flag from its value — both ugly and confusing to copy.
func TestHangHardKeepsCommandContiguous(t *testing.T) {
	const w = 60
	prefix := "    "
	body := detailVal.Render("--role-arn arn:aws:iam::123456789012:role/so-aws-lab-ekspodidentityassociation-carl \\")
	got := hangHard(prefix, body, w)
	checkHung(t, got, w, 4)
	for i, ln := range strings.Split(got, "\n") {
		if strings.TrimSpace(plainOf(ln)) == `\` {
			t.Errorf("line %d orphans the continuation marker:\n%s", i, plainOf(got))
		}
	}
	// The flag must stay attached to the start of its value.
	if first := plainOf(strings.Split(got, "\n")[0]); !strings.Contains(first, "--role-arn arn:") {
		t.Errorf("flag separated from its value: %q", first)
	}
	t.Logf("\n%s", plainOf(got))
}

// A pane too narrow to leave usable room after the indent must degrade rather
// than render a one-column-wide text gutter.
func TestHangDegradesOnNarrowPane(t *testing.T) {
	prefix := "  " + detailKey.Render("walkthrough  ") // 15 columns
	body := detailVal.Render("docs/Walkthroughs/IAM-CreatePolicyVersion.md")
	got := hang(prefix, body, 18) // only 3 columns would remain
	if strings.Contains(got, "\n") {
		t.Errorf("expected no hanging wrap on a too-narrow pane, got:\n%s", plainOf(got))
	}
}

// Styling must survive the wrap. reflow's wrap emits the opening SGR on the
// first line only and the reset on the last, so a continuation line carries no
// color of its own — and lipgloss renders each line into its own bordered box,
// which resets style between them. reopenANSI closes and re-opens the run per
// line to compensate.
//
// The color profile has to be forced: under `go test` there is no TTY, so
// lipgloss degrades to the Ascii profile and Render() emits no escapes at all,
// which would make this assertion vacuously unable to fail.
func TestHangPreservesStylingOnContinuation(t *testing.T) {
	old := lipgloss.ColorProfile()
	lipgloss.SetColorProfile(termenv.TrueColor)
	defer lipgloss.SetColorProfile(old)

	const w = 46
	prefix := "  " + detailKey.Render("target ")
	got := hang(prefix,
		detailVal.Render("arn:aws:iam::123456789012:role/so-aws-lab-createpolicyversion-donut"), w)
	lines := strings.Split(got, "\n")
	if len(lines) < 2 {
		t.Fatal("expected wrapping")
	}
	// Guard the guard: if Render stopped emitting escapes, the test below would
	// pass for the wrong reason.
	if !strings.Contains(lines[0], "\x1b[") {
		t.Fatal("color profile not applied — test cannot detect the regression it targets")
	}
	if !strings.Contains(lines[1], "\x1b[") {
		t.Errorf("continuation line lost its ANSI styling: %q", lines[1])
	}
}

// The banner must never exceed the pane width — it sits above the columns, so
// an overflow would be soft-wrapped by the terminal and desync the height
// arithmetic that charges its line count to chrome.
func TestRenderBannerFitsWidth(t *testing.T) {
	for _, w := range []int{140, 120, 96, 80, 70, 60} {
		got := renderBanner(w)
		for i, ln := range strings.Split(got, "\n") {
			if n := ansi.PrintableRuneWidth(ln); n > w {
				t.Errorf("width %d: line %d is %d wide: %q", w, i, n, plainOf(ln))
			}
		}
		if !strings.Contains(plainOf(got), bannerURL) {
			t.Errorf("width %d: banner dropped the course URL: %q", w, plainOf(got))
		}
	}
}

// One line when it fits, stacked when it doesn't.
func TestRenderBannerCollapses(t *testing.T) {
	if n := strings.Count(renderBanner(140), "\n"); n != 0 {
		t.Errorf("wide terminal should render one line, got %d newlines", n)
	}
	if n := strings.Count(renderBanner(70), "\n"); n != 1 {
		t.Errorf("narrow terminal should stack onto two lines, got %d newlines", n)
	}
}
