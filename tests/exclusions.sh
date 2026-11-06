#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GENERATOR="$ROOT_DIR/forkop/files/usr/lib/singbox/generator.uc"
DNS_UC="$ROOT_DIR/forkop/files/usr/lib/singbox/dns.uc"
DNS_APPLY="$ROOT_DIR/forkop/files/usr/lib/dns/apply.uc"
CONSTANTS="$ROOT_DIR/forkop/files/usr/lib/singbox/constants.uc"
NFT="$ROOT_DIR/forkop/files/usr/lib/nft/apply.uc"
SETTINGS_JS="$ROOT_DIR/luci-app-forkop/htdocs/luci-static/resources/view/forkop/settings.js"
DEVICES_JS="$ROOT_DIR/luci-app-forkop/htdocs/luci-static/resources/view/forkop/local_devices.js"
SECTION_JS="$ROOT_DIR/luci-app-forkop/htdocs/luci-static/resources/view/forkop/section.js"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

require_text() {
  grep -Fq "$2" "$1" || fail "$1 must contain: $2"
}

require_text "$GENERATOR" "forkop-exclusions-fix-5"
require_text "$GENERATOR" "function expanded_ips_for_source_value"
require_text "$GENERATOR" "function ips_from_dhcp_lease_name"
require_text "$GENERATOR" "function add_global_routing_exclusions"
require_text "$NFT" "function apply_expanded_source_values"
require_text "$NFT" "function apply_ips_from_lease_name"
require_text "$NFT" "EXCLUDED_SOURCE_SET"
require_text "$NFT" "EXCLUDED_DNS_PORT"
require_text "$NFT" "EXCLUDED_DNS_UPSTREAM_SET"
require_text "$NFT" "forkop_excluded_dns"
require_text "$DNS_APPLY" "function excluded_dns_sync"
require_text "$DNS_APPLY" "sync-excluded"
require_text "$SETTINGS_JS" "routing_excluded_dns"
require_text "$SETTINGS_JS" "Provider DNS"
require_text "$SETTINGS_JS" "Engine DNS"
require_text "$GENERATOR" "function excluded_dns_uses_engine"
require_text "$GENERATOR" "EXCLUDED_DNS_SERVER_TAG"
require_text "$NFT" "engine-xray"
require_text "$NFT" "XRAY_DNS_EXCLUDED_PORT"
require_text "$ROOT_DIR/forkop/files/usr/lib/xray/generator.uc" "function apply_excluded_real_dns"
require_text "$DEVICES_JS" "function resolveLocalDeviceListValues"
require_text "$SECTION_JS" "resolveLocalDeviceListValues"

if awk '
  $0 ~ /function add_global_routing_exclusions\(/ { in_fn = 1 }
  in_fn && $0 ~ /^function / && $0 !~ /function add_global_routing_exclusions\(/ { in_fn = 0 }
  in_fn && /excluded_dns_uses_engine\(\)/ { gated = 1 }
  in_fn && /EXCLUDED_DNS_SERVER_TAG/ { tagged = 1 }
  END { exit gated && tagged ? 0 : 1 }
' "$GENERATOR"; then
  :
else
  fail "engine DNS for excluded devices must stay behind the routing_excluded_dns choice"
fi

if command -v ucode >/dev/null 2>&1; then
  parsed="$(ucode -L "$ROOT_DIR/forkop/files/usr/lib" "$DNS_APPLY" parse-excluded-upstreams '/example.com/1.1.1.1 127.0.0.42 9.9.9.9#53 [2606:4700:4700::1111]')"
  printf '%s\n' "$parsed" | grep -x '1.1.1.1' >/dev/null || fail "parser dropped the saved IPv4 DNS"
  printf '%s\n' "$parsed" | grep -x '9.9.9.9' >/dev/null || fail "parser dropped a port-qualified DNS address"
  printf '%s\n' "$parsed" | grep -x '2606:4700:4700::1111' >/dev/null || fail "parser dropped an IPv6 DNS address"
  if printf '%s\n' "$parsed" | grep '127.0.0.42' >/dev/null ; then
    fail "parser kept the engine DNS address"
  fi
fi

printf 'exclusion checks passed\n'
