#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF' >&2
Использование: init-project.sh --repo <path> [--project-name <name>] [--home <path>] [--codex-dir <path>] [--global-memory-dir <path>] [--source-root <path>] [--force] [--dry-run] [--verbose]
EOF
}

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
DEFAULT_SOURCE_ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)

REPO_ROOT=
PROJECT_NAME=
HOME_DIR=${HOME:-}
CODEX_DIR=
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

if [ -z "${REPO_ROOT}" ]; then
  usage
  exit 2
fi

if [ "${REPO_ROOT#/}" = "$REPO_ROOT" ]; then
  printf 'Укажите абсолютный путь к репозиторию.\n' >&2
  exit 2
fi

if [ ! -d "$REPO_ROOT" ]; then
  printf 'Каталог репозитория не найден: %s\n' "$REPO_ROOT" >&2
  exit 1
fi

PROJECT_NAME=${PROJECT_NAME:-$(basename "$REPO_ROOT")}
CODEX_DIR=${CODEX_DIR:-"$HOME_DIR/.codex"}
GLOBAL_MEMORY_DIR=${GLOBAL_MEMORY_DIR:-"$CODEX_DIR/memories"}

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

escape_sed() {
  printf '%s' "$1" | sed 's/[|&]/\\&/g'
}

render_template() {
  local src=$1
  local dst=$2
  local home_esc codex_esc global_esc repo_esc project_esc

  if [ ! -f "$src" ]; then
    printf 'Отсутствует шаблон: %s\n' "$src" >&2
    exit 1
  fi

  if [ -e "$dst" ] && [ "$FORCE" -ne 1 ]; then
    status "SKIP $dst"
    return
  fi

  home_esc=$(escape_sed "$HOME_DIR")
  codex_esc=$(escape_sed "$CODEX_DIR")
  global_esc=$(escape_sed "$GLOBAL_MEMORY_DIR")
  repo_esc=$(escape_sed "$REPO_ROOT")
  project_esc=$(escape_sed "$PROJECT_NAME")

  local rendered
  rendered=$(sed \
    -e "s|{{HOME_DIR}}|$home_esc|g" \
    -e "s|{{CODEX_DIR}}|$codex_esc|g" \
    -e "s|{{GLOBAL_MEMORY_DIR}}|$global_esc|g" \
    -e "s|{{REPO_ROOT}}|$repo_esc|g" \
    -e "s|{{PROJECT_NAME}}|$project_esc|g" \
    "$src")

  if printf '%s' "$rendered" | grep -Eq '{{[A-Z_][A-Z0-9_]*}}'; then
    printf 'После рендера остались незаполненные плейсхолдеры: %s\n' "$src" >&2
    exit 1
  fi

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
render_template "$SOURCE_ROOT/templates/project/memory/current-work-queue.md.template" \
  "$REPO_ROOT/memory/current-work-queue.md"
render_template "$SOURCE_ROOT/templates/project/memory/_templates/daily.md.template" \
  "$REPO_ROOT/memory/_templates/daily.md"
render_template "$SOURCE_ROOT/templates/project/memory/_templates/topic.md.template" \
  "$REPO_ROOT/memory/_templates/topic.md"
render_daily_file "$SOURCE_ROOT/templates/project/memory/_templates/daily.md.template" \
  "$REPO_ROOT/memory/$TODAY.md"
