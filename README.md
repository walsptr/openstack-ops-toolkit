# OpenStack Ops Toolkit

A modular command-line toolkit for OpenStack administration, operations, and troubleshooting.

All operational tasks are plain Bash scripts. Each script describes itself with a small
**metadata header** (`@name`, `@description`, `@mutates`, …), and the toolkit discovers them
automatically — no registration needed. A **k9s-style terminal UI** lets you search, preview,
and run those scripts with OpenStack credentials already loaded.

```
╭────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────╮
│ 🔎 scripts>   < 5/5 ─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────  │
│   Context:  admin-openrc.sh               <enter>   Run       <alt-p>   Preview          ___   ___  _____                                          │
│   Cloud:    keystone.example.com:5000     <ctrl-e>  Source    <ctrl-d>  Preview down    / _ \ / _ \|_   _|                                         │
│   Region:   RegionOne                     <ctrl-r>  Reload    <ctrl-u>  Preview up     | (_) | (_) | | |                                           │
│   User:     admin                         <ctrl-o>  Context   <esc>     Clear filter    \___/ \___/  |_|                                           │
│   Project:  admin                         <?>       Help      <ctrl-c>  Quit                                                                       │
│   ──── Scripts(all)[5] ────                                                                                                                        │
│   NAME                       CATEGORY  MUTATES  DESCRIPTION                                                   TAGS                                 │
│ ▌ Assign User to Project     identity  yes      Assign the member or admin role to a user on a project        keystone, role, user, project        │
│   Floating IP Information    network   no       Look up a floating IP (or a list from a file, saved as CSV…   neutron, floating-ip, port, serve··  │
│   Instances Information      servers   no       Show instance name, project, and domain for an instance ID…   nova, server, instance, project, ··  │
│   Live Migrate Instances     servers   yes      Live migrate a list of instances to a target compute host w…  nova, live-migration, rebalance, ··  │
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
| [jq](https://jqlang.org/) | JSON parsing of OpenStack CLI output (e.g. *Live Migrate Instances*) |
| Core utilities | `awk`, `sed`, `grep`, `find`, `sort`, `head`, `wc`, `basename`, `dirname`, `realpath`, `install`, `date`, `mktemp`, `stat`, `df`, `sha256sum`/`sha512sum`/`md5sum` (coreutils), `flock` (util-linux) |
| `sudo` | Only for installation, when not running as root |

Optional:

| Optional | Used for |
|---|---|
| python-cinderclient (`cinder`) | *Import Volume from NetApp* script |
| `qemu-img` (qemu-img / qemu-utils) | *Upload Image*: virtual size (default `--min-disk`) and optional conversion to raw. Without it both are skipped |
| [bat](https://github.com/sharkdp/bat) | Syntax highlighting in the preview pane |
| `less` (or `$PAGER`) | Full source viewer (`Ctrl-E`) and help |

Example on RHEL / Rocky / Fedora:

```bash
sudo dnf install -y python3-openstackclient fzf jq bat
```

Example on Ubuntu / Debian:

```bash
sudo apt-get install -y python3-openstackclient fzf jq bat
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
| Upload Image | images | `images/upload-img.sh` | yes | Upload an image to Glance with progress, sharing, and checksum verification |
| Floating IP Information | network | `network/get-float-ip-info.sh` | no | Look up a floating IP (or a list from a file, saved as CSV in /tmp) and show its project, domain, port, and server |
| Instances Information | servers | `servers/get-instance-info.sh` | no | Show instance name, project, and domain for an instance ID (or a list from a file, saved as CSV in /tmp) |
| Live Migrate Instances | servers | `servers/live-migrate.sh` | yes | Live migrate a list of instances to a target compute host with monitoring |
| Delete Volume | volumes | `volumes/delete-volume.sh` | yes | Delete available Cinder volumes (single ID or list), including snapshots (--purge) |
| Import Volume from NetApp | volumes | `volumes/import-vol-from-netapp.sh` | yes | Bring an existing NetApp volume under Cinder management (cinder manage) |

### Live Migrate Instances (`servers/live-migrate.sh`)

Rebalance: moves a list of instances to one target compute host with live migration, one at
a time, with a confirmation per VM, progress monitoring, and abort. (Evacuating a compute host for
maintenance is out of scope.) Requires an admin role, `jq`, and compute microversion ≥ 2.30.

