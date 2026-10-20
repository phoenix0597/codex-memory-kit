#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF' >&2
Использование: install.sh --home <path> [--agent <codex|dsh|antigravity|all|none>] [--dsh-dir <path>] [--codex-dir <path>] [--global-memory-dir <path>] [--source-root <path>] [--force] [--dry-run] [--verbose] [--no-home-agents]
EOF
}

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
DEFAULT_SOURCE_ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)

HOME_DIR=
CODEX_DIR=
DSH_DIR=
AGENT=codex
GLOBAL_MEMORY_DIR=
SOURCE_ROOT=$DEFAULT_SOURCE_ROOT
FORCE=0
DRY_RUN=0
VERBOSE=0
INSTALL_HOME_AGENTS=1

while [ "$#" -gt 0 ]; do
  case "$1" in
    --home)
      HOME_DIR=${2:-}
      shift 2
      ;;
    --dsh-dir)
      DSH_DIR=${2:-}
      shift 2
      ;;
    --agent)
      AGENT=${2:-}
      shift 2
      ;;
    --codex-dir)
      CODEX_DIR=${2:-}
      shift 2
      ;;
    --global-memory-dir)
      GLOBAL_MEMORY_DIR=${2:-}
      shift 2
      ;;
    --source-root)
      SOURCE_ROOT=${2:-}
      shift 2
      ;;
    --force)
      FORCE=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --verbose)
      VERBOSE=1
      shift
      ;;
    --no-home-agents)
      INSTALL_HOME_AGENTS=0
      shift
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

if [ -z "${HOME_DIR}" ]; then
  usage
  exit 2
fi

. "$SCRIPT_DIR/lib-memory.sh"
resolve_memory_paths

log() {
  if [ "$VERBOSE" -eq 1 ]; then
    printf '%s\n' "$*"
  fi
}

status() {
  if [ "$DRY_RUN" -eq 1 ]; then
    printf 'DRY-RUN %s\n' "$*"
  else
    printf '%s\n' "$*"
  fi
}

log "Корень исходного набора: $SOURCE_ROOT"
log "Глобальная память: $GLOBAL_MEMORY_DIR"

if [ "$DRY_RUN" -eq 0 ]; then
  mkdir -p "$GLOBAL_MEMORY_DIR"
fi

render_template "$SOURCE_ROOT/templates/global/global-collaboration-rules.md" \
  "$GLOBAL_MEMORY_DIR/global-collaboration-rules.md"
render_template "$SOURCE_ROOT/templates/global/memory-architecture.md" \
  "$GLOBAL_MEMORY_DIR/memory-architecture.md"

if [ "$INSTALL_HOME_AGENTS" -eq 1 ]; then
  render_template "$SOURCE_ROOT/templates/home/AGENTS.md.template" "$HOME_DIR/AGENTS.md"
fi

while IFS= read -r entrypoint; do
  [ -n "$entrypoint" ] || continue
  render_template "$SOURCE_ROOT/templates/agent/AGENTS.md.template" "$entrypoint"
done < <(agent_entrypoints)
