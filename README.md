# OpenStack Ops Toolkit

A modular command-line toolkit for OpenStack administration, operations, and troubleshooting.
It provides a **k9s-style terminal UI** for browsing OpenStack resources and a launcher for
reusable operational scripts — all from a single command.

```
╭──────────────────────────────────────────────────────────────────────────────────────────────────────────╮
│ servers>   < 3/3 (0) ────────────────────────────────────────────────────────────────────────────────────  │
│   ⎈ admin-openrc.sh  👤 admin  📁 admin  🌍 RegionOne  https://keystone.example.com:5000/v3                │
│   📋 Servers  all-projects: off                                                                            │
│   <enter> ports  <ctrl-e> describe  <ctrl-r> refresh  <ctrl-a> all-proj  <:> views  <?> help  <esc> back   │
│   <alt-s> start  <alt-x> stop  <alt-b> reboot  <alt-l> console-log  <alt-u> console-url  <tab> mark        │
│   ID             NAME       STATUS   NETWORKS                        IMAGE         FLAVOR                  │
│ ▌ 11111111-aaaa  web-01     ACTIVE   private=10.0.0.5, 203.0.113.10  ubuntu-22.04  m1.small                │
│ ▌ 22222222-bbbb  db-01      SHUTOFF  private=10.0.0.6                rocky-9       m1.large                │
│ ▌ 33333333-cccc  broken-vm  ERROR                                                  m1.tiny                 │
│                                                                                                            │
│ ╭────────────────────────────────────────────────────────────────────────────────────────────────────────╮ │
│ │ id: 11111111-aaaa                                                                                      │ │
│ │ name: web-01                                                                                           │ │
│ │ status: ACTIVE                                                                                         │ │
│ │ flavor: m1.small                                                                                       │ │
│ ╰────────────────────────────────────────────────────────────────────────────────────────────────────────╯ │
╰────────────────────────────────────────────────────────────────────────────────────────────────────────────╯
```

## Features

- **Resource browser** — servers, volumes, floating IPs, networks, subnets, ports, routers,
  security groups, images, flavors, projects, users, hypervisors, and compute / network / volume
  services, rendered as aligned tables with color-coded status.
