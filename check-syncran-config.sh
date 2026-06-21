#!/usr/bin/env bash

set -u

fail_count=0
warn_count=0
ok_count=0
skip_count=0
json_output=0
skip_network=0
include_self=0
timeout_seconds=5
config_path=""
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ssh_setup_script="$script_dir/check-ssh-setup.sh"
VALID_HOSTS=()
UNREACHABLE_HOSTS=()

validation_json="[]"
hosts_json="[]"
connections_json="[]"
remote_diagnostics_json="[]"

. "$script_dir/json-helpers.sh"

print_usage() {
  cat <<'EOF'
Usage: check-syncran-config.sh [options] <config.json>

Validate Syncran computer definitions and test SSH reachability.

Options:
  --timeout SECONDS   Timeout for each SSH command. Default: 5
  --json              Emit structured JSON instead of a text report
  --skip-network      Validate only; skip SSH and host-to-host connections
  --include-self      Include self host-to-host connection checks
  -h, --help          Show this help
EOF
}

append_json() {
  section="$1"
  status="$2"
  message="$3"
  if [ "$#" -ge 4 ]; then
    details="$4"
  else
    details="{}"
  fi

  item="$(json_record "$details" "$status" "$message")"

  case "$section" in
    validation) validation_json="$(json_array_append "$validation_json" "$item")" ;;
    hosts) hosts_json="$(json_array_append "$hosts_json" "$item")" ;;
    connections) connections_json="$(json_array_append "$connections_json" "$item")" ;;
    remote_diagnostics) remote_diagnostics_json="$(json_array_append "$remote_diagnostics_json" "$item")" ;;
  esac
}

record() {
  section="$1"
  status="$2"
  message="$3"
  if [ "$#" -ge 4 ]; then
    details="$4"
  else
    details="{}"
  fi
  if [ "$#" -ge 5 ]; then
    fix="$5"
  else
    fix=""
  fi

  case "$status" in
    ok) ok_count=$((ok_count + 1)); prefix="[ok]  " ;;
    warn) warn_count=$((warn_count + 1)); prefix="[warn]" ;;
    fail) fail_count=$((fail_count + 1)); prefix="[fail]" ;;
    skip) skip_count=$((skip_count + 1)); prefix="[skip]" ;;
    *) prefix="[info]" ;;
  esac

  if [ -n "$fix" ]; then
    details="$(json_merge "$details" fix "$fix")"
  fi

  append_json "$section" "$status" "$message" "$details"

  if [ "$json_output" -eq 0 ]; then
    printf '%s %s\n' "$prefix" "$message"
    if [ -n "$fix" ]; then
      printf '       Fix: %s\n' "$fix"
    fi
  fi
}

info() {
  if [ "$json_output" -eq 0 ]; then
    printf '[info] %s\n' "$1"
  fi
}

section() {
  if [ "$json_output" -eq 0 ]; then
    printf '\n%s\n' "$1"
    printf '%s\n' "$1" | sed 's/./-/g'
  fi
}

print_output_block() {
  output="$1"
  if [ "$json_output" -eq 0 ] && [ -n "$output" ]; then
    printf '       Output:\n'
    printf '%s\n' "$output" | sed 's/^/       | /'
  fi
}

append_summary_item() {
  current="$1"
  value="$2"

  if [ -z "$current" ]; then
    printf '%s' "$value"
  else
    printf '%s, %s' "$current" "$value"
  fi
}

summary_value() {
  if [ -n "$1" ]; then
    printf '%s' "$1"
  else
    printf 'none'
  fi
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --timeout)
        shift
        if [ "$#" -eq 0 ]; then
          printf 'Missing value for --timeout\n' >&2
          exit 2
        fi
        timeout_seconds="$1"
        ;;
      --json) json_output=1 ;;
      --skip-network) skip_network=1 ;;
      --include-self) include_self=1 ;;
      -h|--help)
        print_usage
        exit 0
        ;;
      --*)
        printf 'Unknown option: %s\n' "$1" >&2
        print_usage >&2
        exit 2
        ;;
      *)
        if [ -n "$config_path" ]; then
          printf 'Unexpected argument: %s\n' "$1" >&2
          print_usage >&2
          exit 2
        fi
        config_path="$1"
        ;;
    esac
    shift
  done

  if [ -z "$config_path" ]; then
    print_usage >&2
    exit 2
  fi

  case "$timeout_seconds" in
    ''|*[!0-9]*)
      printf 'Timeout must be a positive integer\n' >&2
      exit 2
      ;;
  esac
}

