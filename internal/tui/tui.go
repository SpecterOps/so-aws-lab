// Package tui is the Bubble Tea lab-toggle dashboard. Two-column layout
// (labs, detail) inspired by DataDog's plabs. Account/profile settings are
// configured out-of-band (the config yaml / setup wizard), not here.
package tui

import (
	"bytes"
	"fmt"
	"os"
	"os/exec"
	"regexp"
	"strings"

	"github.com/charmbracelet/bubbles/key"
	"github.com/charmbracelet/bubbles/spinner"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/muesli/reflow/ansi"
	"github.com/muesli/reflow/wordwrap"
	"github.com/muesli/reflow/wrap"

	"github.com/specterops/so-aws-lab/internal/awsconfig"
	"github.com/specterops/so-aws-lab/internal/config"
	"github.com/specterops/so-aws-lab/internal/labs"
	"github.com/specterops/so-aws-lab/internal/runner"
)

// AWS console palette. Hex values from the AWS brand guidelines:
//
//	Orange   #FF9900  — primary accent (focus, cursor, enabled)
//	Smile    #EC7211  — secondary orange (hover / pressed feel)
//	SquidInk #232F3E  — dark background base (largely unused — we live on
//	                    the terminal's bg)
//	Anchor   #545B64  — medium gray for dim text and unfocused borders
//	Sky      #00A1C9  — AWS link / info blue
//	Mist     #879196  — light cool gray for body text
//	Success  #1D8102  — green for OK status
//	Error    #D13212  — red for failure status
var (
	awsOrange  = lipgloss.Color("#FF9900")
	awsSmile   = lipgloss.Color("#EC7211")
	awsSky     = lipgloss.Color("#00A1C9")
	awsAnchor  = lipgloss.Color("#545B64")
	awsMist    = lipgloss.Color("#879196")
	awsCloud   = lipgloss.Color("#D5DBDB")
	awsSuccess = lipgloss.Color("#1D8102")
	awsError   = lipgloss.Color("#D13212")

	titleStyle    = lipgloss.NewStyle().Bold(true).Foreground(awsOrange)
	categoryStyle = lipgloss.NewStyle().Bold(true).Foreground(awsSky)
	enabledStyle  = lipgloss.NewStyle().Foreground(awsOrange)
	disabledStyle = lipgloss.NewStyle().Foreground(awsAnchor)
	cursorStyle   = lipgloss.NewStyle().Foreground(awsOrange).Bold(true)
	helpStyle     = lipgloss.NewStyle().Foreground(awsAnchor).MarginTop(1)
	statusOK      = lipgloss.NewStyle().Foreground(awsSuccess)
	statusErr     = lipgloss.NewStyle().Foreground(awsError)
	outputStyle   = lipgloss.NewStyle().Foreground(awsMist).MarginTop(1)

	colBorder = lipgloss.NewStyle().
			Border(lipgloss.RoundedBorder()).
			BorderForeground(awsAnchor).
			Padding(0, 1)
	colBorderFocused = lipgloss.NewStyle().
				Border(lipgloss.RoundedBorder()).
				BorderForeground(awsOrange).
				Padding(0, 1)
	colTitle = lipgloss.NewStyle().
			Bold(true).
			Foreground(awsSky)
	colTitleFocused = lipgloss.NewStyle().
			Bold(true).
			Foreground(awsOrange)

	dimAcct      = lipgloss.NewStyle().Foreground(awsAnchor)
	detailKey    = lipgloss.NewStyle().Foreground(awsMist)
	detailVal    = lipgloss.NewStyle().Foreground(awsCloud)
	detailDesc   = lipgloss.NewStyle().Foreground(awsCloud).MarginTop(1)
	sectionLabel = lipgloss.NewStyle().Bold(true).Foreground(awsSky)

	bannerStyle     = lipgloss.NewStyle().Foreground(awsMist)
	bannerLinkStyle = lipgloss.NewStyle().Foreground(awsSmile).Underline(true)
)

// The course this tool accompanies. Shown in the banner above both panels.
const (
	bannerBlurb = "Companion deployment tool for the AWS for Red Teamers course"
	bannerURL   = "https://academy.specterops.io/aws-for-red-teamers"
)

// renderBanner renders the course banner above both panels, on one line when
// it fits and stacked otherwise. The blurb degrades before the URL does —
// a truncated link is useless, whereas a shorter blurb still reads fine.
func renderBanner(width int) string {
	url := bannerLinkStyle.Render(bannerURL)
	oneLine := bannerStyle.Render(bannerBlurb+" — ") + url
	if width <= 0 || ansi.PrintableRuneWidth(oneLine) <= width {
		return oneLine
	}
	blurb := bannerBlurb
	for _, alt := range []string{
		"Companion deploy tool — AWS for Red Teamers",
		"AWS for Red Teamers course",
	} {
		if ansi.PrintableRuneWidth(blurb) <= width {
			break
		}
		blurb = alt
	}
	return bannerStyle.Render(blurb) + "\n" + url
}

