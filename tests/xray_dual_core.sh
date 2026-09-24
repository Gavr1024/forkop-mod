#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FORKOP_LIB="$ROOT_DIR/forkop/files/usr/lib"
FORKOP_BIN="$ROOT_DIR/forkop/files/usr/bin/forkop"
SECTION_JS="$ROOT_DIR/luci-app-forkop/htdocs/luci-static/resources/view/forkop/section.js"
FORKOP_JS="$ROOT_DIR/luci-app-forkop/htdocs/luci-static/resources/view/forkop/forkop.js"
MAIN_JS="$ROOT_DIR/luci-app-forkop/htdocs/luci-static/resources/view/forkop/main.js"
FE_SRC="$ROOT_DIR/fe-app-forkop/src"
ACTION_UC="$FORKOP_LIB/components/action.uc"
UPDATER_UC="$FORKOP_LIB/components/updater.uc"
UPDATES_UC="$FORKOP_LIB/components/updates.uc"
LIFECYCLE_UC="$FORKOP_LIB/service/lifecycle.uc"
GENERATOR_UC="$FORKOP_LIB/singbox/generator.uc"
CONNECTIONS_UC="$FORKOP_LIB/config/connections.uc"
VALIDATOR_UC="$FORKOP_LIB/config/validator.uc"
DIAG_RUNTIME_UC="$FORKOP_LIB/diagnostics/runtime.uc"
DIAG_STATUS_UC="$FORKOP_LIB/diagnostics/status.uc"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

require_file() {
  [ -r "$1" ] || fail "required file is missing: $1"
}

require_contains() {
  local file="$1"
  local needle="$2"
  local message="$3"
  grep -Fq "$needle" "$file" || fail "$message"
}

require_file "$FORKOP_LIB/xray/constants.uc"
require_file "$FORKOP_LIB/xray/outbound.uc"
require_file "$FORKOP_LIB/xray/generator.uc"
require_file "$FORKOP_LIB/xray/runtime.uc"
require_file "$FORKOP_LIB/xray/geodata.uc"

require_contains "$FORKOP_LIB/xray/constants.uc" 'XRAY_BIN = "/usr/bin/xray"' \
  "xray constants must pin the managed binary path"
require_contains "$FORKOP_LIB/xray/constants.uc" 'XRAY_SOCKS_PORT_BASE = 10808' \
  "xray sidecar ports must start at 10808"
require_contains "$FORKOP_LIB/xray/constants.uc" 'OUTBOUND_MARK = 134217728' \
  "xray outbounds must reuse the Forkop outbound mark"
require_contains "$FORKOP_LIB/xray/constants.uc" 'XTLS/Xray-core' \
  "xray updates must use the official XTLS/Xray-core GitHub repo"

require_contains "$FORKOP_LIB/xray/outbound.uc" 'function convert_ir' \
  "xray outbound converter must exist"
require_contains "$FORKOP_LIB/xray/outbound.uc" 'function convert_vless' \
  "xray must convert VLESS share-link IR"
require_contains "$FORKOP_LIB/xray/outbound.uc" 'encryption: encryption' \
  "Xray 26 VLESS must set settings.encryption (none or mlkem string)"
require_contains "$FORKOP_LIB/xray/outbound.uc" 'method: "raw"' \
  "Xray 26 raw/tcp transport must set streamSettings.method raw"
require_contains "$FORKOP_LIB/xray/outbound.uc" 'function flatten_vnext' \
  "classic vnext JSON must be flattened to Xray 26 address/port/id"
require_contains "$FORKOP_LIB/xray/outbound.uc" 'protocol: "hysteria"' \
  "Xray 26 hysteria2 outbounds must use protocol hysteria"
require_contains "$FORKOP_LIB/xray/outbound.uc" 'network: "hysteria"' \
  "Xray 26 hysteria2 outbounds must use stream network hysteria, not hysteria2"
require_contains "$FORKOP_LIB/xray/outbound.uc" 'hysteriaSettings' \
  "Xray 26 hysteria2 password belongs in hysteriaSettings.auth"
