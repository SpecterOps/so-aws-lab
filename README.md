# `so-aws-lab`

A Go TUI + CLI that deploys intentionally vulnerable AWS labs into **your own
sandbox AWS account**. Each lab is a Terraform module gated by an
`enable_<lab>` variable — the TUI toggles them and runs `terraform apply`.

Modeled on [DataDog's `plabs`](https://github.com/DataDog/pathfinding-labs).

## Self-contained

The Terraform modules are **embedded in the binary**. There is no repo to
clone, no clone URL to configure, and no git dependency. On first run they are
extracted to `~/.so-aws-lab/workspace/`, and upgrading the binary upgrades the
Terraform in place — state and the provider cache are left untouched.

Solution scripts are deliberately **not** included. This repo deploys the labs;
it does not answer them.

```
cmd/so-aws-lab/        entrypoint (cobra commands + init wizard)
internal/config/       ~/.so-aws-lab/config.yaml read/write, AWS region metadata
internal/labs/         embedded labs.yaml catalog
internal/workspace/    embedded terraform, extracted on demand
internal/runner/       shells out to terraform; syncs ~/.aws/config profiles
internal/tui/          bubbletea UI
internal/awsconfig/    managed-block writer for ~/.aws/config
```

## Prerequisites

The binary carries its own Terraform source, but it shells out to these — they
must be on `$PATH`:

- `terraform` >= 1.6
- `aws` CLI v2, configured with a named profile for your sandbox account

Plus a throwaway AWS account you have admin in. **Do not use production.**

## Install

### Install script

```sh
curl -fsSL https://raw.githubusercontent.com/specterops/so-aws-lab/main/install.sh | sh
```

Installs into `~/.local/bin`. The script verifies the release checksum, tells
you if that directory isn't on your `$PATH`, and flags any missing runtime
dependencies.

| Var | Effect |
| --- | --- |
| `SO_AWS_LAB_VERSION` | Install a specific tag (e.g. `v0.1.0`) instead of latest |
| `SO_AWS_LAB_BIN_DIR` | Install somewhere other than `~/.local/bin` |

### Manual download

Prebuilt binaries for macOS, Linux, and Windows (amd64 + arm64) are attached to
each [release](https://github.com/specterops/so-aws-lab/releases), alongside a
`checksums.txt` worth verifying.

Binaries downloaded through a *browser* get quarantined by macOS Gatekeeper and
refuse to run until you clear the attribute:

```sh
xattr -d com.apple.quarantine ./so-aws-lab
```

The `curl` install above doesn't set that attribute, which is why it's preferred
over a browser download.

## Usage

```sh
so-aws-lab init      # wizard: AWS profiles per account, region, lab prefix
so-aws-lab           # opens the TUI
```

In the TUI: `↑/↓` navigate, `space` toggle a lab, `a` apply, `q` quit.

Non-interactively:

```sh
so-aws-lab enable putuserpolicy assumerole
so-aws-lab apply
so-aws-lab status    # entry-role / target-role / flag-param per lab
so-aws-lab destroy
```

## On-disk layout

```
~/.so-aws-lab/
├── config.yaml               accounts, lab prefix, enabled set
└── workspace/
    └── terraform/
        ├── modules/          shared module sources
        └── workshop/         root module — state + .terraform live here
```

`workspace/` is managed: `.tf` files are overwritten on every run and stale
ones are pruned, so edits there do not survive. `terraform.tfstate`, the
`.terraform/` provider cache, and generated `.zip` artifacts are never touched.

## AWS config profiles

On `apply`, an entry-role profile is written into `~/.aws/config` for each
enabled lab, inside `# >>> so-aws-lab managed:` sentinel blocks. Everything
outside those blocks is preserved byte-for-byte, and `destroy` removes them.
Reaching the *target* role is the exercise — only entry roles get a profile.

## Cost

Most labs are free (IAM-only). Labs that provision billable infrastructure
carry a `cost`/`daily_usd` field in `internal/labs/labs.yaml` and are marked in
the TUI. Run `so-aws-lab destroy` when you're done.

## Build from source

```sh
make build      # -> bin/so-aws-lab
make install    # -> $GOBIN/so-aws-lab
make test
```

## Releasing

Tag and push; the `release` workflow runs GoReleaser:

```sh
git tag -a v0.1.0 -m "v0.1.0" && git push origin v0.1.0
```

Dependency notices are regenerated as a release pre-hook, and the build fails
if any linked module has no license file. To refresh them by hand:

```sh
make third-party
```

### Homebrew tap

Homebrew publishing is currently disabled.

## License

MIT — see [LICENSE](LICENSE).

so-aws-lab ships as a statically linked binary, so its dependencies' code is
included in the distributed artifact. Their license texts travel with each
release archive in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) (24
modules: MIT, Apache 2.0, and BSD-3-Clause).