- **Fuzzy filtering** — type to filter any view (powered by [fzf](https://github.com/junegunn/fzf)).
- **Command palette** — press `:` to jump to any view (`:hv`, `:fip`, `:vol`, `:sg`, …).
- **Drill-down navigation** — `Enter` on a project shows its servers, on a hypervisor shows the
  servers on that host, on a server / network / router shows its ports. `Esc` goes back.
- **Live describe pane** — `openstack … show` output for the highlighted resource, cached per session.
- **Server actions** — start, stop, soft reboot (single or multi-select with `Tab`), console log,
  and console URL. State-changing actions always ask for confirmation.
- **Context switching** — `:ctx` switches to another OpenStack RC file (cloud / project / user).
- **Ops scripts launcher** — run the toolkit's operational scripts from the `scripts` view, with
  a preview of each script's description and source.
- **Graceful fallback** — without fzf, a plain numbered script menu is used.

## Requirements

| Requirement | Notes |
|---|---|
| Bash ≥ 4 | |
| [python-openstackclient](https://docs.openstack.org/python-openstackclient/) | `openstack` CLI |
| Python 3 | Used to format resource tables (already required by the OpenStack client) |
| [fzf](https://github.com/junegunn/fzf) ≥ 0.20.0 | Terminal UI |
| Core utilities | `awk`, `sed`, `grep`, `find`, `sort`, `cut`, `realpath`, `install` |
| `sudo` | Only for installation, when not running as root |

Optional:

| Optional | Used for |
|---|---|
| python-cinderclient (`cinder`) | *Import Volume from NetApp* script |
| [bat](https://github.com/sharkdp/bat) | Syntax highlighting in previews |
| `less` (or `$PAGER`) | Full describe / console log / source viewer |

Example on RHEL / Rocky / Fedora:

```bash
sudo dnf install -y python3-openstackclient fzf bat
```

Example on Ubuntu / Debian:

```bash
sudo apt-get install -y python3-openstackclient fzf bat
```

> The OpenStack credentials you use determine what you can see and do. Many views
> (hypervisors, services, all-projects listings) and some scripts require an **admin** role.

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
your home directory and the workdir are listed; you can also type a path). The credentials are
verified with `openstack token issue` before the TUI opens.

```bash
# Skip the RC prompt
openstack-ops-toolkit --rc ~/admin-openrc.sh

# Start in a specific view
openstack-ops-toolkit --rc ~/admin-openrc.sh --view hypervisors

# Use a custom working directory (must contain scripts.env)
openstack-ops-toolkit --workdir /path/to/workdir

# Plain numbered script menu, no TUI
openstack-ops-toolkit --no-fzf
```

| Option | Description |
|---|---|
| `--workdir PATH` | Working directory containing `scripts.env` (default `/opt/openstack-ops-toolkit`) |
| `--rc FILE` | OpenStack RC file to load (skips the prompt) |
| `--view NAME` | Initial view (default `servers`) |
| `--no-fzf` | Use the plain numbered script menu |
| `-h`, `--help` | Show help |

You can also run it directly from the repository with `bash main.sh --workdir .`.

### Keyboard shortcuts

Press `?` inside the TUI for the full list.

| Key | Action |
|---|---|
| *type* | Fuzzy filter (prefix with `'` for an exact match) |
| `↑` / `↓` | Move selection |
| `Tab` / `Shift-Tab` | Mark rows (multi-select for bulk actions) |
| `Enter` | Drill down / describe / run script |
| `Esc` | Back to the previous view |
| `:` | Command palette (switch view, `ctx`, `help`, `quit`) |
| `?` | Help |
| `Ctrl-C` | Quit |
| `Ctrl-R` | Refresh from the API |
| `Ctrl-A` | Toggle `--all-projects` (servers, volumes) |
| `Ctrl-E` | Full describe in pager (script source in the `scripts` view) |
| `Alt-P` | Show / hide the describe pane |
| `Ctrl-D` / `Ctrl-U` | Scroll the describe pane |

Server view actions:

| Key | Action |
|---|---|
| `Alt-S` | Start selected server(s) — with confirmation |
| `Alt-X` | Stop selected server(s) — with confirmation |
| `Alt-B` | Soft reboot selected server(s) — with confirmation |
| `Alt-L` | Console log |
| `Alt-U` | Console URL |

### Views

| View | Palette aliases | Enter (drill-down) |
|---|---|---|
| `servers` | `server`, `srv`, `vm`, `instances` | Ports of the server |
| `volumes` | `volume`, `vol` | Describe |
| `floatingips` | `fip`, `floating` | Describe |
| `networks` | `network`, `net` | Ports on the network |
| `subnets` | `subnet` | Describe |
| `ports` | `port` | Describe |
| `routers` | `router`, `rt` | Ports of the router |
| `secgroups` | `sg`, `secgroup`, `security` | Describe |
| `images` | `image`, `img` | Describe |
| `flavors` | `flavor`, `fl` | Describe |
| `projects` | `project`, `proj`, `tenant` | Servers in the project |
| `users` | `user`, `usr` | Describe |
| `hypervisors` | `hypervisor`, `hv`, `host` | Servers on the host |
| `compute-services` | `svc`, `nova`, `compute` | — |
| `network-agents` | `agents`, `neutron` | Describe |
| `volume-services` | `cinder`, `vsvc` | — |
| `scripts` | `script`, `run`, `ops` | Run the script |

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
2. Start the script with a comment block — it is shown as the description in the preview:

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

4. Re-run `./install.sh` to deploy it. `scripts.env` is re-read every time the menu opens.

## Project structure

```
.
├── main.sh                 # Entry point: TUI / script launcher
├── install.sh              # Installer with requirement checks
├── scripts.env.example     # Script registry template ("Name,path")
├── compute/                # Compute (Nova) scripts
├── identity/               # Identity (Keystone) scripts
├── network/                # Network (Neutron) scripts
└── volumes/                # Block storage (Cinder) scripts
```

`scripts.env` is local configuration and is not tracked by git.

## Notes

- **Safety:** there is no delete action in the TUI. Start / stop / reboot and the
  state-changing scripts always show the target and context and ask for confirmation.
- **Credentials:** RC files are only sourced locally; the RC picker preview hides lines
  containing `PASSWORD`, `SECRET`, or `TOKEN`.
- **Performance:** every list and describe is an `openstack` CLI call (typically 1–2 seconds).
  Describe results are cached for the session; `Ctrl-R` refreshes.
- **Refresh:** views do not auto-refresh; press `Ctrl-R`.
- **Interrupting:** `Ctrl-C` while a script or action is running stops only that process and
  returns to the TUI.

## Troubleshooting

| Problem | Solution |
|---|---|
| `fzf tidak ditemukan` | Install fzf ≥ 0.20.0, or use `--no-fzf` |
| `Gagal melakukan autentikasi OpenStack` | Check the RC file: run `source <rc> && openstack token issue` manually |
| A view shows a red error row | The underlying `openstack … list` call failed (missing permission or unavailable service); the error message is shown in the row |
| A column is empty | Column names differ in some older `python-openstackclient` versions |
| Hypervisors / services views fail | These require an admin role |
