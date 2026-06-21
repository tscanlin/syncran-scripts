#!/usr/bin/env bash

set -u

yes=0
dry_run=0
create_key=0
key_path="${HOME:-}/.ssh/id_ed25519"

print_usage() {
  cat <<'EOF'
Usage: fix-ssh-setup.sh [options]

Fix common local SSH setup issues that Syncran can repair safely.

Options:
  --create-key   Generate an ed25519 key if no private keys exist
  --key PATH     Key path to create when --create-key is used. Default: ~/.ssh/id_ed25519
  --yes          Do not ask for confirmation
  --dry-run      Print what would change without changing files
  -h, --help     Show this help
EOF
}

info() {
  printf '[info] %s\n' "$*"
}

ok() {
  printf '[ok]   %s\n' "$*"
}

warn() {
  printf '[warn] %s\n' "$*"
}

fail() {
  printf '[fail] %s\n' "$*" >&2
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

confirm() {
  local prompt="$1"
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

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --create-key) create_key=1 ;;
      --key)
        shift
        [ "$#" -gt 0 ] || { fail "Missing value for --key"; exit 2; }
        key_path="$1"
        ;;
      --yes) yes=1 ;;
      --dry-run) dry_run=1 ;;
      -h|--help)
        print_usage
        exit 0
        ;;
      *)
        fail "Unknown option: $1"
        print_usage >&2
        exit 2
        ;;
    esac
    shift
  done
}

run_or_print() {
  if [ "$dry_run" -eq 1 ]; then
    printf '[dry-run] %s\n' "$*"
    return 0
  fi

  "$@"
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

mode_is_no_more_open_than() {
  local mode="$1"
  local max="$2"
  local mode_dec
  local max_dec

  case "$mode" in
    ''|unknown) return 1 ;;
  esac

  mode_dec=$((8#$mode))
  max_dec=$((8#$max))
  [ "$mode_dec" -le "$max_dec" ]
}

ensure_ssh_dir() {
  local ssh_dir="$1"

  if [ -d "$ssh_dir" ]; then
    ok "$ssh_dir exists"
  elif confirm "Create $ssh_dir?"; then
    run_or_print mkdir -p "$ssh_dir"
  else
    fail "$ssh_dir is required"
    return 1
  fi

  if [ -d "$ssh_dir" ] || [ "$dry_run" -eq 1 ]; then
    run_or_print chmod 700 "$ssh_dir"
    ok "$ssh_dir permissions set to 700"
  fi
}

fix_file_mode() {
  local path="$1"
  local mode="$2"
  local label="$3"
  local current_mode

  [ -e "$path" ] || return 0

  current_mode="$(file_mode "$path")"
  if mode_is_no_more_open_than "$current_mode" "$mode"; then
    ok "$label permissions are $current_mode"
    return 0
  fi

  run_or_print chmod "$mode" "$path"
  ok "$label permissions set to $mode"
}

private_key_exists() {
  local ssh_dir="$1"
  local key_file

  for key_file in "$ssh_dir"/id_* "$ssh_dir"/*.pem; do
    [ -e "$key_file" ] || continue
    [ -f "$key_file" ] || continue
    case "$key_file" in
      *.pub|*known_hosts*|*config*) continue ;;
    esac
    return 0
  done

  return 1
}

fix_private_keys() {
  local ssh_dir="$1"
  local key_file

  for key_file in "$ssh_dir"/id_* "$ssh_dir"/*.pem; do
    [ -e "$key_file" ] || continue
    [ -f "$key_file" ] || continue
    case "$key_file" in
      *.pub|*known_hosts*|*config*) continue ;;
    esac

    fix_file_mode "$key_file" 600 "Private key $(basename "$key_file")"

    if [ ! -f "$key_file.pub" ] && command_exists ssh-keygen; then
      if [ "$dry_run" -eq 1 ]; then
        printf '[dry-run] Derive public key at %s\n' "$key_file.pub"
      else
        ssh-keygen -y -f "$key_file" > "$key_file.pub" && chmod 644 "$key_file.pub"
        ok "Derived public key $(basename "$key_file.pub")"
      fi
    fi
  done
}

ensure_key() {
  local ssh_dir="$1"

  if private_key_exists "$ssh_dir"; then
    fix_private_keys "$ssh_dir"
    return 0
  fi

  if [ "$create_key" -eq 0 ]; then
    warn "No private keys found. Rerun with --create-key to generate $key_path."
    return 0
  fi

  if ! command_exists ssh-keygen; then
    fail "ssh-keygen is required to create a key"
    return 1
  fi

  if confirm "Generate a local SSH key at $key_path?"; then
    run_or_print mkdir -p "$(dirname "$key_path")"
    run_or_print chmod 700 "$(dirname "$key_path")"
    if [ "$dry_run" -eq 1 ]; then
      printf '[dry-run] ssh-keygen -t ed25519 -N \"\" -f %s -C syncran-local-%s\n' "$key_path" "$(hostname -s 2>/dev/null || hostname)"
    else
      ssh-keygen -t ed25519 -N '' -f "$key_path" -C "syncran-local-$(hostname -s 2>/dev/null || hostname)"
      chmod 600 "$key_path"
      chmod 644 "$key_path.pub"
      ok "Generated $key_path"
    fi
  else
    warn "Skipped key generation"
  fi
}

main() {
  parse_args "$@"

  printf 'Syncran SSH setup fixer\n'
  printf '======================\n\n'

  if [ -z "${HOME:-}" ]; then
    fail "HOME is not set"
    exit 1
  fi

  local ssh_dir="${HOME}/.ssh"
  ensure_ssh_dir "$ssh_dir"
  fix_file_mode "$ssh_dir/config" 600 "~/.ssh/config"
  fix_file_mode "$ssh_dir/known_hosts" 644 "~/.ssh/known_hosts"
  ensure_key "$ssh_dir"

  printf '\n'
  ok "Local SSH setup fixer finished"
  printf '[info] Run check-ssh-setup.sh again to verify the result.\n'
}

main "$@"
