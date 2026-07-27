# `so-aws-lab`
Companion deployment tool for the AWS for Red Teamers course — https://academy.specterops.io/aws-for-red-teamers

TUI Modeled on [DataDog's `plabs`](https://github.com/DataDog/pathfinding-labs).

## Prerequisites

The binary carries its own Terraform source, but it shells out to these — they
must be on `$PATH`:

- `terraform` >= 1.6
- `aws` CLI v2, configured with a named profile for your sandbox account

## Installation

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

Most labs are free, buts all labs that provision billable infrastructure
carry a `cost`/`daily_usd` field in `internal/labs/labs.yaml` and are marked in
the TUI. Run `so-aws-lab destroy` when you're done.

## Build from source

```sh
make build      # -> bin/so-aws-lab
make install    # -> $GOBIN/so-aws-lab
make test
```

## License

MIT — see [LICENSE](LICENSE).

so-aws-lab ships as a statically linked binary, so its dependencies' code is
included in the distributed artifact. Their license texts travel with each
release archive in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) (24
modules: MIT, Apache 2.0, and BSD-3-Clause).
