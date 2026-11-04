# CLAUDE.md

## Project Overview

OpenStack Ops Toolkit is a modular command-line toolkit designed to simplify OpenStack administration, operations, and troubleshooting through reusable scripts and an interactive terminal interface.

The project aims to provide a simple, efficient, and maintainable way to discover and execute operational tasks.

The TUI (`main.sh`) only borrows the **look and feel** of k9s (info panel, key hints, titled table, preview pane). Its only function is to search, preview, and run operational scripts. All OpenStack operations live in the scripts — do not add resource browsing or OpenStack actions to the launcher.

## Core Principles

* **Modularity:** Keep individual operational tasks independent and reusable.
* **Simplicity:** Prefer straightforward solutions over unnecessary complexity.
* **Maintainability:** Write clear, consistent, and well-structured code.
* **Extensibility:** Make it easy to add new features and operational scripts.
* **Reliability:** Handle errors, invalid input, and unexpected conditions gracefully.
* **Safety:** Validate inputs and apply appropriate safeguards to operations that modify resources.
* **Compatibility:** Preserve existing functionality unless a change is explicitly required.

## Architecture

```
main.sh               Entry point: k9s-style TUI launcher (fzf), --no-fzf fallback, --list
install.sh            Installer: requirement checks, copies category dirs + lib/, creates log/, installs command
scripts.env.example   Example of the OPTIONAL local override file
<category>/*.sh       Operational scripts (identity/, images/, network/, rhosp/, servers/, volumes/, ...)
lib/                  Shared helpers for scripts — never listed in the TUI
lib/logging.sh        Mandatory logging library (sourced by every script and by main.sh)
lib/api.sh            Shared helper for direct API access with curl (token on stdin, catalog endpoint, pagination)
lib/netinfo.sh        Shared helper: IP validation/canonical form, IPv4 CIDR + allocation pool match, device_owner labels (bash + jq defs)
lib/rhosp.sh          Shared helper for RHOSP scripts: rhosp-release/user check, TripleO inventory search + node/role parsing (no hostvars dump),
                      node picker ([semua <Role>]), host key handling, ssh_node / ssh_node_stdin / scp_fetch wrappers
lib/containerlogs.sh  Shared helper for the container log scripts: discovery of /var/log/containers (one SSH per node = pre-check), path
                      validation, rotated-file mapping, file picker + internal --_preview, pager, saving results (600, noclobber)
tests/<name>/         Test runners, stub CLIs, fixtures — never listed in the TUI, never installed
.shellcheckrc         shellcheck settings (source paths relative to each script)
log/                  Runtime logs (not tracked by git): toolkit.log + log/<category>/<script>-YYYYMMDD.log
```

### Script discovery (single source of truth)

The script file itself is the single source of truth. `main.sh` finds scripts automatically:

1. Scan `*.sh` files in subdirectories of the workdir (default `/opt/openstack-ops-toolkit`, or `--workdir`).
2. Skip files directly in the workdir root (`main.sh`, `install.sh`), any `lib/` or `tests/` directory, and hidden files/directories. `install.sh` copies only discovered category dirs plus `lib/`, so `tests/` is never installed.
   `cp -R` never removes files, so a renamed or removed script must be added to `RENAMED_SCRIPTS` (old → new) or `REMOVED_SCRIPTS` in `install.sh`: only those paths are deleted from the install dir (never "anything not in the source" — operators may keep custom scripts there), and `scripts.env` entries pointing to them are reported (file unchanged).
3. Parse the metadata header of each file (see below). Files without `@name` are treated as helpers and are not listed.
4. Category = first directory of the path relative to the workdir (`network/floating-ip/x.sh` → `network`).
5. Apply the optional `scripts.env` override.
6. Sort by category, then name, then path (`LC_ALL=C`, case-insensitive).

The same parser is used everywhere: TUI table, preview pane, `Ctrl-R` reload, `--no-fzf`, `--list`, and `install.sh` (through the internal `main.sh --discover DIR`).

Internal record format (fields separated by `\x1f` so empty fields survive `read`):

```
path  rel  category  name  mutates  requires  tags  description  source(discovered|custom)  warn  platform
```