```bash
# From the TUI: no arguments, everything is asked interactively.
bash servers/live-migrate.sh --file vms.txt --target compute-07 --dry-run   # plan only
bash servers/live-migrate.sh --file vms.txt --target compute-07 --interval 10 --timeout 45
```

| Option | Description |
|---|---|
| `--file PATH` | List of instance IDs, one per line. `#` comments, blank lines, CRLF, extra spaces and duplicates are handled; invalid UUIDs are recorded as `SKIPPED (invalid id)` |
| `--target HOST` | Target host (skips the picker; still validated as `nova-compute` enabled and up) |
| `--dry-run` | Pre-check all VMs and print the plan (`WILL MIGRATE` / `SKIP (<reason>)`); never migrates, no lock, no report file |
| `--interval SEC` | Polling interval (default 5) |
| `--timeout MIN` | Per-migration time limit before you are asked to wait or abort (default 30; `90s` for seconds). Never aborts automatically |
| `--delay SEC` | Pause between migrations (default 0) |
| `-h`, `--help` | Show help |

Flow:

1. The target host is chosen once from enabled/up compute hosts (fzf picker, or a numbered menu
   without fzf, with vCPU/RAM usage when the cloud reports it).
2. Right before each VM's confirmation a pre-check runs: not found, status not `ACTIVE`, a
   `task_state` in progress, locked, or already on the target → `SKIPPED`.
3. A summary (name, ID, project, flavor, source/target host, boot-from-volume or local disk) is
   shown. Answer `y` migrate, `n` skip (`DECLINED`), `c` change the target for this VM only, `q`
   stop the batch (remaining VMs are reported as not processed). Default is `n`; there is no
   "yes to all".
4. While migrating, one status line shows status, migration status, memory progress, and elapsed
   time. Press `a` to abort (asks for confirmation). Abort is not instant: monitoring continues
   until Nova finishes; if the VM already reached the target it is `SUCCESS` ("abort terlambat").
   A rejected abort (e.g. post-copy) is shown and monitoring continues. When `--timeout` is
   reached you choose `w` (wait another period) or `a` (abort, with confirmation).
5. Result: `SUCCESS` (on target), `FAILED` (status `ERROR`, or still on the source after Nova rolled
   back — the error from `server event show` is included), `ABORTED`. After `SUCCESS`, power state
   and port bindings are checked (warning only). The exit code is 1 when any VM `FAILED`.

Safety: only one run at a time (`flock` on `log/servers/live-migrate.lock`); a warning if not
running inside `tmux`/`screen` (an SSH disconnect stops monitoring, not the migration); `Ctrl-C`
during a migration says the migration continues in Nova, offers to abort it, writes a partial
summary, and returns to the TUI.

Report: besides the daily log, each run writes
`log/servers/live-migrate-<run_id>-results.tsv` (timestamp, server_id, name, src_host, dst_host,
result, duration_s, message), one line as soon as each VM is done.

Environment: `OSOPS_COMPUTE_API_VERSION` (default `2.65`; lowered to the cloud maximum with a
warning, refused below `2.30`) and `OSOPS_OS_CMD` (OpenStack CLI command, default `openstack`).

**Known limitation (RHOSO):** `OSOPS_OS_CMD="oc exec -n openstack openstackclient -- openstack"`
only changes how the CLI is invoked. The `OS_*` credentials loaded by the toolkit are **not**
passed into the pod; the pod must have its own credentials (`clouds.yaml` / environment). Not yet
tested against RHOSO.

### Delete Volume (`volumes/delete-volume.sh`)

Deletes Cinder volumes **permanently, including all their snapshots**
(`openstack volume delete --purge`), one at a time, and waits until each volume is really gone.
Requires an admin role and `jq`.

```bash
# From the TUI: no arguments, input mode and confirmation mode are asked interactively.
bash volumes/delete-volume.sh --id 3f2c...-...                 # one volume
bash volumes/delete-volume.sh --file volumes.txt --dry-run     # plan only
bash volumes/delete-volume.sh --file volumes.txt --no-confirm  # full plan + one batch confirmation
```

