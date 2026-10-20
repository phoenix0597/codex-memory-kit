#!/usr/bin/env bash
# Shared implementation for the Bash CLI. Configuration files are always data.

fail() { printf 'ERROR %s\n' "$*" >&2; exit 2; }
status() { if [ "$DRY_RUN" -eq 1 ]; then printf 'DRY-RUN %s\n' "$*"; else printf '%s\n' "$*"; fi; }
log() { if [ "$VERBOSE" -eq 1 ]; then printf '%s\n' "$*"; fi; }

to_posix_path() {
  local value=$1 drive
  case "$value" in
    [A-Za-z]:[\\/]*)
      drive=$(printf '%s' "${value:0:1}" | tr '[:upper:]' '[:lower:]')
      value="/$drive/${value:3}"; value=${value//\\//} ;;
  esac
  case "${OSTYPE:-}" in
    msys*|cygwin*) case "$value" in /mnt/[A-Za-z]/*) value="/${value:5:1}/${value:7}" ;; esac ;;
  esac
  printf '%s' "$value"
}

normalize_path() {
  local value
  case "$1" in *$'\n'*|*$'\r'*|*$'\t'*) fail "Path contains a newline, carriage return, or tab: $2" ;; esac
  value=$(to_posix_path "$1")
  case "$value" in /*) ;; *) fail "Expected an absolute path for $2: $1" ;; esac
  while [ "$value" != / ] && [ "${value%/}" != "$value" ]; do value=${value%/}; done
  RESULT=$value
}

to_windows_path() {
  local value=$1 drive rest
  case "$value" in
    /mnt/[A-Za-z]/*) drive=${value:5:1}; rest=${value:6} ;;
    /[A-Za-z]/*) drive=${value:1:1}; rest=${value:2} ;;
    *) printf '%s' "$value"; return ;;
  esac
  drive=$(printf '%s' "$drive" | tr '[:lower:]' '[:upper:]')
  printf '%s:%s' "$drive" "${rest//\//\\}"
}

same_path() {
  local left=$1 right=$2
  case "${OSTYPE:-}" in
    msys*|cygwin*) left=$(printf '%s' "$left" | tr '[:upper:]' '[:lower:]'); right=$(printf '%s' "$right" | tr '[:upper:]' '[:lower:]') ;;
  esac
  [ "$left" = "$right" ]
}

read_text() {
  # A sentinel preserves trailing newlines in user-owned Markdown.
  RESULT=$(cat -- "$1"; printf '\001'); RESULT=${RESULT%$'\001'}
}

parse_locator() {
  LOCATOR_PRESENT=0; LOCATOR_MEMORY=; LOCATOR_KIT=
  [ ! -e "$LOCATOR" ] || [ -f "$LOCATOR" ] || fail "Locator is not a regular file: $LOCATOR"
  [ -f "$LOCATOR" ] || return 0
  LOCATOR_PRESENT=1
  local line key value version= seen_version=0 seen_memory=0 seen_kit=0
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}; line=${line#$'\xef\xbb\xbf'}
    case "$line" in ''|'#'*) continue ;; esac
    case "$line" in *=*) key=${line%%=*}; value=${line#*=} ;; *) fail "Malformed locator line: $LOCATOR" ;; esac
    case "$key" in
      VERSION) [ "$seen_version" -eq 0 ] || fail 'Duplicate locator VERSION'; seen_version=1; version=$value ;;
      GLOBAL_MEMORY_DIR) [ "$seen_memory" -eq 0 ] || fail 'Duplicate locator GLOBAL_MEMORY_DIR'; seen_memory=1; normalize_path "$value" GLOBAL_MEMORY_DIR; LOCATOR_MEMORY=$RESULT ;;
      KIT_ROOT) [ "$seen_kit" -eq 0 ] || fail 'Duplicate locator KIT_ROOT'; seen_kit=1; normalize_path "$value" KIT_ROOT; LOCATOR_KIT=$RESULT ;;
      *) fail "Unknown locator key: $key" ;;
    esac
  done < "$LOCATOR"
  [ "$version" = 1 ] && [ "$seen_memory" -eq 1 ] && [ "$seen_kit" -eq 1 ] || fail "Incomplete or unsupported locator: $LOCATOR"
}

resolve_memory_paths() {
  local explicit_codex=$CODEX_DIR key value
  normalize_path "$HOME_DIR" home; HOME_DIR=$RESULT
  LOCATOR="$HOME_DIR/.agents/memory-kit.conf"; parse_locator
  if [ "$HOME_EXPLICIT" -eq 0 ]; then
    CODEX_DIR=${CODEX_DIR:-${CODEX_HOME:-}}; DSH_DIR=${DSH_DIR:-${DSH_HOME:-}}
    MIMOCODE_CONFIG_DIR=${MIMOCODE_CONFIG_DIR:-$NATIVE_MIMO_CONFIG}
    if [ -z "$MIMOCODE_CONFIG_DIR" ]; then
      if [ -n "${MIMOCODE_HOME:-}" ]; then MIMOCODE_CONFIG_DIR="$MIMOCODE_HOME/config"
      elif [ -n "${XDG_CONFIG_HOME:-}" ]; then MIMOCODE_CONFIG_DIR="$XDG_CONFIG_HOME/mimocode"; fi
    fi
  fi
  CODEX_DIR=${CODEX_DIR:-"$HOME_DIR/.codex"}; DSH_DIR=${DSH_DIR:-"$HOME_DIR/.dsh"}
  MIMOCODE_CONFIG_DIR=${MIMOCODE_CONFIG_DIR:-"$HOME_DIR/.config/mimocode"}
  ZCODE_DIR=${ZCODE_DIR:-"$HOME_DIR/.zcode"}; ANTIGRAVITY_DIR=${ANTIGRAVITY_DIR:-"$HOME_DIR/.gemini"}
  for key in CODEX_DIR DSH_DIR MIMOCODE_CONFIG_DIR ZCODE_DIR ANTIGRAVITY_DIR; do
    value=${!key}; normalize_path "$value" "$key"; printf -v "$key" '%s' "$RESULT"
  done
  if [ -z "$GLOBAL_MEMORY_DIR" ]; then
    if [ "$LOCATOR_PRESENT" -eq 1 ]; then GLOBAL_MEMORY_DIR=$LOCATOR_MEMORY
    elif [ -n "$explicit_codex" ]; then GLOBAL_MEMORY_DIR="$CODEX_DIR/memories"
    elif [ -d "$HOME_DIR/.agents/memories" ] && [ -d "$CODEX_DIR/memories" ]; then fail 'Both shared and legacy memory exist; select --global-memory-dir explicitly.'
    elif [ -d "$CODEX_DIR/memories" ]; then GLOBAL_MEMORY_DIR="$CODEX_DIR/memories"
    else GLOBAL_MEMORY_DIR="$HOME_DIR/.agents/memories"; fi
  fi
  normalize_path "$GLOBAL_MEMORY_DIR" global-memory-dir; GLOBAL_MEMORY_DIR=$RESULT
  normalize_path "$SOURCE_ROOT" source-root; SOURCE_ROOT=$RESULT
  [ -d "$SOURCE_ROOT" ] || fail "Source root not found: $SOURCE_ROOT"
  KIT_ROOT=$RUNTIME_ROOT
  if [ -n "$REPO_ROOT" ]; then normalize_path "$REPO_ROOT" repo; REPO_ROOT=$RESULT; fi
  if [ -n "$INPUT_DIR" ]; then normalize_path "$INPUT_DIR" input-dir; INPUT_DIR=$RESULT; fi
  if [ -n "$OUTPUT_DIR" ]; then normalize_path "$OUTPUT_DIR" output-dir; OUTPUT_DIR=$RESULT; fi
}

load_profiles() {
  local header agent scope root file template activation extra line
  PROFILE_AGENTS=(); PROFILE_SCOPES=(); PROFILE_ROOTS=(); PROFILE_FILES=(); PROFILE_TEMPLATES=(); PROFILE_ACTIVATIONS=()
  [ -f "$RUNTIME_ROOT/profiles/agents.tsv" ] || fail 'Missing profiles/agents.tsv'
  IFS= read -r header < "$RUNTIME_ROOT/profiles/agents.tsv"
  header=${header%$'\r'}
  [ "$header" = $'agent\tscope\troot\tfile\ttemplate\tactivation' ] || fail 'Invalid profile registry header'
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}; [ -n "$line" ] || continue; [ "$line" != "$header" ] || continue
    IFS=$'\t' read -r agent scope root file template activation extra <<< "$line"
    [ -n "$agent" ] && [ -n "$scope" ] && [ -n "$root" ] && [ -n "$file" ] && [ -n "$template" ] && [ -n "$activation" ] && [ -z "$extra" ] || fail 'Malformed profile row'
    case "$agent" in codex|dsh|mimocode|zcode|antigravity) ;; *) fail "Unknown registry agent: $agent" ;; esac
    case "$scope:$root:$activation" in
      global:CODEX_DIR:global|global:DSH_DIR:global|global:MIMOCODE_CONFIG_DIR:global|global:ZCODE_DIR:global|global:ANTIGRAVITY_DIR:global|project:REPO_ROOT:always_on) ;;
      *) fail "Invalid profile scope/root/activation: $agent" ;;
    esac
    case "/$file/ /$template/" in *'/../'*|*'/./'*|*'//'*) fail 'Unsafe relative path in profile registry' ;; esac
    case "$file:$template" in /*|*':/'*) fail 'Profile files must be relative paths' ;; esac
    PROFILE_AGENTS+=("$agent"); PROFILE_SCOPES+=("$scope"); PROFILE_ROOTS+=("$root"); PROFILE_FILES+=("$file"); PROFILE_TEMPLATES+=("$template"); PROFILE_ACTIVATIONS+=("$activation")
  done < "$RUNTIME_ROOT/profiles/agents.tsv"
  [ "${#PROFILE_AGENTS[@]}" -gt 0 ] || fail 'Empty profile registry'
}

selected_agent() { [ "$AGENT" = all ] || [ "$AGENT" = "$1" ]; }
escape_sed() { printf '%s' "$1" | sed 's/[\\|&]/\\&/g'; }

render_source() {
  local src=$1 key value rendered
  [ -f "$src" ] || fail "Missing template: $src"
  read_text "$src"; rendered=$RESULT
  if [[ "$rendered" != *'{{'* ]]; then return 0; fi
  local args=()
  for key in HOME_DIR CODEX_DIR DSH_DIR MIMOCODE_CONFIG_DIR ZCODE_DIR ANTIGRAVITY_DIR GLOBAL_MEMORY_DIR KIT_ROOT REPO_ROOT PROJECT_NAME; do
    value=${!key:-}
    if [[ "$rendered" == *"{{$key}}"* ]]; then args+=(-e "s|{{$key}}|$(escape_sed "$value")|g"); fi
    case "$key" in PROJECT_NAME) ;; *)
      if [[ "$rendered" == *"{{${key}_POSIX}}"* ]]; then args+=(-e "s|{{${key}_POSIX}}|$(escape_sed "$value")|g"); fi
      if [[ "$rendered" == *"{{${key}_WINDOWS}}"* ]]; then args+=(-e "s|{{${key}_WINDOWS}}|$(escape_sed "$(to_windows_path "$value")")|g"); fi ;;
    esac
  done
  if [ "${#args[@]}" -gt 0 ]; then rendered=$(sed "${args[@]}" "$src"); fi
  if printf '%s' "$rendered" | grep -Eq '{{[A-Z_][A-Z0-9_]*}}'; then fail "Unresolved template placeholder: $src"; fi
  RESULT="$rendered"$'\n'
}

validate_destination() {
  local destination=$1 parent
  [ ! -d "$destination" ] || fail "Expected a file, found a directory: $destination"
  [ ! -L "$destination" ] || fail "Refusing to overwrite a symbolic link: $destination"
  parent=${destination%/*}; parent=${parent:-/}
  while [ "$parent" != / ]; do
    [ ! -e "$parent" ] || [ -d "$parent" ] || fail "Parent is not a directory: $parent"
    parent=${parent%/*}; parent=${parent:-/}
  done
}

plan_content() {
  local destination=$1 content=$2 verb=${3:-WRITE}
  validate_destination "$destination"
  if [ -f "$destination" ]; then read_text "$destination"; if [ "$RESULT" = "$content" ]; then status "SKIP $destination"; return 0; fi; fi
  PLAN_TYPES+=(text); PLAN_SOURCES+=(""); PLAN_DESTINATIONS+=("$destination"); PLAN_CONTENTS+=("$content"); PLAN_VERBS+=("$verb")
}

plan_copy() {
  local src=$1 dst=$2
  [ -f "$src" ] || fail "Source file not found: $src"
  [ ! -L "$src" ] || fail "Archive source must not be a symbolic link: $src"
  validate_destination "$dst"
  if [ -f "$dst" ] && { [ "$FORCE" -ne 1 ] || cmp -s -- "$src" "$dst"; }; then status "SKIP $dst"; return 0; fi
  PLAN_TYPES+=(copy); PLAN_SOURCES+=("$src"); PLAN_DESTINATIONS+=("$dst"); PLAN_CONTENTS+=(""); PLAN_VERBS+=(COPY)
}

plan_directory() {
  [ ! -e "$1" ] || [ -d "$1" ] || fail "Expected a directory: $1"
  [ ! -L "$1" ] || fail "Symbolic directory is unsupported: $1"
  [ ! -d "$1" ] || return 0
  validate_destination "$1/.memory-kit-directory-probe"
  PLAN_TYPES+=(directory); PLAN_SOURCES+=(""); PLAN_DESTINATIONS+=("$1"); PLAN_CONTENTS+=(""); PLAN_VERBS+=(MKDIR)
}

# Resolve existing ancestors physically, then normalize any remaining components.
# This also catches aliases through symlinks without requiring GNU realpath.
tree_location() {
  local probe=$1 suffix= parent part resolved physical
  local components=()
  while [ ! -d "$probe" ] && [ "$probe" != / ]; do
    part=${probe##*/}; suffix="$part/$suffix"
    parent=${probe%/*}; probe=${parent:-/}
  done
  physical=$(CDPATH='' cd -P -- "$probe" && pwd) || fail "Cannot resolve directory: $probe"
  resolved=/
  IFS=/ read -r -a components <<< "$physical/$suffix"
  for part in "${components[@]}"; do
    case "$part" in
      ''|.) ;;
      ..) resolved=${resolved%/*}; resolved=${resolved:-/} ;;
      *) resolved="${resolved%/}/$part" ;;
    esac
  done
  case "${OSTYPE:-}" in msys*|cygwin*) resolved=$(printf '%s' "$resolved" | tr '[:upper:]' '[:lower:]') ;; esac
  RESULT=$resolved
}

assert_disjoint_trees() {
  local left right
  tree_location "$1"; left="${RESULT%/}/"
  tree_location "$2"; right="${RESULT%/}/"
  case "$left" in "$right"*) fail 'Copy source and destination trees must not overlap.' ;; esac
  case "$right" in "$left"*) fail 'Copy source and destination trees must not overlap.' ;; esac
}

plan_tree() {
  local src=$1 dst=$2 item relative
  [ -d "$src" ] || fail "Source directory not found: $src"
  [ ! -L "$src" ] || fail "Symbolic source directories are unsupported: $src"
  assert_disjoint_trees "$src" "$dst"
  while IFS= read -r -d '' item; do fail "Symbolic links are unsupported in memory archives: $item"; done < <(find "$src" -type l -print0)
  plan_directory "$dst"
  while IFS= read -r -d '' item; do
    relative=${item#"$src/"}
    if [ -d "$item" ]; then plan_directory "$dst/$relative"; else plan_copy "$item" "$dst/$relative"; fi
  done < <(find "$src" -mindepth 1 \( -type d -o -type f \) -print0)
}

plan_template() {
  local src=$1 dst=$2 daily=${3:-0}
  [ -f "$src" ] || fail "Missing template: $src"
  validate_destination "$dst"
  if [ -f "$dst" ] && [ "$FORCE" -ne 1 ]; then status "SKIP $dst"; return 0; fi
  render_source "$src"
  if [ "$daily" -eq 1 ]; then RESULT=${RESULT//YYYY-MM-DD/$TODAY}; fi
  plan_content "$dst" "$RESULT" RENDER
}

split_managed() {
  local text=$1 remainder=$1 begins=0 ends=0
  while [[ "$remainder" == *"$BEGIN"* ]]; do begins=$((begins + 1)); remainder=${remainder#*"$BEGIN"}; done
  remainder=$text
  while [[ "$remainder" == *"$END"* ]]; do ends=$((ends + 1)); remainder=${remainder#*"$END"}; done
  [ "$begins" -eq "$ends" ] && [ "$begins" -le 1 ] || fail 'Incomplete or multiple memory-kit managed markers'
  MANAGED_PRESENT=$begins; MANAGED_PREFIX=; MANAGED_BLOCK=; MANAGED_SUFFIX=
  [ "$begins" -eq 1 ] || return 0
  MANAGED_PREFIX=${text%%"$BEGIN"*}; remainder=${text#*"$BEGIN"}
  [[ "$MANAGED_PREFIX" != *"$END"* ]] || fail 'Managed end marker precedes begin marker'
  MANAGED_BLOCK="$BEGIN${remainder%%"$END"*}$END"; MANAGED_SUFFIX=${remainder#*"$END"}
}

plan_adapter() {
  local src=$1 dst=$2 imported=${3:-} max_bytes=${4:-0} rendered expected existing merged oldblock from_archive=0
  render_source "$src"; rendered=$RESULT; split_managed "$rendered"
  [ "$MANAGED_PRESENT" -eq 1 ] || fail "Adapter template has no managed block: $src"
  expected=$MANAGED_BLOCK
  if [ -f "$dst" ]; then read_text "$dst"; existing=$RESULT
  elif [ -n "$imported" ] && [ -f "$imported" ]; then read_text "$imported"; existing=$RESULT; from_archive=1
  else
    if [ "$max_bytes" -gt 0 ]; then [ "$(printf '%s' "$rendered" | wc -c)" -le "$max_bytes" ] || fail "Adapter exceeds $max_bytes UTF-8 bytes: $dst"; fi
    plan_content "$dst" "$rendered" ADAPTER; return 0
  fi
  split_managed "$existing"
  if [ "$MANAGED_PRESENT" -eq 1 ]; then
    oldblock=$MANAGED_BLOCK
    if [ "${oldblock//$'\r\n'/$'\n'}" = "${expected//$'\r\n'/$'\n'}" ]; then merged=$existing
    else
      [ "$FORCE" -eq 1 ] || [ "$UPDATE_ADAPTERS" -eq 1 ] || [ "$from_archive" -eq 1 ] || fail "Conflicting managed block; use --update-adapters after review to replace only that block: $dst"
      merged="$MANAGED_PREFIX$expected$MANAGED_SUFFIX"
    fi
  else
    merged=$existing
    # Activation metadata outside the block remains user-owned.
    [ -z "$merged" ] || [[ "$merged" == *$'\n' ]] || merged+=$'\n'
    [ -z "$merged" ] || merged+=$'\n'
    merged+="$expected"$'\n'
  fi
  if [ "$max_bytes" -gt 0 ]; then [ "$(printf '%s' "$merged" | wc -c)" -le "$max_bytes" ] || fail "Adapter exceeds $max_bytes UTF-8 bytes: $dst"; fi
  plan_content "$dst" "$merged" ADAPTER
}

plan_locator() {
  if [ "$LOCATOR_PRESENT" -eq 1 ] && same_path "$LOCATOR_MEMORY" "$GLOBAL_MEMORY_DIR" && same_path "$LOCATOR_KIT" "$KIT_ROOT"; then status "SKIP $LOCATOR"; return 0; fi
  plan_content "$LOCATOR" "VERSION=1"$'\n'"GLOBAL_MEMORY_DIR=$GLOBAL_MEMORY_DIR"$'\n'"KIT_ROOT=$KIT_ROOT"$'\n' LOCATOR
}

apply_plan() {
  local i destination parent
  for ((i=0; i<${#PLAN_TYPES[@]}; i++)); do
    destination=${PLAN_DESTINATIONS[$i]}; status "${PLAN_VERBS[$i]} $destination"
    [ "$DRY_RUN" -eq 0 ] || continue
    case "${PLAN_TYPES[$i]}" in
      directory) mkdir -p -- "$destination" ;;
      text|copy)
        parent=$(dirname -- "$destination"); mkdir -p -- "$parent"
        ACTIVE_TEMP=$(mktemp "$parent/.memory-kit.XXXXXX")
        if [ "${PLAN_TYPES[$i]}" = text ]; then
          if [ -f "$destination" ]; then cp -p -- "$destination" "$ACTIVE_TEMP"; fi
          printf '%s' "${PLAN_CONTENTS[$i]}" > "$ACTIVE_TEMP"
        else cp -p -- "${PLAN_SOURCES[$i]}" "$ACTIVE_TEMP"; fi
        mv -f -- "$ACTIVE_TEMP" "$destination"; ACTIVE_TEMP= ;;
    esac
  done
}
