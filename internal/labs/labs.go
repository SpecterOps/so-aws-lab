package labs

import (
	_ "embed"
	"fmt"

	"gopkg.in/yaml.v3"
)

//go:embed labs.yaml
var rawCatalog []byte

// Lab is one record from labs.yaml.
type Lab struct {
	Slug      string   `yaml:"slug"`
	Title     string   `yaml:"title"`
	Category  string   `yaml:"category"`
	Technique string   `yaml:"technique"`
	HasVictim bool     `yaml:"has_victim"`
	Services  []string `yaml:"services"`
	Cost      string   `yaml:"cost"`
	DailyUSD  float64  `yaml:"daily_usd"`
	// SharedResource, when set, names an infra resource this lab shares with
	// other labs (e.g. the EKS cluster). Cost summation dedupes by this key
	// so we don't double-bill a shared cluster.
	SharedResource string `yaml:"shared_resource,omitempty"`
	// Accounts lists which accounts this lab deploys to. Single-account labs
	// use ["dev"]; the capstone is ["dev", "staging", "prod"].
	Accounts []string `yaml:"accounts,omitempty"`
}

type catalogFile struct {
	Labs []Lab `yaml:"labs"`
}

// Load returns the lab catalog in source order.
func Load() ([]Lab, error) {
	var c catalogFile
	if err := yaml.Unmarshal(rawCatalog, &c); err != nil {
		return nil, fmt.Errorf("decode labs.yaml: %w", err)
	}
	return c.Labs, nil
}

// CategoryOrder returns the categories in display order.
func CategoryOrder() []string {
	return []string{"IAM", "EC2", "Lambda", "CloudFormation", "SSM", "S3", "KMS", "EKS", "Conditions", "Capstone"}
}