| Option | Description |
|---|---|
| `--id VOLUME_ID` | One volume (UUID). Cannot be combined with `--file` |
| `--file PATH` | List of volume IDs, one per line. `#` comments, blank lines, CRLF, extra spaces and duplicates are handled; invalid UUIDs are recorded as `SKIPPED (invalid id)` |
| `--no-confirm` | No per-volume prompt: the full plan is shown first, then **one** batch confirmation where you must type the number of volumes to delete (anything else cancels, nothing is deleted) |
| `--dry-run` | Validate everything and print the plan (incl. snapshots and skipped volumes with reasons); never deletes, no lock, no report file |
| `--interval SEC` | Polling interval while waiting for the deletion (default 3) |
| `--timeout MIN` | Time limit per volume (default 10; `90s` for seconds) → `FAILED (timeout, last status=...)` |
| `-h`, `--help` | Show help |

Without `--no-confirm` you are asked for the confirmation mode: per volume (`y` delete, `n` skip
= `DECLINED`, `q` stop the batch; default `n`), or no per-volume confirmation (as `--no-confirm`).

Rules:

- Only volumes with status exactly `available` are deleted. Any other status (`in-use`, `error`,
  `creating`, ...) → `SKIPPED (not available, status=<status>)`. The script never detaches, resets
  state, or uses `--force`.
- Snapshots are listed with `--all-projects` (volumes can belong to any project) and shown before
  the confirmation, because `--purge` deletes them too. A snapshot with a status other than
  `available`/`error` → the volume is `SKIPPED (snapshot <id> status=<status>)`.
- Validation runs again right before each deletion. If the snapshot list changed since it was shown
  (plan or prompt), the volume is skipped (`snapshots changed since plan/confirmation`).
- Project and domain names are resolved once per batch (cached); orphaned ones are shown as
  `<id> (project not found)` / `(domain not found)`.
- Deletion is asynchronous: `SUCCESS` only when `volume show` reports the volume as not found;
  `error_deleting` or timeout → `FAILED`; an API rejection → `FAILED (<API message>)`. Other
  read errors while polling (e.g. HTTP 503) are never counted as deleted.

The final summary lists deleted volumes (ID, name, project, snapshots, size) and a separate
**"Volume yang TIDAK dihapus"** table grouped by reason (not available with the actual status, not
found, invalid id, snapshot status, declined, failed with the error, not processed), plus counts,
snapshots deleted, and GB freed. The exit code is 1 when any volume `FAILED`.

Safety: only one run at a time (`flock` on `log/volumes/delete-volume.lock`); a warning for `--file`
runs outside `tmux`/`screen`; `Ctrl-C` while waiting says the deletion continues in Cinder, records
the volume as `ABORTED` (verify manually), writes a partial summary, and returns to the TUI.

Audit: before deleting, all volume details (ID, name, project ID/name, domain, created_at, status,
size, type) and every snapshot (ID, name, size, created_at) are logged (`VOLUME_INFO`, `SNAPSHOT`),
because they cannot be retrieved after deletion. Each run also writes
`log/volumes/delete-volume-<run_id>-results.tsv` (timestamp, volume_id, name, project_name,
domain_name, created_at, status, size_gb, snapshot_count, snapshot_ids, result, duration_s,
message), one line as soon as each volume is done, including skipped ones.

### Upload Image (`images/upload-img.sh`)

Uploads **one** image to Glance in the active region, waits until it is `active`, and verifies it.
Requires an admin role and `jq`; `qemu-img` is optional.

```bash
# From the TUI: no arguments, everything is asked interactively.
bash images/upload-img.sh --file ubuntu-24.04.qcow2 --name ubuntu-24.04 --disk-format qcow2 \
    --visibility public --preset linux --property os_distro=ubuntu --property os_version=24.04
bash images/upload-img.sh --file win2022.qcow2 --name win2022 --disk-format qcow2 \
    --visibility shared --project proj-a --project proj-b --preset windows-uefi --convert-raw
bash images/upload-img.sh --url https://mirror.example.com/cirros.qcow2 --name cirros \
    --disk-format qcow2 --visibility private --project demo --checksum sha512:<hash>
bash images/upload-img.sh --file x.raw --name x --disk-format raw --visibility public --dry-run
```