require_contains "$FORKOP_LIB/xray/outbound.uc" 'type: "salamander"' \
  "Hysteria2 salamander obfs must use FinalMask udp salamander"
require_contains "$FORKOP_LIB/xray/outbound.uc" 'udphop' \
  "Hysteria2 port hopping must use hysteriaSettings.udphop, not hopPorts"
require_contains "$FORKOP_LIB/xray/outbound.uc" 'function normalize_hysteria_native' \
  "native Xray JSON with protocol hysteria2 must be rewritten for 26.x"
require_contains "$FORKOP_LIB/subscription/parser.uc" 'tls.reality.spider_x' \
  "VLESS Reality share-links must keep the spx/spiderX parameter"
require_contains "$FORKOP_LIB/subscription/parser.uc" 'xtls-rprx-vision-udp443' \
  "VLESS share-links with vision-udp443 flow must parse"
require_contains "$FORKOP_LIB/subscription/parser.uc" 'transport == "raw"' \
  "VLESS type=raw must be treated as tcp"
require_contains "$FORKOP_LIB/xray/outbound.uc" 'function convert_xray_native' \
  "xray must accept native Xray JSON outbounds"
require_contains "$FORKOP_LIB/xray/outbound.uc" 'sockopt.mark = xray_constants.OUTBOUND_MARK' \
  "converted xray outbounds must carry the nft outbound mark"

require_contains "$FORKOP_LIB/xray/generator.uc" 'parser.parse_share_link' \
  "xray generator must reuse the share-link parser"
require_contains "$FORKOP_LIB/xray/generator.uc" 'prepare_share_link' \
  "xray generator must decode share-links the same way as sing-box"
require_contains "$FORKOP_LIB/xray/generator.uc" 'connections.proxy_core(section) != "xray"' \
  "xray generator must only emit sections with proxy_core=xray"
require_contains "$FORKOP_LIB/xray/generator.uc" 'XRAY_PORTS_FILE' \
  "xray generator must write the sidecar port map"
require_contains "$FORKOP_LIB/xray/generator.uc" 'leastPing' \
  "xray URLTest groups must map to observatory leastPing"
require_contains "$FORKOP_LIB/xray/generator.uc" 'network: network' \
  "xray dashboard nodes must include the outbound transport"
require_contains "$FORKOP_LIB/xray/generator.uc" 'enableConcurrency' \
  "xray observatory must probe URLTest outbounds concurrently"
require_contains "$FORKOP_LIB/xray/runtime.uc" 'urltest-worker' \
  "xray URLTest auto-switch must run without sing-box Clash API"
require_contains "$FORKOP_LIB/xray/runtime.uc" 'XRAY_URLTEST_TAG' \
  "xray dashboard Fastest must clear the pinned outbound and restore URLTest"
require_contains "$FORKOP_LIB/xray/runtime.uc" 'function section_inbound_tag' \
  "URLTest worker must not call xray_constants.inbound_tag (LHS is not a function on some ucode builds)"
require_contains "$FORKOP_LIB/xray/runtime.uc" 'function section_is_connection' \
  "URLTest worker must skip bypass/block/dns sections"
require_contains "$FORKOP_LIB/xray/runtime.uc" 'section.proxy_core' \
  "URLTest worker must read proxy_core from the UCI object, not connections.proxy_core"
if awk '/^function section_core_name/,/^}/' "$FORKOP_LIB/xray/runtime.uc" | grep -Fq 'connections.proxy_core'; then
  fail "section_core_name must not call connections.proxy_core (LHS is not a function on some ucode builds)"
fi
require_contains "$FORKOP_LIB/xray/runtime.uc" 'urltest_step' \
  "URLTest worker catch must log the failing step"
if grep -nF 'best = { tag, delay }' "$FORKOP_LIB/xray/runtime.uc"; then
  fail "URLTest worker must not use object shorthand { tag, delay }"
fi
if awk '/^let xray_geodata = require\("xray.geodata"\)/{found=1} END{exit found?0:1}' "$FORKOP_LIB/xray/runtime.uc"; then
  fail "xray runtime must not require geodata at top-level; urltest-worker would load list_cache/rulesets"
