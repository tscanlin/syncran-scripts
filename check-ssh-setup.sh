#!/usr/bin/env bash

set -u

fail_count=0
warn_count=0
ssh_only=0

print_line() {
  printf '%s\n' "$*"
}

ok() {
  print_line "[ok]   $*"
}

warn() {
  warn_count=$((warn_count + 1))
  print_line "[warn] $*"
}

fail() {
  fail_count=$((fail_count + 1))
  print_line "[fail] $*"
}

info() {
  print_line "[info] $*"
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

print_usage() {
  cat <<'EOF'
Usage: check-ssh-setup.sh [options]

Check local SSH tools, config, permissions, keys, and agent setup.

Options:
  --ssh-only   Skip transfer-tool checks and only report SSH setup
  -h, --help   Show this help
EOF
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --ssh-only) ssh_only=1 ;;
      -h|--help)
        print_usage
        exit 0
        ;;
      *)
        printf 'Unknown option: %s\n' "$1" >&2
        print_usage >&2
        exit 2
        ;;
    esac
    shift
  done
}

file_mode() {
  if stat -f '%Lp' "$1" >/dev/null 2>&1; then
    stat -f '%Lp' "$1"
  elif stat -c '%a' "$1" >/dev/null 2>&1; then
    stat -c '%a' "$1"
  else
    printf 'unknown'
  fi
}

file_owner() {
  if stat -f '%Su' "$1" >/dev/null 2>&1; then
    stat -f '%Su' "$1"
  elif stat -c '%U' "$1" >/dev/null 2>&1; then
    stat -c '%U' "$1"
  else
    printf 'unknown'
  fi
}

