# Codex Memory Kit

Portable bootstrap kit for reproducing the Codex memory structure on any machine while preserving the expected runtime paths.

## Purpose

This kit installs and verifies a three-layer Codex memory architecture:

1. Global memory in `~/.codex/memories/`
2. Home bootstrap in `~/AGENTS.md`
3. Project-local memory in `<repo>/AGENTS.md`, `<repo>/START-HERE.md`, `<repo>/assistant-memory.md`, and `<repo>/memory/`

The kit is intended to make the memory setup reproducible across machines without hard-coding one specific username or home directory in the source templates.

## Runtime Layout

After installation, the expected runtime paths are:

- `~/.codex/memories/global-collaboration-rules.md`
- `~/.codex/memories/memory-architecture.md`
- `~/AGENTS.md`
- `<repo>/AGENTS.md`
- `<repo>/START-HERE.md`
- `<repo>/assistant-memory.md`
- `<repo>/memory/current-work-queue.md`
- `<repo>/memory/_templates/daily.md`
- `<repo>/memory/_templates/topic.md`

## Source Layout

- `templates/home/` - home-level bootstrap templates
- `templates/global/` - global memory templates
- `templates/project/` - project-local memory templates
- `scripts/install.sh` - installs global memory and home bootstrap
- `scripts/init-project.sh` - initializes project-local memory in a repo
- `scripts/check.sh` - verifies that the runtime structure is valid
- `scripts/export-memory.sh` - exports the installed memory structure from a machine
- `scripts/import-memory.sh` - imports an exported memory structure onto a machine

## Design Principles

- Runtime paths stay stable.
- Source templates stay machine-agnostic.
- Absolute paths are rendered only at install time.
- Installation should be idempotent.
- Verification should fail loudly on broken startup chains or missing required files.

## Template Variables

Templates may use the following placeholders:

- `{{HOME_DIR}}`
- `{{CODEX_DIR}}`
- `{{GLOBAL_MEMORY_DIR}}`
- `{{REPO_ROOT}}`
- `{{PROJECT_NAME}}`

## Installation

Install the global layer and home bootstrap:

```bash
./scripts/install.sh --home "$HOME"
```

Initialize a repository with project-local memory:

```bash
./scripts/init-project.sh --repo /path/to/repo --project-name my-project
```

Verify the resulting structure:

```bash
./scripts/check.sh --home "$HOME" --repo /path/to/repo
```

## Modes

`install.sh` supports:

- normal install
- dry-run
- force overwrite when explicitly requested

`check.sh` supports:

- global-only checks
- project-only checks
- combined checks

## Safety Rules

- Do not overwrite existing files unless `--force` is passed.
- Do not create project-local files outside the target repo.
- Do not silently skip required files.
- Do not rewrite user-authored memory files during verification.

## Expected Workflow

1. Install global memory and home bootstrap once per machine.
2. Initialize project-local memory once per repository.
3. Run checks after installation or after template changes.
4. Keep accumulated daily/topic notes under normal project version control, not inside the kit.

## Non-Goals

- This kit is not a backup system by itself.
- This kit does not sync live memory files across machines.
- This kit does not replace project git history.

## Implementation Notes

### Template Rendering

- Templates should remain machine-agnostic in source form.
- Runtime files may contain absolute paths, but only after rendering on the target machine.
- Placeholder replacement should be explicit and limited to the documented variables:
  - `{{HOME_DIR}}`
  - `{{CODEX_DIR}}`
  - `{{GLOBAL_MEMORY_DIR}}`
  - `{{REPO_ROOT}}`
  - `{{PROJECT_NAME}}`
- Rendering should fail if a template contains an unknown placeholder or if a required variable is missing.
- Rendering should not try to be a generic templating engine; simple deterministic placeholder substitution is preferred.

### Path Rules

- The runtime path contract is part of the architecture and should stay stable.
- `install.sh` is responsible only for home/global runtime paths.
- `init-project.sh` is responsible only for repo-local runtime paths.
- `check.sh` should validate the runtime structure, not the source template tree.
- No script should assume a fixed username such as `phoenix`; all rendered absolute paths must derive from the provided `--home` or `--repo`.

### Idempotency

- Re-running `install.sh` with the same arguments should produce the same runtime layout without duplicating content.
- Re-running `check.sh` should never modify files.
- Re-running `init-project.sh` without `--force` should skip existing target files and report them explicitly.
- Scripts should be safe to run multiple times during machine setup, migration, or repair.

### Overwrite Policy

- Existing files must not be overwritten by default.
- Overwrite should require an explicit `--force`.
- `--force` should apply only to files managed by the kit, not to arbitrary extra files in the same directories.
- If a target file exists and differs, the script should report one of:
  - `UNCHANGED`
  - `SKIP`
  - `OVERWRITE`
- `check.sh` must never rewrite files, even in strict mode.

### File Ownership Boundaries

- The kit owns only bootstrap and scaffolded files derived from its templates.
- Daily notes, topic files, article notes, and project-specific working content remain user/project-owned after creation.
- Verification may check for their presence when required by the architecture, but should not normalize or rewrite their contents.
- The kit should not delete files that it did not create.

### Validation Rules

- `check.sh` should validate both file existence and architecture coherence.
- In normal mode, validation should focus on required files and readable startup references.
- In `--strict` mode, validation should also detect:
  - broken startup-order references
  - missing linked files explicitly named in bootstrap files
  - placeholder text left unresolved in runtime files
  - obvious path mismatches between rendered files and the current machine layout
- Validation output should identify the failing file and the exact rule that failed.

### Logging and Output

- Scripts should print concise, deterministic status lines.
- Prefer action-oriented output such as:
  - `CREATE <path>`
  - `SKIP <path>`
  - `OVERWRITE <path>`
  - `CHECK OK <path>`
  - `CHECK FAIL <path>: <reason>`
- `--verbose` may print additional reasoning, but default output should stay short and scannable.
- `--dry-run` should print planned actions using the same status vocabulary, prefixed clearly as simulation.

### Failure Behavior

- Scripts should fail fast on invalid arguments.
- Scripts should fail before partial writes when a required source template is missing.
- If a multi-file install stops mid-run, the output should make it obvious which files were already written.
- `check.sh` should return non-zero on any failed required check.

### Portability Constraints

- Prefer POSIX shell behavior where practical.
- Avoid dependencies on Python, GNU-only tools, or external templating engines unless they are made an explicit prerequisite.
- If non-POSIX behavior is required, document it clearly in the prerequisites section.
- Home-relative semantics should be preserved even when the absolute home path changes across machines.

### Upgrade Policy

- Template changes should be forward-applicable through re-running the installer with `--force`.
- The kit should not silently migrate user-authored project memory content.
- If a template contract changes incompatibly, the README should describe the migration path explicitly.
- `check.sh --strict` should help detect stale runtime files after a kit upgrade.