fi
require_contains "$FORKOP_LIB/core/engine.uc" 'sourcepath(1)' \
  "core.engine must return exports when required, ignoring ARGV of urltest-worker"
require_contains "$FORKOP_LIB/xray/generator.uc" 'function add_interfaces' \
  "xray sections must emit freedom outbounds for bound interfaces"
require_contains "$FORKOP_LIB/xray/generator.uc" 'function apply_section_detour' \
  "xray sections must support outbound cascade via dialerProxy"
require_contains "$FORKOP_LIB/xray/generator.uc" 'function resolve_deferred_xray_detours' \
  "xray-to-xray cascade must chain via the target outbound tag, not a self-SOCKS hop"
require_contains "$FORKOP_LIB/xray/generator.uc" 'function is_chainable_leaf' \
  "interface/freedom outbounds must not receive dialerProxy (same as sing-box)"
require_contains "$FORKOP_LIB/xray/outbound.uc" 'function convert_interface' \
  "xray must convert interface bindings to freedom+sockopt.interface"
require_contains "$FORKOP_LIB/xray/outbound.uc" 'interface: iface' \
  "xray interface bindings must set sockopt.interface"
require_contains "$FORKOP_LIB/xray/outbound.uc" 'domainStrategy: "UseIP"' \
  "xray interface freedom outbounds must resolve domains before binding the NIC"
require_contains "$FORKOP_LIB/xray/outbound.uc" 'function apply_dialer_proxy' \
  "xray cascade must set sockopt.dialerProxy on leaf outbounds"
require_contains "$GENERATOR_UC" 'function add_xray_cascade_inbounds' \
  "sing-box must accept xray cascade dials into a sing-box section"
require_contains "$GENERATOR_UC" 'function insert_route_rules_after_system' \
  "xray cascade inbounds must be routed before domain/IP matchers steal the hop"

require_contains "$FORKOP_LIB/xray/runtime.uc" 'function parse_xray_version' \
  "xray version parsing must live in runtime.uc"
require_contains "$FORKOP_LIB/xray/runtime.uc" 'lc(fields[0]) == "xray"' \
  "xray version must be read from the second field of 'Xray 25.x.x ...'"
require_contains "$FORKOP_LIB/xray/runtime.uc" 'function uci_xray_section_count' \
  "diagnostics must see configured xray sections before generate-config"
require_contains "$FORKOP_LIB/xray/runtime.uc" 'uci_xray_section_count() == 0 && !engine.is_xray_primary()' \
  "xray init-config must skip generation when no Xray sections and sing-box is the plane"
require_contains "$FORKOP_LIB/xray/runtime.uc" 'logger' \
  "xray runtime errors must go to syslog via logger"
require_contains "$LIFECYCLE_UC" 'Preparing Xray' \
  "lifecycle must log before xray_init_config so start failures are visible"


require_contains "$CONNECTIONS_UC" 'function routing_engine()' \
  "UCI connections must expose settings.routing_engine"
require_contains "$CONNECTIONS_UC" 'function is_xray_primary()' \
  "UCI connections must expose is_xray_primary"
require_contains "$FORKOP_LIB/core/engine.uc" 'function routing_engine()' \
  "core.engine must resolve the routing plane"
require_contains "$FORKOP_LIB/core/engine.uc" 'function need_xray()' \
  "Xray is required only as the routing plane or as a section sidecar"
require_contains "$ROOT_DIR/luci-app-forkop/htdocs/luci-static/resources/view/forkop/settings.js" \
  'Neither core is bundled with Forkop' \
  "LuCI must say cores are Components, not a native package core"
require_contains "$FORKOP_LIB/core/engine.uc" 'sidecar_engine' \
  "core.engine must name the sidecar core"
require_contains "$FORKOP_LIB/xray/constants.uc" 'XRAY_TPROXY_PORT = 1602' \
  "xray plane must reuse tproxy port 1602"
require_contains "$FORKOP_LIB/xray/constants.uc" 'SINGBOX_SIDECAR_PORT = 4536' \
  "xray plane must SOCKS into sing-box on 4536"
