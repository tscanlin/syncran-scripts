#!/usr/bin/env bash

set -u

config_path=""
host_filter=""
all_hosts=0
yes=0
dry_run=0
key_path="${HOME:-}/.ssh/id_ed25519"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOSTS_TO_SETUP=()

. "$script_dir/json-helpers.sh"

print_usage() {
  cat <<'EOF'
Usage: setup-syncran-initial-ssh.sh [options] <config.json>

Install this computer's SSH public key on Syncran hosts so local-to-remote
connections can work. This script may prompt for each remote user's password.

Options:
  --host HOST_KEY     Only set up one host from the config
  --all              Set up all non-local hosts in the config
  --key PATH         Local private key path to use. Default: ~/.ssh/id_ed25519
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
      --host)
        shift
        [ "$#" -gt 0 ] || { printf 'Missing value for --host\n' >&2; exit 2; }
        host_filter="$1"
        ;;
      --all) all_hosts=1 ;;
      --key)
        shift
        [ "$#" -gt 0 ] || { printf 'Missing value for --key\n' >&2; exit 2; }
        key_path="$1"
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

  if [ -z "$host_filter" ] && [ "$all_hosts" -eq 0 ]; then
    printf 'Choose --host HOST_KEY or --all.\n' >&2
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

confirm() {
  prompt="$1"
  if [ "$yes" -eq 1 ]; then
    return 0
  fi

  printf '%s [y/N] ' "$prompt"
  read answer
  case "$answer" in
    y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

ensure_local_key() {
  pub_key_path="$key_path.pub"

  if [ -f "$key_path" ] && [ -f "$pub_key_path" ]; then
    return 0
  fi

  if [ -f "$key_path" ] && [ ! -f "$pub_key_path" ]; then
    if [ "$dry_run" -eq 1 ]; then
      printf '[dry-run] Would derive public key at %s\n' "$pub_key_path"
      return 0
    fi

    ssh-keygen -y -f "$key_path" > "$pub_key_path"
    chmod 644 "$pub_key_path"
    return 0
  fi

  if [ "$dry_run" -eq 1 ]; then
    printf '[dry-run] Would generate local SSH key at %s\n' "$key_path"
    return 0
  fi

  if ! confirm "Generate a local SSH key at $key_path?"; then
    printf '[fail] Local SSH key is required.\n' >&2
    exit 1
  fi

  mkdir -p "$(dirname "$key_path")"
  chmod 700 "$(dirname "$key_path")"
  ssh-keygen -t ed25519 -N '' -f "$key_path" -C "syncran-local-$(hostname -s 2>/dev/null || hostname)"
}

install_key_on_host() {
  host_key="$1"
  host="$(host_value "$host_key")"
  port="$(host_port "$host_key")"
  pub_key_path="$key_path.pub"

  if is_local_host_value "$host"; then
    printf '[skip] %s resolves to this computer\n' "$host_key"
    return 0
  fi

  ssh_args=(ssh)
  if [ -n "$port" ]; then
    ssh_args+=(-p "$port")
  fi
  ssh_args+=("$host")

  printf '[info] Installing local public key on %s (%s)\n' "$host_key" "$host"
  if [ "$dry_run" -eq 1 ]; then
    printf '[dry-run] Would append %s to %s:~/.ssh/authorized_keys\n' "$pub_key_path" "$host"
    return 0
  fi

  if ! confirm "Install $(basename "$pub_key_path") on $host_key ($host)?"; then
    printf '[skip] Not changing %s\n' "$host_key"
    return 0
  fi

  if command_exists ssh-copy-id; then
    copy_args=(ssh-copy-id)
    if [ -n "$port" ]; then
      copy_args+=(-p "$port")
    fi
    copy_args+=(-i "$pub_key_path" "$host")
    "${copy_args[@]}"
  else
    pub_key="$(cat "$pub_key_path")"
    printf '%s\n' "$pub_key" | "${ssh_args[@]}" '
      umask 077
      mkdir -p "$HOME/.ssh"
      touch "$HOME/.ssh/authorized_keys"
      read key
      grep -qxF "$key" "$HOME/.ssh/authorized_keys" || printf "%s\n" "$key" >> "$HOME/.ssh/authorized_keys"
      chmod 700 "$HOME/.ssh"
      chmod 600 "$HOME/.ssh/authorized_keys"
    '
  fi

  printf '[info] Testing SSH to %s\n' "$host_key"
  "${ssh_args[@]}" true && printf '[ok]   Local computer can SSH to %s\n' "$host_key"
}

main() {
  parse_args "$@"
  require_json_helper
  require_tool ssh
  require_tool ssh-keygen

  if ! json_validate "$config_path" >/dev/null 2>&1; then
    printf '[fail] Config is not valid JSON: %s\n' "$config_path" >&2
    exit 1
  fi

  ensure_local_key

  if [ -n "$host_filter" ]; then
    if ! json_has "$config_path" hosts "$host_filter"; then
      printf '[fail] Host %s is not in %s\n' "$host_filter" "$config_path" >&2
      exit 1
    fi
    install_key_on_host "$host_filter"
  else
    HOSTS_TO_SETUP=()
    while IFS= read -r host_key; do
      HOSTS_TO_SETUP+=("$host_key")
    done < <(json_keys "$config_path" hosts)

    for host_key in "${HOSTS_TO_SETUP[@]}"; do
      install_key_on_host "$host_key"
    done
  fi
}

main "$@"