// focusZone identifies which column owns ↑/↓ keys.
type focusZone int

const (
	focusLabs focusZone = iota
	focusDetail
)

type item struct {
	lab     labs.Lab
	enabled bool
	isHdr   bool
}

type Model struct {
	cfg          *config.Config
	rn           *runner.Runner
	all          []labs.Lab
	items        []item
	cursor       int // index into items (lab cursor)
	detailScroll int // line offset for the detail pane
	focus        focusZone
	status       string
	width        int
	height       int

	// accountIDs maps account name (dev/staging/prod) -> AWS account ID,
	// resolved once at startup via `aws sts get-caller-identity`. Lets the
	// detail pane show full role ARNs + a ready-to-run assume-role command
	// without the lab being deployed. Absent keys just render a placeholder.
	accountIDs map[string]string

	verbose    bool
	applying   bool
	sp         spinner.Model
	lastOutput string

	// Live terraform output stream during an apply. streamCh is the channel
	// the runner writes lines to; streamLines is the rolling buffer the view
	// renders. Both reset on each new apply.
	streamCh    chan string
	streamLines []string

	// Output viewer state. When outputViewer is true, the TUI fullscreens a
	// scrollable view of `lastOutput` (typically the captured terraform
	// output from a failed apply) instead of rendering the 2-column layout.
	outputViewer bool
	outputScroll int
}

func New(cfg *config.Config, ll []labs.Lab, verbose bool) *Model {
	rn := runner.New(cfg, ll)
	rn.Verbose = false
	sp := spinner.New()
	sp.Spinner = spinner.Dot
	sp.Style = lipgloss.NewStyle().Foreground(awsOrange)

	m := &Model{
		cfg: cfg, all: ll, rn: rn, sp: sp, verbose: verbose,
		width: 120, height: 40, focus: focusLabs,
		accountIDs: map[string]string{},
	}
	m.rebuildItems()
	for i, it := range m.items {
		if !it.isHdr {
			m.cursor = i
			break
		}
	}
	return m
}

func (m *Model) rebuildItems() {
	m.items = nil
	for _, cat := range labs.CategoryOrder() {
		m.items = append(m.items, item{isHdr: true, lab: labs.Lab{Category: cat}})
		for _, l := range m.all {
			if l.Category == cat {
				m.items = append(m.items, item{lab: l, enabled: m.cfg.Enabled[l.Slug]})
			}
		}
	}
}

func (m *Model) Init() tea.Cmd {
	return tea.Batch(m.sp.Tick, m.fetchAccountIDsCmd())
}

// accountIDsMsg carries the resolved account IDs from the async caller-identity
// lookup started in Init.
type accountIDsMsg map[string]string

// fetchAccountIDsCmd resolves the AWS account ID for each configured account
// (dev/staging/prod) by calling `aws sts get-caller-identity` with that
// profile. Best-effort and off the render path: accounts that fail to resolve
// are simply absent, and the detail pane shows a placeholder for them.
func (m *Model) fetchAccountIDsCmd() tea.Cmd {
	// Snapshot the accounts so the goroutine doesn't touch the model.
	accts := map[string]config.Account{}
	for name, a := range m.cfg.Accounts {
		if a.Profile != "" {
			accts[name] = a
		}
	}
	return func() tea.Msg {
		out := map[string]string{}
		for name, a := range accts {
			if id := callerAccountID(a.Profile, a.Region); id != "" {
				out[name] = id
			}
		}
		return accountIDsMsg(out)
	}
}

// callerAccountID returns the 12-digit account ID for the given profile, or ""
// if the lookup fails (no creds, aws CLI missing, offline).
func callerAccountID(profile, region string) string {
	c := exec.Command("aws", "sts", "get-caller-identity", "--query", "Account", "--output", "text")
	env := os.Environ()
	if profile != "" {
		env = append(env, "AWS_PROFILE="+profile)
	}
	if region != "" {
		env = append(env, "AWS_REGION="+region)
	}
	c.Env = env
	var buf bytes.Buffer
	c.Stdout = &buf
	if err := c.Run(); err != nil {
		return ""
	}
	return strings.TrimSpace(buf.String())
}

type applyDoneMsg struct {
	err    error
	output string
}

// streamLineMsg carries one terraform output line from the runner to the
// view. streamClosedMsg signals end-of-stream (channel closed by applyCmd
// after terraform exits).
type streamLineMsg string
type streamClosedMsg struct{}

