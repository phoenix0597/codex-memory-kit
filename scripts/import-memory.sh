#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF' >&2
Usage: import-memory.sh --input-dir <path> --home <path> [--repo <path>] [--codex-dir <path>] [--global-memory-dir <path>] [--force] [--verbose]
EOF
}

INPUT_DIR=
HOME_DIR=
REPO_ROOT=
CODEX_DIR=
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

CODEX_DIR=${CODEX_DIR:-"$HOME_DIR/.codex"}
GLOBAL_MEMORY_DIR=${GLOBAL_MEMORY_DIR:-"$CODEX_DIR/memories"}

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
  rm -rf "$dst"
  cp -R "$src" "$dst"
  if [ "$FORCE" -eq 1 ] && [ -e "$dst" ]; then
    printf 'OVERWRITE %s\n' "$dst"
  else
    printf 'IMPORT %s\n' "$dst"
  fi
}

log "Importing memory from $INPUT_DIR"
mkdir -p "$GLOBAL_MEMORY_DIR"

copy_file "$INPUT_DIR/global/.codex/memories/global-collaboration-rules.md" \
  "$GLOBAL_MEMORY_DIR/global-collaboration-rules.md"
copy_file "$INPUT_DIR/global/.codex/memories/memory-architecture.md" \
  "$GLOBAL_MEMORY_DIR/memory-architecture.md"
copy_file "$INPUT_DIR/global/AGENTS.md" "$HOME_DIR/AGENTS.md"

if [ -n "$REPO_ROOT" ]; then
  mkdir -p "$REPO_ROOT"
  copy_file "$INPUT_DIR/project/AGENTS.md" "$REPO_ROOT/AGENTS.md"
  copy_file "$INPUT_DIR/project/START-HERE.md" "$REPO_ROOT/START-HERE.md"
  copy_file "$INPUT_DIR/project/assistant-memory.md" "$REPO_ROOT/assistant-memory.md"
  copy_file "$INPUT_DIR/project/technical-specification-mvp.md" \
    "$REPO_ROOT/technical-specification-mvp.md"
  copy_file "$INPUT_DIR/project/article-notes.md" "$REPO_ROOT/article-notes.md"
  copy_tree "$INPUT_DIR/project/memory" "$REPO_ROOT/memory"
fi
