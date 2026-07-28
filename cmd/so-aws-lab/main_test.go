package main

import (
	"reflect"
	"testing"
)

func TestParseCapstoneStudents(t *testing.T) {
	got, err := parseCapstoneStudents([]string{
		"student01=Alice",
		"red-2",
	})
	if err != nil {
		t.Fatal(err)
	}
	want := map[string]string{
		"student01": "Alice",
		"red-2":     "red-2",
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("students = %#v, want %#v", got, want)
	}
}

func TestParseCapstoneStudentCount(t *testing.T) {
	got, err := parseCapstoneStudents([]string{"3"})
	if err != nil {
		t.Fatal(err)
	}
	want := map[string]string{
		"student01": "student01",
		"student02": "student02",
		"student03": "student03",
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("students = %#v, want %#v", got, want)
	}
}

func TestParseCapstoneStudentCountRejectsOutOfRange(t *testing.T) {
	for _, count := range []string{"0", "51", "999999999999999999999"} {
		if _, err := parseCapstoneStudents([]string{count}); err == nil {
			t.Errorf("parseCapstoneStudents(%q) succeeded, want error", count)
		}
	}
}

func TestParseCapstoneStudentsRejectsUnsafeIDs(t *testing.T) {
	for _, input := range []string{
		"Student=Alice",
		"default=Alice",
		"student-id-is-too-long=Alice",
		"student01=",
		"student01=Alice",
	} {
		args := []string{input}
		if input == "student01=Alice" {
			args = append(args, input)
		}
		if _, err := parseCapstoneStudents(args); err == nil {
			t.Errorf("parseCapstoneStudents(%q) succeeded, want error", args)
		}
	}
}
