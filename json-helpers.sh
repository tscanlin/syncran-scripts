#!/usr/bin/env bash

json_helper_backend() {
  if command -v python3 >/dev/null 2>&1; then
    printf 'python3\n'
    return 0
  fi

  if command -v ruby >/dev/null 2>&1; then
    printf 'ruby\n'
    return 0
  fi

  return 1
}

require_json_helper() {
  if ! json_helper_backend >/dev/null; then
    printf '[fail] A JSON parser is required, but python3 or ruby was not found.\n' >&2
    printf '       Fix: Install python3 or ruby, then rerun this command.\n' >&2
    exit 1
  fi
}

json_helper() {
  backend="$(json_helper_backend)" || {
    printf '[fail] A JSON parser is required, but python3 or ruby was not found.\n' >&2
    return 1
  }

  case "$backend" in
    python3)
      python3 - "$@" <<'PY'
import json
import sys


def die(message, code=1):
    print(message, file=sys.stderr)
    sys.exit(code)


def json_type(value):
    if value is MISSING:
        return "missing"
    if value is None:
        return "null"
    if isinstance(value, bool):
        return "boolean"
    if isinstance(value, str):
        return "string"
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        return "number"
    if isinstance(value, list):
        return "array"
    if isinstance(value, dict):
        return "object"
    return "unknown"


def load_file(path):
    with open(path, "r", encoding="utf-8") as handle:
        return json.load(handle)


MISSING = object()


def get_path(value, path):
    current = value
    for key in path:
        if isinstance(current, dict) and key in current:
            current = current[key]
        else:
            return MISSING
    return current


def print_scalar(value, default=""):
    if value is MISSING or value is None:
        print(default)
    elif isinstance(value, bool):
        print("true" if value else "false")
    elif isinstance(value, (str, int, float)):
        print(value)
    else:
        print(json.dumps(value, separators=(",", ":")))


def load_json_arg(value, fallback):
    try:
        return json.loads(value)
    except Exception:
        return fallback


op = sys.argv[1]
args = sys.argv[2:]

if op == "validate":
    load_file(args[0])
elif op == "type":
    data = load_file(args[0])
    print(json_type(get_path(data, args[1:])))
elif op == "len":
    data = load_file(args[0])
    value = get_path(data, args[1:])
    if isinstance(value, (dict, list)):
        print(len(value))
    else:
        print(0)
elif op == "keys":
    data = load_file(args[0])
    value = get_path(data, args[1:])
    if isinstance(value, dict):
        for key in value.keys():
            print(key)
elif op == "array-values":
    data = load_file(args[0])
    value = get_path(data, args[1:])
    if isinstance(value, list):
        for item in value:
            if isinstance(item, (str, int, float, bool)) or item is None:
                print_scalar(item)
elif op == "array-all-strings":
    data = load_file(args[0])
    value = get_path(data, args[1:])
    sys.exit(0 if isinstance(value, list) and all(isinstance(item, str) for item in value) else 1)
elif op == "array-contains":
    data = load_file(args[0])
    expected = args[1]
    value = get_path(data, args[2:])
    sys.exit(0 if isinstance(value, list) and expected in value else 1)
elif op == "has":
    data = load_file(args[0])
    sys.exit(0 if get_path(data, args[1:]) is not MISSING else 1)
elif op == "port-valid":
    data = load_file(args[0])
    value = get_path(data, args[1:])
    sys.exit(0 if isinstance(value, int) and 1 <= value <= 65535 else 1)
elif op == "value":
    data = load_file(args[0])
    default = args[1]
    print_scalar(get_path(data, args[2:]), default)
elif op == "object":
    omit_empty = args[0] == "--non-empty"
    values = args[1:] if omit_empty else args
    result = {}
    for index in range(0, len(values), 2):
        key = values[index]
        value = values[index + 1] if index + 1 < len(values) else ""
        if omit_empty and value == "":
            continue
        result[key] = value
    print(json.dumps(result, separators=(",", ":")))