New fields are appended at the end (`install.sh` reads records with `_` as the last field).

### `scripts.env` override (optional, local, not tracked by git)

| Line | Meaning |
|---|---|
| `Display Name,path` | If `path` is a discovered script: rename only (no duplicate). Otherwise: add a custom entry with category `custom`. |
| `!path` | Hide the script. |
| `# ...`, blank line | Ignored. Trailing comments (`  # ...`) are ignored too. |

Relative paths resolve against the workdir; paths are compared after normalization (`realpath -m -s`). Old-format files (one line per script, identical to discovery) cause no duplicates. `install.sh` never creates or modifies `scripts.env`; it only reports redundant entries.

## Metadata header specification

```bash
#!/bin/bash
# ============================================================
# @name:        List Orphan Ports
# @description: List ports that are not attached to any device
# @mutates:     no
# @requires:    admin
# @tags:        neutron, port, cleanup
# ============================================================
```

| Tag | Required | Rules |
|---|---|---|
| `@name` | **Yes** | Display name. Without it the file is not listed. |
| `@description` | No | One line. Fallback: first non-tag, non-separator comment line of the header block. |
| `@mutates` | No | `yes` / `no`, default `no`. Any other value is treated as `yes` with a warning (fail safe). |
| `@requires` | No | Free text, e.g. `admin`, `admin, cinder`. Shown in preview and confirmation. |
| `@tags` | No | Comma-separated. Included in fuzzy search. |
| `@platform` | No | Environment the script is made for. Supported: `rhosp` (met when `/etc/rhosp-release` exists; `OSOPS_RHOSP_RELEASE_FILE` overrides the path for tests). Not met: still listed, marked `(<platform> only)` in the fzf table and `--no-fzf` menu, preview shows `Platform : <platform> — tidak terpenuhi`, `Enter` shows a message and does not run it (`RUN_BLOCKED result=SKIPPED` in `toolkit.log`). Unknown values count as not met (fail safe). `--list` output never depends on it (must be identical on every host). Only a TUI marker: the script must check its environment itself. |

Parsing rules:

- Only the header block is read: comment lines after the shebang (blank lines allowed) until the first non-comment line. Tags after the first line of code are ignored.
- Separator lines (`# ====`, `# ----`) are ignored. Keys are case-insensitive; unknown `@keys` are ignored.
- Put the metadata block **directly after the shebang**, before `set -o ...`.

## Adding a new script — checklist

1. Create the file in a category directory: `<category>/<verb-noun>.sh` (e.g. `network/list-orphan-ports.sh`). A new category is just a new directory — never hardcode category lists anywhere.
2. Add the metadata header directly after the shebang. `@name` is required.
3. If the script creates, modifies, or deletes any resource: set `@mutates: yes` **and** the script must ask for its own confirmation (y/N) before the change. The launcher confirmation is an extra safeguard, not a replacement.
4. Set `@requires` when the script needs an admin role or an extra client (e.g. `cinder`).
5. Use the OpenStack credentials already loaded by the launcher (`OS_*` variables); never ask for or print secrets.
6. Add logging: source `lib/logging.sh`, call `log_init`, log inputs, and (for `@mutates: yes`) `log_run` + `log_result` per resource including `DECLINED`/`SKIPPED` — see "Logging (mandatory)".
7. Run the checks in the Testing section.
8. Update the "Operational scripts" table in `README.md` from `bash main.sh --workdir . --list` (run from a clean checkout without `scripts.env`).

## Logging (mandatory)

Every operational script logs through `lib/logging.sh`. Rules:

