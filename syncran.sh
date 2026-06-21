#!/usr/bin/env bash
# syncran.sh - macOS-compatible rsync helper
# - streaming output
# - safe remote->remote execution using proper shell quoting
# - per-host rsync_path support, optional supports_progress2
# - optional --verify-rsync to check rsync binary presence on remote host(s)
# Requirements: bash, rsync, ssh, awk, and python3 or ruby for JSON parsing
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SYNCRAN_CONFIG_FILE:-${SCRIPT_DIR}/syncran.config.json}"
LOG_FILE="${SYNCRAN_LOG_FILE:-./syncran-run.log}"

. "$SCRIPT_DIR/json-helpers.sh"
require_json_helper

log() { echo "$*" | tee -a "$LOG_FILE"; }

# Single-quote helper for logging/display only (not used for remote exec)
shell_quote() {
  local s="$1"
  printf "'%s'" "$(printf "%s" "$s" | sed "s/'/'\\\\''/g")"
}

# Split "user@host" into USER and HOSTNAME (globals)
split_user_host() {
  local raw="$1"
  USER=""; HOSTNAME=""
  [[ -z "$raw" ]] && return
  if [[ "$raw" == *"@"* ]]; then
    USER="${raw%%@*}"
    HOSTNAME="${raw#*@}"
  else
    USER=""; HOSTNAME="$raw"
  fi
}

# ---------- JSON helpers ----------
get_comp_array() { json_array_values "$CONFIG_FILE" comp_array; }
get_host_field() { json_value "$CONFIG_FILE" "" hosts "$1" "$2"; }
get_folder_path_from_config() { json_value "$CONFIG_FILE" "" hosts "$1" folders "$2"; }
get_folder_group_members() { json_array_values "$CONFIG_FILE" folder_groups "$1"; }
get_ignore_list() { json_array_values "$CONFIG_FILE" ignores; }
get_rsync_path() { json_value "$CONFIG_FILE" "/usr/bin/rsync" hosts "$1" rsync_path; }
get_supports_progress2() { json_value "$CONFIG_FILE" "false" hosts "$1" supports_progress2; }

# ---------- globals (flags) ----------
REAL="false"
DELETE_FLAG="false"
DELETE_EXCLUDED_FLAG="false"
KEEP_LOGS="false"
DEBUG="false"
VERIFY_RSYNC="false"
ARCHIVE_FLAG="true"
VERBOSE_FLAG="true"
COMPRESS_FLAG="true"
UPDATE_FLAG="true"
CHECKSUM_FLAG="true"
ITEMIZE_CHANGES_FLAG="true"
STATS_FLAG="true"
PRESERVE_OWNER_FLAG="false"
PRESERVE_GROUP_FLAG="false"
PRESERVE_PERMISSIONS_FLAG="false"
PRESERVE_TIMES_FLAG="true"
OMIT_DIR_TIMES_FLAG="true"
PARTIAL_FLAG="false"
INPLACE_FLAG="false"
IGNORE_EXISTING_FLAG="false"
EXISTING_FLAG="false"
HARD_LINKS_FLAG="false"
LINKS_FLAG="true"
COPY_LINKS_FLAG="false"
SAFE_LINKS_FLAG="false"
DEVICES_FLAG="true"
SPECIALS_FLAG="true"
XATTRS_FLAG="false"
ACLS_FLAG="false"
SPARSE_FLAG="false"
ONE_FILE_SYSTEM_FLAG="false"
NUMERIC_IDS_FLAG="false"
PROGRESS_MODE="auto"
EXTRA_RSYNC_ARGS=()
SOURCE_PATH=""
DEST_PATH=""
SOURCE_TARGET=""
DEST_TARGET=""
SOURCE_PORT=""
DEST_PORT=""

