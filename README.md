# OpenStack Ops Toolkit

A modular command-line toolkit for OpenStack administration, operations, and troubleshooting.

All operational tasks are plain Bash scripts registered in `scripts.env`. The toolkit provides a
**k9s-style terminal UI** to search, preview, and run those scripts with OpenStack credentials
already loaded.

```
╭────────────────────────────────────────────────────────────────────────────────────────────────────────────╮
│ 🔎 scripts>   < 4/4 ─────────────────────────────────────────────────────────────────────────────────────  │
│   Context:  admin-openrc.sh               <enter>   Run       <alt-p>   Preview          ___   ___  _____  │
│   Cloud:    keystone.example.com:5000     <ctrl-e>  Source    <ctrl-d>  Preview down    / _ \ / _ \|_   _| │
│   Region:   RegionOne                     <ctrl-r>  Reload    <ctrl-u>  Preview up     | (_) | (_) | | |   │
│   User:     admin                         <ctrl-o>  Context   <esc>     Clear filter    \___/ \___/  |_|   │
│   Project:  admin                         <?>       Help      <ctrl-c>  Quit                               │
│   ──── Scripts(all)[4] ────                                                                                │
│   NAME                       CATEGORY  DESCRIPTION                                                         │
│ ▌ Floating IP Information    network   Get Floating IP Information (single IP or list from file)           │
│ ▌ Instances Information      compute   OpenStack Instance Information                                      │
│ ▌ Assign User to Project     identity  OpenStack Assign User to Project                                    │
│ ▌ Import Volume from NetApp  volumes   Cinder Manage Volume                                                │
│ ╭────────────────────────────────────────────────────────────────────────────────────────────────────────╮ │
│ │ Floating IP Information                                                                          1/248 │ │
│ │ ────────────────────────────────────────                                                               │ │
│ │ Category : network                                                                                     │ │
│ │ Path     : /opt/openstack-ops-toolkit/network/get-float-ip-info.sh                                     │ │
│ │ Lines    : 238                                                                                         │ │
│ │                                                                                                        │ │
│ │ Description:                                                                                           │ │
│ │   Get Floating IP Information (single IP or list from file)                                            │ │
│ │                                                                                                        │ │
│ │ ──────────────── source ────────────────                                                               │ │
│ │    1 #!/bin/bash                                                                                       │ │
│ ╰────────────────────────────────────────────────────────────────────────────────────────────────────────╯ │
╰────────────────────────────────────────────────────────────────────────────────────────────────────────────╯
```

## Features

- **k9s-style layout** — info panel (context, cloud, region, user, project), key hints, a titled
  script table, and a detail pane.