require_contains "$FORKOP_LIB/xray/constants.uc" 'FREEDOM_TAG = "direct"' \
  "xray freedom outbound tag must be defined"
require_contains "$FORKOP_LIB/xray/constants.uc" 'BLACKHOLE_TAG = "block"' \
  "xray blackhole outbound tag must be defined"
require_contains "$FORKOP_LIB/xray/generator.uc" 'function apply_primary_plane' \
  "xray generator must emit tproxy/FakeDNS when it is the routing plane"
require_contains "$FORKOP_LIB/xray/generator.uc" 'function apply_primary_tproxy_routes' \
  "xray tproxy routes must be applied after section outbounds exist"
require_contains "$FORKOP_LIB/xray/generator.uc" 'function section_socks_route_target' \
  "xray tproxy must reuse the section SOCKS outbound/balancer, not a missing xray-NAME tag"
require_contains "$FORKOP_LIB/xray/generator.uc" 'domain_suffix_text' \
  "xray plane domain matchers must read domain_suffix_text"
require_contains "$FORKOP_LIB/xray/generator.uc" 'FAKEIP_INET6_RANGE' \
  "xray FakeDNS must include the IPv6 pool"
require_contains "$FORKOP_LIB/xray/runtime.uc" 'remember(xray_constants.XRAY_TPROXY_PORT)' \
  "xray primary plane must expect tproxy :1602 even with zero xray sections"
require_contains "$FORKOP_LIB/xray/generator.uc" 'function apply_dial_strategy' \
  "prefer_ipv4 must be applied as outbound UseIPv4v6, not only DNS UseIP"
require_contains "$FORKOP_LIB/xray/generator.uc" 'blockTypes' \
  "dns-out must reject HTTPS/SVCB (types 64/65) instead of leaking them upstream"
require_contains "$FORKOP_LIB/xray/generator.uc" 'function section_converted_lists' \
  "xray plane must convert community lists into Xray domain/IP matchers"
require_contains "$FORKOP_LIB/dns/apply.uc" 'filter-rr=HTTPS' \
  "dnsmasq must strip HTTPS records to match sing-box query_type reject"
require_contains "$FORKOP_LIB/xray/geodata.uc" 'ext:allow-domains.dat:' \
  "itdoginfo country/service lists must become ext:allow-domains.dat matchers"
require_contains "$FORKOP_LIB/xray/geodata.uc" 'rule-set", "decompile' \
  "custom .srs lists must decompile via sing-box when Xray is the plane"
require_contains "$FORKOP_LIB/xray/runtime.uc" 'ensure_from_uci' \
  "xray init-config must convert lists before generating config"
require_contains "$GENERATOR_UC" 'add_xray_sidecar_outbound(config, section, taken)' \
  "sing-box must keep Xray SOCKS leaves when Xray is the plane (dashboard, probe, community lists)"

if awk '
  $0 ~ /function add_outbound_for_section/ { in_fn = 1 }
  in_fn && $0 ~ /^function / && $0 !~ /function add_outbound_for_section/ { in_fn = 0 }
  in_fn && $0 ~ /engine.is_xray_primary\(\)/ { found = 1 }
  END { exit found ? 0 : 1 }
' "$GENERATOR_UC"; then
  fail "add_outbound_for_section must not skip Xray sidecar outbounds when Xray is primary"
fi
if awk '
  $0 ~ /^function add_route_for_section\(\)/ { in_fn = 1 }
  in_fn && $0 ~ /^function / && $0 !~ /^function add_route_for_section\(\)/ { in_fn = 0 }
  in_fn && $0 ~ /engine.is_xray_primary\(\)/ { found = 1 }
  END { exit found ? 0 : 1 }
' "$GENERATOR_UC"; then
  fail "add_route_for_section must keep community-list matching for Xray sections on the sing-box sidecar"
fi

require_contains "$FORKOP_LIB/xray/generator.uc" 'protocol: "dokodemo-door"' \
  "xray plane inbound must be dokodemo-door tproxy"
require_contains "$FORKOP_LIB/xray/runtime.uc" 'engine.is_xray_primary()' \
  "xray runtime must start when Xray is the routing plane"
