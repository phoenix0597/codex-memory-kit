#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

usage() {
  cat <<'EOF' >&2
Использование: import-memory.sh --input-dir <path> --home <path> [--repo <path>] [--agent <codex|dsh|antigravity|all|none>] [--dsh-dir <path>] [--codex-dir <path>] [--global-memory-dir <path>] [--force] [--verbose]
EOF
}

INPUT_DIR=
HOME_DIR=
REPO_ROOT=
CODEX_DIR=
DSH_DIR=
AGENT=codex
GLOBAL_MEMORY_DIR=
FORCE=0
VERBOSE=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --input-dir)
      INPUT_DIR=${2:-}
      shift 2
      ;;
    --home)
      HOME_DIR=${2:-}
      shift 2
      ;;
    --repo)
      REPO_ROOT=${2:-}
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
    --force)
      FORCE=1
      shift
      ;;
    --verbose)
      VERBOSE=1
      shift
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

if [ -z "$INPUT_DIR" ] || [ -z "$HOME_DIR" ]; then
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

copy_file() {
  local src=$1
  local dst=$2
  if [ ! -f "$src" ]; then
    return
  fi
  if [ -e "$dst" ] && [ "$FORCE" -ne 1 ]; then
    printf 'SKIP %s\n' "$dst"
    return
  fi
  mkdir -p "$(dirname "$dst")"
  cp "$src" "$dst"
  if [ "$FORCE" -eq 1 ] && [ -e "$dst" ]; then
    printf 'OVERWRITE %s\n' "$dst"
  else
    printf 'IMPORT %s\n' "$dst"
  fi
}

copy_tree() {
  local src=$1
  local dst=$2
  if [ ! -d "$src" ]; then
    return
  fi
  if [ -e "$dst" ] && [ "$FORCE" -ne 1 ]; then
    printf 'SKIP %s\n' "$dst"
    return
  fi
  mkdir -p "$(dirname "$dst")"
  mkdir -p "$dst"
  cp -R "$src/." "$dst"
  if [ "$FORCE" -eq 1 ] && [ -e "$dst" ]; then
    printf 'OVERWRITE %s\n' "$dst"
  else
    printf 'IMPORT %s\n' "$dst"
  fi
}

log "Импорт памяти: $INPUT_DIR"

ARCHIVE_MEMORY_DIR="$INPUT_DIR/global/memories"
if [ ! -d "$ARCHIVE_MEMORY_DIR" ]; then
  ARCHIVE_MEMORY_DIR="$INPUT_DIR/global/.codex/memories"
fi
if [ ! -f "$ARCHIVE_MEMORY_DIR/global-collaboration-rules.md" ] || [ ! -f "$ARCHIVE_MEMORY_DIR/memory-architecture.md" ]; then
  printf 'Incomplete global memory archive: %s\n' "$INPUT_DIR" >&2
  exit 2
fi
copy_file "$ARCHIVE_MEMORY_DIR/global-collaboration-rules.md" \
  "$GLOBAL_MEMORY_DIR/global-collaboration-rules.md"
copy_file "$ARCHIVE_MEMORY_DIR/memory-architecture.md" \
  "$GLOBAL_MEMORY_DIR/memory-architecture.md"
copy_file "$INPUT_DIR/global/AGENTS.md" "$HOME_DIR/AGENTS.md"
if [ "$AGENT" = codex ] || [ "$AGENT" = all ]; then
  copy_file "$INPUT_DIR/global/agents/codex/AGENTS.md" "$CODEX_DIR/AGENTS.md"
fi
if [ "$AGENT" = dsh ] || [ "$AGENT" = all ]; then
  copy_file "$INPUT_DIR/global/agents/dsh/AGENTS.md" "$DSH_DIR/AGENTS.md"
fi

if [ -n "$REPO_ROOT" ]; then
  mkdir -p "$REPO_ROOT"
  copy_file "$INPUT_DIR/project/AGENTS.md" "$REPO_ROOT/AGENTS.md"
  copy_file "$INPUT_DIR/project/START-HERE.md" "$REPO_ROOT/START-HERE.md"
  copy_file "$INPUT_DIR/project/assistant-memory.md" "$REPO_ROOT/assistant-memory.md"
  copy_file "$INPUT_DIR/project/technical-specification-mvp.md" \
    "$REPO_ROOT/technical-specification-mvp.md"
  copy_file "$INPUT_DIR/project/article-notes.md" "$REPO_ROOT/article-notes.md"
  copy_tree "$INPUT_DIR/project/memory" "$REPO_ROOT/memory"
  if [ "$AGENT" = antigravity ] || [ "$AGENT" = all ]; then
    copy_file "$INPUT_DIR/project/.gemini/rules/antigravity-memory-adapter.md" \
      "$REPO_ROOT/.gemini/rules/antigravity-memory-adapter.md"
  fi
fi
