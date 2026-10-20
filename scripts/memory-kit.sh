#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
RUNTIME_ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)
. "$SCRIPT_DIR/lib-memory.sh"

usage() {
  cat <<'EOF'
Usage: memory-kit.sh <install|init-project|check|export|import> [options]
  --agent codex|dsh|mimocode|zcode|antigravity|all|none
  --home PATH --repo PATH --project-name NAME --global-memory-dir PATH
  --codex-dir PATH --dsh-dir PATH --mimocode-config-dir PATH
  --zcode-dir PATH --antigravity-dir PATH --source-root PATH
  --input-dir PATH --output-dir PATH --mode global|project|all
  --strict --force --update-adapters --dry-run --verbose --no-home-agents
EOF
}

COMMAND=${1:-}; [ "$#" -eq 0 ] || shift
case "$COMMAND" in install|init-project|check|export|import) ;; --help|-h) usage; exit 0 ;; '') usage; exit 2 ;; *) fail "Unknown command: $COMMAND" ;; esac
HOME_DIR=${HOME:-${USERPROFILE:-}}; HOME_EXPLICIT=0
# Save the native process override before initializing CLI argument variables.
NATIVE_MIMO_CONFIG=${MIMOCODE_CONFIG_DIR:-}
CODEX_DIR=; DSH_DIR=; MIMOCODE_CONFIG_DIR=; ZCODE_DIR=; ANTIGRAVITY_DIR=
AGENT=codex; GLOBAL_MEMORY_DIR=; SOURCE_ROOT=$RUNTIME_ROOT; REPO_ROOT=; PROJECT_NAME=
INPUT_DIR=; OUTPUT_DIR=; MODE=all; STRICT=0; FORCE=0; UPDATE_ADAPTERS=0; DRY_RUN=0; VERBOSE=0; INSTALL_HOME_AGENTS=1
TODAY=$(date +%F); BEGIN='<!-- memory-kit:begin -->'; END='<!-- memory-kit:end -->'
PLAN_TYPES=(); PLAN_SOURCES=(); PLAN_DESTINATIONS=(); PLAN_CONTENTS=(); PLAN_VERBS=()
ACTIVE_TEMP=
trap 'if [ -n "$ACTIVE_TEMP" ]; then rm -f -- "$ACTIVE_TEMP"; fi' EXIT
while [ "$#" -gt 0 ]; do
  flag=$1; shift
  case "$flag" in
    --strict) STRICT=1 ;; --force) FORCE=1 ;; --update-adapters) UPDATE_ADAPTERS=1 ;; --dry-run) DRY_RUN=1 ;; --verbose) VERBOSE=1 ;; --no-home-agents) INSTALL_HOME_AGENTS=0 ;;
    --help|-h) usage; exit 0 ;;
    --home|--repo|--project-name|--codex-dir|--dsh-dir|--mimocode-config-dir|--zcode-dir|--antigravity-dir|--global-memory-dir|--source-root|--input-dir|--output-dir|--mode|--agent)
      [ "$#" -gt 0 ] && [ -n "$1" ] || fail "Missing value for $flag"
      case "$1" in --*) fail "Missing value for $flag" ;; esac
      value=$1; shift
      case "$flag" in
        --home) HOME_DIR=$value; HOME_EXPLICIT=1 ;; --repo) REPO_ROOT=$value ;; --project-name) PROJECT_NAME=$value ;;
        --codex-dir) CODEX_DIR=$value ;; --dsh-dir) DSH_DIR=$value ;; --mimocode-config-dir) MIMOCODE_CONFIG_DIR=$value ;;
        --zcode-dir) ZCODE_DIR=$value ;; --antigravity-dir) ANTIGRAVITY_DIR=$value ;; --global-memory-dir) GLOBAL_MEMORY_DIR=$value ;;
        --source-root) SOURCE_ROOT=$value ;; --input-dir) INPUT_DIR=$value ;; --output-dir) OUTPUT_DIR=$value ;; --mode) MODE=$value ;; --agent) AGENT=$value ;;
      esac ;;
    *) fail "Unknown option: $flag" ;;
  esac
