// Package config reads and writes ~/.so-aws-lab/config.yaml — the persistent
// state for the TUI (AWS profiles per named account, lab prefix, enabled
// lab set, and optional multi-student capstone roster).
//
// The terraform is embedded in the binary and extracted by the workspace
// package, so there is no repo path, clone URL, or git ref to configure.
package config

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"

	"gopkg.in/yaml.v3"
)

// DefaultAccountNames is the order init prompts for (and the order shown in
// status). Any subset can be configured; arbitrary additional account names
// can be added by editing the YAML directly.
var DefaultAccountNames = []string{"dev", "staging", "prod"}

// PrimaryAccount is the name of the account every lab deploys to by default.
const PrimaryAccount = "dev"

// Account is one AWS named profile + region. Profile must match a section in
// ~/.aws/credentials or ~/.aws/config.
type Account struct {
	Profile string `yaml:"profile"`
	Region  string `yaml:"region"`
}

// CapstoneConfig controls the optional workshop-scale deployment. Students maps
// a short, stable lab ID to the label printed on that student's access card.
// An empty map preserves the original single-student deployment.
type CapstoneConfig struct {
	Students map[string]string `yaml:"students,omitempty"`
}

type Config struct {
	Accounts  map[string]Account `yaml:"accounts"`
	LabPrefix string             `yaml:"lab_prefix"`
	Enabled   map[string]bool    `yaml:"enabled"`
	Capstone  CapstoneConfig     `yaml:"capstone,omitempty"`

	// Legacy single-account fields. Kept for backwards compat on read; folded
	// into Accounts[PrimaryAccount] on next save.
	LegacyProfile string `yaml:"aws_profile,omitempty"`
	LegacyRegion  string `yaml:"aws_region,omitempty"`
}

func defaultPath() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(home, ".so-aws-lab", "config.yaml"), nil
}

// Load reads ~/.so-aws-lab/config.yaml, applying defaults and migrating legacy
// single-account fields into the accounts map.
func Load() (*Config, error) {
	p, err := defaultPath()
	if err != nil {
		return nil, err
	}
	b, err := os.ReadFile(p)
	if err != nil {
		if os.IsNotExist(err) {
			return newDefault(), nil
		}
		return nil, err
	}
	c := &Config{}
	if err := yaml.Unmarshal(b, c); err != nil {
		return nil, fmt.Errorf("decode config: %w", err)
	}
	c.ensureDefaults()
	c.migrateLegacy()
	return c, nil
}

func newDefault() *Config {
	return &Config{
		Accounts:  map[string]Account{},
		LabPrefix: "so-aws-lab",
		Enabled:   map[string]bool{},
		Capstone: CapstoneConfig{
			Students: map[string]string{},
		},
	}
}

func (c *Config) ensureDefaults() {
	if c.Accounts == nil {
		c.Accounts = map[string]Account{}
	}
	if c.Enabled == nil {
		c.Enabled = map[string]bool{}
	}
	if c.LabPrefix == "" {
		c.LabPrefix = "so-aws-lab"
	}
	if c.Capstone.Students == nil {
		c.Capstone.Students = map[string]string{}
	}
}

// migrateLegacy moves the old flat aws_profile/aws_region fields into
// accounts[PrimaryAccount] if the latter is empty.
func (c *Config) migrateLegacy() {
	if c.LegacyProfile == "" && c.LegacyRegion == "" {
		return
	}
	a := c.Accounts[PrimaryAccount]
	if a.Profile == "" {
		a.Profile = c.LegacyProfile
	}
	if a.Region == "" {
		a.Region = c.LegacyRegion
	}
	if a.Region == "" {
		a.Region = "us-east-1"
	}
	c.Accounts[PrimaryAccount] = a
	// Clear so we don't keep re-migrating + don't write them back.
	c.LegacyProfile = ""
	c.LegacyRegion = ""
}

// Save persists the config to ~/.so-aws-lab/config.yaml.
func (c *Config) Save() error {
	c.ensureDefaults()
	p, err := defaultPath()
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(p), 0o700); err != nil {
		return err
	}
	b, err := yaml.Marshal(c)
	if err != nil {
		return err
	}
	return os.WriteFile(p, b, 0o600)
}

// EnabledSlugs returns lab slugs whose value is true, sorted.
func (c *Config) EnabledSlugs() []string {
	out := []string{}
	for k, v := range c.Enabled {
		if v {
			out = append(out, k)
		}
	}
	sort.Strings(out)
	return out
}

// AccountOr returns the named account if configured, otherwise the primary
// account (the deploy target for any lab that doesn't specify one).
func (c *Config) AccountOr(name string) Account {
	if a, ok := c.Accounts[name]; ok && a.Profile != "" {
		return a
	}
	return c.Accounts[PrimaryAccount]
}

// Primary is the dev account (every existing lab deploys here).
func (c *Config) Primary() Account {
	return c.Accounts[PrimaryAccount]
}

// AccountNames returns the configured account names in DefaultAccountNames
// order first, then any custom keys sorted.
func (c *Config) AccountNames() []string {
	seen := map[string]bool{}
	out := []string{}
	for _, n := range DefaultAccountNames {
		if _, ok := c.Accounts[n]; ok {
			out = append(out, n)
			seen[n] = true
		}
	}
	extras := []string{}
	for n := range c.Accounts {
		if !seen[n] {
			extras = append(extras, n)
		}
	}
	sort.Strings(extras)
	return append(out, extras...)
}

// Ready returns true when the primary account has a profile set. That is the
// only thing setup must establish — the terraform is embedded, so there is no
// repo path to validate.
func (c *Config) Ready() bool {
	return c.Primary().Profile != ""
}

// Path returns the resolved config-file path (for error messages).
func Path() string {
	p, _ := defaultPath()
	return p
}

// Exists reports whether the config file is present on disk. Used to decide
// whether the account-setup wizard needs to run before the TUI opens.
func Exists() bool {
	p, err := defaultPath()
	if err != nil {
		return false
	}
	_, err = os.Stat(p)
	return err == nil
}
