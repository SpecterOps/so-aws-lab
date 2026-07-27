#!/bin/sh
# Install so-aws-lab into ~/.local/bin (or $SO_AWS_LAB_BIN_DIR).
#
#   curl -fsSL https://raw.githubusercontent.com/specterops/so-aws-lab/main/install.sh | sh
#
# Environment:
#   SO_AWS_LAB_VERSION   tag to install (e.g. v0.1.0). Default: latest release.
#   SO_AWS_LAB_BIN_DIR   install directory. Default: ~/.local/bin
set -eu

OWNER="specterops"
REPO="so-aws-lab"
BIN="so-aws-lab"
BIN_DIR="${SO_AWS_LAB_BIN_DIR:-$HOME/.local/bin}"

info()  { printf '  %s\n' "$*"; }
warn()  { printf '  warning: %s\n' "$*" >&2; }
die()   { printf 'error: %s\n' "$*" >&2; exit 1; }

# --- download helper ---------------------------------------------------------
# Prefer curl, fall back to wget. Both are told to fail loudly on HTTP errors —
# silently writing a 404 body to the output file is how install scripts end up
# "installing" an HTML error page.
if command -v curl >/dev/null 2>&1; then
  fetch()  { curl -fsSL "$1"; }
  fetch_to() { curl -fsSL -o "$2" "$1"; }
elif command -v wget >/dev/null 2>&1; then
  fetch()  { wget -qO- "$1"; }
  fetch_to() { wget -qO "$2" "$1"; }
else
  die "need curl or wget"
fi

# --- platform ----------------------------------------------------------------
os=$(uname -s)
case "$os" in
  Darwin) goos="darwin" ;;
  Linux)  goos="linux" ;;
  *)      die "unsupported OS: $os (Windows: download the .zip from the releases page)" ;;
esac

arch=$(uname -m)
case "$arch" in
  x86_64|amd64)  goarch="amd64" ;;
  arm64|aarch64) goarch="arm64" ;;
  *)             die "unsupported architecture: $arch" ;;
esac

# --- resolve version ---------------------------------------------------------
version="${SO_AWS_LAB_VERSION:-}"
if [ -z "$version" ]; then
  info "resolving latest release..."
  version=$(fetch "https://api.github.com/repos/$OWNER/$REPO/releases/latest" \
    | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
    | head -n 1)
  [ -n "$version" ] || die "could not determine the latest release (rate-limited? set SO_AWS_LAB_VERSION=vX.Y.Z)"
fi

# Archive names carry no version — see the name_template note in .goreleaser.yaml.
archive="${REPO}_${goos}_${goarch}.tar.gz"
base="https://github.com/$OWNER/$REPO/releases/download/$version"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM

info "downloading $BIN $version ($goos/$goarch)"
fetch_to "$base/$archive" "$tmp/$archive" \
  || die "download failed: $base/$archive"

# --- verify checksum ---------------------------------------------------------
# A piped-to-shell installer that skips verification is just a remote code
# execution primitive with extra steps.
if command -v sha256sum >/dev/null 2>&1; then
  sha_cmd="sha256sum"
elif command -v shasum >/dev/null 2>&1; then
  sha_cmd="shasum -a 256"
else
  sha_cmd=""
fi

if [ -n "$sha_cmd" ]; then
  if fetch_to "$base/checksums.txt" "$tmp/checksums.txt" 2>/dev/null; then
    expected=$(awk -v f="$archive" '$2 == f || $2 == "*"f {print $1}' "$tmp/checksums.txt" | head -n 1)
    if [ -n "$expected" ]; then
      actual=$($sha_cmd "$tmp/$archive" | awk '{print $1}')
      [ "$expected" = "$actual" ] || die "checksum mismatch for $archive
  expected $expected
  actual   $actual"
      info "checksum verified"
    else
      warn "$archive not listed in checksums.txt — skipping verification"
    fi
  else
    warn "could not download checksums.txt — skipping verification"
  fi
else
  warn "no sha256sum/shasum available — skipping verification"
fi

# --- install -----------------------------------------------------------------
tar -xzf "$tmp/$archive" -C "$tmp" || die "could not extract $archive"
[ -f "$tmp/$BIN" ] || die "$BIN not found inside $archive"

mkdir -p "$BIN_DIR" || die "could not create $BIN_DIR"
# Install to a temp name then rename: mv is atomic within a filesystem, so a
# running so-aws-lab is never replaced mid-read.
chmod +x "$tmp/$BIN"
mv "$tmp/$BIN" "$BIN_DIR/$BIN.new" || die "could not write to $BIN_DIR"
mv "$BIN_DIR/$BIN.new" "$BIN_DIR/$BIN"

info "installed $BIN_DIR/$BIN"
printf '\n'
"$BIN_DIR/$BIN" --version 2>/dev/null || true
printf '\n'

# --- PATH check --------------------------------------------------------------
# ~/.local/bin is on PATH by default on most Linux distros but NOT on macOS.
# Installing somewhere unreachable and saying nothing is the single most common
# failure mode for this pattern.
case ":$PATH:" in
  *":$BIN_DIR:"*)
    ;;
  *)
    warn "$BIN_DIR is not on your \$PATH"
    case "$(basename "${SHELL:-sh}")" in
      zsh)  rc="$HOME/.zshrc" ;;
      bash) if [ "$goos" = "darwin" ]; then rc="$HOME/.bash_profile"; else rc="$HOME/.bashrc"; fi ;;
      fish)
        printf '\n  Add it with:\n    fish_add_path %s\n\n' "$BIN_DIR"
        rc=""
        ;;
      *)    rc="your shell profile" ;;
    esac
    if [ -n "${rc:-}" ]; then
      printf '\n  Add it with:\n    echo '\''export PATH="%s:$PATH"'\'' >> %s\n    exec $SHELL\n\n' \
        "$BIN_DIR" "$rc"
    fi
    ;;
esac

# --- runtime dependency preflight -------------------------------------------
# The binary embeds its own terraform source but still shells out to these.
# Command name and package name differ (aws -> awscli), so track both.
missing=""
brew_pkgs=""
command -v terraform >/dev/null 2>&1 || { missing="$missing terraform"; brew_pkgs="$brew_pkgs terraform"; }
command -v aws >/dev/null 2>&1 || { missing="$missing aws"; brew_pkgs="$brew_pkgs awscli"; }
if [ -n "$missing" ]; then
  warn "missing runtime dependencies:$missing"
  if [ "$goos" = "darwin" ]; then
    info "install with: brew install$brew_pkgs"
  fi
  printf '\n'
fi

info "next: $BIN init"
