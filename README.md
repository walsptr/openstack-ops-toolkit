# OpenStack Ops Toolkit

A modular command-line toolkit for OpenStack administration, operations, and troubleshooting.

All operational tasks are plain Bash scripts. Each script describes itself with a small
**metadata header** (`@name`, `@description`, `@mutates`, …), and the toolkit discovers them
automatically — no registration needed. A **k9s-style terminal UI** lets you search, preview,
and run those scripts with OpenStack credentials already loaded.

```
╭────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────╮
│ 🔎 scripts>   < 4/4 ─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────  │
│   Context:  admin-openrc.sh               <enter>   Run       <alt-p>   Preview          ___   ___  _____                                          │
│   Cloud:    keystone.example.com:5000     <ctrl-e>  Source    <ctrl-d>  Preview down    / _ \ / _ \|_   _|                                         │
│   Region:   RegionOne                     <ctrl-r>  Reload    <ctrl-u>  Preview up     | (_) | (_) | | |                                           │
│   User:     admin                         <ctrl-o>  Context   <esc>     Clear filter    \___/ \___/  |_|                                           │
│   Project:  admin                         <?>       Help      <ctrl-c>  Quit                                                                       │
│   ──── Scripts(all)[4] ────                                                                                                                        │
│   NAME                       CATEGORY  MUTATES  DESCRIPTION                                                   TAGS                                 │
│ ▌ Assign User to Project     identity  yes      Assign the member or admin role to a user on a project        keystone, role, user, project        │
│   Floating IP Information    network   no       Look up a floating IP (or a list from a file, saved as CSV…   neutron, floating-ip, port, serve··  │
│   Instances Information      servers   no       Show instance name, project, and domain for an instance ID…   nova, server, instance, project, ··  │
│   Import Volume from NetApp  volumes   yes      Bring an existing NetApp volume under Cinder management (ci…  cinder, volume, netapp, manage, i··  │
│ ╭────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────╮ │
│ │ Assign User to Project                                                                                                                   1/126 │ │
│ │ ────────────────────────────────────────                                                                                                       │ │
│ │ Category : identity                                                                                                                            │ │
│ │ Path     : /opt/openstack-ops-toolkit/identity/assign-user-to-project.sh                                                                       │ │
│ │ Mutates  : ⚠️  yes — mengubah resource (konfirmasi sebelum dijalankan)                                                                         │ │
│ │ Requires : admin                                                                                                                               │ │
│ │ Tags     : keystone, role, user, project                                                                                                       │ │
│ ╰────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────╯ │
╰────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────╯
```

## Features

- **Auto-discovery** — scripts are found by scanning the category directories and reading the
  metadata header of each script. The script file is the single source of truth.
- **k9s-style layout** — info panel (context, cloud, region, user, project), key hints, a titled
  script table (`NAME`, `CATEGORY`, `MUTATES`, `DESCRIPTION`, `TAGS`), and a preview pane.