func (m *Model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width = msg.Width
		m.height = msg.Height
	case spinner.TickMsg:
		var cmd tea.Cmd
		m.sp, cmd = m.sp.Update(msg)
		return m, cmd
	case accountIDsMsg:
		for name, id := range msg {
			m.accountIDs[name] = id
		}
		return m, nil
	case applyDoneMsg:
		m.applying = false
		m.lastOutput = msg.output
		if msg.err != nil {
			m.status = statusErr.Render("✗ apply failed — press o to see output")
		} else {
			m.status = statusOK.Render("✓ apply complete")
		}
		return m, nil
	case streamLineMsg:
		const maxStreamLines = 500
		m.streamLines = append(m.streamLines, string(msg))
		if len(m.streamLines) > maxStreamLines {
			m.streamLines = m.streamLines[len(m.streamLines)-maxStreamLines:]
		}
		// Read the next line; the Cmd unblocks when the channel produces or
		// closes.
		return m, m.streamReadCmd()
	case streamClosedMsg:
		// End-of-stream — nothing to schedule; applyDoneMsg arrives shortly.
		return m, nil
	case tea.KeyMsg:
		// Output viewer mode: gobble everything but scroll + close.
		if m.outputViewer {
			switch msg.String() {
			case "q", "esc", "o":
				m.outputViewer = false
			case "up", "k":
				if m.outputScroll > 0 {
					m.outputScroll--
				}
			case "down", "j":
				m.outputScroll++
			case "pgup":
				m.outputScroll -= 10
				if m.outputScroll < 0 {
					m.outputScroll = 0
				}
			case "pgdown", " ":
				m.outputScroll += 10
			case "home", "g":
				m.outputScroll = 0
			case "end", "G":
				m.outputScroll = m.outputMaxScroll()
			case "ctrl+c":
				return m, tea.Quit
			}
			return m, nil
		}
		if m.applying {
			if msg.String() == "v" {
				m.verbose = !m.verbose
			}
			return m, nil
		}
		switch {
		case key.Matches(msg, key.NewBinding(key.WithKeys("q", "ctrl+c"))):
			return m, tea.Quit
		case key.Matches(msg, key.NewBinding(key.WithKeys("left", "h"))):
			m.shiftFocus(-1)
		case key.Matches(msg, key.NewBinding(key.WithKeys("right", "l"))):
			m.shiftFocus(1)
		case key.Matches(msg, key.NewBinding(key.WithKeys("tab"))):
			m.shiftFocus(1)
		case key.Matches(msg, key.NewBinding(key.WithKeys("shift+tab"))):
			m.shiftFocus(-1)
		case key.Matches(msg, key.NewBinding(key.WithKeys("up", "k"))):
			m.moveUp()
		case key.Matches(msg, key.NewBinding(key.WithKeys("down", "j"))):
			m.moveDown()
		case key.Matches(msg, key.NewBinding(key.WithKeys(" "))):
			if m.focus == focusLabs {
				m.toggleCurrent()
			}
		case key.Matches(msg, key.NewBinding(key.WithKeys("v"))):
			m.verbose = !m.verbose
		case key.Matches(msg, key.NewBinding(key.WithKeys("o"))):
			// Always allow opening the viewer; if there's no captured
			// output it'll just say so.
			m.outputViewer = true
			m.outputScroll = 0
		case key.Matches(msg, key.NewBinding(key.WithKeys("a"))):
			m.applying = true
			m.status = ""
			m.lastOutput = ""
			m.streamLines = nil
			return m, tea.Batch(m.sp.Tick, m.applyCmd(), m.streamReadCmd())
		}
	}
	return m, nil
}

// outputMaxScroll returns the largest valid outputScroll given the current
// terminal height. The output viewer reserves ~4 rows for chrome.
func (m *Model) outputMaxScroll() int {
	lines := strings.Count(m.lastOutput, "\n") + 1
	avail := m.height - 4
	if avail < 1 {
		avail = 1
	}
	if lines <= avail {
		return 0
	}
	return lines - avail
}

func (m *Model) shiftFocus(d int) {
	zones := []focusZone{focusLabs, focusDetail}
	cur := 0
	for i, z := range zones {
		if z == m.focus {
			cur = i
			break
		}
	}
	cur = (cur + d + len(zones)) % len(zones)
	m.focus = zones[cur]
}

func (m *Model) moveUp()   { m.moveInZone(-1) }
func (m *Model) moveDown() { m.moveInZone(1) }

func (m *Model) moveInZone(d int) {
	switch m.focus {
	case focusLabs:
		prev := m.cursor
		m.moveCursor(d)
		if m.cursor != prev {
			m.detailScroll = 0
		}
	case focusDetail:
		m.detailScroll += d
		if m.detailScroll < 0 {
			m.detailScroll = 0
		}
	}
}

func (m *Model) moveCursor(d int) {
	n := len(m.items)
	for i := 0; i < n; i++ {
		m.cursor = (m.cursor + d + n) % n
		if !m.items[m.cursor].isHdr {
			return
		}
	}
}

func (m *Model) toggleCurrent() {
	it := &m.items[m.cursor]
	if it.isHdr {
		return
	}
	it.enabled = !it.enabled
	m.cfg.Enabled[it.lab.Slug] = it.enabled
	if err := m.cfg.Save(); err != nil {
		m.status = statusErr.Render("save failed: " + err.Error())
	}
}