host_detail_json() {
  json_object_nonempty \
    host_key "$1" \
    host "${2:-}" \
    path "${3:-}" \
    source "${4:-}" \
    destination "${5:-}"
}

host_value() {
  host_key="$1"
  host="$(json_value "$config_path" "" hosts "$host_key" host)"
  if [ -n "$host" ]; then
    printf '%s\n' "$host"
  else
    printf 'localhost\n'
  fi
}

ssh_base_args() {
  host_key="$1"
  host="$(host_value "$host_key")"
  port="$(json_value "$config_path" "" hosts "$host_key" port)"

  printf '%s\n' ssh
  printf '%s\n' -o BatchMode=yes
  printf '%s\n' -o NumberOfPasswordPrompts=0
  printf '%s\n' -o PasswordAuthentication=no
  printf '%s\n' -o "ConnectTimeout=$timeout_seconds"
  if [ -n "$port" ]; then
    printf '%s\n' -p "$port"
  fi
  printf '%s\n' "$host"
}

build_ssh_args() {
  host_key="$1"
  no_stdin="${2:-1}"
  host="$(host_value "$host_key")"
  port="$(json_value "$config_path" "" hosts "$host_key" port)"

  SSH_ARGS=(ssh)
  if [ "$no_stdin" -eq 1 ]; then
    SSH_ARGS+=(-n)
  fi
  SSH_ARGS+=(-o BatchMode=yes -o NumberOfPasswordPrompts=0 -o PasswordAuthentication=no -o "ConnectTimeout=$timeout_seconds")
  if [ -n "$port" ]; then
    SSH_ARGS+=(-p "$port")
  fi
  SSH_ARGS+=("$host")
}

run_with_timeout() {
  if command_exists timeout; then
    timeout "$((timeout_seconds + 2))" "$@"
  elif command_exists gtimeout; then
    gtimeout "$((timeout_seconds + 2))" "$@"
  else
    "$@"
  fi
}

is_local_host_value() {
  value="$1"
  target="${value##*@}"
  short_hostname="$(hostname -s 2>/dev/null || true)"
  full_hostname="$(hostname -f 2>/dev/null || hostname 2>/dev/null || true)"

  case "$target" in
    localhost|127.0.0.1|::1) return 0 ;;
    "$short_hostname"|"$full_hostname") return 0 ;;
    *) return 1 ;;
  esac
}

is_local_host_key() {
  host="$(host_value "$1")"
  is_local_host_value "$host"
}

remote_shell_quote() {
  quoted=""
  for arg in "$@"; do
    escaped="$(printf "%s" "$arg" | sed "s/'/'\\\\''/g")"
    if [ -z "$quoted" ]; then
      quoted="'$escaped'"
    else
      quoted="$quoted '$escaped'"
    fi
  done
  printf '%s\n' "$quoted"
}

validate_file() {
  if [ ! -e "$config_path" ]; then
    record validation fail "$config_path does not exist" "{}" "Choose an existing Syncran config JSON file."
    return 1
  fi

  if [ ! -f "$config_path" ]; then
    record validation fail "$config_path is not a file" "{}" "Pass a JSON config file path, not a directory."
    return 1
  fi

  if ! json_validate "$config_path" >/dev/null 2>&1; then
    record validation fail "Config is not valid JSON" "{}" "Fix the JSON syntax and try again."
    return 1
  fi

  if [ "$(json_type "$config_path")" != "object" ]; then
    record validation fail "Config root must be a JSON object" "{}" "Use an object with comp_array and hosts fields."
    return 1
  fi

  record validation ok "Config file is readable JSON"
}