# ---------- build rsync args for the executor host ----------
# prints one token per line for safe array ingestion
build_rsync_args_array() {
  local executor="$1"
  local supports_progress2
  supports_progress2=$(get_supports_progress2 "$executor")

  # base options. Defaults intentionally mirror the original compact arg list:
  # -vuaciz --update --checksum --stats --no-o --no-g --no-p --omit-dir-times.
  [[ "$ARCHIVE_FLAG" == "true" ]] && printf "%s\n" --archive
  [[ "$VERBOSE_FLAG" == "true" ]] && printf "%s\n" --verbose
  [[ "$UPDATE_FLAG" == "true" ]] && printf "%s\n" --update
  [[ "$CHECKSUM_FLAG" == "true" ]] && printf "%s\n" --checksum
  [[ "$ITEMIZE_CHANGES_FLAG" == "true" ]] && printf "%s\n" --itemize-changes
  [[ "$COMPRESS_FLAG" == "true" ]] && printf "%s\n" --compress
  [[ "$STATS_FLAG" == "true" ]] && printf "%s\n" --stats

  if [[ "$PRESERVE_OWNER_FLAG" == "true" ]]; then
    printf "%s\n" --owner
  else
    printf "%s\n" --no-owner
  fi

  if [[ "$PRESERVE_GROUP_FLAG" == "true" ]]; then
    printf "%s\n" --group
  else
    printf "%s\n" --no-group
  fi

  if [[ "$PRESERVE_PERMISSIONS_FLAG" == "true" ]]; then
    printf "%s\n" --perms
  else
    printf "%s\n" --no-perms
  fi

  if [[ "$PRESERVE_TIMES_FLAG" == "true" ]]; then
    printf "%s\n" --times
  else
    printf "%s\n" --no-times
  fi

  [[ "$OMIT_DIR_TIMES_FLAG" == "true" ]] && printf "%s\n" --omit-dir-times
  [[ "$PARTIAL_FLAG" == "true" ]] && printf "%s\n" --partial
  [[ "$INPLACE_FLAG" == "true" ]] && printf "%s\n" --inplace
  [[ "$IGNORE_EXISTING_FLAG" == "true" ]] && printf "%s\n" --ignore-existing
  [[ "$EXISTING_FLAG" == "true" ]] && printf "%s\n" --existing
  [[ "$HARD_LINKS_FLAG" == "true" ]] && printf "%s\n" --hard-links
  if [[ "$LINKS_FLAG" == "true" ]]; then
    printf "%s\n" --links
  else
    printf "%s\n" --no-links
  fi
  [[ "$COPY_LINKS_FLAG" == "true" ]] && printf "%s\n" --copy-links
  [[ "$SAFE_LINKS_FLAG" == "true" ]] && printf "%s\n" --safe-links
  if [[ "$DEVICES_FLAG" == "true" ]]; then
    printf "%s\n" --devices
  else
    printf "%s\n" --no-devices
  fi
  if [[ "$SPECIALS_FLAG" == "true" ]]; then
    printf "%s\n" --specials
  else
    printf "%s\n" --no-specials
  fi
  [[ "$XATTRS_FLAG" == "true" ]] && printf "%s\n" --xattrs
  [[ "$ACLS_FLAG" == "true" ]] && printf "%s\n" --acls
  [[ "$SPARSE_FLAG" == "true" ]] && printf "%s\n" --sparse
  [[ "$ONE_FILE_SYSTEM_FLAG" == "true" ]] && printf "%s\n" --one-file-system
  [[ "$NUMERIC_IDS_FLAG" == "true" ]] && printf "%s\n" --numeric-ids

  case "$PROGRESS_MODE" in
    auto)
      if [[ "$supports_progress2" == "true" ]]; then
        printf "%s\n" --info=progress2
      else
        printf "%s\n" --progress
      fi
      ;;
    progress) printf "%s\n" --progress ;;
    progress2) printf "%s\n" --info=progress2 ;;
    none) ;;
  esac

  # excludes
  while IFS= read -r pat; do
    [[ -z "$pat" ]] && continue
    printf "%s\n" --exclude
    printf "%s\n" "$pat"
  done < <(get_ignore_list)

  # dry-run unless REAL is true
  if [[ "$REAL" != "true" ]]; then
    printf "%s\n" --dry-run
  fi

  if [[ "$DELETE_FLAG" == "true" ]]; then
    printf "%s\n" --delete
  fi

  if [[ "$DELETE_EXCLUDED_FLAG" == "true" ]]; then
    printf "%s\n" --delete-excluded
  fi

  if [[ ${#EXTRA_RSYNC_ARGS[@]} -gt 0 ]]; then
    local extra_arg
    for extra_arg in "${EXTRA_RSYNC_ARGS[@]}"; do
      [[ -z "$extra_arg" ]] && continue
      printf "%s\n" "$extra_arg"
    done
  fi
}

# ---------- run helpers (streaming) ----------
# Run a command (array) locally with line-buffered streaming to log & stdout
run_rsync_local_with_array() {
  local -a cmd=( "$@" )
  [ "$DEBUG" = "true" ] && log "DEBUG: running local command: ${cmd[*]}"
  if command -v stdbuf >/dev/null 2>&1; then
    stdbuf -oL -eL "${cmd[@]}" 2>&1 | awk '{ print; fflush() }' | tee -a "$LOG_FILE"
  else
    "${cmd[@]}" 2>&1 | awk '{ print; fflush() }' | tee -a "$LOG_FILE"
  fi
}

# For ad-hoc remote commands that we must run via a remote shell (rare)
run_remote_shell_cmd() {
  local ssh_target="$1" ssh_port="$2" remote_cmd="$3"
  [ "$DEBUG" = "true" ] && log "DEBUG: running remote shell cmd: ssh -p ${ssh_port} ${ssh_target} bash -lc ${remote_cmd}"
  if ssh -p "${ssh_port:-22}" "${ssh_target}" bash -lc "$remote_cmd" 2>&1 | awk '{ print; fflush() }' | tee -a "$LOG_FILE"; then
    return 0
  else
    log "DEBUG: retrying remote shell cmd with -tt to force PTY"
    ssh -tt -p "${ssh_port:-22}" "${ssh_target}" bash -lc "$remote_cmd" 2>&1 | awk '{ print; fflush() }' | tee -a "$LOG_FILE"
  fi
}

# Verify a remote path exists and is executable (used only if VERIFY_RSYNC == true)
verify_path_on_host() {
  local ssh_target="$1" ssh_port="$2" path="$3"
  local check_cmd="test -x ${path} && echo OK || echo MISSING"
  if ssh -p "${ssh_port:-22}" "${ssh_target}" bash -lc "$check_cmd" 2>/dev/null | grep -q '^OK$'; then
    return 0
  else
    return 1
  fi
}

# ---------- summary store ----------
ALL_RESULTS=()
ALL_RESULTS+=("Hosts"$'\t'"Directory"$'\t'"Files_changed")
ALL_RESULTS+=("---------------"$'\t'"------------"$'\t'"---------------")

# ---------- core sync logic ----------
sync_pair() {
  local src_comp="$1" dest_comp="$2" folder="$3"

  # read raw host strings
  local src_raw dest_raw
  src_raw=$(get_host_field "$src_comp" "host")
  dest_raw=$(get_host_field "$dest_comp" "host")

  # split user@host
  local src_user src_host dest_user dest_host
  split_user_host "$src_raw"; src_user="$USER"; src_host="$HOSTNAME"
  split_user_host "$dest_raw"; dest_user="$USER"; dest_host="$HOSTNAME"

  # ports and roots
  local src_port dest_port src_root dest_root
  src_port=$(get_host_field "$src_comp" "port")
  dest_port=$(get_host_field "$dest_comp" "port")
  src_root=$(get_host_field "$src_comp" "root")
  dest_root=$(get_host_field "$dest_comp" "root")

  # relative folder paths
  local src_rel dest_rel
  src_rel=$(get_folder_path_from_config "$src_comp" "$folder")
  dest_rel=$(get_folder_path_from_config "$dest_comp" "$folder")

  if [[ -z "$src_rel" || -z "$dest_rel" ]]; then
    log "ERROR: invalid folder '${folder}' for ${src_comp} or ${dest_comp}"
    ALL_RESULTS+=("${src_comp}:${dest_comp}"$'\t'"${folder}"$'\t'"ERROR")
    return 1
  fi

  # full paths
  local src_path dest_path
  src_path="${src_root%/}/${src_rel}"
  dest_path="${dest_root%/}/${dest_rel}"

  # nice dry-run string
  local dryrun_str
  if [[ "$REAL" == "true" ]]; then dryrun_str="none (real run)"; else dryrun_str="--dry-run"; fi

  log "Using paths: ${src_comp}:${src_path} -> ${dest_comp}:${dest_path} (folder: $folder)"
  log "Dry run: ${dryrun_str}, Delete: ${DELETE_FLAG}"

  # determine which sides require SSH. Empty host values are local, which supports
  # config-backed local aliases such as an external drive destination.
  local source_remote=false dest_remote=false both_remote=false
  [[ -n "$src_host" ]] && source_remote=true
  [[ -n "$dest_host" ]] && dest_remote=true
  [[ "$source_remote" == "true" && "$dest_remote" == "true" ]] && both_remote=true

  # executor is the host where rsync will be executed
  local executor_comp
  if [[ "$both_remote" == "true" ]]; then executor_comp="$src_comp"; else executor_comp="mac"; fi

  # build base args using executor's progress capability
  local -a base_args=()
  while IFS= read -r token; do base_args+=( "$token" ); done < <(build_rsync_args_array "$executor_comp")

  # per-host rsync_path values
  local src_rsync_path dest_rsync_path
  src_rsync_path=$(get_rsync_path "$src_comp")
  dest_rsync_path=$(get_rsync_path "$dest_comp")

  [ "$DEBUG" = "true" ] && log "DEBUG: src_rsync_path=${src_rsync_path} dest_rsync_path=${dest_rsync_path}"

  # optional verification (only relevant if both_remote)
  if [[ "$VERIFY_RSYNC" == "true" && "$both_remote" == "true" ]]; then
    local src_ssh_target dest_ssh_target
    if [[ -n "$src_user" ]]; then src_ssh_target="${src_user}@${src_host}"; else src_ssh_target="${src_host}"; fi
    if [[ -n "$dest_user" ]]; then dest_ssh_target="${dest_user}@${dest_host}"; else dest_ssh_target="${dest_host}"; fi

    # dest_rsync_path must exist on destination host because the source rsync will SSH into destination and invoke that path
    if ! verify_path_on_host "$dest_ssh_target" "${dest_port:-22}" "$dest_rsync_path"; then
      log "ERROR: dest rsync_path '${dest_rsync_path}' not found/executable on ${dest_ssh_target}"
      ALL_RESULTS+=("${src_comp}:${dest_comp}"$'\t'"${folder}"$'\t'"RSYNCPATH_DEST_MISSING")
      return 1
    fi
    # optionally test source rsync if you expect to use it locally on source (not strictly required here)
    if ! verify_path_on_host "$src_ssh_target" "${src_port:-22}" "$src_rsync_path"; then
      [ "$DEBUG" = "true" ] && log "DEBUG: note: src rsync_path '${src_rsync_path}' not found/executable on ${src_ssh_target} (may be fine)"
      # not fatal by default
    fi
  fi

  if [[ "$both_remote" == "true" ]]; then
    # Build the rsync command as a single properly-quoted shell string
    # The -e argument needs to be quoted as a single unit: -e "ssh -p PORT"
    local remote_ssh_wrapper="ssh -p ${dest_port:-22}"
    
    # Start building the rsync command - use double quotes for -e argument
    local rsync_cmd="rsync -e \"${remote_ssh_wrapper}\""
    
    # Add base args
    for arg in "${base_args[@]}"; do
        rsync_cmd+=" $(printf '%q' "$arg")"
    done
    
    # Add rsync-path for destination - use double quotes
    rsync_cmd+=" --rsync-path=\"${dest_rsync_path}\""
    
    # Add source path
    rsync_cmd+=" $(printf '%q' "${src_path}")"
    
    # Add destination
    local dest_target
    if [[ -n "${dest_user}" ]]; then
        dest_target="${dest_user}@${dest_host}:${dest_path}"
    else
        dest_target="${dest_host}:${dest_path}"
    fi
    rsync_cmd+=" $(printf '%q' "${dest_target}")"
    
    # Now execute via SSH with the command as a single string
    local ssh_target
    if [[ -n "${src_user}" ]]; then
        ssh_target="${src_user}@${src_host}"
    else
        ssh_target="${src_host}"
    fi
    
    [ "$DEBUG" = "true" ] && log "DEBUG: remote rsync command: ${rsync_cmd}"
    
    # Execute the command string remotely via bash -lc to get proper login environment
    # This ensures SSH keys and agent are available
    local wrapped_cmd="bash -lc $(printf '%q' "${rsync_cmd}")"
    
    [ "$DEBUG" = "true" ] && log "DEBUG: wrapped command: ${wrapped_cmd}"
    
    # Execute the command string remotely
    if command -v stdbuf >/dev/null 2>&1; then
      stdbuf -oL -eL ssh -p "${src_port:-22}" "${ssh_target}" "${wrapped_cmd}" 2>&1 | awk '{ print; fflush() }' | tee -a "$LOG_FILE"
    else
      ssh -p "${src_port:-22}" "${ssh_target}" "${wrapped_cmd}" 2>&1 | awk '{ print; fflush() }' | tee -a "$LOG_FILE"
    fi
  else
    # At least one side is local.
    if [[ "$source_remote" == "false" && "$dest_remote" == "true" ]]; then
      # local -> remote
      local dest_target
      if [[ -n "$dest_user" ]]; then dest_target="${dest_user}@${dest_host}:${dest_path}"; else dest_target="${dest_host}:${dest_path}"; fi
      local -a rsync_cmd=( rsync -e "ssh -p ${dest_port:-22}" "${base_args[@]}" --rsync-path="${dest_rsync_path}" "${src_path}" "${dest_target}" )
      [ "$DEBUG" = "true" ] && log "DEBUG: local rsync_cmd: ${rsync_cmd[*]}"
      run_rsync_local_with_array "${rsync_cmd[@]}"
    elif [[ "$source_remote" == "true" && "$dest_remote" == "false" ]]; then
      # remote -> local (we run local rsync pulling from remote source)
      local src_target
      if [[ -n "$src_user" ]]; then src_target="${src_user}@${src_host}:${src_path}"; else src_target="${src_host}:${src_path}"; fi
      local -a rsync_cmd=( rsync -e "ssh -p ${src_port:-22}" "${base_args[@]}" --rsync-path="${src_rsync_path}" "${src_target}" "${dest_path}" )
      [ "$DEBUG" = "true" ] && log "DEBUG: local rsync_cmd: ${rsync_cmd[*]}"
      run_rsync_local_with_array "${rsync_cmd[@]}"
    else
      # both local
      local -a rsync_cmd=( rsync "${base_args[@]}" "${src_path}" "${dest_path}" )
      [ "$DEBUG" = "true" ] && log "DEBUG: local-local rsync_cmd: ${rsync_cmd[*]}"
      run_rsync_local_with_array "${rsync_cmd[@]}"
    fi
  fi

  # parse files transferred from log
  local files_changed
  files_changed=$(tail -n 200 "$LOG_FILE" | grep -E "Number of files transferred" | tail -n1 | awk '{print $NF}' || true)
  files_changed=${files_changed:-0}
  ALL_RESULTS+=("${src_comp}:${dest_comp}"$'\t'"${folder}"$'\t'"${files_changed}")
}

sync_ad_hoc_pair() {
  local source_label="$1" dest_label="$2" folder_label="$3"

  if [[ -z "$SOURCE_PATH" || -z "$DEST_PATH" ]]; then
    log "ERROR: ad hoc jobs require --source-path and --destination-path"
    ALL_RESULTS+=("${source_label}:${dest_label}"$'\t'"${folder_label}"$'\t'"ERROR")
    return 1
  fi

  local dryrun_str
  if [[ "$REAL" == "true" ]]; then dryrun_str="none (real run)"; else dryrun_str="--dry-run"; fi

  local source_display dest_display
  source_display="${SOURCE_TARGET:-local}:${SOURCE_PATH}"
  dest_display="${DEST_TARGET:-local}:${DEST_PATH}"
  log "Using ad hoc paths: ${source_display} -> ${dest_display}"
  log "Dry run: ${dryrun_str}, Delete: ${DELETE_FLAG}"

  local source_remote=false dest_remote=false both_remote=false
  [[ -n "$SOURCE_TARGET" ]] && source_remote=true
  [[ -n "$DEST_TARGET" ]] && dest_remote=true
  [[ "$source_remote" == "true" && "$dest_remote" == "true" ]] && both_remote=true

  local -a base_args=()
  while IFS= read -r token; do base_args+=( "$token" ); done < <(build_rsync_args_array "mac")

  if [[ "$both_remote" == "true" ]]; then
    local remote_ssh_wrapper="ssh -p ${DEST_PORT:-22}"
    local rsync_cmd="rsync -e \"${remote_ssh_wrapper}\""
    local arg
    for arg in "${base_args[@]}"; do
      rsync_cmd+=" $(printf '%q' "$arg")"
    done
    rsync_cmd+=" $(printf '%q' "${SOURCE_PATH}")"
    rsync_cmd+=" $(printf '%q' "${DEST_TARGET}:${DEST_PATH}")"

    local wrapped_cmd="bash -lc $(printf '%q' "${rsync_cmd}")"
    [ "$DEBUG" = "true" ] && log "DEBUG: ad hoc remote rsync command: ${rsync_cmd}"
    if command -v stdbuf >/dev/null 2>&1; then
      stdbuf -oL -eL ssh -p "${SOURCE_PORT:-22}" "${SOURCE_TARGET}" "${wrapped_cmd}" 2>&1 | awk '{ print; fflush() }' | tee -a "$LOG_FILE"
    else
      ssh -p "${SOURCE_PORT:-22}" "${SOURCE_TARGET}" "${wrapped_cmd}" 2>&1 | awk '{ print; fflush() }' | tee -a "$LOG_FILE"
    fi
  elif [[ "$source_remote" == "true" ]]; then
    local -a rsync_cmd=( rsync -e "ssh -p ${SOURCE_PORT:-22}" "${base_args[@]}" "${SOURCE_TARGET}:${SOURCE_PATH}" "${DEST_PATH}" )
    [ "$DEBUG" = "true" ] && log "DEBUG: ad hoc remote-local rsync_cmd: ${rsync_cmd[*]}"
    run_rsync_local_with_array "${rsync_cmd[@]}"
  elif [[ "$dest_remote" == "true" ]]; then
    local -a rsync_cmd=( rsync -e "ssh -p ${DEST_PORT:-22}" "${base_args[@]}" "${SOURCE_PATH}" "${DEST_TARGET}:${DEST_PATH}" )
    [ "$DEBUG" = "true" ] && log "DEBUG: ad hoc local-remote rsync_cmd: ${rsync_cmd[*]}"
    run_rsync_local_with_array "${rsync_cmd[@]}"
  else
    local -a rsync_cmd=( rsync "${base_args[@]}" "${SOURCE_PATH}" "${DEST_PATH}" )
    [ "$DEBUG" = "true" ] && log "DEBUG: ad hoc local-local rsync_cmd: ${rsync_cmd[*]}"
    run_rsync_local_with_array "${rsync_cmd[@]}"
  fi

  local files_changed
  files_changed=$(tail -n 200 "$LOG_FILE" | grep -E "Number of files transferred" | tail -n1 | awk '{print $NF}' || true)
  files_changed=${files_changed:-0}
  ALL_RESULTS+=("${source_label}:${dest_label}"$'\t'"${folder_label}"$'\t'"${files_changed}")
}

# ---------- group expansion ----------
trim_whitespace() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

process_folder_or_group() {
  local cmd="$1" comps="$2" folder="$3"

  if [[ "$folder" == *,* ]]; then
    local -a folder_items=()
    local item
    IFS=',' read -r -a folder_items <<< "$folder"
    for item in "${folder_items[@]}"; do
      item="$(trim_whitespace "$item")"
      [[ -z "$item" ]] && continue
      process_folder_or_group "$cmd" "$comps" "$item"
    done
    return
  fi

  local members
  members=$(get_folder_group_members "$folder" | tr '\n' ' ')
  if [[ -n "$members" ]]; then
    log "Processing group '$folder': $members"
    for f in $members; do
      process_command "$cmd" "$comps" "$f"
    done
  else
    process_command "$cmd" "$comps" "$folder"
  fi
}

# ---------- multi-dest / parity ----------
process_command() {
  local cmd="$1" comps="$2" folder="$3"
  IFS=':' read -r -a IDS <<< "$comps"
  if [[ -n "$SOURCE_PATH" || -n "$DEST_PATH" ]]; then
    local src_label="${IDS[0]:-source}"
    local dest_label="${IDS[1]:-destination}"
    sync_ad_hoc_pair "$src_label" "$dest_label" "$folder"
    if [[ "$cmd" == "bsync" ]]; then
      local original_source_path="$SOURCE_PATH"
      local original_dest_path="$DEST_PATH"
      local original_source_target="$SOURCE_TARGET"
      local original_dest_target="$DEST_TARGET"
      local original_source_port="$SOURCE_PORT"
      local original_dest_port="$DEST_PORT"

      SOURCE_PATH="$original_dest_path"
      DEST_PATH="$original_source_path"
      SOURCE_TARGET="$original_dest_target"
      DEST_TARGET="$original_source_target"
      SOURCE_PORT="$original_dest_port"
      DEST_PORT="$original_source_port"

      sync_ad_hoc_pair "$dest_label" "$src_label" "$folder"

      SOURCE_PATH="$original_source_path"
      DEST_PATH="$original_dest_path"
      SOURCE_TARGET="$original_source_target"
      DEST_TARGET="$original_dest_target"
      SOURCE_PORT="$original_source_port"
      DEST_PORT="$original_dest_port"
    fi
    return
  fi

  local n=${#IDS[@]}
  if (( n > 2 )); then
    local src="${IDS[0]}"
    for ((i=1;i<n;i++)); do
      local dst="${IDS[i]}"
      sync_pair "$src" "$dst" "$folder"
      if [[ "$cmd" == "bsync" ]]; then
        sync_pair "$dst" "$src" "$folder"
      fi
    done
  else
    IFS=':' read -r src dst <<< "$comps"
    sync_pair "$src" "$dst" "$folder"
    if [[ "$cmd" == "bsync" ]]; then
      sync_pair "$dst" "$src" "$folder"
    fi
  fi
}

# ---------- CLI parsing ----------
print_usage() {
  cat <<EOF
Usage:
  $0 sync --source SRC --destination DEST --folder FOLDER [options]
  $0 bsync --source SRC --destination DEST --folder FOLDER [options]

Examples:
  $0 sync --source mac --destination timnas3 --folder code
  $0 sync -s mac -d timnas3 -f code
  $0 sync --source mac --destination timnas3:timnas2025 --folder code,docs --real
  $0 --mode bsync --source timnas3 --destination timnas2025 --folder famGroup,archive
  $0 sync --source Local --destination External --source-path ~/Documents --destination-path /Volumes/Backup/Documents

Compatibility:
  $0 sync SRC:DEST FOLDER [options]
  $0 -s=SRC -d=DEST -f=FOLDER [options]

Options:
  --mode sync|bsync        Transfer mode. Optional if sync/bsync is provided as the command.
  -s, --source SRC         Source host key from config.
  -d, --dest DEST          Destination host key from config.
      --destination DEST   Same as --dest. DEST may be a colon-delimited list.
  -f, --folder FOLDER      Folder key, folder group, or comma-separated list.
      --source-path PATH   Explicit source path for ad hoc jobs.
      --dest-path PATH     Explicit destination path for ad hoc jobs.
      --destination-path PATH
                           Same as --dest-path.
      --source-target USER@HOST
                           SSH target for source path. Omit for local source.
      --dest-target USER@HOST
      --destination-target USER@HOST
                           SSH target for destination path. Omit for local destination.
      --source-port PORT   SSH port for source target. Default 22.
      --dest-port PORT
      --destination-port PORT
                           SSH port for destination target. Default 22.
      --config PATH        Config file path.
      --config=PATH        Config file path.
      --real               Run for real. Default is dry run.
      --delete             Pass --delete to rsync.
      --delete-excluded    Also delete destination files excluded by filters.
      --archive / --no-archive
      --verbose / --no-verbose
      --compress / --no-compress
      --update / --no-update
      --checksum / --no-checksum
      --itemize-changes / --no-itemize-changes
      --stats / --no-stats
      --preserve-owner / --no-preserve-owner
      --preserve-group / --no-preserve-group
      --preserve-permissions / --no-preserve-permissions
      --preserve-times / --no-preserve-times
      --omit-dir-times / --no-omit-dir-times
      --partial / --no-partial
      --inplace / --no-inplace
      --ignore-existing / --no-ignore-existing
      --existing / --no-existing
      --hard-links / --no-hard-links
      --links / --no-links
      --copy-links / --no-copy-links
      --safe-links / --no-safe-links
      --devices / --no-devices
      --specials / --no-specials
      --xattrs / --no-xattrs
      --acls / --no-acls
      --sparse / --no-sparse
      --one-file-system / --no-one-file-system
      --numeric-ids / --no-numeric-ids
      --progress-mode auto|progress|progress2|none
      --rsync-arg ARG      Additional raw rsync argument. Repeat as needed.
      --verify-rsync       Verify destination rsync_path for remote-to-remote runs.
      --keep-logs          Keep the run log.
      --debug              Print debug output.
  -h, --help               Show this help.

Notes:
  - Per-host config keys:
      "rsync_path": "/path/to/rsync"
      "supports_progress2": false   # if remote rsync is too old for --info=progress2
  - --verify-rsync will attempt to verify destination rsync_path exists & is executable before running remote->remote.
EOF
}

missing_value() {
  printf 'Missing value for %s\n' "$1" >&2
  exit 2
}

COMMAND=""; COMPS=""; SOURCE_COMP=""; DEST_COMP=""; FOLDER=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    sync|bsync) COMMAND="$1"; shift ;;
    --mode=*) COMMAND="${1#*=}"; shift ;;
    --mode)
      shift
      [[ $# -gt 0 ]] || missing_value "--mode"
      COMMAND="$1"
      shift
      ;;
    --config=*) CONFIG_FILE="${1#*=}"; shift ;;
    --config)
      shift
      [[ $# -gt 0 ]] || missing_value "--config"
      CONFIG_FILE="$1"
      shift
      ;;
    --real) REAL="true"; shift ;;
    --dry-run) REAL="false"; shift ;;
    --delete) DELETE_FLAG="true"; shift ;;
    --no-delete) DELETE_FLAG="false"; shift ;;
    --delete-excluded) DELETE_EXCLUDED_FLAG="true"; shift ;;
    --no-delete-excluded) DELETE_EXCLUDED_FLAG="false"; shift ;;
    --archive) ARCHIVE_FLAG="true"; shift ;;
    --no-archive) ARCHIVE_FLAG="false"; shift ;;
    --verbose) VERBOSE_FLAG="true"; shift ;;
    --no-verbose) VERBOSE_FLAG="false"; shift ;;
    --compress) COMPRESS_FLAG="true"; shift ;;
    --no-compress) COMPRESS_FLAG="false"; shift ;;
    --update) UPDATE_FLAG="true"; shift ;;
    --no-update) UPDATE_FLAG="false"; shift ;;
    --checksum) CHECKSUM_FLAG="true"; shift ;;
    --no-checksum) CHECKSUM_FLAG="false"; shift ;;
    --itemize-changes) ITEMIZE_CHANGES_FLAG="true"; shift ;;
    --no-itemize-changes) ITEMIZE_CHANGES_FLAG="false"; shift ;;
    --stats) STATS_FLAG="true"; shift ;;
    --no-stats) STATS_FLAG="false"; shift ;;
    --preserve-owner) PRESERVE_OWNER_FLAG="true"; shift ;;
    --no-preserve-owner) PRESERVE_OWNER_FLAG="false"; shift ;;
    --preserve-group) PRESERVE_GROUP_FLAG="true"; shift ;;
    --no-preserve-group) PRESERVE_GROUP_FLAG="false"; shift ;;
    --preserve-permissions) PRESERVE_PERMISSIONS_FLAG="true"; shift ;;
    --no-preserve-permissions) PRESERVE_PERMISSIONS_FLAG="false"; shift ;;
    --preserve-times) PRESERVE_TIMES_FLAG="true"; shift ;;
    --no-preserve-times) PRESERVE_TIMES_FLAG="false"; shift ;;
    --omit-dir-times) OMIT_DIR_TIMES_FLAG="true"; shift ;;
    --no-omit-dir-times) OMIT_DIR_TIMES_FLAG="false"; shift ;;
    --partial) PARTIAL_FLAG="true"; shift ;;
    --no-partial) PARTIAL_FLAG="false"; shift ;;
    --inplace) INPLACE_FLAG="true"; shift ;;
    --no-inplace) INPLACE_FLAG="false"; shift ;;
    --ignore-existing) IGNORE_EXISTING_FLAG="true"; shift ;;
    --no-ignore-existing) IGNORE_EXISTING_FLAG="false"; shift ;;
    --existing) EXISTING_FLAG="true"; shift ;;
    --no-existing) EXISTING_FLAG="false"; shift ;;
    --hard-links) HARD_LINKS_FLAG="true"; shift ;;
    --no-hard-links) HARD_LINKS_FLAG="false"; shift ;;
    --links) LINKS_FLAG="true"; shift ;;
    --no-links) LINKS_FLAG="false"; shift ;;
    --copy-links) COPY_LINKS_FLAG="true"; shift ;;
    --no-copy-links) COPY_LINKS_FLAG="false"; shift ;;
    --safe-links) SAFE_LINKS_FLAG="true"; shift ;;
    --no-safe-links) SAFE_LINKS_FLAG="false"; shift ;;
    --devices) DEVICES_FLAG="true"; shift ;;
    --no-devices) DEVICES_FLAG="false"; shift ;;
    --specials) SPECIALS_FLAG="true"; shift ;;
    --no-specials) SPECIALS_FLAG="false"; shift ;;
    --xattrs) XATTRS_FLAG="true"; shift ;;
    --no-xattrs) XATTRS_FLAG="false"; shift ;;
    --acls) ACLS_FLAG="true"; shift ;;
    --no-acls) ACLS_FLAG="false"; shift ;;
    --sparse) SPARSE_FLAG="true"; shift ;;
    --no-sparse) SPARSE_FLAG="false"; shift ;;
    --one-file-system) ONE_FILE_SYSTEM_FLAG="true"; shift ;;
    --no-one-file-system) ONE_FILE_SYSTEM_FLAG="false"; shift ;;
    --numeric-ids) NUMERIC_IDS_FLAG="true"; shift ;;
    --no-numeric-ids) NUMERIC_IDS_FLAG="false"; shift ;;
    --progress-mode=*) PROGRESS_MODE="${1#*=}"; shift ;;
    --progress-mode)
      shift
      [[ $# -gt 0 ]] || missing_value "--progress-mode"
      PROGRESS_MODE="$1"
      shift
      ;;
    --rsync-arg=*) EXTRA_RSYNC_ARGS+=( "${1#*=}" ); shift ;;
    --rsync-arg)
      shift
      [[ $# -gt 0 ]] || missing_value "--rsync-arg"
      EXTRA_RSYNC_ARGS+=( "$1" )
      shift
      ;;
    --source-path=*) SOURCE_PATH="${1#*=}"; shift ;;
    --source-path)
      shift
      [[ $# -gt 0 ]] || missing_value "--source-path"
      SOURCE_PATH="$1"
      shift
      ;;
    --dest-path=*|--destination-path=*) DEST_PATH="${1#*=}"; shift ;;
    --dest-path|--destination-path)
      shift
      [[ $# -gt 0 ]] || missing_value "--destination-path"
      DEST_PATH="$1"
      shift
      ;;
    --source-target=*) SOURCE_TARGET="${1#*=}"; shift ;;
    --source-target)
      shift
      [[ $# -gt 0 ]] || missing_value "--source-target"
      SOURCE_TARGET="$1"
      shift
      ;;
    --dest-target=*|--destination-target=*) DEST_TARGET="${1#*=}"; shift ;;
    --dest-target|--destination-target)
      shift
      [[ $# -gt 0 ]] || missing_value "--destination-target"
      DEST_TARGET="$1"
      shift
      ;;
    --source-port=*) SOURCE_PORT="${1#*=}"; shift ;;
    --source-port)
      shift
      [[ $# -gt 0 ]] || missing_value "--source-port"
      SOURCE_PORT="$1"
      shift
      ;;
    --dest-port=*|--destination-port=*) DEST_PORT="${1#*=}"; shift ;;
    --dest-port|--destination-port)
      shift
      [[ $# -gt 0 ]] || missing_value "--destination-port"
      DEST_PORT="$1"
      shift
      ;;
    --verify-rsync) VERIFY_RSYNC="true"; shift ;;
    --keep-logs) KEEP_LOGS="true"; shift ;;
    --debug) DEBUG="true"; shift ;;
    -s=*|--source=*) SOURCE_COMP="${1#*=}"; shift ;;
    -s|--source)
      shift
      [[ $# -gt 0 ]] || missing_value "--source"
      SOURCE_COMP="$1"
      shift
      ;;
    -d=*|--dest=*|--destination=*) DEST_COMP="${1#*=}"; shift ;;
    -d|--dest|--destination)
      shift
      [[ $# -gt 0 ]] || missing_value "--destination"
      DEST_COMP="$1"
      shift
      ;;
    -f=*|--folder=*) FOLDER="${1#*=}"; shift ;;
    -f|--folder)
      shift
      [[ $# -gt 0 ]] || missing_value "--folder"
      FOLDER="$1"
      shift
      ;;
    -h|--help) print_usage; exit 0 ;;
    *) if [[ -z "$COMMAND" ]]; then COMMAND="$1"; elif [[ -z "$COMPS" ]]; then COMPS="$1"; elif [[ -z "$FOLDER" ]]; then FOLDER="$1"; fi; shift ;;
  esac