require_contains "$GENERATOR_UC" 'engine.is_xray_primary()' \
  "sing-box generator must skip tproxy when Xray is the routing plane"
require_contains "$GENERATOR_UC" 'XRAY_PLANE_MIXED_INBOUND_TAG' \
  "sing-box must expose a mixed inbound for the Xray plane sidecar"
require_contains "$LIFECYCLE_UC" 'Routing plane is Xray' \
  "lifecycle must log the Xray routing plane"
require_contains "$LIFECYCLE_UC" 'sing-box sidecar is not required' \
  "Xray-only configs must skip the sing-box sidecar"
require_contains "$VALIDATOR_UC" 'settings.routing_engine' \
  "validator must check routing_engine"
require_contains "$ROOT_DIR/luci-app-forkop/htdocs/luci-static/resources/view/forkop/settings.js" 'routing_engine' \
  "LuCI settings must expose Routing engine"
require_contains "$SECTION_JS" 'Empty follows Settings → Routing engine' \
  "section proxy_core help must follow the selected routing engine"

require_contains "$CONNECTIONS_UC" 'function proxy_core(section)' \
  "UCI connections must expose per-section proxy_core"
require_contains "$CONNECTIONS_UC" 'if (value == "xray" || value == "xray-core")' \
  "proxy_core must accept xray"
require_contains "$CONNECTIONS_UC" 'return routing_engine()' \
  "empty proxy_core must follow the selected routing plane, not a native core"

require_contains "$GENERATOR_UC" 'function add_xray_sidecar_outbound' \
  "sing-box must emit a SOCKS sidecar for xray sections"
require_contains "$GENERATOR_UC" 'routing_mark: runtime_constants.OUTBOUND_MARK' \
  "xray sidecar SOCKS outbound must use the Forkop outbound mark"
require_contains "$GENERATOR_UC" 'connections.proxy_core(section) == "xray"' \
  "sing-box generator must branch on proxy_core=xray"
require_contains "$GENERATOR_UC" 'type: "selector"' \
  "xray sidecar must expose a Clash selector so Outbounds diagnostics can probe it"
require_contains "$GENERATOR_UC" 'domain_resolver: runtime_constants.DNS_SERVER_TAG' \
  "xray sidecar SOCKS must resolve via real DNS, not FakeIP"
require_contains "$GENERATOR_UC" 'unique_tag(as_string(node.tag' \
  "xray sidecar leaf tag must not collide with the section selector"
require_contains "$FORKOP_LIB/xray/outbound.uc" 'function vless_has_transport_security' \
  "Xray 26.9+ must skip plaintext VLESS instead of aborting the whole config"
require_contains "$FORKOP_LIB/xray/outbound.uc" 'native_vless_is_plaintext' \
  "native VLESS JSON without TLS must not be emitted"
require_contains "$FORKOP_LIB/xray/runtime.uc" 'latency-test' \
  "dashboard latency must probe Xray SOCKS when Clash is absent"
require_contains "$FORKOP_LIB/service/ui.uc" 'need_singbox_sidecar' \
  "latency worker must not call Clash when the sidecar is not running"
require_contains "$FORKOP_LIB/subscription/parser.uc" 'query.ech' \
  "hysteria2/vless share-links must parse the ech query parameter"

require_contains "$LIFECYCLE_UC" 'xray_init_config()' \
  "lifecycle must generate xray config"
require_contains "$LIFECYCLE_UC" 'module_success(XRAY_UC, [ "start-runtime" ])' \
  "lifecycle must start xray as plane or sidecar"
require_contains "$LIFECYCLE_UC" 'start sing-box sidecar' \
  "Xray plane still starts the sing-box sidecar when a section needs it"
require_contains "$LIFECYCLE_UC" 'module_success(XRAY_UC, [ "stop-runtime" ])' \
  "lifecycle must stop xray after sing-box"
require_contains "$LIFECYCLE_UC" 'module_success(XRAY_UC, [ "reload-runtime" ])' \
  "reload must refresh the xray sidecar"

