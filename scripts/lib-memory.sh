#!/usr/bin/env bash
# Shared path and template contract for the Bash entry points.

resolve_memory_paths() {
  while [ "$HOME_DIR" != / ] && [ "${HOME_DIR%/}" != "$HOME_DIR" ]; do HOME_DIR=${HOME_DIR%/}; done
  local explicit_codex=${CODEX_DIR:-}
  CODEX_DIR=${CODEX_DIR:-"$HOME_DIR/.codex"}
  DSH_DIR=${DSH_DIR:-"$HOME_DIR/.dsh"}
  while [ "$CODEX_DIR" != / ] && [ "${CODEX_DIR%/}" != "$CODEX_DIR" ]; do CODEX_DIR=${CODEX_DIR%/}; done
  AGENT=${AGENT:-codex}
  case "$AGENT" in
    codex|dsh|antigravity|all|none) ;;
    *) printf 'Unknown agent: %s\n' "$AGENT" >&2; exit 2 ;;
  esac

  if [ -z "${GLOBAL_MEMORY_DIR:-}" ]; then
    if [ -n "$explicit_codex" ]; then
      # Keep the historical --codex-dir default for existing callers.
      GLOBAL_MEMORY_DIR="$CODEX_DIR/memories"
    elif [ -d "$HOME_DIR/.agents/memories" ] && [ -d "$CODEX_DIR/memories" ]; then
      printf 'Both shared and legacy memory exist; select --global-memory-dir explicitly.\n' >&2
      exit 2
    elif [ -d "$CODEX_DIR/memories" ]; then
      GLOBAL_MEMORY_DIR="$CODEX_DIR/memories"
    else
      GLOBAL_MEMORY_DIR="$HOME_DIR/.agents/memories"
    fi
  fi

  local key value
  for key in HOME_DIR CODEX_DIR DSH_DIR GLOBAL_MEMORY_DIR; do
    value=${!key}
    case "$value" in
      /*) ;;
      *) printf 'Expected an absolute POSIX path for %s: %s\n' "$key" "$value" >&2; exit 2 ;;
    esac
    while [ "$value" != / ] && [ "${value%/}" != "$value" ]; do value=${value%/}; done
    printf -v "$key" '%s' "$value"
  done
  if [ -n "${SOURCE_ROOT:-}" ]; then
    SOURCE_ROOT=$(CDPATH='' cd -- "$SOURCE_ROOT" && pwd)
  fi
}

agent_entrypoints() {
  case "$AGENT" in
    codex) printf '%s\n' "$CODEX_DIR/AGENTS.md" ;;
    dsh) printf '%s\n' "$DSH_DIR/AGENTS.md" ;;
    all) printf '%s\n' "$CODEX_DIR/AGENTS.md" "$DSH_DIR/AGENTS.md" ;;
  esac
}

to_posix_path() { printf '%s' "$1"; }

to_windows_path() {
  local path=$1 drive rest
  case "$path" in
    /[A-Za-z]/*)
      drive=$(printf '%s' "${path:1:1}" | tr '[:lower:]' '[:upper:]')
      rest=${path:2}
      printf '%s:%s' "$drive" "${rest//\//\\}"
      ;;
    /mnt/[A-Za-z]/*)
      drive=$(printf '%s' "${path:5:1}" | tr '[:lower:]' '[:upper:]')
      rest=${path:6}
      printf '%s:%s' "$drive" "${rest//\//\\}"
      ;;
    [A-Za-z]:/*) printf '%s' "${path//\//\\}" ;;
    *) printf '%s' "$path" ;;
  esac
}

escape_sed() { printf '%s' "$1" | sed 's/[\\|&]/\\&/g'; }

TEMPLATE_SED_ARGS=()
TEMPLATE_SED_READY=0
prepare_template_substitutions() {
  local key value escaped
  KIT_ROOT=$SOURCE_ROOT
  for key in HOME_DIR CODEX_DIR DSH_DIR GLOBAL_MEMORY_DIR KIT_ROOT REPO_ROOT; do
    value=${!key:-}
    [ -n "$value" ] || continue
    escaped=$(escape_sed "$value")
    TEMPLATE_SED_ARGS+=(-e "s|{{$key}}|$escaped|g")
    TEMPLATE_SED_ARGS+=(-e "s|{{${key}_POSIX}}|$escaped|g")
    TEMPLATE_SED_ARGS+=(-e "s|{{${key}_WINDOWS}}|$(escape_sed "$(to_windows_path "$value")")|g")
  done
  if [ -n "${PROJECT_NAME:-}" ]; then
    TEMPLATE_SED_ARGS+=(-e "s|{{PROJECT_NAME}}|$(escape_sed "$PROJECT_NAME")|g")
  fi
  TEMPLATE_SED_READY=1
}

render_template() {
  local src=$1 dst=$2 rendered existed=0
  if [ ! -f "$src" ]; then
    printf 'Missing template: %s\n' "$src" >&2
    exit 1
  fi
  if [ -e "$dst" ]; then
    existed=1
    if [ "$FORCE" -ne 1 ]; then status "SKIP $dst"; return; fi
  fi
  if [ "$TEMPLATE_SED_READY" -eq 0 ]; then prepare_template_substitutions; fi
  rendered=$(sed "${TEMPLATE_SED_ARGS[@]}" "$src")
  if printf '%s' "$rendered" | grep -Eq '{{[A-Z_][A-Z0-9_]*}}'; then
    printf 'Unresolved template placeholder: %s\n' "$src" >&2
    exit 1
  fi
  if [ "$DRY_RUN" -eq 0 ]; then
    mkdir -p "$(dirname "$dst")"
    printf '%s\n' "$rendered" > "$dst"
  fi
  if [ "$existed" -eq 1 ]; then status "OVERWRITE $dst"; else status "CREATE $dst"; fi
}