func (m *Model) applyCmd() tea.Cmd {
	// Fresh channel per apply. The runner writes lines to it; streamReadCmd
	// reads them; this goroutine closes it after terraform exits, which
	// triggers a streamClosedMsg on the read side.
	ch := make(chan string, 256)
	m.streamCh = ch
	m.rn.SetStream(ch)
	return func() tea.Msg {
		err := m.rn.Apply()
		m.rn.SetStream(nil)
		close(ch)
		return applyDoneMsg{err: err, output: m.rn.LastOutput()}
	}
}

// streamReadCmd waits for one line on the current stream channel and emits it
// as a streamLineMsg, or streamClosedMsg if the channel has closed. The view
// re-issues this command after each line so streaming continues until
// end-of-stream.
func (m *Model) streamReadCmd() tea.Cmd {
	ch := m.streamCh
	if ch == nil {
		return nil
	}
	return func() tea.Msg {
		line, ok := <-ch
		if !ok {
			return streamClosedMsg{}
		}
		return streamLineMsg(line)
	}
}

// View ------------------------------------------------------------------------

func (m *Model) View() string {
	if m.outputViewer {
		return m.renderOutputViewer()
	}
	labsW, detailW, showDetail := m.columnWidths()

	// Banner spans the full width of the rendered columns (each column adds 2
	// border chars). Measured before bodyH so its height can be charged to
	// chrome — otherwise the layout would overflow the terminal by its height.
	totalW := labsW + 2
	if showDetail {
		totalW += detailW + 2
	}
	banner := renderBanner(totalW)

	// Body height = terminal height minus chrome (title row + banner + margin
	// row + help row + spacers). Status adds more — reserve for it so the
	// title never scrolls off the top.
	chrome := 4 + strings.Count(banner, "\n") + 1
	if m.status != "" || m.applying {
		chrome += 2
	}
	bodyH := m.height - chrome
	if bodyH < 12 {
		bodyH = 12
	}

	labsBorder, detailBorder := m.borderStyles()

	cols := []string{}
	labsContentW := labsW - 4
	if labsContentW < 20 {
		labsContentW = 20
	}
	cols = append(cols, labsBorder.Width(labsW).Height(bodyH).Render(m.renderLabs(bodyH, labsContentW)))
	if showDetail {
		detailContentW := detailW - 4
		if detailContentW < 20 {
			detailContentW = 20
		}
		cols = append(cols, detailBorder.Width(detailW).Height(bodyH).Render(m.renderDetail(bodyH, detailContentW)))
	}
	colsOut := lipgloss.JoinHorizontal(lipgloss.Top, cols...)

	title := titleStyle.Render("so-aws-lab")
	verboseInner := "v stream (off)"
	if m.verbose {
		verboseInner = lipgloss.NewStyle().
			Bold(true).
			Foreground(awsOrange).
			Render("v stream (ON)")
	}
	hasOutput := m.lastOutput != ""
	outputHint := ""
	if hasOutput {
		outputHint = " • o output"
	}
	help := helpStyle.Render(
		"←/→ focus • ↑/↓ move • space toggle • a apply • " + verboseInner + outputHint + " • q quit",
	)
	var statusLine string
	if m.applying {
		statusLine = "\n" + m.sp.View() + " applying terraform..."
		if m.verbose {
			statusLine += m.renderStreamTail()
		}
	} else if m.status != "" {
		statusLine = "\n" + m.status
	}

	body := title + "\n" + banner + "\n" + colsOut + "\n" + help + statusLine
	return body
}

// renderStreamTail returns the last few lines of live terraform output,
// stripped of ANSI sequences and width-clipped to fit on a single visual row
// each. Used during apply when verbose is on so the user sees real progress
// instead of a blank spinner. The number of lines shown scales with the
// terminal so the pane never crowds the help line — minimum 3, maximum 10.
func (m *Model) renderStreamTail() string {
	if len(m.streamLines) == 0 {
		return ""
	}
	rows := 5
	if m.height > 40 {
		rows = 8
	}
	if m.height > 60 {
		rows = 10
	}
	if rows < 3 {
		rows = 3
	}
	start := len(m.streamLines) - rows
	if start < 0 {
		start = 0
	}
	tail := m.streamLines[start:]
	width := m.width
	if width < 40 {
		width = 40
	}
	out := make([]string, 0, len(tail))
	for _, raw := range tail {
		s := strings.TrimRight(stripANSI(raw), " \t")
		if len(s) > width-2 {
			s = s[:width-3] + "…"
		}
		out = append(out, dimAcct.Render(s))
	}
	return "\n" + strings.Join(out, "\n")
}

