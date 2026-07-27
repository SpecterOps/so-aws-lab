package config

import (
	"bufio"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// ListProfiles returns the union of profile names discovered in
// ~/.aws/credentials and ~/.aws/config, sorted alphabetically with `default`
// surfaced first. Profile names are parsed from INI-style section headers:
//
//	~/.aws/credentials  [name]               -> name
//	~/.aws/config       [default]            -> default
//	                    [profile name]       -> name
//
// `current` (if not empty) is appended to the result if not already present,
// so an existing config value the user can't see in the files is still
// selectable.
func ListProfiles(current string) []string {
	set := map[string]struct{}{}
	home, _ := os.UserHomeDir()

	readSections := func(path string, normalize func(string) (string, bool)) {
		f, err := os.Open(path)
		if err != nil {
			return
		}
		defer f.Close()
		sc := bufio.NewScanner(f)
		for sc.Scan() {
			line := strings.TrimSpace(sc.Text())
			if !strings.HasPrefix(line, "[") || !strings.HasSuffix(line, "]") {
				continue
			}
			raw := strings.TrimSuffix(strings.TrimPrefix(line, "["), "]")
			if name, ok := normalize(raw); ok && name != "" {
				set[name] = struct{}{}
			}
		}
	}

	// credentials: section header IS the profile name
	readSections(filepath.Join(home, ".aws", "credentials"), func(raw string) (string, bool) {
		return raw, true
	})
	// config: [default] or [profile NAME]
	readSections(filepath.Join(home, ".aws", "config"), func(raw string) (string, bool) {
		if raw == "default" {
			return "default", true
		}
		if strings.HasPrefix(raw, "profile ") {
			return strings.TrimSpace(strings.TrimPrefix(raw, "profile")), true
		}
		return "", false
	})

	if current != "" {
		set[current] = struct{}{}
	}

	out := make([]string, 0, len(set))
	for n := range set {
		out = append(out, n)
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i] == "default" {
			return true
		}
		if out[j] == "default" {
			return false
		}
		return out[i] < out[j]
	})
	return out
}

// Regions returns a curated list of AWS commercial regions in roughly
// usage-frequency order.
func Regions() []string {
	return []string{
		"us-east-1",
		"us-east-2",
		"us-west-1",
		"us-west-2",
		"ca-central-1",
		"eu-west-1",
		"eu-west-2",
		"eu-west-3",
		"eu-central-1",
		"eu-north-1",
		"eu-south-1",
		"ap-northeast-1",
		"ap-northeast-2",
		"ap-northeast-3",
		"ap-south-1",
		"ap-southeast-1",
		"ap-southeast-2",
		"sa-east-1",
		"af-south-1",
		"me-south-1",
	}
}