validate_shape() {
  VALID_HOSTS=()
  UNREACHABLE_HOSTS=()

  if [ "$(json_type "$config_path" comp_array)" != "array" ] || ! json_array_all_strings "$config_path" comp_array; then
    record validation fail "comp_array must be an array of host keys" "{}" 'Set comp_array to something like ["mac", "nas"].'
  else
    count="$(json_len "$config_path" comp_array)"
    record validation ok "comp_array contains $count host key(s)"
  fi

  if [ "$(json_type "$config_path" hosts)" != "object" ] || [ "$(json_len "$config_path" hosts)" -eq 0 ]; then
    record validation fail "hosts must be a non-empty object" "{}" "Add at least one host under the hosts object."
  else
    count="$(json_len "$config_path" hosts)"
    record validation ok "hosts contains $count host definition(s)"
  fi

  while IFS= read -r host_key; do
    if ! json_has "$config_path" hosts "$host_key"; then
      record validation fail "comp_array references missing host '$host_key'" \
        "$(host_detail_json "$host_key")" \
        "Add hosts.$host_key or remove it from comp_array."
    fi
  done < <(json_array_values "$config_path" comp_array)

  while IFS= read -r host_key; do
    if ! json_array_contains "$config_path" "$host_key" comp_array; then
      record validation warn "Host '$host_key' is not listed in comp_array" \
        "$(host_detail_json "$host_key")" \
        "Add it to comp_array if it should appear in job configuration order."
    fi
  done < <(json_keys "$config_path" hosts)

  while IFS= read -r host_key; do
    host_type="$(json_type "$config_path" hosts "$host_key")"
    if [ "$host_type" != "object" ]; then
      record hosts fail "Host '$host_key' must be an object" \
        "$(host_detail_json "$host_key")" \
        "Replace this host entry with an object containing an optional host value and port."
      continue
    fi

    host="$(json_value "$config_path" "" hosts "$host_key" host)"
    port_type="$(json_type "$config_path" hosts "$host_key" port)"

    if [ -z "$host" ]; then
      record hosts warn "Host '$host_key' has no host value; treating it as this computer" \
        "$(host_detail_json "$host_key")" \
        'Set host to an SSH hostname or alias if this is not the local computer.'
      host="localhost"
    fi

    if [ "$port_type" != "null" ] && [ "$port_type" != "missing" ] && ! json_port_valid "$config_path" hosts "$host_key" port; then
      record hosts fail "Host '$host_key' has an invalid port" \
        "$(host_detail_json "$host_key" "$host")" \
        "Use an integer port between 1 and 65535, or remove the port field."
      continue
    fi

    VALID_HOSTS+=("$host_key")
    record hosts ok "Host '$host_key' is structurally valid" "$(host_detail_json "$host_key" "$host")"
  done < <(json_keys "$config_path" hosts)

  valid_host_count="${#VALID_HOSTS[@]}"
  if [ "$valid_host_count" -eq 0 ]; then
    record validation fail "No valid host definitions are available for connection checks" "{}" "Fix the host definitions above, then rerun this diagnostic."
  else
    info "Queued valid hosts for network checks: ${VALID_HOSTS[*]}"
  fi
}

check_local_tools() {
  section "Local tools"
  for tool in ssh; do
    if command_exists "$tool"; then
      record validation ok "$tool found at $(command -v "$tool")" "$(json_object tool "$tool" path "$(command -v "$tool")")"
    else
      record validation fail "$tool is not installed or is not on PATH" "$(json_object tool "$tool")" "Install $tool and make sure it is available on PATH."
    fi
  done
}

check_host_reachability() {
  host_key="$1"
  host="$(host_value "$host_key")"
  if is_local_host_key "$host_key"; then
    record hosts ok "Host '$host_key' resolves to this computer" "$(host_detail_json "$host_key" "$host")"
    return 0
  fi

  build_ssh_args "$host_key"
  output="$(run_with_timeout "${SSH_ARGS[@]}" true 2>&1)"
  status=$?
  if [ "$status" -eq 0 ]; then
    record hosts ok "Local computer can SSH to '$host_key' ($host)" "$(host_detail_json "$host_key" "$host")"
    return 0
  else
    UNREACHABLE_HOSTS+=("$host_key")
    record hosts fail "Local computer cannot SSH to '$host_key' ($host)" \
      "$(json_object host_key "$host_key" host "$host" output "$output")" \
      "Check the SSH host alias, network reachability, key authorization, and known_hosts entry."
    print_output_block "$output"
    return 1
  fi
}

host_is_unreachable() {
  host_key="$1"
  if [ "${#UNREACHABLE_HOSTS[@]}" -eq 0 ]; then
    return 1
  fi

  for unreachable_host in "${UNREACHABLE_HOSTS[@]}"; do
    if [ "$unreachable_host" = "$host_key" ]; then
      return 0
    fi
  done

  return 1
}