elif op == "merge":
    result = load_json_arg(args[0], {})
    values = args[1:]
    for index in range(0, len(values), 2):
        key = values[index]
        value = values[index + 1] if index + 1 < len(values) else ""
        result[key] = value
    print(json.dumps(result, separators=(",", ":")))
elif op == "record":
    result = load_json_arg(args[0], {})
    result["status"] = args[1]
    result["message"] = args[2]
    print(json.dumps(result, separators=(",", ":")))
elif op == "array-append":
    array = load_json_arg(args[0], [])
    item = load_json_arg(args[1], {})
    array.append(item)
    print(json.dumps(array, separators=(",", ":")))
elif op == "report":
    summary = {
        "ok": int(args[6]),
        "warn": int(args[7]),
        "fail": int(args[8]),
        "skip": int(args[9]),
    }
    report = {
        "tool": args[0],
        "config_path": args[1],
        "validation": load_json_arg(args[2], []),
        "hosts": load_json_arg(args[3], []),
        "connections": load_json_arg(args[4], []),
        "remote_diagnostics": load_json_arg(args[5], []),
        "summary": summary,
    }
    print(json.dumps(report, separators=(",", ":")))
elif op == "connection-pairs":
    array = load_json_arg(args[0], [])
    status = args[1]
    require_source = args[2] == "1"
    pairs = []
    for item in array:
        if item.get("status") != status:
            continue
        source = item.get("source")
        destination = item.get("destination")
        if require_source and (source is None or destination is None):
            continue
        if source is not None and destination is not None:
            pairs.append(f"{source} -> {destination}")
    print(", ".join(pairs))
elif op == "host-keys-by-status":
    array = load_json_arg(args[0], [])
    status = args[1]
    keys = sorted({item.get("host_key") for item in array if item.get("status") == status and item.get("host_key")})
    print(", ".join(keys))
else:
    die(f"Unknown json helper operation: {op}", 2)
PY
      ;;
    ruby)
      ruby -rjson - "$@" <<'RB'
MISSING = Object.new

def load_file(path)
  JSON.parse(File.read(path))
end

def get_path(value, path)
  current = value
  path.each do |key|
    if current.is_a?(Hash) && current.key?(key)
      current = current[key]
    else
      return MISSING
    end
  end
  current
end

def json_type(value)
  return "missing" if value.equal?(MISSING)
  return "null" if value.nil?
  return "boolean" if value == true || value == false
  return "string" if value.is_a?(String)
  return "number" if value.is_a?(Numeric)
  return "array" if value.is_a?(Array)
  return "object" if value.is_a?(Hash)
  "unknown"
end

def print_scalar(value, default = "")
  if value.equal?(MISSING) || value.nil?
    puts default
  elsif value == true || value == false
    puts(value ? "true" : "false")
  elsif value.is_a?(String) || value.is_a?(Numeric)
    puts value
  else
    puts JSON.generate(value)
  end
end

def load_json_arg(value, fallback)
  JSON.parse(value)
rescue StandardError
  fallback
end

op = ARGV.shift

case op
when "validate"
  load_file(ARGV[0])
when "type"
  data = load_file(ARGV.shift)
  puts json_type(get_path(data, ARGV))
when "len"
  data = load_file(ARGV.shift)
  value = get_path(data, ARGV)
  puts(value.is_a?(Array) || value.is_a?(Hash) ? value.length : 0)
when "keys"
  data = load_file(ARGV.shift)
  value = get_path(data, ARGV)
  puts value.keys if value.is_a?(Hash)
when "array-values"
  data = load_file(ARGV.shift)
  value = get_path(data, ARGV)
  value.each { |item| print_scalar(item) } if value.is_a?(Array)
when "array-all-strings"
  data = load_file(ARGV.shift)
  value = get_path(data, ARGV)
  exit(value.is_a?(Array) && value.all? { |item| item.is_a?(String) } ? 0 : 1)
when "array-contains"
  data = load_file(ARGV.shift)
  expected = ARGV.shift
  value = get_path(data, ARGV)
  exit(value.is_a?(Array) && value.include?(expected) ? 0 : 1)
