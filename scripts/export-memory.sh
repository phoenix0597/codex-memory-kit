#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF' >&2
Usage: export-memory.sh --home <path> --output-dir <path> [--repo <path>] [--codex-dir <path>] [--global-memory-dir <path>] [--force] [--verbose]
EOF
}

HOME_DIR=
OUTPUT_DIR=
REPO_ROOT=
CODEX_DIR=
GLOBAL_MEMORY_DIR=
FORCE=0
VERBOSE=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --home)
      HOME_DIR=${2:-}
      shift 2
      ;;
    --output-dir)
      OUTPUT_DIR=${2:-}
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

if [ -z "$HOME_DIR" ] || [ -z "$OUTPUT_DIR" ]; then
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
    printf 'Missing source file: %s\n' "$src" >&2
    exit 1
  fi
  if [ -e "$dst" ] && [ "$FORCE" -ne 1 ]; then
    printf 'SKIP %s\n' "$dst"
    return
  fi
  mkdir -p "$(dirname "$dst")"
  cp "$src" "$dst"
  printf 'EXPORT %s\n' "$dst"
}

copy_tree() {
  local src=$1
  local dst=$2
  if [ ! -d "$src" ]; then
    printf 'Missing source directory: %s\n' "$src" >&2
    exit 1
  fi
  if [ -e "$dst" ] && [ "$FORCE" -ne 1 ]; then
    printf 'SKIP %s\n' "$dst"
    return
  fi
  mkdir -p "$(dirname "$dst")"
  rm -rf "$dst"
  cp -R "$src" "$dst"
  printf 'EXPORT %s\n' "$dst"
}

log "Exporting memory to $OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"

copy_file "$GLOBAL_MEMORY_DIR/global-collaboration-rules.md" \
  "$OUTPUT_DIR/global/.codex/memories/global-collaboration-rules.md"
copy_file "$GLOBAL_MEMORY_DIR/memory-architecture.md" \
  "$OUTPUT_DIR/global/.codex/memories/memory-architecture.md"
copy_file "$HOME_DIR/AGENTS.md" "$OUTPUT_DIR/global/AGENTS.md"

if [ -n "$REPO_ROOT" ]; then
  copy_file "$REPO_ROOT/AGENTS.md" "$OUTPUT_DIR/project/AGENTS.md"
  copy_file "$REPO_ROOT/START-HERE.md" "$OUTPUT_DIR/project/START-HERE.md"
  copy_file "$REPO_ROOT/assistant-memory.md" "$OUTPUT_DIR/project/assistant-memory.md"
  if [ -f "$REPO_ROOT/technical-specification-mvp.md" ]; then
    copy_file "$REPO_ROOT/technical-specification-mvp.md" \
      "$OUTPUT_DIR/project/technical-specification-mvp.md"
  fi
  if [ -f "$REPO_ROOT/article-notes.md" ]; then
    copy_file "$REPO_ROOT/article-notes.md" "$OUTPUT_DIR/project/article-notes.md"
  fi
  copy_tree "$REPO_ROOT/memory" "$OUTPUT_DIR/project/memory"
fi
