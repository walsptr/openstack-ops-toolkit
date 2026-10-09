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
install.sh            Installer: requirement checks, copies category dirs, installs command
scripts.env.example   Example of the OPTIONAL local override file
<category>/*.sh       Operational scripts (compute/, identity/, network/, volumes/, ...)
lib/                  (optional) shared helpers for scripts — never listed in the TUI
```

### Script discovery (single source of truth)

The script file itself is the single source of truth. `main.sh` finds scripts automatically:

1. Scan `*.sh` files in subdirectories of the workdir (default `/opt/openstack-ops-toolkit`, or `--workdir`).
2. Skip files directly in the workdir root (`main.sh`, `install.sh`), any `lib/` directory, and hidden files/directories.
3. Parse the metadata header of each file (see below). Files without `@name` are treated as helpers and are not listed.
4. Category = first directory of the path relative to the workdir (`network/floating-ip/x.sh` → `network`).
5. Apply the optional `scripts.env` override.
6. Sort by category, then name, then path (`LC_ALL=C`, case-insensitive).

The same parser is used everywhere: TUI table, preview pane, `Ctrl-R` reload, `--no-fzf`, `--list`, and `install.sh` (through the internal `main.sh --discover DIR`).

Internal record format (fields separated by `\x1f` so empty fields survive `read`):

```
path  rel  category  name  mutates  requires  tags  description  source(discovered|custom)  warn
```

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
6. Run the checks in the Testing section.
7. Update the "Operational scripts" table in `README.md` from `bash main.sh --workdir . --list` (run from a clean checkout without `scripts.env`).

## Development Standards

* Use Bash ≥ 4 for shell-based functionality; keep compatibility with fzf ≥ 0.20.0.
* Operational scripts use `set -o errexit`, `set -o nounset`, `set -o pipefail` (long form, as in the existing scripts). `main.sh` intentionally does not use errexit (interactive loop); `install.sh` does — guard `[[ ... ]] && ...` patterns and end functions with `return 0`.
* User-facing messages follow the language already used in the file being edited: `main.sh` and most script prompts/errors are in Indonesian; `install.sh` mixes English status lines with Indonesian errors. Code comments and metadata (`@description`) may be English. Keep it consistent within a file.
* Follow consistent naming conventions and formatting.
* Quote variables and handle command arguments safely.
* Validate user input and check external command results.
* Provide clear and actionable error messages.
* Do not add new required dependencies beyond those listed in the README (bash, openstack client, fzf, core utilities).
* Never expose credentials, tokens, or other sensitive information.
* Avoid destructive operations without appropriate safeguards.
* Keep documentation consistent with actual behavior.

## Prohibited

* Do not register scripts that live inside the repo in `scripts.env` — use the metadata header. `scripts.env` is only for local renames, hiding, and scripts outside the repo.
* Do not hardcode the list of categories (`compute identity network volumes`) in `main.sh`, `install.sh`, or docs logic.
* Do not add OpenStack resource views or actions to the TUI; add a script instead.
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
bash -n main.sh install.sh */*.sh          # syntax
shellcheck main.sh install.sh */*.sh        # if available
bash main.sh --workdir . --list             # discovery + metadata as Markdown table
bash main.sh --workdir . --no-fzf           # plain menu (same data as the TUI)
bash main.sh --workdir .                    # TUI (needs a terminal, fzf, and an RC file)
```

Override behavior can be tested with a temporary workdir containing a `scripts.env` (rename, `!path`, custom absolute path, old format). The TUI needs an interactive terminal; tmux (`send-keys` / `capture-pane`) works for scripted checks. A stub `openstack` command in `PATH` avoids touching a real cloud.

Tests should cover relevant error conditions and edge cases. Avoid performing destructive operations against production infrastructure during testing.

Clearly identify any checks that could not be performed.

## Documentation

Keep project documentation concise, accurate, and useful. Include setup instructions, usage guidance, prerequisites, and relevant configuration details where appropriate. The README "Operational scripts" table must match `main.sh --list`.

## General Instructions

Prioritize correctness, maintainability, and consistency with the existing project.

When requirements are ambiguous, inspect the current implementation and choose the simplest reasonable approach. Explain significant architectural changes and their trade-offs before introducing them.

Do not assume requirements that have not been established, and do not overengineer features for hypothetical future needs.
