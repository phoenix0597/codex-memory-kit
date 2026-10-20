#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

usage() {
  cat <<'EOF' >&2
Использование: check.sh [--home <path>] [--repo <path>] [--agent <codex|dsh|antigravity|all|none>] [--dsh-dir <path>] [--codex-dir <path>] [--global-memory-dir <path>] [--mode <global|project|all>] [--no-home-agents] [--strict] [--verbose]
EOF
}

HOME_DIR=${HOME:-}
REPO_ROOT=
CODEX_DIR=
DSH_DIR=
AGENT=codex
GLOBAL_MEMORY_DIR=
MODE=all
STRICT=0
VERBOSE=0
FAILURES=0
INSTALL_HOME_AGENTS=1

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
    --mode)
      MODE=${2:-}
      shift 2
      ;;
    --no-home-agents)
      INSTALL_HOME_AGENTS=0
      shift
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
  REPO_ROOT=${REPO_ROOT:-$(pwd)}
fi

. "$SCRIPT_DIR/lib-memory.sh"
resolve_memory_paths

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

require_memory_link() {
  local path=$1 filename=$2 relative
  if [ ! -f "$path" ]; then
    check_fail "$path" "обязательный файл отсутствует"
    return
  fi
  if grep -Fq -- "\`$GLOBAL_MEMORY_DIR/$filename\`" "$path"; then
    check_ok "$path"
    return
  fi
  case "$GLOBAL_MEMORY_DIR" in
    "$HOME_DIR"/*)
      relative=${GLOBAL_MEMORY_DIR#"$HOME_DIR/"}/$filename
      if grep -Fq -- "\`$relative\`" "$path" || grep -Fq -- "\`\$HOME/$relative\`" "$path"; then
        check_ok "$path"
        return
      fi
      ;;
  esac
  check_fail "$path" "нет ссылки на выбранную общую память: $filename"
}

check_global() {
  log "Проверка глобальных файлов: $GLOBAL_MEMORY_DIR"
  require_file "$GLOBAL_MEMORY_DIR/global-collaboration-rules.md"
  require_file "$GLOBAL_MEMORY_DIR/memory-architecture.md"
  if { [ "$AGENT" = codex ] || [ "$AGENT" = all ]; } && [ -s "$CODEX_DIR/AGENTS.override.md" ]; then
    check_fail "$CODEX_DIR/AGENTS.override.md" "override скрывает стартовый файл Codex; проверь его содержимое"
  fi
  if [ "$STRICT" -eq 1 ]; then
    require_no_placeholders "$GLOBAL_MEMORY_DIR/global-collaboration-rules.md"
    require_no_placeholders "$GLOBAL_MEMORY_DIR/memory-architecture.md"
  fi
  local entrypoint
  while IFS= read -r entrypoint; do
    [ -n "$entrypoint" ] || continue
    require_file "$entrypoint"
    if [ "$STRICT" -eq 1 ]; then
      require_memory_link "$entrypoint" global-collaboration-rules.md
      require_memory_link "$entrypoint" memory-architecture.md
      require_no_placeholders "$entrypoint"
    fi
  done < <(
    if [ "$INSTALL_HOME_AGENTS" -eq 1 ]; then printf '%s\n' "$HOME_DIR/AGENTS.md"; fi
    agent_entrypoints
  )
}

check_project() {
  log "Проверка проектных файлов: $REPO_ROOT"
  require_file "$REPO_ROOT/AGENTS.md"
  require_file "$REPO_ROOT/START-HERE.md"
  require_file "$REPO_ROOT/assistant-memory.md"
  require_file "$REPO_ROOT/memory/current-work-queue.md"
  require_file "$REPO_ROOT/memory/topic-memory-improvement.md"
  require_file "$REPO_ROOT/memory/_templates/daily.md"
  require_file "$REPO_ROOT/memory/_templates/topic.md"

  if [ "$AGENT" = antigravity ] || [ "$AGENT" = all ]; then
    require_file "$REPO_ROOT/.gemini/rules/antigravity-memory-adapter.md"
    if [ "$STRICT" -eq 1 ]; then
      require_no_placeholders "$REPO_ROOT/.gemini/rules/antigravity-memory-adapter.md"
      require_memory_link "$REPO_ROOT/.gemini/rules/antigravity-memory-adapter.md" global-collaboration-rules.md
    fi
  fi

  if [ "$STRICT" -eq 1 ]; then
    local file
    for file in AGENTS.md START-HERE.md assistant-memory.md; do
      require_memory_link "$REPO_ROOT/$file" global-collaboration-rules.md
      require_memory_link "$REPO_ROOT/$file" memory-architecture.md
    done
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
