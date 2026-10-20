#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF' >&2
Использование: init-project.sh [--repo <path>] [--project-name <name>] [--home <path>] [--agent <codex|dsh|antigravity|all|none>] [--dsh-dir <path>] [--codex-dir <path>] [--global-memory-dir <path>] [--source-root <path>] [--force] [--dry-run] [--verbose]
EOF
}

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
DEFAULT_SOURCE_ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)

REPO_ROOT=
PROJECT_NAME=
HOME_DIR=${HOME:-}
CODEX_DIR=
DSH_DIR=
AGENT=codex
GLOBAL_MEMORY_DIR=
SOURCE_ROOT=$DEFAULT_SOURCE_ROOT
FORCE=0
DRY_RUN=0
VERBOSE=0
TODAY=$(date +%F)

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo)
      REPO_ROOT=${2:-}
      shift 2
      ;;
    --project-name)
      PROJECT_NAME=${2:-}
      shift 2
      ;;
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
    *)
      usage
      exit 2
      ;;
  esac
done

REPO_ROOT=${REPO_ROOT:-$(pwd)}

if [ "${REPO_ROOT#/}" = "$REPO_ROOT" ]; then
  printf 'Укажите абсолютный путь к репозиторию.\n' >&2
  exit 2
fi

if [ ! -d "$REPO_ROOT" ]; then
  printf 'Каталог репозитория не найден: %s\n' "$REPO_ROOT" >&2
  exit 1
fi

PROJECT_NAME=${PROJECT_NAME:-$(basename "$REPO_ROOT")}
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

render_daily_file() {
  local src=$1
  local dst=$2
  local rendered

  if [ ! -f "$src" ]; then
    printf 'Отсутствует шаблон: %s\n' "$src" >&2
    exit 1
  fi

  if [ -e "$dst" ] && [ "$FORCE" -ne 1 ]; then
    status "SKIP $dst"
    return
  fi

  rendered=$(sed "s|YYYY-MM-DD|$TODAY|g" "$src")

  if [ "$DRY_RUN" -eq 1 ]; then
    if [ -e "$dst" ]; then
      status "OVERWRITE $dst"
    else
      status "CREATE $dst"
    fi
    return
  fi

  mkdir -p "$(dirname "$dst")"
  printf '%s' "$rendered" > "$dst"

  if [ -e "$dst" ] && [ "$FORCE" -eq 1 ]; then
    status "OVERWRITE $dst"
  else
    status "CREATE $dst"
  fi
}

log "Корень исходного набора: $SOURCE_ROOT"
log "Проектная память: $REPO_ROOT"

if [ "$DRY_RUN" -eq 0 ]; then
  mkdir -p "$REPO_ROOT/memory/_templates"
fi

render_template "$SOURCE_ROOT/templates/project/AGENTS.md.template" "$REPO_ROOT/AGENTS.md"
render_template "$SOURCE_ROOT/templates/project/START-HERE.md.template" "$REPO_ROOT/START-HERE.md"
render_template "$SOURCE_ROOT/templates/project/assistant-memory.md.template" "$REPO_ROOT/assistant-memory.md"
if [ "$AGENT" = antigravity ] || [ "$AGENT" = all ]; then
  render_template "$SOURCE_ROOT/templates/project/.gemini/rules/antigravity-memory-adapter.md.template" "$REPO_ROOT/.gemini/rules/antigravity-memory-adapter.md"
fi

render_template "$SOURCE_ROOT/templates/project/memory/current-work-queue.md.template" \
  "$REPO_ROOT/memory/current-work-queue.md"
render_template "$SOURCE_ROOT/templates/project/memory/topic-memory-improvement.md.template" \
  "$REPO_ROOT/memory/topic-memory-improvement.md"
render_template "$SOURCE_ROOT/templates/project/memory/_templates/daily.md.template" \
  "$REPO_ROOT/memory/_templates/daily.md"
render_template "$SOURCE_ROOT/templates/project/memory/_templates/topic.md.template" \
  "$REPO_ROOT/memory/_templates/topic.md"
render_daily_file "$SOURCE_ROOT/templates/project/memory/_templates/daily.md.template" \
  "$REPO_ROOT/memory/$TODAY.md"
