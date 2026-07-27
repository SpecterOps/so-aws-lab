#!/bin/sh
# Regenerate THIRD_PARTY_NOTICES.md from the modules actually linked into the
# so-aws-lab binary.
#
# The MIT/BSD licenses of our dependencies require their notices to travel with
# redistributed copies — and a compiled binary is a redistributed copy, since
# that dependency code is statically linked into it. This collects them.
#
# Deliberately dependency-free (no go-licenses): it runs unattended in the
# GoReleaser before-hook, so it must not need anything beyond the Go toolchain.
set -eu

cd "$(dirname "$0")/.."

MAIN=$(go list -m)
OUT="THIRD_PARTY_NOTICES.md"
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT INT TERM

{
  printf '# Third-party notices\n\n'
  printf 'so-aws-lab is distributed as a statically linked binary that includes\n'
  printf 'the following third-party modules. Each is reproduced below with its\n'
  printf 'original license text, as those licenses require.\n\n'
  printf 'Regenerate with `make third-party`.\n'
} > "$tmp"

# -deps over the actual command (not ./...) so test-only and tooling deps are
# excluded — only what ships in the binary is listed.
mods=$(go list -deps -f '{{if .Module}}{{.Module.Path}}{{end}}' ./cmd/so-aws-lab \
  | grep -v "^$MAIN$" | grep . | sort -u)

missing=""
for mod in $mods; do
  dir=$(go list -m -f '{{.Dir}}' "$mod" 2>/dev/null || true)
  if [ -z "$dir" ] || [ ! -d "$dir" ]; then
    missing="$missing $mod"
    continue
  fi
  lic=$(find "$dir" -maxdepth 1 \
    \( -iname 'LICENSE' -o -iname 'LICENSE.*' -o -iname 'COPYING' -o -iname 'COPYING.*' \) \
    2>/dev/null | sort | head -n 1)
  if [ -z "$lic" ]; then
    missing="$missing $mod"
    continue
  fi
  {
    printf '\n---\n\n## %s\n\n```\n' "$mod"
    cat "$lic"
    printf '```\n'
  } >> "$tmp"
done

if [ -n "$missing" ]; then
  printf 'error: no license file found for:%s\n' "$missing" >&2
  printf '       vendor its notice by hand before releasing.\n' >&2
  exit 1
fi

mv "$tmp" "$OUT"
trap - EXIT INT TERM
printf 'wrote %s (%s modules)\n' "$OUT" "$(printf '%s\n' "$mods" | wc -l | tr -d ' ')"
