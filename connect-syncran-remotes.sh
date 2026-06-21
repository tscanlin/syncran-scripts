#!/usr/bin/env bash

set -u

config_path=""
source_filter=""
dest_filter=""
all_pairs=0
yes=0
dry_run=0
timeout_seconds=8
remote_key_name="syncran_remote_ed25519"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

VALID_HOSTS=()

. "$script_dir/json-helpers.sh"

print_usage() {
  cat <<'EOF'
Usage: connect-syncran-remotes.sh [options] <config.json>

Use working local SSH access to make Syncran remote hosts trust each other for
direct remote-to-remote syncs. This script never copies private keys between
machines. It generates or reuses a dedicated key on the source host, installs
that public key on the destination host, and adds a Syncran-managed SSH config
block on the source host for the destination.

Options:
  --source HOST_KEY   Source host key from config
  --dest HOST_KEY     Destination host key from config
  --all              Configure every non-local ordered remote-to-remote pair
  --key-name NAME    Remote key filename under ~/.ssh. Default: syncran_remote_ed25519
  --timeout SECONDS  SSH connect timeout. Default: 8
  --yes              Do not ask for confirmation
  --dry-run          Print what would happen without changing remote hosts
  -h, --help         Show this help
EOF
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

require_tool() {
  if ! command_exists "$1"; then
    printf '[fail] %s is required\n' "$1" >&2
    exit 1
  fi
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --source)
        shift
        [ "$#" -gt 0 ] || { printf 'Missing value for --source\n' >&2; exit 2; }
        source_filter="$1"
        ;;
      --dest|--destination)
        shift
        [ "$#" -gt 0 ] || { printf 'Missing value for --dest\n' >&2; exit 2; }
        dest_filter="$1"
        ;;
      --all) all_pairs=1 ;;
      --key-name)
        shift
        [ "$#" -gt 0 ] || { printf 'Missing value for --key-name\n' >&2; exit 2; }
        remote_key_name="$1"
        ;;
      --timeout)
        shift
        [ "$#" -gt 0 ] || { printf 'Missing value for --timeout\n' >&2; exit 2; }
        timeout_seconds="$1"
        ;;
      --yes) yes=1 ;;
      --dry-run) dry_run=1 ;;
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

  if [ "$all_pairs" -eq 0 ] && { [ -z "$source_filter" ] || [ -z "$dest_filter" ]; }; then
    printf 'Choose --source HOST_KEY --dest HOST_KEY, or use --all.\n' >&2
    exit 2
  fi
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

host_port() {
  json_value "$config_path" "" hosts "$1" port
}

host_user() {
  host="$(host_value "$1")"
  case "$host" in
    *@*) printf '%s\n' "${host%@*}" ;;
    *) printf '%s\n' "" ;;
  esac
}

host_name_only() {
  host="$(host_value "$1")"
  printf '%s\n' "${host##*@}"
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
  is_local_host_value "$(host_value "$1")"
}

sq() {
  escaped="$(printf "%s" "$1" | sed "s/'/'\\\\''/g")"
  printf "'%s'" "$escaped"
}

build_ssh_args() {
  host_key="$1"
  no_stdin="${2:-1}"
  host="$(host_value "$host_key")"
  port="$(host_port "$host_key")"

  SSH_ARGS=(ssh)
  if [ "$no_stdin" -eq 1 ]; then
    SSH_ARGS+=(-n)
  fi
  SSH_ARGS+=(-o "ConnectTimeout=$timeout_seconds")
  if [ -n "$port" ]; then
    SSH_ARGS+=(-p "$port")
  fi
  SSH_ARGS+=("$host")
}