// renderOutputViewer is the fullscreen view that takes over the TUI when the
// user presses `o` after a captured run. It scrolls through `lastOutput` line
// by line and ignores the 3-column layout.
func (m *Model) renderOutputViewer() string {
	width := m.width
	if width < 40 {
		width = 40
	}
	title := titleStyle.Render("so-aws-lab — terraform output")
	help := helpStyle.Render(
		"↑/↓ scroll • pgup/pgdn ±10 • g top • G bottom • o/esc/q close",
	)

	if strings.TrimSpace(m.lastOutput) == "" {
		empty := dimAcct.Render("(no terraform output captured yet — run an apply with `a` first)")
		return title + "\n\n" + empty + "\n\n" + help
	}

	// Split, strip ANSI, hard-truncate each line to width-1 so terminal
	// soft-wrap doesn't mess up the scroll arithmetic.
	all := strings.Split(strings.TrimRight(m.lastOutput, "\n"), "\n")
	cleaned := make([]string, 0, len(all))
	for _, l := range all {
		l = strings.TrimRight(l, " \t")
		stripped := stripANSI(l)
		if len(stripped) > width-1 {
			stripped = stripped[:width-2] + "…"
		}
		cleaned = append(cleaned, stripped)
	}

	// Window the visible region.
	avail := m.height - 3 // title + help + safety
	if avail < 5 {
		avail = 5
	}
	if m.outputScroll < 0 {
		m.outputScroll = 0
	}
	max := len(cleaned) - avail
	if max < 0 {
		max = 0
	}
	if m.outputScroll > max {
		m.outputScroll = max
	}
	end := m.outputScroll + avail
	if end > len(cleaned) {
		end = len(cleaned)
	}
	visible := cleaned[m.outputScroll:end]

	posHint := fmt.Sprintf("  (lines %d-%d of %d)", m.outputScroll+1, end, len(cleaned))
	return title + dimAcct.Render(posHint) + "\n" +
		outputStyle.Render(strings.Join(visible, "\n")) + "\n" +
		help
}

// stripANSI removes ANSI escape sequences from s. Crude but adequate for the
// terraform output we capture (CSI sequences only).
func stripANSI(s string) string {
	var out strings.Builder
	out.Grow(len(s))
	inEsc := false
	for i := 0; i < len(s); i++ {
		if inEsc {
			c := s[i]
			// CSI sequences end with a byte in the range 0x40..0x7E.
			if c >= 0x40 && c <= 0x7E {
				inEsc = false
			}
			continue
		}
		if s[i] == 0x1b && i+1 < len(s) && s[i+1] == '[' {
			inEsc = true
			i++ // skip '['
			continue
		}
		out.WriteByte(s[i])
	}
	return out.String()
}

func (m *Model) borderStyles() (lipgloss.Style, lipgloss.Style) {
	l, d := colBorder, colBorder
	switch m.focus {
	case focusLabs:
		l = colBorderFocused
	case focusDetail:
		d = colBorderFocused
	}
	return l, d
}

// columnWidths returns per-column widths plus whether the detail pane is
// shown given the current terminal width. The lab list is always visible.
//
// Tiers:
//
//	width >= 70  → labs (~40%) + detail (~60%)
//	width < 70   → very narrow: show only the focused column
func (m *Model) columnWidths() (labsW, detailW int, showDetail bool) {
	w := m.width
	if w <= 0 {
		w = 120 // initial guess before WindowSizeMsg
	}
	// Each visible column consumes 2 border chars; between columns
	// JoinHorizontal adds no extra gap.
	switch {
	case w >= 70:
		showDetail = true
		rem := w - 4
		labsW = rem * 4 / 10
		detailW = rem - labsW
	default:
		// Very narrow: collapse to whichever column has focus.
		showDetail = m.focus == focusDetail
		if showDetail {
			detailW = w - 2
		} else {
			labsW = w - 2
		}
	}
	if labsW < 28 && w >= 50 {
		labsW = 28
	}
	if detailW < 30 && showDetail && w >= 80 {
		detailW = 30
	}
	return
}

func (m *Model) sectionTitle(name string, focused bool) string {
	if focused {
		return colTitleFocused.Render(name)
	}
	return colTitle.Render(name)
}

