#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/forkop/files/usr/lib"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

extract_fn() {
  local file="$1"
  local name="$2"
  awk -v name="$name" '
    $0 ~ "^function " name "\\(" { grab = 1 }
    grab { print }
    grab && $0 ~ /^}$/ { exit }
  ' "$file"
}

cat >"$WORK_DIR/check.uc" <<'UCODE'
let common = require("core.common");
let option = common.option;
let settings = {};

function settings_section() {
    return settings;
}
UCODE

extract_fn "$LIB/xray/generator.uc" xray_query_strategy >>"$WORK_DIR/check.uc"
extract_fn "$LIB/xray/generator.uc" xray_dial_strategy >>"$WORK_DIR/check.uc"

cat >>"$WORK_DIR/check.uc" <<'UCODE'
let cases = [
    [ "prefer_ipv4", "UseIP", "UseIPv4v6" ],
    [ "prefer_ipv6", "UseIP", "UseIPv6v4" ],
    [ "ipv4_only", "UseIPv4", "UseIPv4" ],
    [ "ipv6_only", "UseIPv6", "UseIPv6" ],
    [ null, "UseIP", "UseIPv4v6" ],
    [ "", "UseIP", "UseIPv4v6" ],
    [ "PREFER_IPV4", "UseIP", "UseIPv4v6" ],
    [ "PREFER_IPV6", "UseIP", "UseIPv6v4" ]
];

let failures = 0;
for (let test in cases) {
    settings = test[0] == null ? {} : { dns_strategy: test[0] };
    let label = test[0] == null ? "default" : test[0] == "" ? "empty" : test[0];
    let query = xray_query_strategy();
    let dial = xray_dial_strategy();
    if (query != test[1] || dial != test[2]) {
        warn(sprintf("FAIL: %s: expected DNS=%s dial=%s, got DNS=%s dial=%s\n",
            label, test[1], test[2], query, dial));
        failures++;
    }
    else {
        print(sprintf("ok  %s: DNS=%s dial=%s\n", label, query, dial));
    }
}
if (failures > 0)
    die(sprintf("%d Xray DNS strategy checks failed\n", failures));
UCODE

ucode -L "$LIB" "$WORK_DIR/check.uc"
printf 'Xray DNS strategy runtime checks passed\n'

cat >"$WORK_DIR/cache.uc" <<'UCODE'
let fs = require("fs");
let xray_constants = require("xray.constants");
let common = require("core.common");
let as_string = common.as_string;
let stamps = {};
let body = "";
let cached = { fingerprint: "" };

function file_content_stamp(path) { return stamps[path] || path; }
function subscription_cache_stamp() { return "unchanged subscriptions"; }
function write_file(_path, value) { body = value; }
function remove_file(_path) {}
function persist_lists_locally() { return true; }
function file_exists(_path) { return true; }
function read_config_stamp() { return cached; }
UCODE

# Keep real hashing while avoiding writes to the router's configuration paths.
cat >>"$WORK_DIR/cache.uc" <<UCODE
function file_md5(_path) {
    fs.writefile("$WORK_DIR/fingerprint", body);
    let pipe = fs.popen("md5sum '$WORK_DIR/fingerprint'", "r");
    let hash = split(pipe.read("all"), " ")[0];
    pipe.close();
    return hash;
}
UCODE

extract_fn "$LIB/xray/runtime.uc" config_input_fingerprint >>"$WORK_DIR/cache.uc"
extract_fn "$LIB/xray/runtime.uc" can_reuse_generated_config >>"$WORK_DIR/cache.uc"

cat >>"$WORK_DIR/cache.uc" <<'UCODE'
cached.fingerprint = config_input_fingerprint();
if (!can_reuse_generated_config())
    die("Unchanged inputs must reuse the cached Xray configuration\n");

stamps[getenv("FORKOP_LIB") + "/xray/generator.uc"] = "updated generator content";
if (can_reuse_generated_config())
    die("A generator update must invalidate the cached Xray configuration\n");

cached.fingerprint = config_input_fingerprint();
if (!can_reuse_generated_config())
    die("The regenerated Xray configuration must be reusable\n");
print("ok  generator updates invalidate cached configuration; unchanged inputs reuse it\n");
UCODE

FORKOP_LIB="$LIB" ucode -L "$LIB" "$WORK_DIR/cache.uc"
