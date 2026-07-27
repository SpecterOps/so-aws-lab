package tui

import (
	"fmt"
	"strings"

	tea "github.com/charmbracelet/bubbletea"
)

// picker is a minimal fullscreen single-select list used by the setup wizard
// (e.g. choosing an AWS profile or region). It reuses the dashboard's styles so
// the whole tool looks consistent.
type picker struct {
	title     string
	options   []string
	cursor    int
	cancelled bool
	width     int
	height    int
}

func (p picker) Init() tea.Cmd { return nil }

func (p picker) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		p.width, p.height = msg.Width, msg.Height
	case tea.KeyMsg:
		switch msg.String() {
		case "ctrl+c", "esc", "q":
			p.cancelled = true
			return p, tea.Quit
		case "up", "k":
			if p.cursor > 0 {
				p.cursor--
			}
		case "down", "j":
			if p.cursor < len(p.options)-1 {
				p.cursor++
			}
		case "home", "g":
			p.cursor = 0
		case "end", "G":
			p.cursor = len(p.options) - 1
		case "pgup":
			if p.cursor -= 10; p.cursor < 0 {
				p.cursor = 0
			}
		case "pgdown":
			if p.cursor += 10; p.cursor > len(p.options)-1 {
				p.cursor = len(p.options) - 1
			}
		case "enter":
			return p, tea.Quit
		}
	}
	return p, nil
}

func (p picker) View() string {
	title := titleStyle.Render(p.title)
	help := helpStyle.Render("↑/↓ move • enter select • esc cancel")

	avail := p.height - 4
	if avail < 3 {
		avail = 3
	}
	n := len(p.options)
	start := 0
	if n > avail {
		start = p.cursor - avail/2
		if start < 0 {
			start = 0
		}
		if start+avail > n {
			start = n - avail
		}
	}
	end := start + avail
	if end > n {
		end = n
	}

	lines := []string{title, ""}
	if start > 0 {
		lines = append(lines, dimAcct.Render(fmt.Sprintf("  ▲ %d more", start)))
	}
	for i := start; i < end; i++ {
		cursor := "  "
		style := detailVal
		if i == p.cursor {
			cursor = cursorStyle.Render("> ")
			style = enabledStyle
		}
		lines = append(lines, cursor+style.Render(p.options[i]))
	}
	if end < n {
		lines = append(lines, dimAcct.Render(fmt.Sprintf("  ▼ %d more", n-end)))
	}
	lines = append(lines, "", help)
	return strings.Join(lines, "\n")
}

// PickList shows an interactive single-select list and returns the chosen
// index. ok is false if the user cancelled (esc/q/ctrl+c) or the program
// failed to start (e.g. no TTY). initial seeds the highlighted row.
func PickList(title string, options []string, initial int) (idx int, ok bool) {
	if len(options) == 0 {
		return -1, false
	}
	if initial < 0 || initial >= len(options) {
		initial = 0
	}
	m, err := tea.NewProgram(
		picker{title: title, options: options, cursor: initial, width: 80, height: 24},
		tea.WithAltScreen(),
	).Run()
	if err != nil {
		return -1, false
	}
	res := m.(picker)
	if res.cancelled {
		return -1, false
	}
	return res.cursor, true
}