check_connection() {
  source_key="$1"
  dest_key="$2"
  source_host="$(host_value "$source_key")"
  dest_host="$(host_value "$dest_key")"

  if [ "$source_key" = "$dest_key" ]; then
    record connections skip "Skipping self connection '$source_key' -> '$dest_key'" "$(host_detail_json "" "" "" "$source_key" "$dest_key")"
    return
  fi

  if is_local_host_key "$source_key" && is_local_host_key "$dest_key"; then
    record connections ok "Connection '$source_key' -> '$dest_key' stays on this computer" "$(host_detail_json "" "" "" "$source_key" "$dest_key")"
    return
  fi

  if is_local_host_key "$source_key"; then
    if host_is_unreachable "$dest_key"; then
      record connections skip "Skipping '$source_key' -> '$dest_key' because '$dest_key' is not reachable from this computer" \
        "$(host_detail_json "" "" "" "$source_key" "$dest_key")" \
        "Fix SSH from this computer to '$dest_host', then rerun this diagnostic."
      return
    fi
    build_ssh_args "$dest_key"
    COMMAND_ARGS=("${SSH_ARGS[@]}" true)
    success_message="Local source '$source_key' can SSH to destination '$dest_key'"
    fail_message="Local source '$source_key' cannot SSH to destination '$dest_key'"
  else
    if host_is_unreachable "$source_key"; then
      record connections skip "Skipping '$source_key' -> '$dest_key' because '$source_key' is not reachable from this computer" \
        "$(host_detail_json "" "" "" "$source_key" "$dest_key")" \
        "Fix SSH from this computer to '$source_host', then rerun this diagnostic."
      return
    fi
    build_ssh_args "$source_key"
    SOURCE_SSH_ARGS=("${SSH_ARGS[@]}")
    build_ssh_args "$dest_key"
    DEST_SSH_ARGS=("${SSH_ARGS[@]}" true)
    COMMAND_ARGS=("${SOURCE_SSH_ARGS[@]}" "$(remote_shell_quote "${DEST_SSH_ARGS[@]}")")
    success_message="Source '$source_key' can SSH directly to destination '$dest_key'"
    fail_message="Source '$source_key' cannot SSH directly to destination '$dest_key'"
  fi

  output="$(run_with_timeout "${COMMAND_ARGS[@]}" 2>&1)"
  status=$?

  if [ "$status" -eq 0 ]; then
    record connections ok "$success_message" "$(json_object source "$source_key" destination "$dest_key" source_host "$source_host" destination_host "$dest_host")"
  else
    record connections fail "$fail_message" \
      "$(json_object source "$source_key" destination "$dest_key" source_host "$source_host" destination_host "$dest_host" output "$output")" \
      "Make sure '$source_key' can SSH to '$dest_host' without a password. For remote-to-remote backups, authorize the source host's SSH key on the destination."
    print_output_block "$output"
  fi
}

check_remote_ssh_setup() {
  host_key="$1"
  host="$(host_value "$host_key")"

  if [ ! -f "$ssh_setup_script" ]; then
    record remote_diagnostics fail "Cannot find SSH diagnostic script at $ssh_setup_script" \
      "$(host_detail_json "$host_key" "$host")" \
      "Make sure check-ssh-setup.sh exists next to this script."
    return
  fi

  if is_local_host_key "$host_key"; then
    output="$(bash "$ssh_setup_script" --ssh-only 2>&1)"
  else
    build_ssh_args "$host_key" 0
    output="$(run_with_timeout "${SSH_ARGS[@]}" "bash -s -- --ssh-only" < "$ssh_setup_script" 2>&1)"
  fi
  status=$?

  if [ "$status" -eq 0 ]; then
    record remote_diagnostics ok "SSH setup diagnostic passed on '$host_key'" \
      "$(json_object host_key "$host_key" host "$host" output "$output")"
  else
    record remote_diagnostics fail "SSH setup diagnostic found issues on '$host_key'" \
      "$(json_object host_key "$host_key" host "$host" output "$output")" \
      "Review the diagnostic output for missing tools, bad ~/.ssh permissions, missing keys, or agent setup."
    if [ "$json_output" -eq 0 ] && [ -n "$output" ]; then
      print_output_block "$output"
    fi
  fi
}

run_network_checks() {
  check_local_tools

  section "Hosts"
  for host_key in "${VALID_HOSTS[@]}"; do
    info "Testing host '$host_key' ($(host_value "$host_key"))"
    check_host_reachability "$host_key"
  done

  section "Remote SSH diagnostics"
  for host_key in "${VALID_HOSTS[@]}"; do
    info "Running SSH setup diagnostic for '$host_key' ($(host_value "$host_key"))"
    if host_is_unreachable "$host_key"; then
      record remote_diagnostics skip "Skipping SSH setup diagnostic on '$host_key' because SSH is not reachable" \
        "$(host_detail_json "$host_key" "$(host_value "$host_key")")" \
        "Fix SSH first, then rerun this diagnostic."
    else
      check_remote_ssh_setup "$host_key"
    fi
  done

  section "Connections"
  for source_key in "${VALID_HOSTS[@]}"; do
    for dest_key in "${VALID_HOSTS[@]}"; do
      if [ "$include_self" -eq 0 ] && [ "$source_key" = "$dest_key" ]; then
        continue
      fi
      info "Testing connection '$source_key' -> '$dest_key'"
      check_connection "$source_key" "$dest_key"
    done
  done
}

