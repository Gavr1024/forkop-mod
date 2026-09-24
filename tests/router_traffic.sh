#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FORKOP_LIB="$ROOT_DIR/forkop/files/usr/lib"
GENERATOR_UC="$FORKOP_LIB/singbox/generator.uc"
CONSTANTS_UC="$FORKOP_LIB/singbox/constants.uc"
ROUTE_UC="$FORKOP_LIB/singbox/route.uc"
NFT_UC="$FORKOP_LIB/nft/apply.uc"
LIFECYCLE_UC="$FORKOP_LIB/service/lifecycle.uc"
STATE_UC="$FORKOP_LIB/service/state.uc"
VALIDATOR_UC="$FORKOP_LIB/config/validator.uc"
MIGRATION_UC="$FORKOP_LIB/config/migration.uc"
SETTINGS_JS="$ROOT_DIR/luci-app-forkop/htdocs/luci-static/resources/view/forkop/settings.js"
UCI_DEFAULT="$ROOT_DIR/forkop/files/etc/config/forkop"
RU_PO="$ROOT_DIR/luci-app-forkop/po/ru/forkop.po"
XRAY_RUNTIME="$FORKOP_LIB/xray/runtime.uc"
XRAY_GEN="$FORKOP_LIB/xray/generator.uc"
XRAY_CONST="$FORKOP_LIB/xray/constants.uc"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

require_contains() {
  local file="$1"
  local needle="$2"
  local message="$3"
  grep -Fq "$needle" "$file" || fail "$message"
}

require_contains "$CONSTANTS_UC" 'REDIRECT_INBOUND_TAG = "redirect-in"' \
  "redirect inbound tag must be redirect-in"
require_contains "$CONSTANTS_UC" 'REDIRECT_INBOUND_ADDRESS = "127.0.0.1"' \
  "redirect inbound must listen on 127.0.0.1 only"
require_contains "$CONSTANTS_UC" 'REDIRECT_INBOUND_PORT = 1604' \
  "redirect inbound must use port 1604"
require_contains "$GENERATOR_UC" 'function add_router_traffic_redirect' \
  "generator must emit a router-traffic redirect inbound"
require_contains "$GENERATOR_UC" 'type: "redirect"' \
  "router traffic inbound must be sing-box type redirect"
require_contains "$GENERATOR_UC" 'function strip_redirect_inbound_network' \
  "generator must strip unknown inbound.network before write"
require_contains "$GENERATOR_UC" 'insert_route_rules_after_system(config, [{' \
  "router traffic must force the selected outbound before domain rules"
require_contains "$ROUTE_UC" 'REDIRECT_INBOUND_TAG' \
  "redirect inbound must be sniffed when router traffic is enabled"
require_contains "$SETTINGS_JS" '"route_router_traffic"' \
  "settings must expose the router-traffic flag"
require_contains "$SETTINGS_JS" '"route_router_traffic_section"' \
  "settings must expose the router-traffic section selector"
require_contains "$SETTINGS_JS" 'configureDownloadSectionOption' \
  "router-traffic section selector must reuse the download-section picker"
require_contains "$VALIDATOR_UC" 'function validate_router_traffic_section_rows' \
  "validator must require a usable section when router traffic is enabled"
require_contains "$NFT_UC" 'output_redirect' \
  "nft must create an OUTPUT NAT redirect chain"
require_contains "$NFT_UC" 'nft-sync-router-output-intercept' \
  "nft CLI must sync router-traffic intercept after sing-box is up"
require_contains "$NFT_UC" '"redirect", "to", ":" + port' \
  "nft intercept must use redirect, not TPROXY, for locally generated TCP"
require_contains "$LIFECYCLE_UC" 'nft-sync-router-output-intercept' \
  "lifecycle must apply router-traffic intercept after a stable start"
require_contains "$STATE_UC" 'settings.route_router_traffic' \
  "sing-box signature must include the router-traffic flag so reload regenerates"
require_contains "$NFT_UC" 'settings.route_router_traffic' \
  "nft signature must include the router-traffic flag so reload rebuilds rules"
require_contains "$MIGRATION_UC" 'router_traffic_section' \
  "migration must clear leftover router-traffic flag without a section"
require_contains "$UCI_DEFAULT" "option route_router_traffic '0'" \
  "default UCI must leave router-traffic intercept off"
require_contains "$RU_PO" 'Маршрутизировать трафик роутера' \
  "Russian catalog must translate the router-traffic flag"
require_contains "$RU_PO" 'Трафик роутера через' \
  "Russian catalog must translate the router-traffic section selector"

if grep -nE 'listen: "0.0.0.0".*1604|REDIRECT_INBOUND_ADDRESS = "0.0.0.0"' \
  "$GENERATOR_UC" "$CONSTANTS_UC"; then
  fail "redirect inbound must not listen on 0.0.0.0"
fi

if awk '
  $0 ~ /function add_router_traffic_redirect\(/ { in_fn = 1 }
  in_fn && $0 ~ /^function / && $0 !~ /function add_router_traffic_redirect\(/ { in_fn = 0 }
  in_fn && $0 ~ /network:/ { found = 1 }
  END { exit found ? 0 : 1 }
' "$GENERATOR_UC"; then
  fail "redirect inbound must not set the unknown field network"
fi

require_contains "$XRAY_CONST" 'XRAY_REDIRECT_PORT = 1604' \
  "Xray plane must listen on the same redirect port nft DNAT uses"
require_contains "$XRAY_GEN" 'function apply_router_traffic_route' \
  "Xray plane must route redirect-in through the selected section outbound"
require_contains "$XRAY_GEN" 'function redirect_inbound' \
  "Xray plane must emit dokodemo-door followRedirect for router OUTPUT DNAT"
require_contains "$GENERATOR_UC" 'if (engine.is_xray_primary())' \
  "sing-box must not bind :1604 when Xray is the routing plane"

if awk '
  $0 ~ /function start_main\(/ { in_fn = 1 }
  in_fn && $0 ~ /^function / && $0 !~ /function start_main\(/ { in_fn = 0 }
  in_fn && $0 ~ /wait-forkop-stable-start/ { stable = NR }
  in_fn && $0 ~ /nft_sync_router_output_intercept/ { sync = NR }
  END { exit (stable && sync && stable < sync) ? 0 : 1 }
' "$LIFECYCLE_UC"; then
  :
else
  fail "start_main must apply OUTPUT DNAT only after sing-box is stable"
fi

if grep -Fq 'route_localnet' "$NFT_UC" "$LIFECYCLE_UC"; then
  fail "router-traffic intercept must not enable route_localnet"
fi

if awk '
  $0 ~ /^function ports_listening\(\)/ { in_fn = 1 }
  in_fn && $0 ~ /^function / && $0 !~ /^function ports_listening\(\)/ { in_fn = 0 }
  in_fn && $0 ~ /return true/ { found = 1 }
  END { exit found ? 0 : 1 }
' "$XRAY_RUNTIME"; then
  fail "ports_listening must not report success when Xray is unused or missing"
fi

printf 'router traffic checks passed\n'
