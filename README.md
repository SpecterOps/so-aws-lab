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
so-aws-lab --update  # install a newer release, if one is available
```

In the TUI: `↑/↓` navigate, `space` toggle a lab, `a` apply, `q` quit.

The update flag verifies the release checksum and replaces the running binary
atomically. It refuses to update while Terraform state contains any deployed
lab resources. Run `so-aws-lab destroy` before crossing an infrastructure
version boundary.

Non-interactively:

```sh
so-aws-lab enable putuserpolicy assumerole
so-aws-lab apply
so-aws-lab status    # entry / target / objective per lab
so-aws-lab destroy
```

## On-disk layout

```
~/.so-aws-lab/
├── config.yaml               accounts, lab prefix, enabled set, capstone roster
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
enabled role-based single-student lab, including the single-student capstone, inside
`# >>> so-aws-lab managed:` sentinel blocks. Everything outside those blocks is
preserved byte-for-byte, and `destroy` removes them. Reaching the *target* role
is the exercise, so only entry roles get a profile. The PrincipalTag lab starts
as an IAM user and intentionally receives no role-assuming profile. For
example, the capstone starts with:

```sh
aws --profile <prefix>-capstone-carl sts get-caller-identity
```

## Multi-student capstone

The capstone always defaults to the original self-deployed, single-user
behavior. Multi-student workshop mode is opt-in: it is used only after an
organizer configures a non-empty roster.

Workshop mode deploys isolated capstone chains for multiple students in the
same dev, staging, and prod accounts. Configure the three account deployment
profiles with `so-aws-lab init`, then provide the number of students:

```sh
so-aws-lab capstone configure 30
```

That creates `student01` through `student30`. To put names on the printed
cards, replace the generated roster with explicit IDs and optional display
labels:

```sh
so-aws-lab capstone configure \
  student01="Alice" \
  student02="Bob"
```

Return to the default single-user deployment at any time:

```sh
so-aws-lab capstone configure --single-user
```

Then deploy the configured roster and issue its access cards:

```sh
so-aws-lab enable capstone
so-aws-lab apply
so-aws-lab status
so-aws-lab capstone access-cards
```

Terraform creates one console-only IAM bootstrap user per roster entry in dev.
It creates no access keys. Each user has a permissions boundary and matching
inline policy that allow only the CloudShell control-plane actions,
`sts:GetCallerIdentity`, and `sts:AssumeRole` on that student's exact
`<prefix>-capstone-<student-id>-carl` role. Carl's trust policy names that
student's bootstrap user directly.

`access-cards` creates or rotates the console login profiles through the AWS
CLI and writes a self-contained printable HTML file to
`~/.so-aws-lab/capstone-access-cards.html`. The file is mode `0600` and
contains active passwords, so do not commit or share the complete sheet.
Passwords never enter Terraform state or terminal output. Running the command
again rotates every password and invalidates older cards.

Each card contains the student ID, IAM username, temporary workshop password,
AWS account sign-in link, and a prefilled Carl role-switch link. After signing
in and switching to Carl, the student opens AWS CloudShell. CloudShell provides
the AWS CLI, `jq`, `kubectl`, Python, and ZIP tooling needed by the capstone
without local AWS credentials.

The prod EKS cluster, its VPC and node group, and the staging EC2 outpost and
VPC are shared. The node group scales with the configured roster. The mutable
or inexpensive parts of the path are per student:

- student-specific IAM roles, boundaries, and inline policies
- Lambda gate, CloudFormation stack, and relay
- fixed SSM credential-handoff document and SecureString parameters
- both KMS keys and aliases
- EKS namespace, access-entry target, and Pod Identity association
- S3 evidence bucket, encrypted flag object, and baseline bucket policy

Mordecai writes its short-lived credentials to a private handoff and invokes a
parameterless student-specific SSM document; it cannot run
`AWS-RunShellScript`. The shared Ward role cannot assume any downstream role.
The fixed document replays only that Mordecai session from the outpost's stable
source IP to assume its matching Katia role. EKS access-policy conditions force
Odette to associate `AmazonEKSAdminPolicy` with the student's namespace only.
Every Pod Identity
association points to one shared Mongo role. Its permissions boundary, inline
policy, S3 resources, and KMS key policies use EKS-supplied cluster, namespace,
and service-account session tags to keep runtimes isolated. Pod Security
`restricted`, a `LimitRange`, and a `ResourceQuota` prevent privileged pods,
load balancers, NodePorts, or unbounded compute use from affecting the shared
cluster.

To return to the original resource names and local managed profile:

```sh
so-aws-lab capstone configure --single-user
```

Apply that change before issuing cards. Removing a student from the roster and
applying deletes that student's bootstrap user and login profile. Disabling
the capstone and applying, or running `so-aws-lab destroy`, removes all
workshop users. Terraform's `force_destroy` is limited to these capstone-owned
bootstrap users.

## Cost

Most labs are free, but all labs that provision billable infrastructure
carry a `cost`/`daily_usd` field in `internal/labs/labs.yaml` and are marked in
the TUI. Multi-student mode shares EKS and EC2 but adds two KMS keys per
student (about $0.07/day per roster entry, before request charges). Run
`so-aws-lab destroy` when you're done.

## Build from source

```sh
make build      # -> bin/so-aws-lab
make install    # -> $GOBIN/so-aws-lab, or ~/.local/bin/so-aws-lab when GOBIN is unset
make test
```

## License

MIT — see [LICENSE](LICENSE).

so-aws-lab ships as a statically linked binary, so its dependencies' code is
included in the distributed artifact. Their license texts travel with each
release archive in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) (24
modules: MIT, Apache 2.0, and BSD-3-Clause).