require_contains "$ACTION_UC" 'function install_xray' \
  "components must install Xray-core from GitHub"
require_contains "$ACTION_UC" 'function remove_xray' \
  "components must be able to remove Xray-core"
require_contains "$ACTION_UC" 'function list_xray_versions' \
  "components must list Xray GitHub releases for the version picker"
require_contains "$ACTION_UC" 'function dispatch_xray' \
  "component_action must dispatch xray install/check/list_versions"
require_contains "$ACTION_UC" 'index(action, "install@") == 0' \
  "xray install must accept a specific version tag"
require_contains "$ACTION_UC" 'function parse_xray_version_text' \
  "install must parse Xray version from the second field"
require_contains "$ACTION_UC" 'procd_set_param command \"$PROG\" run -c \"$CONF\"' \
  "managed xray init must not load /etc/xray as confdir (geo .dat files live there)"

require_contains "$UPDATER_UC" 'function xray_arch_suffix' \
  "updater must map router arch to Xray zip suffix"
require_contains "$UPDATER_UC" 'linux-arm64-v8a' \
  "updater must support aarch64 Xray zips"
require_contains "$ACTION_UC" 'prerelease_versions' \
  "Xray list_versions must return pre-release tags separately from stable"
require_contains "$UPDATER_UC" 'function xray_asset_url' \
  "updater must resolve the Xray GitHub asset URL"
require_contains "$UPDATES_UC" 'component == "xray"' \
  "updates cache must accept the xray component"

require_contains "$VALIDATOR_UC" 'core == "xray" && !context.xray_installed' \
  "validator must refuse xray sections when the binary is missing"
require_contains "$VALIDATOR_UC" 'value.protocol' \
  "validator must accept native Xray JSON outbounds"

require_contains "$DIAG_RUNTIME_UC" 'XRAY_RUNTIME_UC' \
  "diagnostics runtime must call xray/runtime.uc"
require_contains "$DIAG_RUNTIME_UC" 'xray_version' \
  "system information must include xray_version"
require_contains "$DIAG_RUNTIME_UC" 'check-xray' \
  "diagnostics must expose check-xray"
require_contains "$DIAG_RUNTIME_UC" 'Xray status' \
  "global_check must print an Xray status block"
require_contains "$DIAG_STATUS_UC" 'function render_global_xray_check' \
  "CLI status must render the Xray check"
require_contains "$DIAG_STATUS_UC" 'Xray:' \
  "CLI system information must always print Xray version"

require_contains "$FORKOP_BIN" 'check_xray' \
  "CLI must expose check_xray"
require_contains "$FORKOP_BIN" 'get_xray_status' \
  "CLI must expose get_xray_status"
require_contains "$FORKOP_BIN" 'get_xray_nodes' \
  "CLI must expose get_xray_nodes for the dashboard"
require_contains "$FORKOP_BIN" 'set_xray_group_proxy' \
  "CLI must expose set_xray_group_proxy for manual Xray outbound switching"
require_contains "$FE_SRC/forkop/tabs/dashboard/initController.ts" 'setXrayGroupProxy' \
  "dashboard must switch Xray outbounds through Xray, not Clash API"
require_contains "$MAIN_JS" 'setXrayGroupProxy' \
  "LuCI dashboard must switch Xray outbounds through Xray, not Clash API"

require_contains "$SECTION_JS" '"proxy_core"' \
  "LuCI section settings must expose proxy_core"
require_contains "$SECTION_JS" 'o.value("xray", "Xray")' \
  "LuCI proxy_core must offer Xray"
require_contains "$FORKOP_JS" 'xrayInstalled' \
  "LuCI entrypoint must track xrayInstalled capability"

require_contains "$FE_SRC/forkop/types.ts" "CHECK_XRAY = 'check_xray'" \
  "frontend types must include CHECK_XRAY"
require_contains "$FE_SRC/forkop/types.ts" "| 'xray'" \
  "frontend ComponentName must include xray"
require_contains "$FE_SRC/forkop/helpers/getComponentActionKey.ts" "'xray:install': 'xrayInstall'" \
  "frontend must map xray component actions"