mode_is_no_more_open_than() {
  mode="$1"
  max="$2"

  case "$mode" in
    ''|unknown) return 1 ;;
  esac

  mode_dec=$((8#$mode))
  max_dec=$((8#$max))
  [ "$mode_dec" -le "$max_dec" ]
}

check_required_tool() {
  tool="$1"
  if command_exists "$tool"; then
    ok "$tool found at $(command -v "$tool")"
  else
    fail "$tool is not installed or is not on PATH"
  fi
}

check_optional_tool() {
  tool="$1"
  if command_exists "$tool"; then
    ok "$tool found at $(command -v "$tool")"
  else
    warn "$tool is not installed or is not on PATH"
  fi
}

check_path_mode() {
  path="$1"
  max_mode="$2"
  label="$3"

  mode="$(file_mode "$path")"
  if mode_is_no_more_open_than "$mode" "$max_mode"; then
    ok "$label permissions are $mode"
  else
    fail "$label permissions are $mode; expected $max_mode or stricter"
  fi
}

parse_args "$@"

print_line "Syncran SSH setup diagnostics"
print_line "============================"
print_line ""

info "User: $(id -un 2>/dev/null || printf 'unknown')"
info "Home: ${HOME:-unknown}"
print_line ""

print_line "Tools"
print_line "-----"
check_required_tool ssh
check_required_tool ssh-keygen
if [ "$ssh_only" -eq 0 ]; then
  check_required_tool rsync
fi
check_optional_tool scp
check_optional_tool ssh-add
print_line ""

ssh_dir="${HOME:-}/.ssh"
print_line "SSH directory"
print_line "-------------"
if [ -z "${HOME:-}" ]; then
  fail "HOME is not set"
elif [ -d "$ssh_dir" ]; then
  ok "$ssh_dir exists"
  check_path_mode "$ssh_dir" 700 "~/.ssh"

  owner="$(file_owner "$ssh_dir")"
  current_user="$(id -un 2>/dev/null || printf 'unknown')"
  if [ "$owner" = "$current_user" ]; then
    ok "~/.ssh is owned by $owner"
  else
    warn "~/.ssh is owned by $owner; current user is $current_user"
  fi
else
  fail "$ssh_dir does not exist"
fi
print_line ""

print_line "SSH config"
print_line "----------"
config_file="$ssh_dir/config"
if [ -f "$config_file" ]; then
  ok "$config_file exists"
  check_path_mode "$config_file" 600 "~/.ssh/config"

  host_count="$(awk 'tolower($1) == "host" { for (i = 2; i <= NF; i++) if ($i != "*") count++ } END { print count + 0 }' "$config_file" 2>/dev/null || printf '0')"
  if [ "$host_count" -gt 0 ]; then
    ok "Found $host_count explicit Host entr$( [ "$host_count" -eq 1 ] && printf 'y' || printf 'ies' )"
  else
    warn "No explicit Host entries found in ~/.ssh/config"
  fi

  if ssh -G example.invalid -F "$config_file" >/dev/null 2>&1; then
    ok "ssh can parse ~/.ssh/config"
  else
    warn "ssh reported an issue parsing ~/.ssh/config"
  fi
else
  warn "$config_file does not exist; host aliases may not be configured"
fi
print_line ""

print_line "Known hosts"
print_line "-----------"
known_hosts="$ssh_dir/known_hosts"
if [ -f "$known_hosts" ]; then
  ok "$known_hosts exists"
  check_path_mode "$known_hosts" 644 "~/.ssh/known_hosts"
else
  warn "$known_hosts does not exist yet"
fi
print_line ""

print_line "Keys"
print_line "----"
if [ -d "$ssh_dir" ]; then
  key_count=0
  bad_key_count=0
  for key_file in "$ssh_dir"/id_* "$ssh_dir"/*.pem; do
    [ -e "$key_file" ] || continue
    [ -f "$key_file" ] || continue
    case "$key_file" in
      *.pub|*known_hosts*|*config*) continue ;;
    esac

    key_count=$((key_count + 1))
    mode="$(file_mode "$key_file")"
    if mode_is_no_more_open_than "$mode" 600; then
      ok "Private key $(basename "$key_file") permissions are $mode"
    else
      bad_key_count=$((bad_key_count + 1))
      fail "Private key $(basename "$key_file") permissions are $mode; expected 600 or stricter"
    fi
  done

  if [ "$key_count" -eq 0 ]; then
    warn "No private keys found in ~/.ssh"
  elif [ "$bad_key_count" -eq 0 ]; then
    ok "Checked $key_count private key file$( [ "$key_count" -eq 1 ] || printf 's' )"
  fi
else
  warn "Skipping key checks because ~/.ssh is missing"
fi
print_line ""

print_line "SSH agent"
print_line "---------"
if [ -n "${SSH_AUTH_SOCK:-}" ]; then
  ok "SSH_AUTH_SOCK is set"
  if command_exists ssh-add; then
    agent_output="$(ssh-add -l 2>&1)"
    agent_status=$?
    if [ "$agent_status" -eq 0 ]; then
      ok "ssh-agent has loaded identities"
      printf '%s\n' "$agent_output" | sed 's/^/[info]   /'
    elif [ "$agent_status" -eq 1 ]; then
      warn "ssh-agent is reachable but has no loaded identities"
    else
      warn "ssh-add could not query the agent: $agent_output"
    fi
  fi
else
  warn "SSH_AUTH_SOCK is not set; ssh-agent may not be running"
fi
print_line ""

print_line "Summary"
print_line "-------"
if [ "$fail_count" -eq 0 ] && [ "$warn_count" -eq 0 ]; then
  ok "No local SSH setup issues found"
elif [ "$fail_count" -eq 0 ]; then
  warn "$warn_count warning$( [ "$warn_count" -eq 1 ] || printf 's' ), no failures"
else
  fail "$fail_count failure$( [ "$fail_count" -eq 1 ] || printf 's' ) and $warn_count warning$( [ "$warn_count" -eq 1 ] || printf 's' ) found"
fi

[ "$fail_count" -eq 0 ]