func (m *Model) renderLabs(viewportH, contentW int) string {
	// Build the full list into a slice of styled lines, then take a window
	// around the lab cursor so the focused lab is always visible even on
	// short terminals.
	type renderedItem struct {
		text     string
		itemIdx  int // index into m.items, or -1 for headers/spacers
		isCursor bool
	}
	rows := []renderedItem{}
	firstHeader := true
	for i, it := range m.items {
		if it.isHdr {
			if !firstHeader {
				rows = append(rows, renderedItem{text: "", itemIdx: -1})
			}
			firstHeader = false
			rows = append(rows, renderedItem{
				text:    categoryStyle.Render(it.lab.Category),
				itemIdx: -1,
			})
			continue
		}
		cursor := "  "
		if i == m.cursor && m.focus == focusLabs {
			cursor = cursorStyle.Render("> ")
		}
		mark := "[ ]"
		style := disabledStyle
		if it.enabled {
			mark = "[x]"
			style = enabledStyle
		}
		cost := costBadge(it.lab)
		// Wrapped titles hang under the title column rather than resetting to
		// the pane edge, so the checkbox gutter stays visually intact.
		rows = append(rows, renderedItem{
			text: hang(
				cursor+style.Render(mark)+" ",
				style.Render(it.lab.Title)+cost,
				contentW,
			),
			itemIdx:  i,
			isCursor: i == m.cursor,
		})
	}

	header := m.sectionTitle("Labs", m.focus == focusLabs)
	// viewportH covers the bordered box; subtract 2 for border + 1 for the
	// "Labs" header line.
	avail := viewportH - 3
	if avail < 5 {
		avail = 5
	}
	if len(rows) <= avail {
		// Everything fits.
		parts := []string{header}
		for _, r := range rows {
			parts = append(parts, r.text)
		}
		return strings.Join(parts, "\n")
	}

	// Find the cursor's row position.
	cursorRow := 0
	for i, r := range rows {
		if r.isCursor {
			cursorRow = i
			break
		}
	}
	// Center the cursor in the visible window (clamped to ends).
	start := cursorRow - avail/2
	if start < 0 {
		start = 0
	}
	if start+avail > len(rows) {
		start = len(rows) - avail
	}
	end := start + avail

	parts := []string{header}
	if start > 0 {
		parts = append(parts, dimAcct.Render(fmt.Sprintf("▲ %d more", start)))
		// Drop one row to make space for the marker.
		end--
	}
	for i := start; i < end && i < len(rows); i++ {
		parts = append(parts, rows[i].text)
	}
	if end < len(rows) {
		parts = append(parts, dimAcct.Render(fmt.Sprintf("▼ %d more", len(rows)-end)))
	}
	return strings.Join(parts, "\n")
}

// costBadge renders a compact cost suffix for the lab list. Free labs get no
// badge so the list stays clean; anything billed shows the per-day estimate
// in the AWS sky color when enabled, dim otherwise.
func costBadge(l labs.Lab) string {
	if l.DailyUSD <= 0 {
		return ""
	}
	return "  " + dimAcct.Render(fmt.Sprintf("$%.2f/day", l.DailyUSD))
}

// totalDailyUSD sums daily_usd across enabled labs, deduping by
// shared_resource so labs that share infra (e.g. EKS cluster) are only
// counted once.
func (m *Model) totalDailyUSD() float64 {
	var total float64
	seenShared := map[string]bool{}
	for _, l := range m.all {
		if !m.cfg.Enabled[l.Slug] {
			continue
		}
		if l.SharedResource != "" {
			if seenShared[l.SharedResource] {
				continue
			}
			seenShared[l.SharedResource] = true
		}
		total += l.DailyUSD
	}
	return total
}