done
case "$AGENT" in codex|dsh|mimocode|zcode|antigravity|all|none) ;; *) fail "Unknown agent: $AGENT" ;; esac
case "$MODE" in global|project|all) ;; *) fail "Unknown check mode: $MODE" ;; esac
[ -n "$HOME_DIR" ] || fail 'A home directory is required'
case "$PROJECT_NAME" in *$'\n'*|*$'\r'*|*$'\t'*) fail 'Project name contains a control character' ;; esac
if [ "$COMMAND" = init-project ] || { [ "$COMMAND" = check ] && [ "$MODE" != global ]; }; then REPO_ROOT=${REPO_ROOT:-$(pwd)}; fi
case "$COMMAND" in export) [ -n "$OUTPUT_DIR" ] || fail '--output-dir is required' ;; import) [ -n "$INPUT_DIR" ] || fail '--input-dir is required' ;; esac
resolve_memory_paths
load_profiles
if [ -n "$REPO_ROOT" ]; then PROJECT_NAME=${PROJECT_NAME:-$(basename -- "$REPO_ROOT")}; fi

plan_profile_adapters() {
  local scope=$1 archive=${2:-} i root destination imported max_bytes
  for ((i=0; i<${#PROFILE_AGENTS[@]}; i++)); do
    selected_agent "${PROFILE_AGENTS[$i]}" || continue
    [ "${PROFILE_SCOPES[$i]}" = "$scope" ] || continue
    root=${PROFILE_ROOTS[$i]}; destination="${!root}/${PROFILE_FILES[$i]}"; imported=
    if [ -n "$archive" ]; then
      if [ "$scope" = global ]; then imported="$archive/global/agents/${PROFILE_AGENTS[$i]}/${PROFILE_FILES[$i]}"
      else imported="$archive/project/${PROFILE_FILES[$i]}"; fi
    fi
    max_bytes=0; if [ "${PROFILE_AGENTS[$i]}" = antigravity ]; then max_bytes=24000; fi
    plan_adapter "$SOURCE_ROOT/${PROFILE_TEMPLATES[$i]}" "$destination" "$imported" "$max_bytes"
  done
}

install_memory() {
  plan_template "$SOURCE_ROOT/templates/global/global-collaboration-rules.md" "$GLOBAL_MEMORY_DIR/global-collaboration-rules.md"
  plan_template "$SOURCE_ROOT/templates/global/memory-architecture.md" "$GLOBAL_MEMORY_DIR/memory-architecture.md"
  plan_profile_adapters global
  if [ "$INSTALL_HOME_AGENTS" -eq 1 ]; then plan_adapter "$SOURCE_ROOT/templates/home/AGENTS.md.template" "$HOME_DIR/AGENTS.md"; fi
  plan_locator
}

init_project() {
  [ -d "$REPO_ROOT" ] || fail "Project directory not found: $REPO_ROOT"
  local file
  for file in AGENTS.md START-HERE.md assistant-memory.md memory/current-work-queue.md memory/topic-memory-improvement.md memory/_templates/daily.md memory/_templates/topic.md; do
    plan_template "$SOURCE_ROOT/templates/project/$file.template" "$REPO_ROOT/$file"
  done
  plan_template "$SOURCE_ROOT/templates/project/memory/_templates/daily.md.template" "$REPO_ROOT/memory/$TODAY.md" 1
  plan_profile_adapters project
}

FAILURES=0
check_fail() { printf 'CHECK FAIL %s: %s\n' "$1" "$2" >&2; FAILURES=$((FAILURES + 1)); }
require_file() {
  if [ ! -f "$1" ]; then check_fail "$1" 'required file is missing'
  elif [ "$STRICT" -eq 1 ] && ! grep -q '[^[:space:]]' "$1"; then check_fail "$1" 'required file is empty'
  else printf 'CHECK OK %s\n' "$1"; fi
}
require_contains() { if [ -f "$1" ] && grep -Fq -- "$2" "$1"; then :; else check_fail "$1" "missing reference: $2"; fi; }
require_no_placeholders() { if [ -f "$1" ] && grep -Eq '{{[A-Z_][A-Z0-9_]*}}|__PROJECT_ROOT__|__PROJECT_NAME__' "$1"; then check_fail "$1" 'unresolved template placeholder'; fi; }

check_adapter() {
  local path=$1 scope=$2 activation=$3 max_bytes=${4:-0} content managed= count_begin count_end needle
  require_file "$path"; [ "$STRICT" -eq 1 ] && [ -f "$path" ] || return 0
  require_no_placeholders "$path"; content=$(cat -- "$path")
  count_begin=$(printf '%s' "$content" | awk -v marker="$BEGIN" 'BEGIN{n=0}{line=$0;while((i=index(line,marker))>0){n++;line=substr(line,i+length(marker))}}END{print n}')
  count_end=$(printf '%s' "$content" | awk -v marker="$END" 'BEGIN{n=0}{line=$0;while((i=index(line,marker))>0){n++;line=substr(line,i+length(marker))}}END{print n}')
  if [ "$count_begin" -ne 1 ] || [ "$count_end" -ne 1 ] || [[ "${content%%"$BEGIN"*}" == *"$END"* ]]; then check_fail "$path" 'invalid managed block'
  else managed=${content#*"$BEGIN"}; managed=${managed%%"$END"*}; fi
  if [ "$max_bytes" -gt 0 ]; then [ "$(wc -c < "$path")" -le "$max_bytes" ] || check_fail "$path" "adapter exceeds $max_bytes UTF-8 bytes"; fi
  if [ "$scope" = global ]; then
    for needle in '~/.agents/memory-kit.conf' global-collaboration-rules.md memory-architecture.md; do
      [[ "$managed" == *"$needle"* ]] || check_fail "$path" "managed block is missing reference: $needle"
    done
  else [[ "$managed" == *AGENTS.md* ]] || check_fail "$path" 'managed block is missing project AGENTS.md reference'; fi
  if [ "$activation" = always_on ]; then
    if ! awk 'BEGIN{q=sprintf("%c",39)} NR==1{sub(/^\357\273\277/, "");sub(/\r$/, "");if($0!="---")exit 1;started=1;next} started {sub(/\r$/, "");if($0=="---"){closed=1;exit}if($0 ~ /^trigger:[[:space:]]*/){value=$0;sub(/^trigger:[[:space:]]*/,"",value);sub(/[[:space:]]+#.*$/,"",value);sub(/[[:space:]]+$/,"",value);triggers++;if(value=="always_on"||value=="\"always_on\""||value==q "always_on" q)active++}} END{if(!closed||triggers!=1||active!=1)exit 1}' "$path"; then check_fail "$path" 'rule frontmatter must set trigger: always_on'; fi
  fi
}

check_profiles() {
  local scope=$1 i root max_bytes
  for ((i=0; i<${#PROFILE_AGENTS[@]}; i++)); do
    selected_agent "${PROFILE_AGENTS[$i]}" || continue
    [ "${PROFILE_SCOPES[$i]}" = "$scope" ] || continue
    root=${PROFILE_ROOTS[$i]}; max_bytes=0; if [ "${PROFILE_AGENTS[$i]}" = antigravity ]; then max_bytes=24000; fi
    check_adapter "${!root}/${PROFILE_FILES[$i]}" "$scope" "${PROFILE_ACTIVATIONS[$i]}" "$max_bytes"
  done
}

check_memory() {
  local file
  if [ "$STRICT" -eq 1 ]; then
    if [ "$LOCATOR_PRESENT" -eq 0 ]; then check_fail "$LOCATOR" 'locator is missing'
    else
      same_path "$LOCATOR_MEMORY" "$GLOBAL_MEMORY_DIR" || check_fail "$LOCATOR" 'locator differs from selected global memory'
      [ -d "$LOCATOR_KIT" ] && [ -f "$LOCATOR_KIT/scripts/install.sh" ] && [ -f "$LOCATOR_KIT/scripts/memory-kit.ps1" ] && [ -f "$LOCATOR_KIT/profiles/agents.tsv" ] || check_fail "$LOCATOR" 'KIT_ROOT does not identify an available source kit'
    fi
  fi
  if [ "$MODE" = project ] && [ "$STRICT" -eq 1 ]; then
    for file in global-collaboration-rules.md memory-architecture.md; do
      require_file "$GLOBAL_MEMORY_DIR/$file"; require_no_placeholders "$GLOBAL_MEMORY_DIR/$file"
    done
  fi
  if [ "$MODE" != project ]; then
    for file in global-collaboration-rules.md memory-architecture.md; do
      require_file "$GLOBAL_MEMORY_DIR/$file"
      if [ "$STRICT" -eq 1 ]; then require_no_placeholders "$GLOBAL_MEMORY_DIR/$file"; fi
    done
    check_profiles global
    if [ "$INSTALL_HOME_AGENTS" -eq 1 ]; then check_adapter "$HOME_DIR/AGENTS.md" global global; fi
    if selected_agent codex && [ -s "$CODEX_DIR/AGENTS.override.md" ]; then check_fail "$CODEX_DIR/AGENTS.override.md" 'override hides the Codex bootstrap'; fi
  fi
  if [ "$MODE" != global ]; then
    for file in AGENTS.md START-HERE.md assistant-memory.md memory/current-work-queue.md memory/topic-memory-improvement.md memory/_templates/daily.md memory/_templates/topic.md; do
      require_file "$REPO_ROOT/$file"
      if [ "$STRICT" -eq 1 ]; then require_no_placeholders "$REPO_ROOT/$file"; fi
    done
    if [ "$STRICT" -eq 1 ]; then
      require_contains "$REPO_ROOT/AGENTS.md" '~/.agents/memory-kit.conf'
      require_contains "$REPO_ROOT/AGENTS.md" global-collaboration-rules.md
      require_contains "$REPO_ROOT/AGENTS.md" memory-architecture.md
      require_contains "$REPO_ROOT/AGENTS.md" memory/current-work-queue.md
      require_contains "$REPO_ROOT/START-HERE.md" AGENTS.md
      require_contains "$REPO_ROOT/START-HERE.md" assistant-memory.md
      require_contains "$REPO_ROOT/assistant-memory.md" AGENTS.md
    fi
    check_profiles project
  fi
  if [ "$FAILURES" -gt 0 ]; then if [ "$STRICT" -eq 1 ]; then exit 3; else exit 1; fi; fi
}

export_memory() {
  local i root file
  [ -f "$GLOBAL_MEMORY_DIR/global-collaboration-rules.md" ] && [ -f "$GLOBAL_MEMORY_DIR/memory-architecture.md" ] || fail 'Incomplete global memory source'
  case "$OUTPUT_DIR/" in "$GLOBAL_MEMORY_DIR/"*) fail 'Archive output must be outside global memory' ;; esac
  plan_tree "$GLOBAL_MEMORY_DIR" "$OUTPUT_DIR/global/memories"
  if [ "$INSTALL_HOME_AGENTS" -eq 1 ] && [ -f "$HOME_DIR/AGENTS.md" ]; then plan_copy "$HOME_DIR/AGENTS.md" "$OUTPUT_DIR/global/AGENTS.md"; fi
  for ((i=0; i<${#PROFILE_AGENTS[@]}; i++)); do
    selected_agent "${PROFILE_AGENTS[$i]}" || continue
    root=${PROFILE_ROOTS[$i]}; file=${PROFILE_FILES[$i]}
    if [ "${PROFILE_SCOPES[$i]}" = global ]; then
      if [ -f "${!root}/$file" ]; then plan_copy "${!root}/$file" "$OUTPUT_DIR/global/agents/${PROFILE_AGENTS[$i]}/$file"; fi
    elif [ -n "$REPO_ROOT" ] && [ -f "$REPO_ROOT/$file" ]; then plan_copy "$REPO_ROOT/$file" "$OUTPUT_DIR/project/$file"; fi
  done
  if [ -n "$REPO_ROOT" ]; then
    for file in AGENTS.md START-HERE.md assistant-memory.md; do plan_copy "$REPO_ROOT/$file" "$OUTPUT_DIR/project/$file"; done
    for file in technical-specification-mvp.md article-notes.md; do if [ -f "$REPO_ROOT/$file" ]; then plan_copy "$REPO_ROOT/$file" "$OUTPUT_DIR/project/$file"; fi; done
    plan_tree "$REPO_ROOT/memory" "$OUTPUT_DIR/project/memory"
  fi
  plan_content "$OUTPUT_DIR/memory-kit-export.conf" "VERSION=2"$'\n'"AGENT=$AGENT"$'\n' MANIFEST
}

validate_manifest() {
  local line key value version= manifest_agent= version_seen=0 agent_seen=0
  if [ ! -f "$INPUT_DIR/memory-kit-export.conf" ]; then
    printf '%s\n' 'LEGACY ARCHIVE: original user text is preserved; old absolute project links require a separately authorized migration.' >&2
    return 0
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}; line=${line#$'\xef\xbb\xbf'}
    case "$line" in ''|'#'*) continue ;; *=*) key=${line%%=*}; value=${line#*=} ;; *) fail 'Malformed archive manifest' ;; esac
    case "$key" in
      VERSION) [ "$version_seen" -eq 0 ] || fail 'Duplicate manifest VERSION'; version_seen=1; version=$value ;;
      AGENT) [ "$agent_seen" -eq 0 ] || fail 'Duplicate manifest AGENT'; agent_seen=1; manifest_agent=$value ;;
      *) fail "Unknown manifest key: $key" ;;
    esac
  done < "$INPUT_DIR/memory-kit-export.conf"
  [ "$version" = 2 ] && [ "$agent_seen" -eq 1 ] || fail 'Incomplete or unsupported archive manifest'
  case "$manifest_agent" in codex|dsh|mimocode|zcode|antigravity|all|none) ;; *) fail 'Unsupported archive profile' ;; esac
}

import_memory() {
  local archive_memory="$INPUT_DIR/global/memories" file
  validate_manifest
  if [ ! -d "$archive_memory" ]; then archive_memory="$INPUT_DIR/global/.codex/memories"; fi
  [ -f "$archive_memory/global-collaboration-rules.md" ] && [ -f "$archive_memory/memory-architecture.md" ] || fail "Incomplete global memory archive: $INPUT_DIR"
  plan_tree "$archive_memory" "$GLOBAL_MEMORY_DIR"
  plan_profile_adapters global "$INPUT_DIR"
  if [ "$INSTALL_HOME_AGENTS" -eq 1 ]; then plan_adapter "$SOURCE_ROOT/templates/home/AGENTS.md.template" "$HOME_DIR/AGENTS.md" "$INPUT_DIR/global/AGENTS.md"; fi
  if [ -n "$REPO_ROOT" ]; then
    for file in AGENTS.md START-HERE.md assistant-memory.md technical-specification-mvp.md article-notes.md; do if [ -f "$INPUT_DIR/project/$file" ]; then plan_copy "$INPUT_DIR/project/$file" "$REPO_ROOT/$file"; fi; done
    if [ -d "$INPUT_DIR/project/memory" ]; then plan_tree "$INPUT_DIR/project/memory" "$REPO_ROOT/memory"; fi
    plan_profile_adapters project "$INPUT_DIR"
  fi
  plan_locator
}

case "$COMMAND" in
  install) install_memory ;; init-project) init_project ;; check) check_memory; exit 0 ;;
  export) export_memory ;; import) import_memory ;;
esac
apply_plan
