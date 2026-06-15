#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF' >&2
Использование: check.sh --home <path> [--repo <path>] [--codex-dir <path>] [--global-memory-dir <path>] [--mode <global|project|all>] [--strict] [--verbose]
EOF
}

HOME_DIR=
REPO_ROOT=
CODEX_DIR=
GLOBAL_MEMORY_DIR=
MODE=all
STRICT=0
VERBOSE=0
FAILURES=0

while [ "$#" -gt 0 ]; do
  case "$1" in
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
    --mode)
      MODE=${2:-}
      shift 2
      ;;
    --strict)
      STRICT=1
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

if [ "$MODE" != "global" ] && [ "$MODE" != "project" ] && [ "$MODE" != "all" ]; then
  usage
  exit 2
fi

if [ "$MODE" = "global" ] || [ "$MODE" = "all" ]; then
  if [ -z "$HOME_DIR" ]; then
    usage
    exit 2
  fi
fi

if [ "$MODE" = "project" ] || [ "$MODE" = "all" ]; then
  if [ -z "$REPO_ROOT" ]; then
    usage
    exit 2
  fi
fi

CODEX_DIR=${CODEX_DIR:-"$HOME_DIR/.codex"}
GLOBAL_MEMORY_DIR=${GLOBAL_MEMORY_DIR:-"$CODEX_DIR/memories"}

check_ok() {
  printf 'CHECK OK %s\n' "$1"
}

check_fail() {
  printf 'CHECK FAIL %s: %s\n' "$1" "$2" >&2
  FAILURES=$((FAILURES + 1))
}

log() {
  if [ "$VERBOSE" -eq 1 ]; then
    printf '%s\n' "$*"
  fi
}

require_file() {
  local path=$1
  if [ -f "$path" ]; then
    check_ok "$path"
  else
    check_fail "$path" "обязательный файл отсутствует"
  fi
}

require_contains() {
  local path=$1
  local needle=$2
  local reason=$3
  if [ ! -f "$path" ]; then
    check_fail "$path" "обязательный файл отсутствует"
    return
  fi
  if grep -Fq "$needle" "$path"; then
    check_ok "$path"
  else
    check_fail "$path" "$reason"
  fi
}

require_no_placeholders() {
  local path=$1
  if [ ! -f "$path" ]; then
    check_fail "$path" "обязательный файл отсутствует"
    return
  fi
  if grep -Eq '{{[A-Z_][A-Z0-9_]*}}|__PROJECT_ROOT__|__PROJECT_NAME__' "$path"; then
    check_fail "$path" "содержит незаполненные плейсхолдеры"
  else
    check_ok "$path"
  fi
}

check_global() {
  log "Проверка глобальных файлов: $GLOBAL_MEMORY_DIR"
  require_file "$GLOBAL_MEMORY_DIR/global-collaboration-rules.md"
  require_file "$GLOBAL_MEMORY_DIR/memory-architecture.md"
  require_file "$HOME_DIR/AGENTS.md"

  if [ "$STRICT" -eq 1 ]; then
    require_contains "$HOME_DIR/AGENTS.md" \
      "global-collaboration-rules.md" \
      "нет ссылки на глобальные правила сотрудничества"
    require_contains "$HOME_DIR/AGENTS.md" \
      "memory-architecture.md" \
      "нет ссылки на глобальную архитектуру памяти"
    require_no_placeholders "$GLOBAL_MEMORY_DIR/global-collaboration-rules.md"
    require_no_placeholders "$GLOBAL_MEMORY_DIR/memory-architecture.md"
    require_no_placeholders "$HOME_DIR/AGENTS.md"
  fi
}

check_project() {
  log "Проверка проектных файлов: $REPO_ROOT"
  require_file "$REPO_ROOT/AGENTS.md"
  require_file "$REPO_ROOT/START-HERE.md"
  require_file "$REPO_ROOT/assistant-memory.md"
  require_file "$REPO_ROOT/memory/current-work-queue.md"
  require_file "$REPO_ROOT/memory/_templates/daily.md"
  require_file "$REPO_ROOT/memory/_templates/topic.md"

  if [ "$STRICT" -eq 1 ]; then
    require_contains "$REPO_ROOT/AGENTS.md" \
      "global-collaboration-rules.md" \
      "нет ссылки на глобальные правила сотрудничества"
    require_contains "$REPO_ROOT/AGENTS.md" \
      "memory/current-work-queue.md" \
      "нет ссылки на текущую очередь работы"
    require_contains "$REPO_ROOT/START-HERE.md" \
      "assistant-memory.md" \
      "нет ссылки на assistant-memory.md"
    require_contains "$REPO_ROOT/assistant-memory.md" \
      "memory-architecture.md" \
      "нет ссылки на глобальную архитектуру памяти"
    require_no_placeholders "$REPO_ROOT/AGENTS.md"
    require_no_placeholders "$REPO_ROOT/START-HERE.md"
    require_no_placeholders "$REPO_ROOT/assistant-memory.md"
  fi
}

if [ "$MODE" = "global" ] || [ "$MODE" = "all" ]; then
  check_global
fi

if [ "$MODE" = "project" ] || [ "$MODE" = "all" ]; then
  check_project
fi

if [ "$FAILURES" -gt 0 ]; then
  if [ "$STRICT" -eq 1 ]; then
    exit 3
  fi
  exit 1
fi
