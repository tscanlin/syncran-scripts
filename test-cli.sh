#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/syncran-cli-test.XXXXXX")"
export SYNCRAN_LOG_FILE="$tmp_dir/syncran-run.log"

cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local label="$3"

  if [[ "$haystack" != *"$needle"* ]]; then
    printf 'Expected output to contain: %s\n' "$needle" >&2
    printf 'Actual output:\n%s\n' "$haystack" >&2
    fail "$label"
  fi
}

write_local_config() {
  local config_path="$1"
  local source_root="$2"
  local dest_root="$3"

  cat > "$config_path" <<JSON
{
  "comp_array": ["laptop", "external"],
  "hosts": {
    "laptop": {
      "host": "",
      "root": "$source_root",
      "folders": {
        "docs": "Documents/"
      }
    },
    "external": {
      "host": "",
      "root": "$dest_root",
      "folders": {
        "docs": "Documents/"
      }
    }
  },
  "folder_groups": {},
  "ignores": ["*.tmp"]
}
JSON
}

source_root="$tmp_dir/source"
dest_root="$tmp_dir/external"
mkdir -p "$source_root/Documents" "$dest_root/Documents"
printf 'hello\n' > "$source_root/Documents/example.txt"
printf 'ignore me\n' > "$source_root/Documents/cache.tmp"

config_path="$tmp_dir/syncran.config.json"
write_local_config "$config_path" "$source_root" "$dest_root"

help_output="$(bash "$script_dir/syncran.sh" --help)"
assert_contains "$help_output" "--source-path PATH" "syncran help documents ad hoc source paths"
assert_contains "$help_output" "External" "syncran help documents local external-drive example"
pass "syncran help documents ad hoc local paths"

diagnostic_output="$(bash "$script_dir/check-syncran-config.sh" --skip-network "$config_path")"
assert_contains "$diagnostic_output" "Config file is readable JSON" "config diagnostics validate test config"
assert_contains "$diagnostic_output" "Local hosts: laptop, external" "config diagnostics identify local hosts"
pass "check-syncran-config validates local-only config without network"

configured_output="$(
  bash "$script_dir/syncran.sh" sync \
    --config "$config_path" \
    --source laptop \
    --destination external \
    --folder docs \
    --dry-run \
    --progress-mode none
)"
assert_contains "$configured_output" "Using paths: laptop:$source_root/Documents" "configured local-to-local run uses source path"
assert_contains "$configured_output" "external:$dest_root/Documents" "configured local-to-local run uses destination path"
assert_contains "$configured_output" "laptop:external" "configured local-to-local run records summary route"
assert_contains "$configured_output" "Number of files transferred" "configured local-to-local run emits rsync stats"
pass "syncran runs config-backed local-to-local dry run"

adhoc_dest="$tmp_dir/adhoc-external/Documents"
mkdir -p "$adhoc_dest"
adhoc_output="$(
  bash "$script_dir/syncran.sh" sync \
    --source Local \
    --destination ExternalDrive \
    --source-path "$source_root/Documents/" \
    --destination-path "$adhoc_dest/" \
    --folder docs \
    --dry-run \
    --progress-mode none
)"
assert_contains "$adhoc_output" "Using ad hoc paths: local:$source_root/Documents/ -> local:$adhoc_dest/" "ad hoc local-to-local run uses explicit paths"
assert_contains "$adhoc_output" "Local:ExternalDrive" "ad hoc local-to-local run records summary route"
assert_contains "$adhoc_output" "Number of files transferred" "ad hoc local-to-local run emits rsync stats"
pass "syncran runs ad hoc local-to-local dry run"

set +e
missing_path_output="$(
  bash "$script_dir/syncran.sh" sync \
    --source Local \
    --destination ExternalDrive \
    --source-path "$source_root/Documents/" \
    --folder docs 2>&1
)"
missing_path_status=$?
set -e

if [[ $missing_path_status -eq 0 ]]; then
  printf 'Expected missing destination path command to fail.\n' >&2
  printf 'Actual output:\n%s\n' "$missing_path_output" >&2
  fail "ad hoc jobs require both explicit paths"
fi
assert_contains "$missing_path_output" "Use both --source-path and --destination-path" "ad hoc jobs require both explicit paths"
pass "syncran rejects incomplete ad hoc path arguments"
