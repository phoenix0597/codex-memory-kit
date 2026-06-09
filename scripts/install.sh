#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF' >&2
Использование: install.sh --home <path> [--codex-dir <path>] [--global-memory-dir <path>] [--source-root <path>] [--force] [--dry-run] [--verbose] [--no-home-agents]
EOF
}

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
DEFAULT_SOURCE_ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)

HOME_DIR=
CODEX_DIR=
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
  printf '%s' "$1" | sed 's/[\\|&]/\\&/g'
}

to_posix_path() {
  printf '%s' "$1"
}

to_windows_path() {
  local path=$1
  local drive rest

  case "$path" in
    /[A-Za-z]/*)
      drive=$(printf '%s' "${path:1:1}" | tr '[:lower:]' '[:upper:]')
      rest=${path:2}
      rest=${rest//\//\\}
      printf '%s:%s' "$drive" "$rest"
      ;;
    /mnt/[A-Za-z]/*)
      drive=$(printf '%s' "${path:5:1}" | tr '[:lower:]' '[:upper:]')
      rest=${path:6}
      rest=${rest//\//\\}
      printf '%s:%s' "$drive" "$rest"
      ;;
    [A-Za-z]:/*)
      printf '%s' "${path//\//\\}"
      ;;
    *)
      printf '%s' "$path"
      ;;
  esac
}

render_template() {
  local src=$1
  local dst=$2
  local home_esc codex_esc global_esc
  local home_posix_esc codex_posix_esc global_posix_esc
  local home_windows_esc codex_windows_esc global_windows_esc

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
  home_posix_esc=$(escape_sed "$(to_posix_path "$HOME_DIR")")
  codex_posix_esc=$(escape_sed "$(to_posix_path "$CODEX_DIR")")
  global_posix_esc=$(escape_sed "$(to_posix_path "$GLOBAL_MEMORY_DIR")")
  home_windows_esc=$(escape_sed "$(to_windows_path "$HOME_DIR")")
  codex_windows_esc=$(escape_sed "$(to_windows_path "$CODEX_DIR")")
  global_windows_esc=$(escape_sed "$(to_windows_path "$GLOBAL_MEMORY_DIR")")

  local rendered
  rendered=$(sed \
    -e "s|{{HOME_DIR}}|$home_esc|g" \
    -e "s|{{CODEX_DIR}}|$codex_esc|g" \
    -e "s|{{GLOBAL_MEMORY_DIR}}|$global_esc|g" \
    -e "s|{{HOME_DIR_POSIX}}|$home_posix_esc|g" \
    -e "s|{{CODEX_DIR_POSIX}}|$codex_posix_esc|g" \
    -e "s|{{GLOBAL_MEMORY_DIR_POSIX}}|$global_posix_esc|g" \
    -e "s|{{HOME_DIR_WINDOWS}}|$home_windows_esc|g" \
    -e "s|{{CODEX_DIR_WINDOWS}}|$codex_windows_esc|g" \
    -e "s|{{GLOBAL_MEMORY_DIR_WINDOWS}}|$global_windows_esc|g" \
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