require_contains "$FE_SRC/forkop/tabs/updates/initController.ts" "component: 'xray'" \
  "Updates tab must show an Xray card"
require_contains "$FE_SRC/forkop/tabs/updates/initController.ts" "class: 'fkp_xray-version-select'" \
  "Updates tab must offer an Xray version picker"
require_contains "$FE_SRC/forkop/tabs/updates/initController.ts" 'function loadCoreVersionLists' \
  "sing-box and Xray version lists must load from GitHub in parallel, not through the component lock"
require_contains "$FE_SRC/forkop/tabs/updates/initController.ts" "result.component === 'xray'" \
  "list_versions results must not overwrite the sing-box version list"
require_contains "$FE_SRC/forkop/tabs/diagnostic/partials/renderAvailableActions.ts" "Show Xray config" \
  "diagnostics must have a Show Xray config button"
require_contains "$FE_SRC/forkop/types.ts" "SHOW_XRAY_CONFIG = 'show_xray_config'" \
  "frontend types must include SHOW_XRAY_CONFIG"
require_contains "$DIAG_RUNTIME_UC" 'show-xray-config' \
  "diagnostics runtime must dump the Xray config"
require_contains "$DIAG_STATUS_UC" 'mask-xray-config' \
  "diagnostics must mask secrets in the Xray config dump"
require_contains "$FORKOP_BIN" 'show_xray_config' \
  "CLI must expose show_xray_config"
require_contains "$FORKOP_LIB/xray/generator.uc" 'display_names[tag] = iface' \
  "xray interface nodes must keep the VPN interface name for the dashboard"
require_contains "$GENERATOR_UC" 'urltest_candidates' \
  "xray sidecar URLTest must wrap Clash urltest of SOCKS leaves, not only the Xray balancer"
require_contains "$FE_SRC/forkop/tabs/diagnostic/checks/runXrayCheck.ts" 'export async function runXrayCheck' \
  "diagnostics must run an Xray check"
require_contains "$FE_SRC/forkop/tabs/monitoring/initController.ts" "type MonitoringTabId = 'active' | 'closed' | 'cores'" \
  "monitoring must have a Cores tab"
require_contains "$FE_SRC/forkop/tabs/monitoring/initController.ts" "normalizeString(section.proxy_core).toLowerCase() === 'xray'" \
  "monitoring must map section.proxy_core to Xray"
require_contains "$FE_SRC/forkop/tabs/monitoring/render.ts" "_('Cores')" \
  "monitoring UI must render the Cores tab button"

require_contains "$FORKOP_LIB/xray/constants.uc" 'XRAY_NODE_PORT_BASE = 11008' \
  "each xray share-link must get its own SOCKS port from 11008"
require_contains "$FORKOP_LIB/xray/constants.uc" 'XRAY_NODES_FILE' \
  "xray generator must write a per-node sidecar map"
require_contains "$FORKOP_LIB/xray/generator.uc" 'node_inbound_tag' \
  "xray must emit a SOCKS inbound per outbound so the dashboard can select it"
require_contains "$GENERATOR_UC" 'function read_xray_section_nodes' \
  "sing-box sidecar must expand all xray nodes into the Clash selector"
require_contains "$GENERATOR_UC" 'xray-nodes.json' \
  "sing-box sidecar must read the xray per-node port map"
require_contains "$FE_SRC/forkop/methods/custom/getDashboardSections.ts" 'function dashboardClashType' \
  "dashboard must show Xray node protocol instead of SOCKS"
require_contains "$FORKOP_LIB/xray/runtime.uc" 'function process_detected' \
  "Xray process check must not rely on pgrep -x xray alone"
require_contains "$FORKOP_LIB/xray/runtime.uc" 'pidof' \
  "Xray process check must use pidof"
require_contains "$FORKOP_LIB/xray/runtime.uc" 'ubus call service list' \
  "Xray process check must consult procd via ubus"
require_contains "$FORKOP_LIB/xray/runtime.uc" 'configured_ports_listening' \
  "Xray listening ports must come from the sidecar port map, not an empty default"
