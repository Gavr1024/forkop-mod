#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FORKOP_LIB="$ROOT_DIR/forkop/files/usr/lib"
GENERATOR="$FORKOP_LIB/singbox/generator.uc"
WORK_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

mkdir -p "$WORK_DIR/bin"
cat >"$WORK_DIR/bin/sing-box" <<'EOF'
#!/bin/sh
echo "sing-box version 1.14.3-extended-2.7.3"
exit 0
EOF
chmod +x "$WORK_DIR/bin/sing-box"
export PATH="$WORK_DIR/bin:$PATH"

generate() {
  local name="$1"
  ucode -L "$FORKOP_LIB" "$GENERATOR" generate-config-fixture \
    "$WORK_DIR/$name.json" "$WORK_DIR/$name.out.json" "127.0.0.1" >/dev/null
}

cat >"$WORK_DIR/register.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "dns_server": "1.1.1.1",
    "routing_engine": "sing-box",
    "service_listen_address": "127.0.0.1"
  },
  "section": [
    {
      ".name": "hop",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "proxy_core": "sing-box",
      "selector_proxy_links": [ "socks5://127.0.0.1:1080#Hop" ]
    },
    {
      ".name": "CF_WARP",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "proxy_core": "sing-box"
    }
  ],
  "masque": [
    {
      ".name": "mq1",
      ".type": "masque",
      "section": "CF_WARP",
      "name": "MQ_WARP",
      "endpoint_port": "443",
      "ipv4_only": "1",
      "register_via": "hop"
    }
  ]
}
JSON

generate register
ucode -e '
let fs = require("fs");
let config = json(fs.readfile(ARGV[0]));
let found = null;
for (let item in config.outbounds || [])
    if (item && item.type == "masque")
        found = item;
if (found == null)
    die("masque outbound missing\n");
if (found.detour != null)
    die("registration hop must not take the tunnel: " + found.detour + "\n");
if (!found.profile || found.profile.detour != "hop-out")
    die("registration did not go through hop-out\n");
' "$WORK_DIR/register.out.json" || fail "register-only hop"

cat >"$WORK_DIR/direct.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "dns_server": "1.1.1.1",
    "routing_engine": "sing-box",
    "service_listen_address": "127.0.0.1"
  },
  "section": [
    {
      ".name": "CF_WARP",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "proxy_core": "sing-box"
    }
  ],
  "masque": [
    {
      ".name": "mq1",
      ".type": "masque",
      "section": "CF_WARP",
      "name": "MQ_WARP",
      "endpoint_port": "443"
    }
  ]
}
JSON

generate direct
ucode -e '
let fs = require("fs");
let config = json(fs.readfile(ARGV[0]));
let found = null;
for (let item in config.outbounds || [])
    if (item && item.type == "masque")
        found = item;
if (found == null)
    die("masque outbound missing\n");
if (found.detour != null)
    die("direct profile must not set a tunnel detour\n");
if (!found.profile || found.profile.detour != "direct-out")
    die("direct registration was not kept\n");
' "$WORK_DIR/direct.out.json" || fail "direct registration"

cat >"$WORK_DIR/http2.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "dns_server": "1.1.1.1",
    "routing_engine": "sing-box",
    "service_listen_address": "127.0.0.1"
  },
  "section": [
    {
      ".name": "CF_WARP",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "proxy_core": "sing-box"
    }
  ],
  "masque": [
    {
      ".name": "mq1",
      ".type": "masque",
      "section": "CF_WARP",
      "name": "MQ_WARP",
      "endpoint_port": "443",
      "use_http2": "1",
      "server_name": "www.cloudflare.com"
    }
  ]
}
JSON

generate http2
ucode -e '
let fs = require("fs");
let config = json(fs.readfile(ARGV[0]));
let found = null;
for (let item in config.outbounds || [])
    if (item && item.type == "masque")
        found = item;
if (found == null)
    die("masque outbound missing\n");
if (found.use_http2 != true)
    die("HTTP/2 was not enabled\n");
if (!found.tls || found.tls.server_name != "www.cloudflare.com")
    die("SNI was not written\n");
' "$WORK_DIR/http2.out.json" || fail "http2 sni"

mkdir -p "$WORK_DIR/run"
PORT_FILE="$WORK_DIR/run/xray-ports.json"
export XRAY_PORTS_FILE="$PORT_FILE"
export FORKOP_RUNTIME_STATE_DIR="$WORK_DIR/run"
printf '%s\n' '{ "hop": 10808 }' >"$PORT_FILE"

cat >"$WORK_DIR/xray.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "dns_server": "1.1.1.1",
    "routing_engine": "xray",
    "service_listen_address": "127.0.0.1"
  },
  "section": [
    {
      ".name": "hop",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "proxy_core": "xray",
      "selector_proxy_links": [ "vless://00000000-0000-4000-8000-000000000001@192.0.2.10:443#Hop" ]
    },
    {
      ".name": "CF_WARP",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "proxy_core": "sing-box"
    }
  ],
  "masque": [
    {
      ".name": "mq1",
      ".type": "masque",
      "section": "CF_WARP",
      "name": "MQ_WARP",
      "endpoint_port": "443",
      "ipv4_only": "1",
      "register_via": "hop"
    }
  ]
}
JSON

generate xray
ucode -e '
let fs = require("fs");
let config = json(fs.readfile(ARGV[0]));
let masque = null;
let via = null;
for (let item in config.outbounds || []) {
    if (item && item.type == "masque")
        masque = item;
    if (item && item.tag == "ovpn-via-hop")
        via = item;
}
if (masque == null)
    die("masque outbound missing\n");
if (masque.detour != null)
    die("xray registration hop took the tunnel\n");
if (!masque.profile || masque.profile.detour != "ovpn-via-hop")
    die("registration did not use the local SOCKS hop\n");
if (via == null || via.type != "socks" || via.server != "127.0.0.1" || via.server_port != 10808)
    die("local SOCKS hop is wrong\n");
let selector = null;
for (let item in config.outbounds || [])
    if (item && item.tag == "CF_WARP-out")
        selector = item;
if (selector == null)
    die("section selector missing\n");
for (let tag in selector.outbounds || [])
    if (tag == "ovpn-via-hop")
        die("registration hop was added to the section selector\n");
' "$WORK_DIR/xray.out.json" || fail "xray registration hop"

printf 'masque register-via checks passed\n'