done

if [[ -n "$SOURCE_COMP" || -n "$DEST_COMP" ]]; then
  if [[ -z "$SOURCE_COMP" || -z "$DEST_COMP" ]]; then
    printf 'Use both --source SRC and --destination DEST when using named host options.\n' >&2
    print_usage >&2
    exit 1
  fi
  COMPS="${SOURCE_COMP}:${DEST_COMP}"
fi

if [[ -n "$COMMAND" && "$COMMAND" != "sync" && "$COMMAND" != "bsync" ]]; then
  printf 'Invalid mode: %s\n' "$COMMAND" >&2
  print_usage >&2
  exit 1
fi

case "$PROGRESS_MODE" in
  auto|progress|progress2|none) ;;
  *)
    printf 'Invalid progress mode: %s\n' "$PROGRESS_MODE" >&2
    print_usage >&2
    exit 1
    ;;
esac

if [[ -z "$FOLDER" && -n "$SOURCE_PATH" && -n "$DEST_PATH" ]]; then
  FOLDER="$(basename "$SOURCE_PATH")"
fi

if [[ -z "$SOURCE_COMP" && -z "$DEST_COMP" && -z "$COMPS" && -n "$SOURCE_PATH" && -n "$DEST_PATH" ]]; then
  SOURCE_COMP="${SOURCE_TARGET:-local-source}"
  DEST_COMP="${DEST_TARGET:-local-dest}"
  COMPS="${SOURCE_COMP}:${DEST_COMP}"