// renderDetail builds the right-column card for the focused lab.
//
// Layout (top to bottom):
//  1. Title + slug (pinned)
//  2. identities section: entry/target/victim?/flag
//  3. scenario section: wrapped technique blurb from labs.yaml
//  4. docs section: paths to docs/Labs/<Title>.md and docs/Walkthroughs/...
//
// No markdown is parsed or rendered. All values are deterministic from the
// labs.yaml entry + lab_prefix, so the panel is correct whether or not the
// lab is currently deployed.
func (m *Model) renderDetail(bodyH, contentW int) string {
	if m.cursor >= len(m.items) {
		return ""
	}
	it := m.items[m.cursor]
	if it.isHdr {
		return m.sectionTitle("Detail", m.focus == focusDetail) + "\n\n" +
			dimAcct.Render("Hover a lab to see its description.")
	}
	l := it.lab

	titleStr := colTitle.Render(l.Title)
	if m.focus == focusDetail {
		titleStr = colTitleFocused.Render(l.Title)
	}
	prefix := m.cfg.LabPrefix

	headerRows := []string{
		titleStr,
		dimAcct.Render(l.Slug),
		"",
	}

	// The entry role is where every lab starts. It lives in the lab's first
	// account (dev for single-account labs) and is assumed from that account's
	// profile.
	entryAcct := labAccounts(l)[0]
	acct := m.cfg.AccountOr(entryAcct)
	acctID := m.accountIDs[entryAcct]
	entryARN := iamRoleARN(acctID, entryAcct, prefix, l.Slug, "carl")
	targetARN := iamRoleARN(acctID, entryAcct, prefix, l.Slug, "donut")

	bodyRows := []string{
		sectionLabel.Render("identities"),
		hang("  "+detailKey.Render("entry  "), detailVal.Render(entryARN), contentW),
		hang("  "+detailKey.Render("target "), detailVal.Render(targetARN), contentW),
	}
	if l.HasVictim {
		bodyRows = append(bodyRows,
			hang("  "+detailKey.Render("victim "), detailVal.Render(prefix+"-"+l.Slug+"-bopca"), contentW))
	}
	bodyRows = append(bodyRows,
		hang("  "+detailKey.Render("flag   "), detailVal.Render("/labs/"+prefix+"/"+l.Slug+"/flag"), contentW),
		"")

	// Start-of-lab. Prefer the ready-made profile (written to ~/.aws/config on
	// apply); keep the manual assume-role command as a fallback. Session name
	// defaults to the current OS user for CloudTrail attribution.
	profileName := prefix + "-" + l.Slug + "-carl"
	sess := awsconfig.CurrentSessionName()
	bodyRows = append(bodyRows,
		sectionLabel.Render("start — entry role"),
		hang("  "+detailKey.Render("profile "), detailVal.Render(profileName), contentW),
		"  "+dimAcct.Render("(added to ~/.aws/config on apply)"),
		hang("  ", detailVal.Render("aws --profile "+profileName+" sts get-caller-identity"), contentW),
		"",
		"  "+dimAcct.Render("or assume it manually:"),
	)
	for _, cl := range []string{
		"aws sts assume-role \\",
		"  --role-arn " + entryARN + " \\",
		"  --role-session-name " + sess + " \\",
		"  --profile " + acct.Profile,
	} {
		// Continuation lines hang under the flag itself, keeping the two-space
		// argument indent of the copyable command readable when it wraps.
		indent := "  " + strings.Repeat(" ", len(cl)-len(strings.TrimLeft(cl, " ")))
		bodyRows = append(bodyRows, hangHard(indent, detailVal.Render(strings.TrimLeft(cl, " ")), contentW))
	}
	if acctID == "" {
		bodyRows = append(bodyRows, "  "+dimAcct.Render("(resolving account id…)"))
	}
	bodyRows = append(bodyRows, "")

	// Accounts span — visible for every lab. Single-account labs just show
	// "dev"; the capstone shows "dev → staging → prod".
	if accts := labAccounts(l); len(accts) > 0 {
		bodyRows = append(bodyRows,
			sectionLabel.Render("accounts"),
			"  "+detailVal.Render(strings.Join(accts, " → ")),
			"")
	}

	// Scenario blurb — wrap the lab.Technique line to the content width
	// (less the 2-space indent we add per line).
	scenarioW := contentW - 2
	if scenarioW < 20 {
		scenarioW = 20
	}
	scenarioWrapped := wrap.String(l.Technique, scenarioW)
	bodyRows = append(bodyRows, sectionLabel.Render("scenario"))
	for _, line := range strings.Split(scenarioWrapped, "\n") {
		bodyRows = append(bodyRows, "  "+detailVal.Render(line))
	}
	bodyRows = append(bodyRows, "")

	// Cost section.
	bodyRows = append(bodyRows, sectionLabel.Render("cost"))
	costStyle := detailVal
	if l.DailyUSD > 0 {
		costStyle = lipgloss.NewStyle().Foreground(awsOrange)
	}
	bodyRows = append(bodyRows, "  "+costStyle.Render(l.Cost))
	if l.DailyUSD > 0 {
		bodyRows = append(bodyRows,
			"  "+detailKey.Render(fmt.Sprintf("approx. $%.2f/day  $%.2f/mo",
				l.DailyUSD, l.DailyUSD*30)))
	}
	bodyRows = append(bodyRows, "")

	// Deployment footer — global (not per-lab): the lab prefix everything is
	// named with, and the running cost across all currently-enabled labs.
	// This used to live in the accounts column, which no longer exists.
	bodyRows = append(bodyRows, sectionLabel.Render("deployment"))
	bodyRows = append(bodyRows, hang("  "+detailKey.Render("prefix       "), detailVal.Render(prefix), contentW))
	daily := m.totalDailyUSD()
	if daily <= 0 {
		bodyRows = append(bodyRows, hang("  "+detailKey.Render("running cost "), detailVal.Render("$0.00/day"), contentW))
	} else {
		costColor := lipgloss.NewStyle().Foreground(awsOrange).Bold(true)
		bodyRows = append(bodyRows,
			hang("  "+detailKey.Render("running cost "),
				costColor.Render(fmt.Sprintf("$%.2f/day  $%.2f/mo", daily, daily*30)), contentW))
	}

	// Scroll offset shifts the body; the header (title + slug) stays pinned.
	if m.detailScroll > 0 {
		if m.detailScroll < len(bodyRows) {
			bodyRows = bodyRows[m.detailScroll:]
		} else if len(bodyRows) > 0 {
			bodyRows = bodyRows[len(bodyRows)-1:]
		}
	}

	full := append(headerRows, bodyRows...)
	maxLines := bodyH - 2
	if maxLines > 0 && len(full) > maxLines {
		full = full[:maxLines]
	}
	return strings.Join(full, "\n")
}

// Utilities ------------------------------------------------------------------

func tailLines(s string, n int) string {
	lines := strings.Split(s, "\n")
	if len(lines) <= n {
		return s
	}
	return strings.Join(lines[len(lines)-n:], "\n")
}