* **Every new script must source `lib/logging.sh` and call `log_init`**, right after the `set -o ...` lines, with the standard snippet (see `README.md` → Adding a script). If the library is missing the script exits with a clear error.
* **Scripts that change resources (`@mutates: yes`) must call `log_result` for every resource**, for every outcome — including `DECLINED` (operator answered no at the script's confirmation) and `SKIPPED`. Run the changing command through `log_run` so the command (`CMD`) and its stderr (`$LOG_LAST_ERROR`, used as `msg=` on `FAILED`) are logged.
* **Valid `result` values:** `SUCCESS`, `FAILED`, `SKIPPED`, `DECLINED`, `ABORTED`. Anything else is logged as `FAILED` with a warning.
* Log user input with `log_event INPUT key=value ...` (IDs, IPs, names, input file paths). Read-only scripts log their queries (`log_result ... action=lookup`) and a `SUMMARY`, not the full output.
* When the script already printed an error/warning, log it with `log_error -q` / `log_warn -q` so terminal output does not change.
* **Never log secrets:** no `OS_PASSWORD`, tokens, application credential secrets, or any variable containing `PASSWORD`, `SECRET`, or `TOKEN` (the library also redacts their values as a safety net — do not rely on it).
* **Never `tee` the whole script output** (or wrap scripts in `tee` in `main.sh`): it breaks interactive prompts, colors, and fzf. Log explicitly.
* Do not set your own `EXIT`/`INT`/`TERM` trap in a script — it replaces the library's `START`/`END` trap. For cleanup on `Ctrl-C`/SIGTERM set `LOG_INTERRUPT_HOOK=<function>`; the library calls it (once; a second signal exits immediately) before `exit 130/143`, so `main.sh` still returns to the TUI. The hook must not block forever (use `read -t`). For cleanup that must run on every exit (normal, error, signal), e.g. temporary files, set `LOG_EXIT_HOOK=<function>` (called once, before the `END` line). Only exception: a bounded restore of a temporary cluster change may ignore signals inside `LOG_EXIT_HOOK` (see "Temporary changes to cluster configuration").
* After `log_init`, `LOG_FILE` and `LOG_RUN_ID` are available (e.g. for per-run report files next to the log). Use `log_event DECISION ...` for user decisions and `log_info` with `dry_run=true` (never `log_result`) for planned-only actions.
* **Do not hardcode log paths or category names.** The log directory comes from `OSOPS_LOG_DIR` / `LOG_DIR` / `<toolkit root>/log` (with the XDG fallback); the category is derived from the script path. Logging failures must never fail a script.
* Line format: `<ISO8601+TZ> <LEVEL> run=<run_id> user=<operator> <EVENT> key=value ...`. `main.sh` passes `OSOPS_RUN_ID` so `toolkit.log` and the script log share the `run_id`.

## Script conventions (OpenStack CLI, JSON, prompts)

These rules come from `servers/live-migrate.sh`, `volumes/delete-volume.sh`, `images/upload-img.sh`, `network/collect-public-fip.sh`, `servers/list-instances-by-host.sh`, `network/get-ip-info.sh`, `rhosp/collect-sosreport.sh` and `rhosp/view-container-logs.sh` / `rhosp/search-container-logs.sh` and apply to every new script:

* **Call the OpenStack CLI through one wrapper:** an array `OS_CMD=(openstack)` (overridable with the env string `OSOPS_OS_CMD`, split with `read -ra`, because arrays cannot be exported) and a function `os_cli` (plus `os_run` = `log_run` for changing actions). Never call `openstack` directly elsewhere in the script. This keeps scripts testable with a stub and ready for RHOSO (`oc exec ... openstack`).
* **Scripts that use the compute API: pin the compute microversion in one variable** (overridable via env), pass it through the wrapper (`--os-compute-api-version`), check the cloud maximum (`versions show --service compute`) and warn about affected features.
* **Parse JSON with `jq`** (`-f json`), with `-` as default for null fields; do not parse table output with awk/sed. Check `jq` at startup with a clear message. One `server show -f json` per state read, not one call per field.
* **Prompts read from `/dev/tty`** (helper `ask VAR "prompt"`; inside it use a uniquely named local, because `printf -v` with a local of the same name as the caller's variable assigns the wrong variable). Check `( : < /dev/tty )` and fail clearly when no terminal is available.
* **Never `while read ... < file` when the loop body prompts** — the prompts consume the input file. Read the whole file first with `mapfile`, then strip `\r`, comments, blanks, and duplicates.
* Long-running or batch operations: lock with `flock -n` (lock file next to the script's log), warn when not inside `tmux`/`screen`, and confirm each resource individually (no "yes to all"); the only exception is an explicit no-confirmation mode with one batch confirmation (see below).
* **Listing resources of other projects requires `--all-projects`** (e.g. `volume snapshot list --volume <id> --all-projects`); without it an admin only sees its own project and the script silently misses resources.
* **Asynchronous deletes must be polled until the resource is gone** (with interval and timeout). Only an explicit "not found" for that ID counts as `SUCCESS`; other read errors (5xx, auth) never do. An `error_deleting`-style status or timeout is `FAILED`.
* **Log resource details before deleting them** (`log_event` with all identifying fields, including dependent resources like snapshots): after deletion the API can no longer return them.
* **A "no confirmation" mode still needs one batch confirmation with explicit input** (e.g. typing the number of resources), after showing the full plan; re-validate each resource right before changing it, and skip it if what will be deleted changed since the plan.
* **Skipped resources must appear in the final summary with their reason** (e.g. the actual status), not only in the log.
* **Never assume a backend or region configuration** (Glance/Cinder storage backend, import methods, API versions, policies): regions differ. Detect capabilities at runtime (e.g. `versions show --service <svc>`, `image import info`), never fail when detection is not possible, and make features that depend on them optional (only offer them when available).
* **Show the active region** (`OS_REGION_NAME`, auth host) in the summary before any action that changes resources.
* **Mask credentials in URLs** (`user:pass@`, query parameters like `token`/`signature`/`key`) before they are shown or logged — including in commands logged as `CMD` and in API error messages. Mask each argument before shell-quoting it.
* **Never capture or discard CLI progress output** (`--progress`, `qemu-img -p`): `$(...)` or redirecting stdout hides the bar (OSC only draws it when stdout is a TTY). Get IDs another way, e.g. reserve the image ID with `image create --id <uuid>`.
* **OSC pitfalls (7.x):** `image create` looks the name up first and fails when more than one visible image has it; `image set --accept --project P` also changes the image owner to `P` (do not use it to accept on a member's behalf); without `--file`, `image create` reads image data from stdin when stdin is not a TTY (close it with `<&-`). `server list --host <host>` always returns an empty list with OSC 7.1.2 / openstacksdk 4.0.0 (the SDK filters again client-side on the wrong attribute): never trust it — use the API (`GET /servers/detail?host=`) or filter `server list --all-projects --long` by the `Host` column with `jq`. `port list` requests only its displayed columns (`fields=`), so even with `--long` it has no `device_id`, `network_id`, `project_id`, `allowed_address_pairs`, or `created_at`: use it to find candidates, then `port show` only the matches (or the Neutron API, which returns full ports).
* **Large data sets: never one CLI call per item.** Fetch in bulk (one list call, or one API request per page) and join with `jq` (e.g. one `project list` / `server list --all-projects` as an ID → name map). Per-item calls are only a fallback, run in parallel (`xargs -P`, one output file per item, never interleaved stdout). `server list --limit` disables OSC pagination (only one page is returned): leave it out to get all pages.
* **Always `-f json` for fields that are objects** (`port_details`, `fixed_ips`, ...): `-f value` prints a Python dict that `jq` cannot parse. OSC 7.x even formats some dicts as a string in `-f json` (`floating ip show` → `port_details` is `"device_owner='compute:nova', ..."`): accept both object and string.
* **Tokens must never appear in process arguments (visible in `ps`) or in logs.** Pass them on stdin, e.g. `printf 'header = "X-Auth-Token: %s"\n' "$token" | curl -K - ...`; do not write them to files. `curl` is optional: only use it where a CLI fallback exists, and honour `OS_CACERT`, `OS_CERT`/`OS_KEY`, `OS_INSECURE`. Take the endpoint from `catalog show <service>` for `OS_REGION_NAME`/`OS_INTERFACE`, and follow pagination links by query string on that endpoint (links can carry a wrong host behind a proxy).
* **Direct API access must use the shared helper `lib/api.sh`** (`api_setup`, `api_get`, `api_collect`; source it after `lib/logging.sh`, set `API_WORK_DIR`, call `api_cleanup` in `LOG_EXIT_HOOK`). Do not re-implement token, endpoint, or pagination handling in a script.
* **IP lookups must expect several results.** Private CIDRs overlap between projects (and subnets can overlap with each other), so an IP search returns *all* matching ports / floating IPs / subnets with their network and project — never pick the first one. Compare IPs in canonical form (`ip_normalize` from `lib/netinfo.sh`; IPv6 lowercase + `::` compression).
* **Classify ports with the shared `device_owner` rules** (`device_type` in `NETINFO_JQ`, or `device_label` in bash, from `lib/netinfo.sh`; source it after `lib/logging.sh`), and IPv4 CIDR / allocation-pool checks with `cidr4_contains` / `in_pools` / `ip4_in_cidr` — do not re-implement them in a script. A floating IP's own internal port (`network:floatingip`) is not a separate user of the address.
* **Output files meant as input for another script must follow that script's input format exactly** (e.g. `.ids` files for `servers/live-migrate.sh --file`: `#` comments, one ID per line) and be verified in the tests with that script's own parser.
* **Output files with sensitive data** (project names, public IPs, ...) are created with permission `600` (`umask 077`) and `noclobber`, never overwriting an existing file. Temporary directories: `mktemp -d` under `umask 077`, removed in `LOG_EXIT_HOOK`.
* **Instance ports: match `device_owner` by the prefix `compute:`** (the value is `compute:<availability-zone>`), never by `compute:nova` only.
* **Temporary changes to cluster configuration** (e.g. Pacemaker `stonith-enabled`) must: record the original value (including "not set"), restore exactly that value — never an assumed one (`unset` → `pcs property unset`, not `set true`) — and verify it; be guaranteed through the library's trap hooks (`LOG_EXIT_HOOK`, plus `LOG_INTERRUPT_HOOK` to stop workers), not an own `EXIT`/`INT`/`TERM` trap; and write a state file (run id, controller, original value, time) *before* the change, removed only after a verified restore, so the next run can detect a crash (`kill -9`, lost SSH) and offer to restore. If the state file cannot be written, do not make the change. Try another controller when the restore fails; if all fail, show the manual command, keep the state file, log `FAILED`, and exit non-zero. Keep the window short (change only when a selected resource needs it, restore as soon as that part is done). The only exception to "no own trap": inside `LOG_EXIT_HOOK`, `trap '' INT TERM HUP` for the bounded restore, so a second `Ctrl-C` cannot cut it short.
* **Inventory hostvars are never printed or logged as a whole** (`ansible-inventory --list` output contains secrets such as `overcloud_admin_password`, `os_auth_token`). Extract only the needed fields with `jq` (hostname, role, `ansible_host`, user, key path, port) and keep the JSON in the `umask 077` temp directory. Do not let group vars of the `Undercloud` group (e.g. its private key) apply to overcloud nodes.
* **RHOSP scripts must use `lib/rhosp.sh`** (source it after `lib/logging.sh`) for the environment check (`rhosp_check_env confirm` for scripts that change something, `warn` for read-only ones), inventory search and parsing (`rhosp_find_inventory`, `rhosp_load_nodes`; set `RHOSP_WORK_DIR`), node selection (`rhosp_select_nodes`, `rhosp_pick_nodes`), host keys (`check_host_keys`, `log_accepted_key`) and all SSH/SCP (`ssh_node`, `ssh_node_stdin`, `scp_fetch`, `ssh_fail_reason`). Do not re-implement them in a script. Script-specific per-node arrays are initialised in the optional hook `rhosp_on_node_added IDX`; `RHOSP_WITH_UNDERCLOUD=1` adds the undercloud as a local node. Scripts that read `/var/log/containers` also use `lib/containerlogs.sh` (discovery, path validation, rotated files, file picker, pager, saving).
* **Remote commands go through one SSH wrapper and one SCP wrapper** (`ssh_node` / `scp_fetch`, binaries overridable with `OSOPS_SSH` / `OSOPS_SCP`): `BatchMode=yes`, `ConnectTimeout`, `ServerAliveInterval`, no `-t`, stdin from `/dev/null`, a local `timeout`. Never disable host key checking silently: known hosts use `StrictHostKeyChecking=yes`, unknown hosts need one explicit confirmation for `accept-new`, a changed key is a `SKIPPED` resource. Validate inventory values (hostname, IP, user, port) before they become `ssh` arguments.
* **Exception to "stdin from `/dev/null`" — `ssh_node_stdin`:** (1) user data that must never be part of the remote command string (a search pattern, long file lists) is sent on stdin and read remotely with `IFS= read -r` (see `search-container-logs.sh`: pattern on line 1, `xargs -0` for the file list, `-e "$1"` before the pattern); (2) a long-running stream (`tail -F`) reads its stdin from a FIFO the script holds open and runs as `... tail -F --pid=$$ ... & cat >/dev/null`, so the remote command gets EOF and stops when `ssh` ends, without `-t`. Paths that go into a remote command are validated (`cl_valid_path`) and quoted with `%q`. On RHOSP nodes `/var/log/containers` is only accessible through `sudo` (the SSH user cannot even `cd` into it): always pass absolute paths to the `sudo` command, never `cd` or read them without `sudo`. Filter the sshd banner and `Warning: Permanently added` from stderr before showing it as an error (`cl_err_tail`). Read-only remote commands are limited to `sudo -n find|tail|grep|zgrep` (plus `nice`/`ionice`/`timeout`/`xargs` around a search); the tests check this allowlist.
* **Background workers** (non-interactive bash) ignore `SIGINT`: kill them (and their process tree) explicitly in `LOG_INTERRUPT_HOOK` / `LOG_EXIT_HOOK`. Workers never prompt; they write status to a file the main process reads.
* **Known limitation (RHOSO):** `OSOPS_OS_CMD` only changes how the CLI is called; the toolkit's `OS_*` credentials are not passed into an `oc exec` pod, which needs its own `clouds.yaml`/environment. Document it, do not try to forward secrets.

## Development Standards

* Use Bash ≥ 4 for shell-based functionality; keep compatibility with fzf ≥ 0.20.0.
* Operational scripts use `set -o errexit`, `set -o nounset`, `set -o pipefail` (long form, as in the existing scripts). `main.sh` intentionally does not use errexit (interactive loop); `install.sh` does — guard `[[ ... ]] && ...` patterns and end functions with `return 0`.
* User-facing messages follow the language already used in the file being edited: `main.sh` and most script prompts/errors are in Indonesian; `install.sh` mixes English status lines with Indonesian errors. Code comments and metadata (`@description`) may be English. Keep it consistent within a file.
* Follow consistent naming conventions and formatting.
* Quote variables and handle command arguments safely.
* Validate user input and check external command results.
* Provide clear and actionable error messages.
* Do not add new required dependencies beyond those listed in the README (bash, openstack client, fzf, jq, core utilities incl. `flock`).
* **Development tools** (not runtime dependencies): `shellcheck` (must report no warnings for all `.sh` files; settings in `.shellcheckrc`; if not installed, use a throwaway venv: `python3 -m venv /tmp/sc && /tmp/sc/bin/pip install shellcheck-py`), `tmux` for scripted TUI/prompt tests.
* Never expose credentials, tokens, or other sensitive information.
* Avoid destructive operations without appropriate safeguards.
* Keep documentation consistent with actual behavior.

## Prohibited

* Do not register scripts that live inside the repo in `scripts.env` — use the metadata header. `scripts.env` is only for local renames, hiding, and scripts outside the repo.
* Do not hardcode the list of categories (`identity network servers volumes`) in `main.sh`, `install.sh`, or docs logic.
* Do not add OpenStack resource views or actions to the TUI; add a script instead.
* Do not log secrets, do not `tee` whole script output, and do not hardcode log paths or category names.
* Do not call `openstack` directly outside the `os_cli`/`os_run` wrapper, and do not use `while read` on an input file in a loop that prompts.
* Do not change business logic of operational scripts when only metadata or documentation is requested.

## Development Workflow

Before implementing changes:

1. Review the relevant existing code and project structure.
2. Understand the intended behavior and compatibility requirements.
3. Implement the smallest maintainable solution.
4. Test the changes and validate relevant edge cases.
5. Update documentation when necessary.

Do not modify unrelated components or introduce unnecessary abstractions.

## Testing

Validate changes using appropriate syntax checks, tests, and representative usage scenarios:

```bash
bash -n main.sh install.sh */*.sh          # syntax (includes lib/*.sh)
shellcheck -x main.sh install.sh */*.sh     # dev tool, no warnings allowed
bash tests/live-migrate/run.sh              # live-migrate tests (stub CLI, tmux)
bash tests/delete-volume/run.sh             # delete-volume tests (stub CLI, tmux)
bash tests/upload-img/run.sh                # upload-img tests (stub CLI + stub qemu-img, tmux)
bash tests/collect-public-fip/run.sh        # collect-public-fip tests (stub CLI + stub curl, tmux)
bash tests/list-instances-by-host/run.sh    # list-instances-by-host tests (stub CLI + stub curl, tmux)
bash tests/get-ip-info/run.sh               # get-ip-info + lib/netinfo.sh + install.sh rename tests (stub CLI + stub curl, tmux, unshare -r)
bash tests/collect-sosreport/run.sh         # collect-sosreport + @platform in main.sh (stub ssh/scp/ansible-inventory/sudo/sosreport/pcs/fzf, tmux, ssh-keygen)
bash tests/view-container-logs/run.sh       # view-container-logs + lib/rhosp.sh + lib/containerlogs.sh (stub ssh/sudo/fzf/less, tmux, setsid)
bash tests/search-container-logs/run.sh     # search-container-logs (same stubs; real find/grep/zgrep/xargs/nice/ionice/timeout)
bash main.sh --workdir . --list             # discovery + metadata as Markdown table
bash main.sh --workdir . --no-fzf           # plain menu (same data as the TUI)
bash main.sh --workdir .                    # TUI (needs a terminal, fzf, and an RC file)
```

Logging checks: after running scripts, inspect `./log/<category>/*.log` and `./log/toolkit.log` (format, `run_id` shared with `toolkit.log`); set `OSOPS_LOG_DIR` to a read-only directory to test the fallback warning; grep the log directory for the test RC file's `OS_PASSWORD` value (must return nothing).

Scripts that call the OpenStack CLI through `os_cli` are tested with a stub CLI (`OSOPS_OS_CMD=tests/<name>/stub/openstack`) returning JSON fixtures, driven in tmux because prompts read `/dev/tty`. Other external tools are stubbed the same way through an override variable (e.g. `OSOPS_QEMU_IMG`, `OSOPS_CURL`, `OSOPS_FZF`, `OSOPS_SSH`, `OSOPS_SCP`, `OSOPS_ANSIBLE_INVENTORY`); local `sudo`/`sosreport` are stubbed through `PATH`. Remote commands are tested with a stub `ssh` that runs the real command string against a fake per-host directory (paths such as `/var/tmp` mapped), so the exact commands the script sends are exercised. The container log stub (`tests/view-container-logs/stub/ssh`) detaches the "remote" process (it is not a child of the stub) and feeds its stdin through a FIFO held by the stub, like `sshd`: killing the stub must be enough to stop remote streams (checked with `pgrep`). Put stubs and fixtures under `tests/<name>/` (stub without `.sh` extension, runner without `@name`). Behavior that only a real cloud shows (abort timing, CLI output format of other OSC versions) must be reported as not verified.

Override behavior can be tested with a temporary workdir containing a `scripts.env` (rename, `!path`, custom absolute path, old format). The TUI needs an interactive terminal; tmux (`send-keys` / `capture-pane`) works for scripted checks. A stub `openstack` command in `PATH` avoids touching a real cloud.

Tests should cover relevant error conditions and edge cases. Avoid performing destructive operations against production infrastructure during testing.

Clearly identify any checks that could not be performed.

## Documentation

Keep project documentation concise, accurate, and useful. Include setup instructions, usage guidance, prerequisites, and relevant configuration details where appropriate. The README "Operational scripts" table must match `main.sh --list`.

## General Instructions

Prioritize correctness, maintainability, and consistency with the existing project.

When requirements are ambiguous, inspect the current implementation and choose the simplest reasonable approach. Explain significant architectural changes and their trade-offs before introducing them.

Do not assume requirements that have not been established, and do not overengineer features for hypothetical future needs.