fi

if [[ -z "$COMMAND" || -z "$COMPS" || -z "$FOLDER" ]]; then
  print_usage
  exit 1
fi

> "$LOG_FILE"

[ "$DEBUG" = "true" ] && log "DEBUG: COMMAND=$COMMAND COMPS=$COMPS FOLDER=$FOLDER REAL=$REAL DELETE=$DELETE_FLAG PROGRESS_MODE=$PROGRESS_MODE VERIFY_RSYNC=$VERIFY_RSYNC SOURCE_PATH=$SOURCE_PATH DEST_PATH=$DEST_PATH SOURCE_TARGET=$SOURCE_TARGET DEST_TARGET=$DEST_TARGET"

if [[ -n "$SOURCE_PATH" || -n "$DEST_PATH" ]]; then
  if [[ -z "$SOURCE_PATH" || -z "$DEST_PATH" ]]; then
    printf 'Use both --source-path and --destination-path for ad hoc jobs.\n' >&2
    exit 1
  fi
  process_command "$COMMAND" "$COMPS" "$FOLDER"
else
  process_folder_or_group "$COMMAND" "$COMPS" "$FOLDER"
fi

# ---------- SUMMARY ----------
echo
echo "SUMMARY:"
for item in "${ALL_RESULTS[@]}"; do
  printf "%s\n" "$item"
done | column -s $'\t' -t
echo

if [[ "$KEEP_LOGS" == "false" ]]; then
  rm -f "$LOG_FILE" || true
else
  echo "Log kept at: $LOG_FILE"
fi

exit 0