- **Fuzzy search** — type to search scripts by name, category, description, or tags
  (powered by [fzf](https://github.com/junegunn/fzf)).
- **Safety marker** — scripts with `@mutates: yes` are highlighted, and the launcher asks for
  confirmation before running them (in addition to the script's own confirmation).
- **Preview pane** — category, path, mutates, requires, tags, description, and
  syntax-highlighted source of the selected script.
- **Credentials loaded once** — pick an OpenStack RC file at start; every script inherits the
  `OS_*` variables. Switch RC file anytime with `Ctrl-O`.
- **Stay in the TUI** — after a script finishes you return to the list; the result (success,
  exit code, or cancelled) is shown in the title bar.
- **Optional local override** — `scripts.env` can rename, hide, or add scripts per server.
- **`--list`** — print all scripts as a Markdown table (for documentation and CI).
- **Graceful fallback** — without fzf, a plain numbered menu with text filtering is used.
- **Audit logging** — every run is logged (who, which script, which resource, which OpenStack
  context, result) per category under `log/`, with a `run_id` to trace one execution. Secrets are
  never logged. See [Logging](#logging).

## Requirements

| Requirement | Notes |
|---|---|
| Bash ≥ 4 | |
| [python-openstackclient](https://docs.openstack.org/python-openstackclient/) | `openstack` CLI, used by the scripts and to verify credentials |
| [fzf](https://github.com/junegunn/fzf) ≥ 0.20.0 | Terminal UI |
| Core utilities | `awk`, `sed`, `grep`, `find`, `sort`, `head`, `wc`, `basename`, `dirname`, `realpath`, `install`, `date`, `mktemp` |
| `sudo` | Only for installation, when not running as root |

Optional:

| Optional | Used for |
|---|---|
| python-cinderclient (`cinder`) | *Import Volume from NetApp* script |
| [bat](https://github.com/sharkdp/bat) | Syntax highlighting in the preview pane |
| `less` (or `$PAGER`) | Full source viewer (`Ctrl-E`) and help |

Example on RHEL / Rocky / Fedora:

```bash
sudo dnf install -y python3-openstackclient fzf bat
```

Example on Ubuntu / Debian:

```bash
sudo apt-get install -y python3-openstackclient fzf bat
```

> What each script can do depends on the role of the OpenStack credentials you load.
> The `@requires` metadata (shown in the preview pane) tells you what a script needs.

## Installation

```bash
git clone https://github.com/walsptr/openstack-ops-toolkit.git
cd openstack-ops-toolkit
./install.sh        # or: bash install.sh

# Recommended when several non-root operators share the toolkit:
sudo groupadd osops && sudo usermod -aG osops <user>   # once; users re-login afterwards
./install.sh --log-group osops
```

The installer:

1. Checks all requirements **before** escalating to root (so an `openstack` client installed in
   your user `PATH` or a virtualenv is detected) and prints install hints for anything missing.
2. Re-runs itself with `sudo` if needed.
3. Discovers the scripts (same parser as the TUI) and copies every category directory that
   contains a script with `@name` — plus `lib/` if present — to `/opt/openstack-ops-toolkit/`.
   If the repository is already located there, copying is skipped.
4. Never creates or modifies `scripts.env`. If an existing `scripts.env` contains entries that are
   now redundant (same path and same name as discovered), it prints them so you can remove them.
5. Creates `log/` and one `log/<category>/` per discovered category, owned by the log group with
   mode `2775` (setgid, so new files inherit the group). Existing log files are never deleted or
   overwritten; only their group and group-write bit are adjusted.
6. Installs the command to `/usr/local/bin/openstack-ops-toolkit`.

Installer options:

| Option | Description |
|---|---|
| `--log-group GROUP` | Group that owns `log/` (must exist). Members can write logs. Default: the primary group of the user running `sudo` (`SUDO_USER`) |
| `--skip-checks` | Skip the requirement check (not recommended) |
| `-y`, `--yes` | Deprecated, has no effect (kept for compatibility) |
| `-h`, `--help` | Show help |

To update, pull the latest changes and run `./install.sh` again.

## Usage

```bash
openstack-ops-toolkit
```

On start you pick an OpenStack RC file (candidates matching `*openrc*`, `*rc.sh`, or `*-rc` in
your home directory and the workdir are listed; you can also type a path). Lines containing
`PASSWORD`, `SECRET`, or `TOKEN` are hidden in the picker preview. The credentials are verified
with `openstack token issue` before the TUI opens.

```bash
# Skip the RC prompt
openstack-ops-toolkit --rc ~/admin-openrc.sh

# Use a custom working directory (scripts are discovered there)
openstack-ops-toolkit --workdir /path/to/workdir

# Plain numbered menu, no TUI
openstack-ops-toolkit --no-fzf

# Print the script list as a Markdown table (no RC file needed)
openstack-ops-toolkit --list
```

| Option | Description |
|---|---|
| `--workdir PATH` | Directory to discover scripts in (default `/opt/openstack-ops-toolkit`); `scripts.env` there is optional |
| `--rc FILE` | OpenStack RC file to load (skips the prompt) |
| `--no-fzf` | Use the plain numbered menu |
| `--list` | Print scripts (name, category, path, mutates, description) as a Markdown table and exit |
| `-h`, `--help` | Show help |

You can also run it directly from the repository with `bash main.sh --workdir .`.

### Keyboard shortcuts

Press `?` inside the TUI for the full list.

| Key | Action |
|---|---|
| *type* | Search scripts — name, category, description, tags (fuzzy; prefix with `'` for an exact match) |
| `↑` / `↓` | Move selection |
| `Enter` | Run the selected script (asks for confirmation first if `MUTATES` is `yes`) |
| `Ctrl-E` | View the full script source in the pager |
| `Ctrl-R` | Re-discover scripts (and re-read `scripts.env`) |
| `Ctrl-O` | Switch OpenStack RC file (context) |
| `Alt-P` | Show / hide the preview pane |
| `Ctrl-D` / `Ctrl-U` | Scroll the preview pane |
| `Esc` | Clear the search filter |
| `?` | Help |
| `Ctrl-C` | Quit (while a script runs: stop that script and return to the TUI) |

## Operational scripts

Generated with `bash main.sh --workdir . --list`:

| Name | Category | Path | Mutates | Description |
|---|---|---|---|---|
| Assign User to Project | identity | `identity/assign-user-to-project.sh` | yes | Assign the member or admin role to a user on a project |
| Floating IP Information | network | `network/get-float-ip-info.sh` | no | Look up a floating IP (or a list from a file, saved as CSV in /tmp) and show its project, domain, port, and server |
| Instances Information | servers | `servers/get-instance-info.sh` | no | Show instance name, project, and domain for an instance ID (or a list from a file, saved as CSV in /tmp) |
| Import Volume from NetApp | volumes | `volumes/import-vol-from-netapp.sh` | yes | Bring an existing NetApp volume under Cinder management (cinder manage) |

## Logging

Every script run is logged, whether it is started from the TUI or directly
(`bash servers/get-instance-info.sh`).

```
/opt/openstack-ops-toolkit/log/
├── toolkit.log                                   # launcher: sessions, runs, context switches
├── identity/assign-user-to-project-20261010.log  # one file per script per day (append)
├── network/get-float-ip-info-20261010.log
├── servers/...
└── volumes/...
```

The subdirectory is the script's category (first directory of its path); a new category gets its
own subdirectory automatically. Scripts outside the toolkit (custom `scripts.env` entries) log to
`log/custom/`.

Line format — one event per line (newlines are escaped as `\n`):

```
<ISO 8601 time+TZ> <LEVEL> run=<run_id> user=<operator> <EVENT> key=value ...
```

```
2026-10-10T15:29:06+07:00 INFO run=20261010T152906-303852-369a user=syawal START script=identity/assign-user-to-project.sh pid=303945 os_user=opsadmin os_project=admin os_region=RegionOne os_auth_host=keystone.example.com:5000
2026-10-10T15:29:06+07:00 INFO run=20261010T152906-303852-369a user=syawal INPUT user=user9 project=demo role=admin
2026-10-10T15:29:06+07:00 INFO run=20261010T152906-303852-369a user=syawal CMD openstack role add --user user9 --project demo admin
2026-10-10T15:29:06+07:00 INFO run=20261010T152906-303852-369a user=syawal RESULT resource=user9 project=demo role=admin action=assign-role result=SUCCESS
2026-10-10T15:29:06+07:00 INFO run=20261010T152906-303852-369a user=syawal END rc=0 duration=0s
```

- `user` is the real Linux user (`SUDO_USER` when run through `sudo`).
- `START` records the OpenStack context: `OS_USERNAME`, `OS_PROJECT_NAME`, `OS_REGION_NAME`, and
  the host of `OS_AUTH_URL`. Passwords, tokens, and application credential secrets are never
  logged; the value of any environment variable whose name contains `PASSWORD`, `SECRET`, or
  `TOKEN` is replaced by `***` if it ever appears in a message.
- `RESULT` lines record the outcome per resource: `result` is one of `SUCCESS`, `FAILED`,
  `SKIPPED`, `DECLINED` (the operator answered "no"), or `ABORTED`.
- `END` records the exit code and duration (`signal=INT` when stopped with `Ctrl-C`).
- Script output is not copied to the log; scripts log their inputs, commands, and results.

Each run has a unique `run_id`. When started from the TUI, the same `run_id` is used in
`toolkit.log` and in the script log, so one grep shows the whole run:

```bash
grep -r 'run=20261010T152906-303852-369a' /opt/openstack-ops-toolkit/log
grep -rh 'result=FAILED' /opt/openstack-ops-toolkit/log/volumes/
```

Location:

| Setting | Effect |
|---|---|
| default | `<workdir>/log` (`/opt/openstack-ops-toolkit/log`; `./log` with `--workdir .`, ignored by git) |
| `OSOPS_LOG_DIR=/path` | Use another log directory |
| fallback | If the log directory is not writable, one warning is shown and logs go to `${XDG_STATE_HOME:-$HOME/.local/state}/openstack-ops-toolkit/log`. If that fails too, logging is disabled. A logging failure never stops a script. |

Retention is not automated yet; old daily files can be removed with e.g.
`find /opt/openstack-ops-toolkit/log -name '*.log' -mtime +90 -delete`.

## Adding a script

Create a Bash script in a category directory with a metadata header **directly after the
shebang** — that's all. No registration in `scripts.env` is needed.

```bash
#!/bin/bash
# ============================================================
# @name:        List Orphan Ports
# @description: List ports that are not attached to any device
# @mutates:     no
# @requires:    admin
# @tags:        neutron, port, cleanup
# ============================================================

set -o errexit
set -o nounset
set -o pipefail

# Logging terpusat (lib/logging.sh)
# shellcheck source=../lib/logging.sh
if ! source "${OSOPS_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/lib/logging.sh" 2>/dev/null; then
    echo "❌ lib/logging.sh tidak ditemukan. Periksa instalasi toolkit (install.sh)."
    exit 1
fi
log_init

# ... script ...
```

Logging (required for every script, see [Logging](#logging)):

| Function | Use |
|---|---|
| `log_init` | Once, right after sourcing. Logs `START`/`END` (exit code, duration) automatically. |
| `log_event INPUT key=value ...` | User input (IDs, IPs, names, input file paths) — never secrets. |
| `log_info` / `log_warn` / `log_error` | Free-text messages. `log_warn`/`log_error` also print to stderr; add `-q` when the script already printed the message. |
| `log_run cmd args...` | Log and run an OpenStack command; its stderr is shown and kept in `$LOG_LAST_ERROR`. |
| `log_result resource=<id> action=<action> result=<RESULT> [key=value ...]` | Outcome per resource. Required in scripts that change resources, including `DECLINED` / `SKIPPED`. |

Do not set your own `EXIT`/`INT`/`TERM` trap (it replaces the logging trap) and do not pipe the
whole script output through `tee`. In a nested category (`network/floating-ip/x.sh`) use `../..`
in the source line.

| Tag | Required | Description |
|---|---|---|
| `@name` | **Yes** | Display name. Files without `@name` are treated as helpers and not listed. |
| `@description` | No | One line. Fallback: the first comment line of the header block. |
| `@mutates` | No | `yes` / `no` (default `no`). Use `yes` for any script that changes resources — the launcher then asks for confirmation. The script must still ask for its own confirmation. |
| `@requires` | No | Free text, e.g. `admin`, `admin, cinder`. |
| `@tags` | No | Comma-separated keywords, included in search. |

Rules:

- Only the header block is parsed (comment lines after the shebang, until the first line of code).
- The category is the first directory of the path, so `network/floating-ip/release.sh` belongs to
  `network`. A new category is just a new directory.
- Files in `lib/` and hidden directories are never listed — put shared helpers in `lib/`
  (e.g. `lib/logging.sh`).
- The script inherits the OpenStack credentials (`OS_*` variables) loaded by the toolkit.

Then:

1. Press `Ctrl-R` in the TUI (or run `bash main.sh --workdir . --list`) to check it is discovered.
2. Re-run `./install.sh` to deploy it.
3. Regenerate the table in [Operational scripts](#operational-scripts) with `--list`.

## Local override: `scripts.env` (optional)

`scripts.env` in the workdir is an optional, per-server override file (not tracked by git).
See `scripts.env.example`.

| Line | Effect |
|---|---|
| `Display Name,path` | If `path` is a discovered script: change its display name. Otherwise: add it as a custom entry (category `custom`), e.g. a script outside the repo. |
| `!path` | Hide the script. |
| `# comment` | Ignored (trailing comments too). |

```
Floating IP Lookup,network/get-float-ip-info.sh          # rename
!volumes/import-vol-from-netapp.sh                       # hide on this server
Site Backup Check,/usr/local/sbin/check-backup.sh        # custom script
```

Relative paths resolve against the workdir. Existing `scripts.env` files in the old format
(one `Name,path` line per script) keep working without duplicates.

## Project structure

```
.
├── main.sh                 # Entry point: k9s-style TUI script launcher (discovery, --list)
├── install.sh              # Installer with requirement checks
├── scripts.env.example     # Example of the optional local override file
├── CLAUDE.md               # Architecture and contribution guide
├── lib/                    # Shared helpers for scripts (logging.sh), never listed in the TUI
├── log/                    # Logs, created at runtime / by install.sh (not tracked by git)
├── identity/               # Identity (Keystone) scripts
├── network/                # Network (Neutron) scripts
├── servers/                # Server (Nova) scripts
└── volumes/                # Block storage (Cinder) scripts
```

Category directories are discovered dynamically; add a directory to add a category.

## Troubleshooting

| Problem | Solution |
|---|---|
| `fzf tidak ditemukan` | Install fzf ≥ 0.20.0, or use `--no-fzf` |
| `Gagal melakukan autentikasi OpenStack` | Check the RC file: run `source <rc> && openstack token issue` manually |
| `Tidak ada script ber-@name di workdir` | The workdir has no discoverable scripts: run `./install.sh`, or point `--workdir` to the toolkit directory |
| A new script is missing from the list | Check that `@name` is in the header block directly after the shebang (not after `set -o ...` or code), the file ends in `.sh`, and it is not in `lib/` or a hidden directory; then press `Ctrl-R` |
| A script appears under `custom` | It is added by `scripts.env` with a path that discovery did not find — check the path |
| DESCRIPTION shows `⚠️ script tidak ditemukan` | A `scripts.env` entry points to a file that does not exist |
| Installer reports redundant `scripts.env` entries | They are now discovered automatically; remove those lines (optional) |
| `Direktori log tidak bisa ditulis: ... — log dialihkan ke ...` | Your user cannot write to `log/`. Add the user to the log group (`sudo usermod -aG <group> <user>`, then log in again) or re-run `./install.sh --log-group <group>`. Until then, logs are in the fallback directory shown. |
| `lib/logging.sh tidak ditemukan` | `lib/` is missing from the install: re-run `./install.sh` |