if awk '
  $0 ~ /^function ports_listening\(\)/ { in_fn = 1 }
  in_fn && $0 ~ /^function / && $0 !~ /^function ports_listening\(\)/ { in_fn = 0 }
  in_fn && $0 ~ /return true/ { found = 1 }
  END { exit found ? 0 : 1 }
' "$FORKOP_LIB/xray/runtime.uc"; then
  fail "ports_listening must not report success when Xray is unused or missing"
fi
require_contains "$FE_SRC/forkop/tabs/diagnostic/checks/runXrayCheck.ts" 'installed && Boolean(data.xray_ports_listening)' \
  "diagnostics must not mark Xray ports as listening when Xray is not installed"
require_contains "$FE_SRC/forkop/tabs/diagnostic/checks/runXrayCheck.ts" "Xray is not listening on ports" \
  "diagnostics must show a negative ports status when Xray is not listening"
require_contains "$FORKOP_LIB/xray/runtime.uc" 'XRAY_NODES_FILE' \
  "Xray port check must include per-node SOCKS inbounds"
require_contains "$LIFECYCLE_UC" 'Failed to start Xray sidecar' \
  "Forkop start must abort if the Xray sidecar fails to come up"
require_contains "$FE_SRC/forkop/tabs/dashboard/partials/renderSections.ts" '[section.displayName, renderCoreBadge(section.proxyCore)]' \
  "dashboard sections must show Xray/sing-box core badges"
if grep -Fq 'renderCoreBadge(outbound' "$FE_SRC/forkop/tabs/dashboard/partials/renderSections.ts"; then
  fail "dashboard outbound cards must not show a core badge"
fi
require_contains "$FE_SRC/forkop/tabs/dashboard/initController.ts" 'getXrayServiceRow' \
  "dashboard services widget must show Xray running state"
require_contains "$FE_SRC/forkop/tabs/dashboard/initController.ts" "key: _('Cores')" \
  "dashboard system info must count outbounds per core"
require_contains "$FORKOP_LIB/service/ui.uc" 'sing_box_needed' \
  "Xray-only mode must not report sing-box as running just because Forkop is up"
require_contains "$FE_SRC/forkop/tabs/dashboard/initController.ts" 'formatSingBoxServiceStatus' \
  "dashboard must show sing-box as unused when it is not the sidecar"
require_contains "$FE_SRC/forkop/tabs/dashboard/initController.ts" 'isSingBoxSidecarNeeded' \
  "dashboard must hide leftover sing-box when the sidecar is not required"
require_contains "$FE_SRC/forkop/methods/custom/getDashboardSections.ts" 'node.delay' \
  "Xray latency file delays must appear on dashboard cards"
require_contains "$FORKOP_LIB/xray/runtime.uc" 'function write_latency_delays' \
  "Xray group/proxy latency tests must persist delays for the dashboard"
require_contains "$FORKOP_LIB/xray/runtime.uc" 'write_latency_delays(result)' \
  "group latency must write xray-latency.json, not only stdout"
require_contains "$FORKOP_LIB/service/ui.uc" 'function xray_running' \
  "UI state must report whether the Xray process is running"
require_contains "$FORKOP_LIB/service/ui.uc" 'xray/runtime.uc' \
  "dashboard Xray status must reuse the runtime process check"

require_contains "$MAIN_JS" 'runXrayCheck' \
  "compiled LuCI main.js must include the Xray diagnostic check"
require_contains "$MAIN_JS" 'xrayInstall' \
  "compiled LuCI main.js must include Xray component actions"
require_contains "$MAIN_JS" 'monitoring-tab-cores' \
  "compiled LuCI main.js must include the Cores monitoring tab"
require_contains "$MAIN_JS" 'fkp_dashboard-page__core-badge' \
  "compiled LuCI main.js must badge dashboard sections with Xray/sing-box"
require_contains "$MAIN_JS" 'Not used' \
  "compiled LuCI main.js must label unused sing-box as Not used"
require_contains "$MAIN_JS" 'node.delay' \
  "compiled LuCI main.js must merge Xray SOCKS delays onto dashboard cards"

printf 'xray dual-core checks passed\n'