// hang renders prefix+body on one line when it fits, and otherwise wraps body
// so continuation lines start under the body rather than at the pane edge:
//
//	entry  arn:aws:iam::123456789012:role/so-aws-lab-
//	       createpolicyversion-carl
//
// rather than the default soft-wrap, which drops the remainder to column 0.
//
// prefix and body may both carry ANSI styling; widths are measured with
// PrintableRuneWidth so escape sequences don't count toward the column budget.
// body is word-wrapped first, then hard-wrapped, so an unbreakable token like
// an ARN still gets split instead of overflowing the pane.
func hang(prefix, body string, width int) string {
	return hangWith(prefix, body, width, true)
}

// hangHard is hang without word-wrapping, for copyable shell commands. Word
// wrapping breaks at spaces, which strands a trailing "\" line-continuation
// marker alone on the next line and splits a flag from its value. Breaking at
// the column keeps the command visually contiguous.
func hangHard(prefix, body string, width int) string {
	return hangWith(prefix, body, width, false)
}

func hangWith(prefix, body string, width int, wordBreak bool) string {
	indent := ansi.PrintableRuneWidth(prefix)
	// Nothing to do when it already fits — importantly, this keeps rows that
	// fit within width from being re-wrapped at the narrower body width.
	if width <= 0 || ansi.PrintableRuneWidth(prefix+body) <= width {
		return prefix + body
	}
	avail := width - indent
	if avail < 8 {
		// Indent so deep there's no usable room left; fall back to plain
		// wrapping rather than rendering a one-character-wide column.
		return prefix + body
	}
	wrapped := body
	if wordBreak {
		// Word-wrap on spaces only. reflow's default breakpoints include '-',
		// which shreds hyphen-dense values like ARNs and role names into
		// fragments (and can strand a lone "-" on its own line).
		ww := wordwrap.NewWriter(avail)
		ww.Breakpoints = []rune{}
		ww.KeepNewlines = true
		_, _ = ww.Write([]byte(body))
		_ = ww.Close()
		wrapped = ww.String()
	}
	// Anything still over the limit — an ARN has no spaces at all — is broken
	// at the column here. wrap.String preserves ANSI state within a line.
	lines := reopenANSI(strings.Split(wrap.String(wrapped, avail), "\n"))
	pad := strings.Repeat(" ", indent)
	for i := range lines {
		if i == 0 {
			lines[i] = prefix + lines[i]
			continue
		}
		lines[i] = pad + lines[i]
	}
	return strings.Join(lines, "\n")
}

// sgrRE matches SGR (color/attribute) escape sequences.
var sgrRE = regexp.MustCompile(`\x1b\[[0-9;]*m`)

// reopenANSI makes each line style-independent: any SGR still active at the end
// of a line is closed there and re-opened at the start of the next.
//
// Wrapping alone isn't enough. A terminal would carry SGR state across a bare
// newline, but these lines are handed to lipgloss, which renders each one into
// a bordered box — emitting border color and resets between them. Without
// re-opening, every continuation line renders in the default foreground.
func reopenANSI(lines []string) []string {
	const reset = "\x1b[0m"
	active := ""
	out := make([]string, len(lines))
	for i, ln := range lines {
		carried := active
		// Track the style in effect at the end of this line. lipgloss emits one
		// combined sequence per styled run, so last-one-wins is accurate here.
		for _, seq := range sgrRE.FindAllString(ln, -1) {
			if seq == reset || seq == "\x1b[m" {
				active = ""
				continue
			}
			active = seq
		}
		out[i] = carried + ln
		if active != "" {
			out[i] += reset
		}
	}
	return out
}

// wrap is a tiny word-wrap implementation for the detail pane.
func wrapPlain(s string, n int) string {
	if n <= 0 || len(s) <= n {
		return s
	}
	words := strings.Fields(s)
	if len(words) == 0 {
		return s
	}
	var lines []string
	line := words[0]
	for _, w := range words[1:] {
		if len(line)+1+len(w) > n {
			lines = append(lines, line)
			line = w
		} else {
			line += " " + w
		}
	}
	lines = append(lines, line)
	return strings.Join(lines, "\n")
}

// labAccounts returns the lab's account list with a default of ["dev"] when
// the field is unset, so existing single-account labs still render a row.
func labAccounts(l labs.Lab) []string {
	if len(l.Accounts) == 0 {
		return []string{"dev"}
	}
	return l.Accounts
}

// iamRoleARN builds the full ARN for a lab role, matching the terraform naming
// convention (<prefix>-<slug>-<kind>). When the account ID hasn't resolved yet
// it substitutes a readable placeholder so the ARN shape is still clear.
func iamRoleARN(accountID, accountName, prefix, slug, kind string) string {
	id := accountID
	if id == "" {
		id = "<" + accountName + "-account-id>"
	}
	return fmt.Sprintf("arn:aws:iam::%s:role/%s-%s-%s", id, prefix, slug, kind)
}

// Run starts the TUI program. verbose seeds the initial verbose toggle.
func Run(cfg *config.Config, ll []labs.Lab, verbose bool) error {
	m := New(cfg, ll, verbose)
	_, err := tea.NewProgram(m, tea.WithAltScreen()).Run()
	return err
}