- **Fuzzy search** — type to search scripts by name, category, or description
  (powered by [fzf](https://github.com/junegunn/fzf)).
- **Keyboard navigation** — arrow keys to move, `Enter` to run, no mouse needed.
- **Preview pane** — description, category, path, and syntax-highlighted source of the selected script.
- **Credentials loaded once** — pick an OpenStack RC file at start; every script inherits the
  `OS_*` variables. Switch RC file anytime with `Ctrl-O`.
- **Stay in the TUI** — after a script finishes you return to the list; the result (success or
  exit code) is shown in the title bar.
- **Simple extension** — add a script and one line in `scripts.env`; no code changes needed.
- **Graceful fallback** — without fzf, a plain numbered menu with text filtering is used.

## Requirements

| Requirement | Notes |
|---|---|
| Bash ≥ 4 | |
| [python-openstackclient](https://docs.openstack.org/python-openstackclient/) | `openstack` CLI, used by the scripts and to verify credentials |
| [fzf](https://github.com/junegunn/fzf) ≥ 0.20.0 | Terminal UI |
| Core utilities | `awk`, `sed`, `grep`, `find`, `sort`, `head`, `wc`, `basename`, `dirname`, `realpath`, `install` |
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
> Some scripts (e.g. assigning roles, importing volumes) require an **admin** role.

## Installation

```bash
git clone https://github.com/walsptr/openstack-ops-toolkit.git
cd openstack-ops-toolkit
./install.sh        # or: bash install.sh
```

The installer:

1. Checks all requirements **before** escalating to root (so an `openstack` client installed in
   your user `PATH` or a virtualenv is detected) and prints install hints for anything missing.
2. Re-runs itself with `sudo` if needed.
3. Copies the script directories (`compute/`, `identity/`, `network/`, `volumes/`) to
   `/opt/openstack-ops-toolkit/`. If the repository is already located there, copying is skipped.
4. Creates `/opt/openstack-ops-toolkit/scripts.env` from `scripts.env.example`. An existing
   `scripts.env` is never overwritten — new entries from the example are offered to be appended.
5. Installs the command to `/usr/local/bin/openstack-ops-toolkit`.

Installer options:

| Option | Description |
|---|---|
| `-y`, `--yes` | Non-interactive: automatically append new entries to `scripts.env` |
| `--skip-checks` | Skip the requirement check (not recommended) |
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

# Use a custom working directory (must contain scripts.env)
openstack-ops-toolkit --workdir /path/to/workdir

# Plain numbered menu, no TUI
openstack-ops-toolkit --no-fzf
```

| Option | Description |
|---|---|
| `--workdir PATH` | Working directory containing `scripts.env` (default `/opt/openstack-ops-toolkit`) |
| `--rc FILE` | OpenStack RC file to load (skips the prompt) |
| `--no-fzf` | Use the plain numbered menu |
| `-h`, `--help` | Show help |

You can also run it directly from the repository with `bash main.sh --workdir .`.

### Keyboard shortcuts

Press `?` inside the TUI for the full list.

| Key | Action |
|---|---|
| *type* | Search scripts (fuzzy; prefix with `'` for an exact match) |
| `↑` / `↓` | Move selection |
| `Enter` | Run the selected script |
| `Ctrl-E` | View the full script source in the pager |
| `Ctrl-R` | Reload the script list from `scripts.env` |
| `Ctrl-O` | Switch OpenStack RC file (context) |
| `Alt-P` | Show / hide the preview pane |
| `Ctrl-D` / `Ctrl-U` | Scroll the preview pane |
| `Esc` | Clear the search filter |
| `?` | Help |
| `Ctrl-C` | Quit (while a script runs: stop that script and return to the TUI) |

## Operational scripts

| Script | Description | Modifies resources |
|---|---|---|
| `network/get-float-ip-info.sh` | Look up a floating IP (or a list from a file) and show its project, port, and server; optionally save results to a file | No |
| `compute/get-instance-info.sh` | Show instance name, project ID, and project name for an instance ID | No |
| `identity/assign-user-to-project.sh` | Assign the `member` or `admin` role to a user on a project | **Yes** (with confirmation) |
| `volumes/import-vol-from-netapp.sh` | Bring an existing NetApp volume under Cinder management (`cinder manage`), choosing volume type and pool interactively | **Yes** (with confirmation) |

### Adding a script

1. Create a Bash script in a category directory, e.g. `compute/list-orphan-ports.sh`.
   The script inherits the OpenStack credentials (`OS_*` variables) loaded by the toolkit.
   The category shown in the TUI is the directory name.
2. Start the script with a comment block — its first line is shown in the DESCRIPTION column
   and the whole block in the preview pane:

   ```bash
   #!/bin/bash

   # ============================================================
   # List ports that are not attached to any device
   # ============================================================
   ```

3. Register it in `scripts.env.example` (and in your `scripts.env`):

   ```
   List Orphan Ports,compute/list-orphan-ports.sh
   ```

   Format: `Display Name,path` — one per line. Relative paths resolve against the workdir;
   blank lines and lines starting with `#` are ignored.

4. Re-run `./install.sh` to deploy it, then press `Ctrl-R` in the TUI (or restart it).

## Project structure

```
.
├── main.sh                 # Entry point: k9s-style TUI script launcher
├── install.sh              # Installer with requirement checks
├── scripts.env.example     # Script registry template ("Name,path")
├── compute/                # Compute (Nova) scripts
├── identity/               # Identity (Keystone) scripts
├── network/                # Network (Neutron) scripts
└── volumes/                # Block storage (Cinder) scripts
```

`scripts.env` is local configuration and is not tracked by git.

## Troubleshooting

| Problem | Solution |
|---|---|
| `fzf tidak ditemukan` | Install fzf ≥ 0.20.0, or use `--no-fzf` |
| `Gagal melakukan autentikasi OpenStack` | Check the RC file: run `source <rc> && openstack token issue` manually |
| `File scripts.env tidak ditemukan!` | Run `./install.sh`, or pass `--workdir` pointing to a directory containing `scripts.env` |
| A script is missing from the list | Check its entry in `scripts.env` (`Name,path`), then press `Ctrl-R` |
| DESCRIPTION shows `⚠️ script tidak ditemukan` | The path in `scripts.env` does not exist relative to the workdir |