| Option | Description |
|---|---|
| `--file PATH` / `--url URL` | Source (mutually exclusive). A local file must exist, be readable and not empty. A URL must be `http`/`https` and is only offered when the region supports the `web-download` import method |
| `--name NAME` | Image name (interactive default: file/URL name without extension) |
| `--disk-format FMT` | **Required.** Never detected or guessed (not from content, not from the extension). The interactive picker lists `raw qcow2 vmdk vhd vhdx vdi iso ploop`; any value given here is passed to Glance as-is. Container format is always `bare` |
| `--visibility V` | `public`, `private` (one owner project: `--project` or picker), `shared` (owned by the credentials' project; recipients: repeat `--project` or multi-select picker), `community` (usable by all projects, not listed by default) |
| `--project P` | Project name or ID (names that exist in several domains must use the ID) |
| `--min-disk GB`, `--min-ram MB` | Default `--min-disk`: virtual size from `qemu-img` rounded up to GB |
| `--preset P` | `linux` (`hw_qemu_guest_agent=yes`, `hw_disk_bus=virtio`, interactive: `os_distro`/`os_version`), `windows` (`os_type=windows`, `hw_qemu_guest_agent=yes`), `windows-uefi` (windows + `hw_firmware_type=uefi`, `hw_machine_type=q35`), `none` |
| `--property K=V`, `--tag T` | Repeatable; `--property` overrides preset values |
| `--convert-raw` | Convert to raw with `qemu-img convert -p -f <disk-format> -O raw` before uploading |
| `--tmp-dir PATH` | Where the converted file is written (default `${TMPDIR:-/tmp}`) |
| `--checksum ALGO:HASH` | Expected hash (`md5`, `sha1`, `sha224`, `sha256`, `sha384`, `sha512`). URL: compared with Glance's hash after import. File: checked against the local file before uploading |
| `--interval SEC`, `--timeout MIN` | Polling interval (default 5) and time limit until `active` (default 60; `90s` for seconds) |
| `--dry-run` | Detection, validation, format/project selection, duplicate check and summary, plus the OpenStack commands that would run. No conversion, upload, sharing or rotation |
| `-h`, `--help` | Show help |

Run with arguments, only required values that are missing are asked for (source, name, disk format,
visibility, projects, duplicate action). Optional values (conversion, min-disk/min-ram, preset,
`os_distro`/`os_version`) are asked only when the script runs without arguments.

Flow:

1. **Region capabilities** (shown at start, never fatal): region and auth host, maximum Glance API
   version (`os_hidden` needs ≥ 2.7), import methods (`web-download`). The Glance storage backend
   is not detected.
2. **Virtual size**: with `qemu-img`, a local file and a format other than `iso`,
   `qemu-img info -f <disk-format>` sets the default `--min-disk` (`vhd` is passed to qemu-img as
   `vpc`, `ploop` as `parallels`). If qemu-img cannot read the file as that format, a warning says
   the file may not match the chosen format; the upload is not blocked.
3. **Conversion to raw** (offered only with `qemu-img`, a local file, and a format other than
   `raw`/`iso`): recommended for **Ceph RBD** backends (copy-on-write clones); for other backends
   (file, swift, cinder) the original format is usually smaller and faster to upload. Free space in
   `--tmp-dir` must be at least virtual size + 5% (min. 1 GiB). The temporary file is always removed
   (success, failure, `Ctrl-C`).
4. **Duplicate names**: images with the same name (including hidden ones when supported) are listed
   with ID, owner, visibility, status and created_at. Choose `a` cancel, `c` continue with a
   duplicate name, or `r` **rotate**: after the new image is `active` and verified, older images of
   the same owner are renamed to `<name>-<YYYYMMDD of created_at>` (suffix `-2`, `-3`… if taken) and
   hidden (`os_hidden=true`, if supported). Rotation never runs when the upload fails. With `c`,
   the final summary shows the uploaded image ID next to the IDs of the other images with the same
   name. The OpenStack client looks up the name before uploading and refuses when more than one
   image with that name is visible; the script then shows the reserved ID (not created) and the
   duplicate IDs.
5. **Summary and one `y/N` confirmation** — always shows the region. Outside `tmux`/`screen`, files
   larger than 5 GiB get a warning that an SSH disconnect stops the upload.
6. **Upload**: `openstack image create --id <uuid> ... --file <path> --progress`. The image ID is
   generated by the script and reserved with `--id`, so the output (the progress bar) is never
   captured. URL: an empty image is created, then `openstack image import --method web-download`
   (no progress bar). The script then polls until `active` (`killed`/`deleted`, a failed import
   (`os_glance_failed_import`) or the timeout → failed), with status and elapsed time on one line.
7. **Verification**: Glance's `size` and `os_hash_algo`/`os_hash_value` are compared with the
   uploaded file (the converted file when converted). If they differ but Glance changed the
   `disk_format` (conversion during import in that region), it is a warning; otherwise
   `FAILED (checksum mismatch)` and you are offered to delete the image.
8. **Sharing** (`shared`): `openstack image add project` per recipient. Members stay `pending` until
   the recipient project accepts with its own credentials: `openstack image set --accept <image_id>`
   (the instruction is shown and logged). The script does not accept on the recipient's behalf:
   `openstack image set --accept --project <p>` also changes the image owner to `<p>`.

On failure or `Ctrl-C` during the upload, an image left in `queued`/`saving`/`importing`/`killed` is
detected and you are offered to delete it (after `Ctrl-C` the prompt times out after 60 s → kept).
The final summary shows image ID, name, status, disk format, visibility, owner, recipients with
member status, hash, size, verification result and the log path.

Audit: capabilities, source, chosen disk format, `qemu-img info` result or warning, conversion
(duration, size before/after), all image parameters, decisions, and commands are logged; the progress
bar is not (only upload start, end and duration). `RESULT` lines: `action=upload-image` (`name`,
`region`, `disk_format`, `visibility`, `owner`, `size`, `hash`, `duration`, `msg`), `share-image`,
`rotate-image`, `cleanup-image`. Credentials in a URL (`user:pass@`, query parameters such as
`token`, `signature`, `key`) are masked (`***`) on screen and in the log.

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

Do not set your own `EXIT`/`INT`/`TERM` trap (it replaces the logging trap); for cleanup on
`Ctrl-C`, set `LOG_INTERRUPT_HOOK=<function>` (called before the script exits); for cleanup that
must always run (e.g. temporary files), set `LOG_EXIT_HOOK=<function>` (called once on any exit).
Do not pipe the whole script output through `tee`. In a nested category (`network/floating-ip/x.sh`) use `../..`
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
- Files in `lib/`, `tests/`, and hidden directories are never listed (and never installed) — put
  shared helpers in `lib/` (e.g. `lib/logging.sh`) and test stubs/fixtures in `tests/`.
- Call the OpenStack CLI through a wrapper (`OS_CMD` array + `os_cli` function, overridable via
  `OSOPS_OS_CMD`) and parse JSON output (`-f json`) with `jq`.
- Read prompts from `/dev/tty`. When a loop over an input file asks questions, read the whole file
  first (`mapfile`) — never `while read ... < file`, or the prompts consume the file.
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
├── tests/                  # Test stubs, fixtures and runners (not listed, not installed)
├── identity/               # Identity (Keystone) scripts
├── images/                 # Image (Glance) scripts
├── network/                # Network (Neutron) scripts
├── servers/                # Server (Nova) scripts
└── volumes/                # Block storage (Cinder) scripts
```

Category directories are discovered dynamically; add a directory to add a category.

Tests for `servers/live-migrate.sh`, `volumes/delete-volume.sh` and `images/upload-img.sh` run
against a stub OpenStack CLI (and a stub `qemu-img`; no cloud needed; requires `tmux`, `jq`, `flock`;
`fzf` for the picker tests):

```bash
bash tests/live-migrate/run.sh            # all tests
bash tests/live-migrate/run.sh abort      # only tests whose name matches
bash tests/delete-volume/run.sh
bash tests/upload-img/run.sh
```

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
| `Live migration lain sedang berjalan` | Another `live-migrate.sh` run holds `log/servers/live-migrate.lock` (the holder is shown). Wait for it to finish |
| `Delete volume lain sedang berjalan` | Another `delete-volume.sh` run holds `log/volumes/delete-volume.lock` (the holder is shown). Wait for it to finish |
| `Cloud hanya mendukung compute microversion ... (< 2.30)` | Live migration to a chosen host needs compute API ≥ 2.30 |
| `Sumber URL butuh import method web-download, tidak tersedia di region ...` | The active region's Glance does not offer `web-download`: download the file and use `--file` |
| `Upload ditolak karena ada lebih dari satu image bernama ...` | The OpenStack client refuses an upload when more than one visible image has that name: use another name, or rename/hide the old images (rotation) |
| `lib/logging.sh tidak ditemukan` | `lib/` is missing from the install: re-run `./install.sh` |