confirm() {
  prompt="$1"
  if [ "$yes" -eq 1 ] || [ "$dry_run" -eq 1 ]; then
    return 0
  fi

  printf '%s [y/N] ' "$prompt"
  read answer
  case "$answer" in
    y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

ensure_host_exists() {
  host_key="$1"
  if ! json_has "$config_path" hosts "$host_key"; then
    printf '[fail] Host %s is not in %s\n' "$host_key" "$config_path" >&2
    exit 1
  fi
}

load_valid_hosts() {
  VALID_HOSTS=()
  while IFS= read -r host_key; do
    VALID_HOSTS+=("$host_key")
  done < <(json_keys "$config_path" hosts)
}

test_local_access() {
  host_key="$1"
  if is_local_host_key "$host_key"; then
    return 0
  fi

  build_ssh_args "$host_key"
  "${SSH_ARGS[@]}" true >/dev/null 2>&1
}

ensure_source_key_and_read_pubkey() {
  source_key="$1"
  key_path="\$HOME/.ssh/$remote_key_name"

  if [ "$dry_run" -eq 1 ]; then
    printf '[dry-run] Would ensure dedicated key exists on %s at ~/.ssh/%s\n' "$source_key" "$remote_key_name" >&2
    printf 'dry-run-public-key-for-%s\n' "$source_key"
    return 0
  fi

  build_ssh_args "$source_key"
  "${SSH_ARGS[@]}" "
    set -e
    umask 077
    mkdir -p \"\$HOME/.ssh\"
    if [ ! -f \"$key_path\" ]; then
      ssh-keygen -t ed25519 -N '' -f \"$key_path\" -C \"syncran-$source_key-\$(hostname -s 2>/dev/null || hostname)\" >/dev/null
    fi
    if [ ! -f \"$key_path.pub\" ]; then
      ssh-keygen -y -f \"$key_path\" > \"$key_path.pub\"
    fi
    chmod 700 \"\$HOME/.ssh\"
    chmod 600 \"$key_path\"
    chmod 644 \"$key_path.pub\"
    cat \"$key_path.pub\"
  "
}

install_pubkey_on_destination() {
  dest_key="$1"
  public_key="$2"

  if [ "$dry_run" -eq 1 ]; then
    printf '[dry-run] Would install source public key into %s:~/.ssh/authorized_keys\n' "$dest_key"
    return 0
  fi

  build_ssh_args "$dest_key" 0
  printf '%s\n' "$public_key" | "${SSH_ARGS[@]}" '
    set -e
    umask 077
    mkdir -p "$HOME/.ssh"
    touch "$HOME/.ssh/authorized_keys"
    read key
    grep -qxF "$key" "$HOME/.ssh/authorized_keys" || printf "%s\n" "$key" >> "$HOME/.ssh/authorized_keys"
    chmod 700 "$HOME/.ssh"
    chmod 600 "$HOME/.ssh/authorized_keys"
  '
}

configure_source_for_destination() {
  source_key="$1"
  dest_key="$2"
  dest_host_name="$(host_name_only "$dest_key")"
  dest_user="$(host_user "$dest_key")"
  dest_port="$(host_port "$dest_key")"

  config_block="Host $dest_key $dest_host_name
  HostName $dest_host_name
  IdentityFile ~/.ssh/$remote_key_name
  IdentitiesOnly yes"

  if [ -n "$dest_user" ]; then
    config_block="$config_block
  User $dest_user"
  fi

  if [ -n "$dest_port" ]; then
    config_block="$config_block
  Port $dest_port"
  fi

  if [ "$dry_run" -eq 1 ]; then
    printf '[dry-run] Would add/update this SSH config block on %s:\n%s\n' "$source_key" "$config_block"
    return 0
  fi

  build_ssh_args "$source_key" 0
  marker_start="# >>> syncran $dest_key"
  marker_end="# <<< syncran $dest_key"
  payload="$marker_start
$config_block
$marker_end"

  printf '%s\n' "$payload" | "${SSH_ARGS[@]}" "
    set -e
    umask 077
    mkdir -p \"\$HOME/.ssh\"
    touch \"\$HOME/.ssh/config\"
    tmp=\"\$HOME/.ssh/config.syncran.tmp\"
    awk -v start=$(sq "$marker_start") -v end=$(sq "$marker_end") '
      \$0 == start { skip = 1; next }
      \$0 == end { skip = 0; next }
      skip != 1 { print }
    ' \"\$HOME/.ssh/config\" > \"\$tmp\"
    cat >> \"\$tmp\"
    mv \"\$tmp\" \"\$HOME/.ssh/config\"
    chmod 700 \"\$HOME/.ssh\"
    chmod 600 \"\$HOME/.ssh/config\"
  "
}

test_remote_to_remote() {
  source_key="$1"
  dest_key="$2"
  dest_host="$(host_value "$dest_key")"

  if [ "$dry_run" -eq 1 ]; then
    printf '[dry-run] Would test %s -> %s with ssh %s true\n' "$source_key" "$dest_key" "$dest_host"
    return 0
  fi

  build_ssh_args "$source_key"
  "${SSH_ARGS[@]}" "ssh -o BatchMode=yes -o NumberOfPasswordPrompts=0 -o ConnectTimeout=$timeout_seconds $(sq "$dest_host") true"
}

connect_pair() {
  source_key="$1"
  dest_key="$2"

  if [ "$source_key" = "$dest_key" ]; then
    printf '[skip] %s -> %s is the same host\n' "$source_key" "$dest_key"
    return 0
  fi

  if is_local_host_key "$source_key" || is_local_host_key "$dest_key"; then
    printf '[skip] %s -> %s is not a remote-to-remote pair\n' "$source_key" "$dest_key"
    return 0
  fi

  printf '\n%s -> %s\n' "$source_key" "$dest_key"
  printf '%s\n' "----------------"

  if [ "$dry_run" -eq 0 ]; then
    if ! test_local_access "$source_key"; then
      printf '[fail] Local computer cannot SSH to source %s (%s)\n' "$source_key" "$(host_value "$source_key")"
      return 1
    fi

    if ! test_local_access "$dest_key"; then
      printf '[fail] Local computer cannot SSH to destination %s (%s)\n' "$dest_key" "$(host_value "$dest_key")"
      return 1
    fi
  fi

  if ! confirm "Allow changes on $source_key and $dest_key for direct SSH?"; then
    printf '[skip] Not changing %s -> %s\n' "$source_key" "$dest_key"
    return 0
  fi

  public_key="$(ensure_source_key_and_read_pubkey "$source_key")" || return 1
  install_pubkey_on_destination "$dest_key" "$public_key" || return 1
  configure_source_for_destination "$source_key" "$dest_key" || return 1

  if [ "$dry_run" -eq 1 ]; then
    test_remote_to_remote "$source_key" "$dest_key"
    printf '[dry-run] Would configure %s to SSH directly to %s\n' "$source_key" "$dest_key"
    return 0
  fi

  if test_remote_to_remote "$source_key" "$dest_key"; then
    printf '[ok]   %s can SSH directly to %s\n' "$source_key" "$dest_key"
  else
    printf '[fail] %s still cannot SSH directly to %s\n' "$source_key" "$dest_key"
    printf '       Check network routing, destination sshd settings, and source ~/.ssh/config.\n'
    return 1
  fi
}

main() {
  parse_args "$@"
  require_json_helper
  require_tool ssh

  if ! json_validate "$config_path" >/dev/null 2>&1; then
    printf '[fail] Config is not valid JSON: %s\n' "$config_path" >&2
    exit 1
  fi

  load_valid_hosts

  failures=0
  if [ "$all_pairs" -eq 1 ]; then
    for source_key in "${VALID_HOSTS[@]}"; do
      for dest_key in "${VALID_HOSTS[@]}"; do
        connect_pair "$source_key" "$dest_key" || failures=$((failures + 1))
      done
    done
  else
    ensure_host_exists "$source_filter"
    ensure_host_exists "$dest_filter"
    connect_pair "$source_filter" "$dest_filter" || failures=$((failures + 1))
  fi

  if [ "$failures" -eq 0 ]; then
    printf '\n[ok]   Remote-to-remote setup completed\n'
  else
    printf '\n[fail] %s remote-to-remote setup task(s) failed\n' "$failures"
    exit 1
  fi
}

main "$@"