when "has"
  data = load_file(ARGV.shift)
  exit(get_path(data, ARGV).equal?(MISSING) ? 1 : 0)
when "port-valid"
  data = load_file(ARGV.shift)
  value = get_path(data, ARGV)
  exit(value.is_a?(Integer) && value >= 1 && value <= 65_535 ? 0 : 1)
when "value"
  data = load_file(ARGV.shift)
  default = ARGV.shift
  print_scalar(get_path(data, ARGV), default)
when "object"
  omit_empty = ARGV[0] == "--non-empty"
  values = omit_empty ? ARGV[1, ARGV.length] : ARGV
  result = {}
  values.each_slice(2) do |key, value|
    next if omit_empty && value.to_s.empty?
    result[key] = value.to_s
  end
  puts JSON.generate(result)
when "merge"
  result = load_json_arg(ARGV.shift, {})
  ARGV.each_slice(2) { |key, value| result[key] = value.to_s }
  puts JSON.generate(result)
when "record"
  result = load_json_arg(ARGV[0], {})
  result["status"] = ARGV[1]
  result["message"] = ARGV[2]
  puts JSON.generate(result)
when "array-append"
  array = load_json_arg(ARGV[0], [])
  item = load_json_arg(ARGV[1], {})
  array << item
  puts JSON.generate(array)
when "report"
  report = {
    "tool" => ARGV[0],
    "config_path" => ARGV[1],
    "validation" => load_json_arg(ARGV[2], []),
    "hosts" => load_json_arg(ARGV[3], []),
    "connections" => load_json_arg(ARGV[4], []),
    "remote_diagnostics" => load_json_arg(ARGV[5], []),
    "summary" => {
      "ok" => ARGV[6].to_i,
      "warn" => ARGV[7].to_i,
      "fail" => ARGV[8].to_i,
      "skip" => ARGV[9].to_i,
    },
  }
  puts JSON.generate(report)
when "connection-pairs"
  array = load_json_arg(ARGV[0], [])
  status = ARGV[1]
  require_source = ARGV[2] == "1"
  pairs = array.map do |item|
    next nil unless item["status"] == status
    source = item["source"]
    destination = item["destination"]
    next nil if require_source && (source.nil? || destination.nil?)
    source && destination ? "#{source} -> #{destination}" : nil
  end.compact
  puts pairs.join(", ")
when "host-keys-by-status"
  array = load_json_arg(ARGV[0], [])
  status = ARGV[1]
  puts array.map { |item| item["status"] == status ? item["host_key"] : nil }.compact.uniq.sort.join(", ")
else
  warn "Unknown json helper operation: #{op}"
  exit 2
end
RB
      ;;
  esac
}

json_validate() { json_helper validate "$1"; }
json_type() { file="$1"; shift; json_helper type "$file" "$@"; }
json_len() { file="$1"; shift; json_helper len "$file" "$@"; }
json_keys() { file="$1"; shift; json_helper keys "$file" "$@"; }
json_array_values() { file="$1"; shift; json_helper array-values "$file" "$@"; }
json_array_all_strings() { file="$1"; shift; json_helper array-all-strings "$file" "$@"; }
json_array_contains() { file="$1"; value="$2"; shift 2; json_helper array-contains "$file" "$value" "$@"; }
json_has() { file="$1"; shift; json_helper has "$file" "$@"; }
json_port_valid() { file="$1"; shift; json_helper port-valid "$file" "$@"; }
json_value() { file="$1"; default="$2"; shift 2; json_helper value "$file" "$default" "$@"; }
json_object() { json_helper object "$@"; }
json_object_nonempty() { json_helper object --non-empty "$@"; }
json_merge() { json_helper merge "$@"; }
json_record() { json_helper record "$@"; }
json_array_append() { json_helper array-append "$@"; }
json_report() { json_helper report "$@"; }
json_connection_pairs() { json_helper connection-pairs "$@"; }
json_host_keys_by_status() { json_helper host-keys-by-status "$@"; }