finish() {
  if [ "$json_output" -eq 1 ]; then
    json_report \
      "check-syncran-config" \
      "$config_path" \
      "$validation_json" \
      "$hosts_json" \
      "$connections_json" \
      "$remote_diagnostics_json" \
      "$ok_count" \
      "$warn_count" \
      "$fail_count" \
      "$skip_count"
  else
    section "Summary"
    if [ "${valid_host_count:-0}" -gt 0 ]; then
      hosts_tested_text=""
      reachable_hosts_text=""
      unreachable_hosts_text=""
      local_hosts_text=""
      untested_hosts_text=""

      for host_key in "${VALID_HOSTS[@]}"; do
        hosts_tested_text="$(append_summary_item "$hosts_tested_text" "$host_key")"
        if is_local_host_key "$host_key"; then
          local_hosts_text="$(append_summary_item "$local_hosts_text" "$host_key")"
        elif [ "$skip_network" -eq 1 ]; then
          untested_hosts_text="$(append_summary_item "$untested_hosts_text" "$host_key")"
        elif host_is_unreachable "$host_key"; then
          unreachable_hosts_text="$(append_summary_item "$unreachable_hosts_text" "$host_key")"
        else
          reachable_hosts_text="$(append_summary_item "$reachable_hosts_text" "$host_key")"
        fi
      done

      printf 'Hosts tested: %s\n' "$(summary_value "$hosts_tested_text")"
      printf 'Reachable by SSH from this computer: %s\n' "$(summary_value "$reachable_hosts_text")"
      printf 'Local hosts: %s\n' "$(summary_value "$local_hosts_text")"
      printf 'Not reachable from this computer: %s\n' "$(summary_value "$unreachable_hosts_text")"
      if [ "$skip_network" -eq 1 ]; then
        printf 'Reachability not tested: %s\n' "$(summary_value "$untested_hosts_text")"
      fi
      printf '\n'

      connection_ok="$(json_connection_pairs "$connections_json" ok 0)"
      connection_fail="$(json_connection_pairs "$connections_json" fail 0)"
      connection_skip="$(json_connection_pairs "$connections_json" skip 1)"

      printf 'Host-to-host connections working: %s\n' "${connection_ok:-none}"
      printf 'Host-to-host connections failing: %s\n' "${connection_fail:-none}"
      printf 'Host-to-host connections skipped: %s\n' "${connection_skip:-none}"
      printf '\n'

      remote_diag_ok="$(json_host_keys_by_status "$remote_diagnostics_json" ok)"
      remote_diag_fail="$(json_host_keys_by_status "$remote_diagnostics_json" fail)"
      remote_diag_skip="$(json_host_keys_by_status "$remote_diagnostics_json" skip)"

      printf 'SSH setup diagnostics passed: %s\n' "${remote_diag_ok:-none}"
      printf 'SSH setup diagnostics with issues: %s\n' "${remote_diag_fail:-none}"
      printf 'SSH setup diagnostics skipped: %s\n' "${remote_diag_skip:-none}"
      printf '\n'
    fi

    if [ "$fail_count" -eq 0 ] && [ "$warn_count" -eq 0 ]; then
      printf '[ok]   No Syncran config issues found'
    elif [ "$fail_count" -eq 0 ]; then
      printf '[warn] %s warning(s), no failures' "$warn_count"
    else
      printf '[fail] %s failure(s), %s warning(s), %s skipped check(s)' "$fail_count" "$warn_count" "$skip_count"
    fi

    printf ' | ok: %s, warn: %s, fail: %s, skipped: %s\n' "$ok_count" "$warn_count" "$fail_count" "$skip_count"
  fi

  [ "$fail_count" -eq 0 ]
}

parse_args "$@"
require_json_helper

if [ "$json_output" -eq 0 ]; then
  printf 'Syncran config diagnostics\n'
  printf '==========================\n\n'
  printf 'Config: %s\n' "$config_path"
fi

section "Validation"
if validate_file; then
  validate_shape
fi

if [ "${valid_host_count:-0}" -gt 0 ]; then
  if [ "$skip_network" -eq 1 ]; then
    record connections skip "Network checks skipped by --skip-network" "{}" "Run without --skip-network to test SSH and host-to-host connections."
  else
    run_network_checks
  fi
fi

finish
