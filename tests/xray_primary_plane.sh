#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/forkop/files/usr/lib"
XRAY_GEN="$LIB/xray/generator.uc"
XRAY_SERVERS="$LIB/xray/servers.uc"
XRAY_CONST="$LIB/xray/constants.uc"
XRAY_RT="$LIB/xray/runtime.uc"
XRAY_OUT="$LIB/xray/outbound.uc"
XRAY_GEO="$LIB/xray/geodata.uc"
SB_GEN="$LIB/singbox/generator.uc"
NFT_APPLY="$LIB/nft/apply.uc"
HOSTRESOLVE="$LIB/core/hostresolve.uc"
LIFECYCLE="$LIB/service/lifecycle.uc"
STATE="$LIB/service/state.uc"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok  %s\n' "$1"
}

require_file() {
  [ -r "$1" ] || fail "missing $1"
}

extract_fn() {
  local file="$1"
  local name="$2"
  awk -v name="$name" '
    $0 ~ "^function " name "\\(" { grab = 1 }
    grab { print }
    grab && $0 ~ /^}$/ { exit }
  ' "$file"
}

require_file "$XRAY_GEN"
require_file "$XRAY_SERVERS"
require_file "$XRAY_CONST"
require_file "$XRAY_RT"
require_file "$XRAY_OUT"
require_file "$XRAY_GEO"
require_file "$NFT_APPLY"
require_file "$SB_GEN"
require_file "$LIFECYCLE"
require_file "$STATE"

# --- P0: constants must exist or require("xray.constants") dies ---
grep -Eq 'const FREEDOM_TAG = "direct"' "$XRAY_CONST" ||
  fail "FREEDOM_TAG is exported but was never defined — Xray config generation cannot load"
grep -Eq 'const BLACKHOLE_TAG = "block"' "$XRAY_CONST" ||
  fail "BLACKHOLE_TAG is exported but was never defined"
pass "FREEDOM_TAG/BLACKHOLE_TAG are defined"

grep -Eq 'const XRAY_API_PORT = 10085' "$XRAY_CONST" ||
  fail "Xray stats API port must be defined"
extract_fn "$XRAY_GEN" "apply_stats_api" | grep -Fq 'StatsService' ||
  fail "Xray plane must enable StatsService for dashboard traffic"
extract_fn "$XRAY_GEN" "apply_stats_api" | grep -Fq 'listen' ||
  fail "Xray Stats API must listen without a dokodemo-door inbound"
extract_fn "$XRAY_RT" "xray_inbound_stats" | grep -Fq 'inbound>>>' ||
  fail "Xray stats must read inbound uplink/downlink"
extract_fn "$XRAY_RT" "stats_json" | grep -Fq 'section_traffic_map' ||
  fail "dashboard section traffic must sum outbound counters since Xray start"
extract_fn "$XRAY_RT" "nft_chain_bytes" | grep -Fq 'nft' ||
  fail "Xray stats must fall back to nft counters when the API is empty"
grep -Fq 'get_xray_connections' "$ROOT_DIR/forkop/files/usr/bin/forkop" ||
  fail "forkop CLI must expose get_xray_connections"
extract_fn "$XRAY_RT" "connections_json" | grep -Fq 'nf_conntrack' ||
  fail "Xray monitoring must read conntrack when Clash API is the sidecar"
extract_fn "$XRAY_RT" "filter_conntrack" | grep -Fq 'awk' ||
  fail "Xray monitoring must filter conntrack in awk before the ucode scan"
extract_fn "$XRAY_RT" "conntrack_filter_script" | grep -Fq 'dport=1602' ||
  fail "conntrack prefilter must keep TPROXY :1602 rows"
extract_fn "$XRAY_RT" "conntrack_is_forkop" | grep -Fq 'XRAY_TPROXY_PORT' ||
  fail "Xray monitoring must keep TPROXY redirected conntrack (dst 127.0.0.1:1602), not only FakeIP/mark"
extract_fn "$XRAY_RT" "connections_json" | grep -Fq 'access[' ||
  fail "Xray monitoring must keep unmarked conntrack rows that still match the access log"
extract_fn "$XRAY_RT" "select_outbound_json" | grep -Fq 'override_balancer_tag' ||
  fail "manual Xray server switch must retarget the section balancer without restarting"
extract_fn "$XRAY_RT" "override_balancer_tag" | grep -Fq 'api' ||
  fail "balancer switch must use the Xray Routing API"
extract_fn "$XRAY_RT" "select_outbound_json" | grep -Fq 'replace_routing_live' ||
  fail "if the balancer API fails, the switch must update routing rules without a restart"
extract_fn "$XRAY_RT" "replace_routing_live" | grep -Fq 'adrules' ||
  fail "routing fallback must use the Xray adrules API"
extract_fn "$XRAY_RT" "replace_routing_live" | grep -Fq '"-t", "60"' ||
  fail "routing API replace must wait long enough for a large ruleset"
extract_fn "$XRAY_RT" "apply_saved_balancer_overrides" | grep -Fq 'section_rule_already_pinned' ||
  fail "restoring a pinned server must not call adrules when the generated rule already matches"
extract_fn "$XRAY_RT" "apply_saved_balancer_overrides" | grep -Fq 'pin_targets_live_node' ||
  fail "stale dashboard pins must not be pushed into Xray routing"
extract_fn "$XRAY_RT" "select_outbound_json" | grep -Fq 'reload_runtime' ||
  fail "manual Xray server switch must still reload if both live APIs fail"
extract_fn "$XRAY_GEN" "apply_stats_api" | grep -Fq 'RoutingService' ||
  fail "Xray API must expose RoutingService for live balancer override"
extract_fn "$XRAY_GEN" "read_selected_outbounds" | grep -Fq 'XRAY_SELECTED_FILE' ||
  fail "Xray config generation must honor the pinned dashboard outbound"
extract_fn "$XRAY_GEN" "xray_balancer_strategy" | grep -Fq 'return "random"' ||
  fail "Xray sections without URLTest must default to a random balancer"
extract_fn "$XRAY_GEN" "xray_balancer_strategy" | grep -Fq 'return "roundRobin"' ||
  fail "Xray balancer must support round robin"
extract_fn "$XRAY_OUT" "apply_mux" | grep -Fq 'xudpConcurrency' ||
  fail "Xray Mux must be able to carry UDP"
extract_fn "$XRAY_OUT" "apply_mux" | grep -Fq 'vision' ||
  fail "VLESS Vision must not be wrapped in Mux"
extract_fn "$XRAY_GEN" "section_mux_spec" | grep -Fq 'xray_mux_enabled' ||
  fail "section Mux settings must reach the Xray outbound"
extract_fn "$XRAY_RT" "nodes_with_latency" | grep -Fq 'probed' ||
  fail "every probed Xray server must keep a dead-or-alive mark"
extract_fn "$XRAY_RT" "urltest_tick" | grep -Fq 'record_node_delays' ||
  fail "Xray must probe every server in a section, not only the selected one"
extract_fn "$XRAY_GEN" "xray_balancer_strategy" | grep -Fq 'return "off"' ||
  fail "Xray balancer must be possible to turn off"
extract_fn "$XRAY_GEN" "add_section" | grep -Fq 'strategy != "off"' ||
  fail "turning the balancer off must send traffic to one server"
extract_fn "$XRAY_GEN" "add_section" | grep -Fq 'least_load_settings' ||
  fail "least load must pass expected, maxRTT and tolerance to Xray"
extract_fn "$XRAY_GEN" "add_section" | grep -Fq 'strategy_needs_observatory' ||
  fail "least ping and least load must probe servers before choosing one"
extract_fn "$XRAY_GEN" "apply_balancer_fallbacks" | grep -Fq 'fallbackTag' ||
  fail "fallback must be one outbound from another section, not another balancer"
extract_fn "$XRAY_GEN" "section_fallback_request" | grep -Fq 'xray_fallback_target' ||
  fail "fallback server must be read from xray_fallback_target"
extract_fn "$XRAY_GEN" "apply_dial_strategy" | grep -Fq 'protocol == "hysteria"' ||
  fail "Hysteria2 QUIC outbounds must not get TCP domainStrategy sockopt"
extract_fn "$XRAY_OUT" "convert_hysteria2" | grep -Fq 'udphop' ||
  fail "Hysteria2 share-links with port hopping must map server_ports to udphop"
extract_fn "$XRAY_OUT" "apply_hysteria_finalmask" | grep -Fq 'salamander' ||
  fail "Hysteria2 salamander obfs must be emitted as FinalMask udp salamander"
extract_fn "$XRAY_OUT" "apply_tcp_finalmask" | grep -Fq 'type: "fragment"' ||
  fail "ordinary Xray protocols must be able to add TCP FinalMask fragment"
extract_fn "$XRAY_OUT" "apply_tcp_finalmask" | grep -Fq 'maxSplit' ||
  fail "FinalMask fragment must be able to set maxSplit"
extract_fn "$XRAY_OUT" "apply_tcp_finalmask" | grep -Fq 'type: "noise"' ||
  fail "FinalMask must be able to add UDP noise"
extract_fn "$XRAY_OUT" "apply_freedom_fragment" | grep -Fq 'fragment_packets' ||
  fail "direct Xray freedom outbounds must support TLS hello fragment"
extract_fn "$XRAY_OUT" "fragment_packets" | grep -Fq 'tlshello' ||
  fail "fragment packets must keep tlshello"
extract_fn "$XRAY_OUT" "apply_freedom_fragment" | grep -Fq 'noises' ||
  fail "direct fragment must be able to add TCP noise"
extract_fn "$XRAY_GEN" "section_finalmask_spec" | grep -Fq 'xray_finalmask' ||
  fail "section FinalMask must follow the section checkbox"
extract_fn "$XRAY_GEN" "global_freedom_fragment_spec" | grep -Fq 'xray_freedom_fragment' ||
  fail "direct fragment must follow the settings checkbox"
grep -Fq 'get_xray_nodes' "$ROOT_DIR/forkop/files/usr/bin/forkop" ||
  fail "forkop CLI must expose get_xray_nodes"
grep -Fq 'set_xray_group_proxy' "$ROOT_DIR/forkop/files/usr/bin/forkop" ||
  fail "forkop CLI must expose set_xray_group_proxy"
extract_fn "$XRAY_GEN" "empty_config" | grep -Fq 'XRAY_ACCESS_LOG' ||
  fail "Xray access log is required to attach host/route to monitoring rows"
pass "Xray plane exposes connections for the monitoring tab"
pass "Xray plane exposes Stats API for dashboard traffic"

# --- P0: tproxy routes after add_section, using real outbound/balancer ---
gen="$(cat "$XRAY_GEN")"
printf '%s' "$gen" | grep -Fq 'function apply_primary_tproxy_routes' ||
  fail "missing apply_primary_tproxy_routes"
printf '%s' "$gen" | grep -Fq 'function section_socks_route_target' ||
  fail "tproxy must copy the SOCKS inbound target (balancer or first leaf)"

awk '
  /if \(engine.is_xray_primary\(\)\)/ { n++ }
  /apply_primary_plane/ && n == 1 { plane = NR }
  /add_section/ { add = NR }
  /apply_primary_tproxy_routes/ { tproxy = NR }
  END {
    if (plane == 0 || add == 0 || tproxy == 0) exit 1
    if (!(plane < add && add < tproxy)) exit 2
  }
' "$XRAY_GEN" || fail "generate_config order must be plane inbounds → add_section → tproxy routes"

extract_fn "$XRAY_GEN" "apply_primary_tproxy_routes" | grep -Fq 'outbound_tag(name)' &&
  fail "tproxy must not point at a synthetic xray-NAME outbound that add_section never creates"
extract_fn "$XRAY_GEN" "apply_primary_tproxy_routes" | grep -Fq 'section_tproxy_target' ||
  fail "tproxy section rules must use section_tproxy_target"
extract_fn "$XRAY_GEN" "apply_primary_tproxy_routes" | grep -Fq 'section_policy_tproxy_target' ||
  fail "Xray tproxy must emit bypass/block before connection sections"
extract_fn "$XRAY_GEN" "section_policy_tproxy_target" | grep -Fq 'bypass' ||
  fail "bypass sections must route to freedom/direct on the Xray plane"
extract_fn "$XRAY_GEN" "section_policy_tproxy_target" | grep -Fq 'block' ||
  fail "block sections must route to blackhole on the Xray plane"
awk '
  /^function section_policy_tproxy_target\(/ { p = NR }
  /^function apply_primary_tproxy_routes\(/ { a = NR }
  END { if (p == 0 || a == 0 || p > a) exit 1 }
' "$XRAY_GEN" ||
  fail "ucode binds names at definition time; section_policy_tproxy_target must be defined before apply_primary_tproxy_routes"
extract_fn "$XRAY_GEN" "section_tproxy_target" | grep -Fq 'section_socks_route_target' ||
  fail "Xray sections must keep SOCKS inbound target (balancer or first leaf)"
extract_fn "$XRAY_GEN" "section_tproxy_target" | grep -Fq 'SINGBOX_SIDECAR_TAG' ||
  fail "sing-box sections must hand restored FakeDNS names to the sidecar, not 198.18.x"
extract_fn "$XRAY_GEN" "apply_section_tproxy_matchers" | grep -Fq 'push_tproxy_rule' ||
  fail "tproxy domain and ip matchers must be separate rules (Xray ANDs fields in one rule)"
extract_fn "$XRAY_GEN" "apply_section_tproxy_sources" | grep -Fq 'fully_routed_ips' ||
  fail "Xray tproxy must honor fully_routed_ips as source rules (separate from domain/ip)"
awk '
  /^function service_exists\(/ { s = NR }
  /^function procd_instance_running\(/ { p = NR }
  END { if (s == 0 || p == 0 || s > p) exit 1 }
' "$XRAY_RT" ||
  fail "ucode: service_exists must be defined before procd_instance_running"
awk '
  /^function push_tproxy_rule\(/ { p = NR }
  /^function apply_primary_tproxy_routes\(/ { a = NR }
  END { if (p == 0 || a == 0 || p > a) exit 1 }
' "$XRAY_GEN" ||
  fail "ucode binds names at definition time; push_tproxy_rule must be defined before apply_primary_tproxy_routes"
extract_fn "$XRAY_GEN" "plane_fallback_tag" | grep -Fq 'FREEDOM_TAG' ||
  fail "Xray default route must be direct when no section uses the sing-box sidecar"
extract_fn "$XRAY_GEN" "apply_primary_tproxy_routes" | grep -Fq 'plane_fallback_tag' ||
  fail "TPROXY catch-all must use plane_fallback_tag, not a hard-coded sidecar"
extract_fn "$XRAY_GEN" "apply_primary_tproxy_routes" | grep -Fq 'BLACKHOLE_TAG' ||
  fail "unmatched FakeIP 198.18/15 must stay on Xray blackhole, never sidecar/direct"
awk '
  /^function section_tproxy_target\(/ { t = NR }
  /^function apply_primary_tproxy_routes\(/ { a = NR }
  END { if (t == 0 || a == 0 || t > a) exit 1 }
' "$XRAY_GEN" ||
  fail "ucode binds names at definition time; section_tproxy_target must be defined before apply_primary_tproxy_routes"
pass "tproxy routes use real section outbounds; unmatched traffic stays on Xray when sections are Xray"

# --- P0: domain_suffix_text / keyword / regex ---
extract_fn "$XRAY_GEN" "tproxy_inbound" | grep -Fq '"tls"' ||
  fail "real-IP TPROXY sniff must use TLS SNI so AdGuard youtube still matches NL"
extract_fn "$XRAY_GEN" "tproxy_inbound" | grep -Fq 'routeOnly: true' ||
  fail "real-IP TPROXY must keep dest IP (routeOnly) so CDN subnet rules still match"
grep -Fq 'const XRAY_SECTION_PIN_PORT_BASE = 17020' "$XRAY_CONST" ||
  fail "resolved-domain pin must use a dedicated TPROXY port base"
grep -Fq 'section_pin_specs' "$XRAY_CONST" ||
  fail "Xray constants must export section pin specs"
extract_fn "$XRAY_CONST" "section_pin_has_recorded_domains" | grep -Fq 'community_lists' ||
  fail "youtube-style community lists must be pinned to their section"
extract_fn "$XRAY_CONST" "section_pin_specs" | grep -Fq 'is_xray_primary' ||
  fail "section pin specs are only for the Xray plane"
if extract_fn "$XRAY_CONST" "section_pin_specs" | grep -Fq 'bypass'; then
  fail "bypass sections must not pin resolved addresses onto a capture inbound"
fi
extract_fn "$XRAY_GEN" "apply_primary_tproxy_routes" | grep -Fq 'apply_section_resolved_pins(config)' ||
  fail "Xray routing must hard-wire pinned inbounds to the section outbound before the final direct rule"
awk '
  /^function apply_section_resolved_pins\(/ { p = NR }
  /^function apply_primary_tproxy_routes\(/ { a = NR }
  END { if (p == 0 || a == 0 || p > a) exit 1 }
' "$XRAY_GEN" ||
  fail "ucode binds names at definition time; apply_section_resolved_pins must be defined before apply_primary_tproxy_routes"
extract_fn "$XRAY_GEN" "apply_section_resolved_pins" | grep -Fq 'section_pin_tag' ||
  fail "pin routing must match only the dedicated pin inbound"
extract_fn "$XRAY_GEN" "tproxy_pin_inbound" | grep -Fq 'tproxy_inbound' ||
  fail "pin inbound must keep the real CDN address (routeOnly TPROXY)"
extract_fn "$NFT_APPLY" "nft_install_resolved_pin_tproxies" | grep -Fq '_resolved' ||
  fail "section pin must tproxy dnsmasq-resolved addresses"
extract_fn "$NFT_APPLY" "nft_install_resolved_pin_tproxies" | grep -Fq 'nft_insert_rule' ||
  fail "section pin rules must be inserted ahead of generic TPROXY :1602"
extract_fn "$NFT_APPLY" "nft_install_resolved_pin_tproxies" | grep -Fq 'accept' ||
  fail "section pin must accept after tproxy so :1602 does not overwrite the section port"
extract_fn "$NFT_APPLY" "nft_install_resolved_pin_tproxies" | grep -Fq 'FAKEIP_INET4_RANGE' ||
  fail "section pin must not capture FakeIP; those flows belong to the FakeDNS inbound"
extract_fn "$NFT_APPLY" "nft_add_section_priority_rules_from_sections" | grep -Fq 'nft_install_resolved_pin_tproxies' ||
  fail "nft rebuild must install section pins after resolved sets exist"
awk '
  /^function nft_install_resolved_pin_tproxies\(/ { p = NR }
  /^function nft_add_section_priority_rules_from_sections\(/ { a = NR }
  END { if (p == 0 || a == 0 || p > a) exit 1 }
' "$NFT_APPLY" ||
  fail "ucode binds names at definition time; nft_install_resolved_pin_tproxies must be defined before its caller"
extract_fn "$XRAY_GEN" "tproxy_inbound" | grep -Fq '"fakedns"' ||
  fail "TPROXY must destOverride FakeIP even on :1602; Xray replaces dest when the IP is in the FakeDNS pool"
extract_fn "$XRAY_GEN" "apply_primary_tproxy_routes" | awk '
  /FAKEIP_INET4_RANGE/ { f = NR }
  /apply_section_tproxy_sources/ { s = NR }
  END { if (!(f > 0 && s > 0 && f < s)) exit 1 }
' || fail "unmatched FakeIP must blackhole before BLESS fully_routed sources"
extract_fn "$XRAY_GEN" "tproxy_fakeip_inbound" | grep -Fq '"fakedns"' ||
  fail "FakeIP TPROXY sniff must destOverride FakeIP to the domain"
extract_fn "$XRAY_GEN" "tproxy_fakeip_inbound" | grep -Fq '"tls"' ||
  fail "FakeIP TPROXY must still read SNI when the FakeDNS pool forgot the IP"
extract_fn "$XRAY_GEN" "tproxy_fakeip_inbound" | grep -Fq 'routeOnly: false' ||
  fail "FakeIP TPROXY must replace dest so the proxy does not dial 198.18"
grep -Fq 'XRAY_TPROXY_FAKEIP_PORT = 1605' "$XRAY_CONST" ||
  fail "FakeIP TPROXY must listen on a second port"
extract_fn "$NFT_APPLY" "nft_create_runtime_base" | grep -Fq 'nft_install_xray_fakeip_tproxy' ||
  fail "nft must tproxy 198.18/15 to the FakeIP inbound before the generic 1602 rule"
extract_fn "$NFT_APPLY" "nft_install_xray_fakeip_tproxy" | grep -Fq 'XRAY_TPROXY_FAKEIP_PORT' ||
  fail "FakeIP TPROXY install must use XRAY_TPROXY_FAKEIP_PORT"
extract_fn "$NFT_APPLY" "nft_install_xray_fakeip_tproxy" | grep -Fq 'nft_insert_rule' ||
  fail "FakeIP TPROXY rules must be inserted first so 198.18 does not fall through to :1602"
extract_fn "$NFT_APPLY" "nft_install_xray_fakeip_tproxy" | grep -Fq '"counter", "accept"' ||
  fail "FakeIP TPROXY must accept so the generic :1602 rule does not override it"
extract_fn "$NFT_APPLY" "section_has_xray_domain_nft" | grep -Fq 'community_lists' ||
  fail "community list sections must create nft priority sets so dnsmasq nftset= has a target"
extract_fn "$NFT_APPLY" "nft_create_full_runtime_from_uci" | grep -Fq 'nftables failed: runtime base' ||
  fail "nft rebuild must name the failing step instead of aborting silently"
extract_fn "$NFT_APPLY" "nft_create_full_runtime_from_uci" | grep -Fq 'return true' ||
  fail "after FakeIP TPROXY is in place, later nft steps must not abort start"
extract_fn "$NFT_APPLY" "run_nft" | grep -Fq 'nftables failed' ||
  fail "nft command failures must be logged with a step name"
extract_fn "$LIFECYCLE" "start_main" | grep -Fq 'nftables rebuild reported an error; continuing' ||
  fail "start_main must not abort after nft rebuild once FakeIP TPROXY is in place"
extract_fn "$NFT_APPLY" "nft_create_full_runtime_from_uci" | grep -Fq 'nftables runtime model is ready' ||
  fail "nft rebuild must log when the table is ready so a later abort is visible"
extract_fn "$LIFECYCLE" "start_main" | grep -Fq 'nftables runtime applied' ||
  fail "start must log after nft rebuild so a hang/abort after FakeIP TPROXY is visible"
extract_fn "$LIFECYCLE" "start_main" | grep -Fq 'nft-write-xray-nftset-conf' ||
  fail "dnsmasq nftset must be written in a child process so a 3018-entry list cannot abort nft rebuild"
if extract_fn "$NFT_APPLY" "nft_create_full_runtime_from_uci" | grep -Fq 'write_xray_dnsmasq_nftset_conf'; then
  fail "nft rebuild must not expand community nftset lists in-process (that abort is silent after FakeIP TPROXY)"
fi
extract_fn "$LIFECYCLE" "start_main" | grep -Fq 'Failed to configure sing-box sidecar' ||
  fail "configure-service failure must not abort start silently"
extract_fn "$LIFECYCLE" "need_singbox_process" | grep -Fq 'engine.need_singbox' ||
  fail "need_singbox_process must call engine.need_singbox; trim/module_output are defined later and throw LHS is not a function"
extract_fn "$LIFECYCLE" "start_main" | grep -Fq 'engine.is_xray_primary' ||
  fail "start_main must read the plane from core.engine, not a subprocess after nft rebuild"
if extract_fn "$LIFECYCLE" "start_main" | grep -Fq 'Failed to resolve routing plane'; then
  fail "start must not abort on routing-plane lookup after nft is ready"
fi
extract_fn "$NFT_APPLY" "nft_add_section_priority_rules_from_sections" | grep -Fq 'priority rules incomplete' ||
  fail "configure-service failure must not abort start silently"
extract_fn "$NFT_APPLY" "nft_add_section_priority_rules_from_sections" | grep -Fq 'priority rules incomplete' ||
  fail "one section's nft rules must not abort the whole table rebuild"
extract_fn "$XRAY_GEN" "tproxy_inbound_tags" | grep -Fq 'XRAY_TPROXY_FAKEIP_TAG' ||
  fail "section routes must match both real-IP and FakeIP TPROXY inbounds"
! extract_fn "$XRAY_GEN" "tproxy_inbound" | grep -Fq 'fakedns+others' ||
  fail "fakedns+others is ignored by Xray; use fakedns,http,tls,quic"
extract_fn "$XRAY_GEN" "collect_fake_dns_domains" | grep -Fq 'bypass' ||
  fail "BYPASS must be excluded from FakeDNS so rustore is a real IP for freedom"
extract_fn "$XRAY_GEN" "collect_fake_dns_domains" | grep -Fq 'claimed' ||
  fail "DNS-action domains (AdGuard youtube) must not be swallowed by FakeDNS"
extract_fn "$XRAY_GEN" "collect_fake_dns_domains" | grep -Fq 'block' ||
  fail "FakeDNS must include BLOCK domains so 2ip.ru is not routed as a Hetzner IP"
extract_fn "$XRAY_GEN" "empty_config" | grep -Fq '"AsIs"' ||
  fail "Xray routing domainStrategy must be AsIs; IPIfNonMatch re-resolves FakeIP and blackholes 2ip.io"
extract_fn "$XRAY_GEN" "section_ip_matchers" | grep -Fq 'ip_cidr' ||
  fail "Xray IP rules must read LuCI ip_cidr, not the unused subnet key"
extract_fn "$XRAY_GEN" "collect_fake_dns_domains" | grep -Fq 'section_domain_matchers' ||
  fail "Xray FakeDNS must include domains from section rules and converted lists"
if extract_fn "$XRAY_GEN" "collect_fake_dns_domains" | grep -Fq 'section_uses_interface_outbound'; then
  fail "OpenConnect and other interface sections must use FakeDNS; real CDN IPs let YouTube QUIC leave via WAN"
fi
extract_fn "$XRAY_GEN" "xray_log_level" | grep -Fq 'log_level' ||
  fail "Xray must use the settings log level"
extract_fn "$XRAY_GEN" "output_network_interface" | grep -Fq 'enable_output_network_interface' ||
  fail "Xray direct dials must follow the output interface setting"
extract_fn "$XRAY_GEN" "apply_bittorrent_bypass" | grep -Fq 'bittorrent' ||
  fail "Exclude BitTorrent must send the bittorrent protocol direct on Xray"
extract_fn "$XRAY_GEN" "collect_fake_dns_domains" | grep -Fq 'fake_dns_domain_usable' ||
  fail "FakeDNS must drop geosite/ext matchers that are missing from dat"
extract_fn "$HOSTRESOLVE" "resolve_hosts" | grep -Fq '8.8.8.8' ||
  fail "domain intercept must resolve via upstream DNS, not FakeDNS/resolveip"
extract_fn "$HOSTRESOLVE" "resolve_hosts" | grep -Fq '77.88.8.8' ||
  fail "domain intercept must try 77.88.8.8 before the often-blocked 8.8.8.8"
extract_fn "$HOSTRESOLVE" "resolve_wave" | grep -Fq 'timeout 1' ||
  fail "domain intercept must resolve many hosts in parallel with a 1s timeout"
if grep -Fq 'tolower' "$HOSTRESOLVE"; then
  fail "ucode has no tolower(); hostresolve must use builtin lc()"
fi
extract_fn "$XRAY_GEN" "dns_pinned_ip" | grep -Fq 'dns.quad9.net' ||
  fail "DoQ/DoH3 names must be pinned so FakeDNS cannot answer the resolver"
extract_fn "$XRAY_GEN" "dns_pinned_ip" | grep -Fq '94.140.14.14' ||
  fail "AdGuard DoQ name must pin to 94.140.14.14"
extract_fn "$XRAY_GEN" "primary_dns_config" | grep -Fq 'dns_pinned_ip' ||
  fail "Xray hosts must pin DoQ/DoH3 names to real IPs"
extract_fn "$LIB/singbox/dns.uc" "server_from_options" | grep -Fq 'dns_pinned_ip' ||
  fail "sing-box DoQ/DoH3 must dial a pinned IP with the certificate name in SNI"
extract_fn "$NFT_APPLY" "nft_add_resolved_section_domains" | grep -Fq 'resolve_hosts' ||
  fail "nft populate must resolve section domains in one batch"
extract_fn "$NFT_APPLY" "resolve_host_is_fake_or_self" | grep -Fq '198.18.' ||
  fail "FakeIP answers must not be added to section nft sets"
extract_fn "$NFT_APPLY" "nft_populate_runtime_set_for_section" | grep -Fq 'nft_add_resolved_section_domains' ||
  fail "nft populate must add resolved inline domain IPs to the section set"
extract_fn "$XRAY_GEN" "section_ip_matchers" | grep -Fq 'section_user_domain_hosts' ||
  fail "Xray ip matchers must include resolved IPs of inline section domains"
extract_fn "$XRAY_GEN" "section_domain_matchers" | grep -Fq 'domain_keyword' ||
  fail "section_domain_matchers ignores domain_keyword"
extract_fn "$XRAY_GEN" "section_domain_matchers" | grep -Fq 'domain_regex' ||
  fail "section_domain_matchers ignores domain_regex"
extract_fn "$XRAY_GEN" "as_xray_domain_matcher" | grep -Fq 'full:' ||
  fail "exact domains must be emitted as Xray full: matchers"
extract_fn "$XRAY_GEN" "as_xray_domain_matcher" | grep -Fq 'keyword:' ||
  fail "keyword matchers must use Xray keyword: prefix"
extract_fn "$XRAY_GEN" "as_xray_domain_matcher" | grep -Fq 'regexp:' ||
  fail "regex matchers must use Xray regexp: prefix"
extract_fn "$XRAY_GEN" "as_xray_domain_matcher" | grep -Fq 'domain:' ||
  fail "LuCI Domains field is a suffix list and must become Xray domain: not full:"
extract_fn "$XRAY_GEN" "xray_query_strategy" | grep -Fq 'prefer_ipv4' ||
  fail "prefer_ipv4 must query A records only so FakeIP does not leak onto broken IPv6"
pass "domain matchers cover LuCI text fields and Xray prefixes"

# --- P0: sidecar always present on Xray plane ---
extract_fn "$XRAY_GEN" "apply_primary_plane" | grep -Fq 'singbox_sidecar_outbound' ||
  fail "Xray plane must always emit the sing-box SOCKS outbound (bypass/zapret/community lists)"
extract_fn "$XRAY_GEN" "apply_primary_plane" | grep -Fq 'primary_dns_config' ||
  fail "Xray plane must build DNS from settings, not a hardcoded UDP address"
extract_fn "$XRAY_GEN" "primary_dns_config" | grep -Fq 'FAKEIP_INET6_RANGE' ||
  fail "Xray FakeDNS is IPv4-only; IPv6 FakeIP range is missing"
extract_fn "$XRAY_GEN" "xray_dns_server_address" | grep -Fq 'https://' ||
  fail "Xray plane must map dns_type=doh to https:// DNS servers"
extract_fn "$XRAY_GEN" "xray_dns_server_address" | grep -Fq 'tls://' ||
  fail "Xray plane must map dns_type=dot to tls:// DNS servers"
extract_fn "$XRAY_GEN" "xray_dns_server_address" | grep -Fq 'quic+local://' ||
  fail "Xray DoQ must use quic+local://; plain quic:// is not a DNS client"
if extract_fn "$XRAY_GEN" "xray_dns_server_address" | grep -Fq 'h3://'; then
  fail "Xray has no h3:// DNS client; DoH3 on the Xray plane must use https://"
fi
extract_fn "$XRAY_GEN" "primary_dns_config" | grep -Fq 'pin_custom_dns_hosts' ||
  fail "Xray must resolve a custom DoQ hostname and pin it outside FakeIP"
extract_fn "$XRAY_GEN" "xray_dns_server_address" | grep -Fq 'tls_dns_name' ||
  fail "Xray DoQ must use an explicit certificate name for a custom IP"
extract_fn "$XRAY_GEN" "primary_dns_config" | grep -Fq 'dns_certificate_name' ||
  fail "settings certificate name must be attached only to an unknown IP"
extract_fn "$LIB/singbox/dns.uc" "server_from_options" | grep -Fq 'explicit_certificate_name' ||
  fail "sing-box DoQ must use the certificate name from a custom IP"
extract_fn "$LIB/singbox/dns.uc" "server_list" | grep -Fq 'dns_certificate_name' ||
  fail "sing-box must keep preset DoQ names and only fill a custom IP"
awk '
  /^function doh3_server_name\(/ { doh3 = NR }
  /^function doq_server_name\(/ { doq = NR }
  /^function preset_tls_name\(/ { preset = NR }
  END {
    if (doh3 == 0 || doq == 0 || preset == 0 || doh3 > preset || doq > preset)
      exit 1
  }
' "$LIB/singbox/dns.uc" ||
  fail "preset_tls_name must be declared after doq/doh3 helpers (ucode forward ref)"
grep -Fq 'dns_certificate_name' "$ROOT_DIR/luci-app-forkop/htdocs/luci-static/resources/view/forkop/settings.js" ||
  fail "settings must offer a certificate name for a custom DoQ IP"
grep -Fq 'dns_server_name' "$ROOT_DIR/luci-app-forkop/htdocs/luci-static/resources/view/forkop/section.js" ||
  fail "a DNS section must offer a certificate name for a custom DoQ IP"
extract_fn "$XRAY_GEN" "doq_hostname_for" | grep -Fq '94.140.14.14' ||
  fail "AdGuard DoQ IP must keep the certificate name dns.adguard-dns.com"
extract_fn "$XRAY_GEN" "doq_hostname_for" | grep -Fq 'dns.quad9.net' ||
  fail "DoQ to 9.9.9.9 must use dns.quad9.net"
extract_fn "$XRAY_GEN" "doq_hostname_for" | grep -Fq 'dns.alidns.com' ||
  fail "AliDNS DoQ hostname is dns.alidns.com:853"
if extract_fn "$XRAY_GEN" "doq_hostname_for" | grep -Eq 'dns.google|one.one.one.one|yandex|opendns'; then
  fail "DoQ must not invent hostnames for resolvers that do not publish DoQ"
fi
extract_fn "$XRAY_GEN" "doh3_hostname_for" | grep -Fq 'dns.google' ||
  fail "DoH3 to 8.8.8.8 must use dns.google"
extract_fn "$XRAY_GEN" "doh3_hostname_for" | grep -Fq 'cloudflare-dns.com' ||
  fail "DoH3 to 1.1.1.1 must use cloudflare-dns.com"
extract_fn "$LIB/singbox/dns.uc" "server_from_options" | grep -Fq '"quic"' ||
  fail "sing-box must map dns_type=doq to a quic DNS server"
extract_fn "$LIB/singbox/dns.uc" "server_from_options" | grep -Fq '"h3"' ||
  fail "sing-box must map dns_type=doh3 to an h3 DNS server"
extract_fn "$LIB/singbox/dns.uc" "doq_server_name" | grep -Fq 'dns.quad9.net' ||
  fail "Quad9 DoQ name is dns.quad9.net"
grep -Fq 'DOQ_DNS_SERVER_OPTIONS' "$ROOT_DIR/luci-app-forkop/htdocs/luci-static/resources/view/forkop/main.js" ||
  fail "DoQ settings presets must be a separate list"
grep -Fq 'DOH3_DNS_SERVER_OPTIONS' "$ROOT_DIR/luci-app-forkop/htdocs/luci-static/resources/view/forkop/main.js" ||
  fail "DoH3 settings presets must be a separate list"
grep -Fq 'dns.adguard-dns.com' "$ROOT_DIR/luci-app-forkop/htdocs/luci-static/resources/view/forkop/main.js" ||
  fail "AdGuard DoQ preset must keep the official quic hostname"
extract_fn "$XRAY_GEN" "doh_hostname_for" | grep -Fq 'dns.google' ||
  fail "DoH to 8.8.8.8 must use dns.google (TLS cert is not 8.8.8.8)"
extract_fn "$XRAY_GEN" "xray_dns_server_address" | grep -Fq '853' ||
  fail "DoT must use port 853; Xray tls:// without a port defaults to 53"
extract_fn "$XRAY_GEN" "dot_hostname_for" | grep -Fq 'one.one.one.one' ||
  fail "Cloudflare DoT hostname is one.one.one.one, not cloudflare-dns.com"
extract_fn "$XRAY_GEN" "dot_hostname_for" | grep -Fq 'dns.opendns.com' ||
  fail "OpenDNS DoT hostname is dns.opendns.com, not doh.opendns.com"
extract_fn "$XRAY_GEN" "primary_dns_config" | grep -Fq 'enableParallelQuery' ||
  fail "Xray DNS must query the configured servers in parallel"
if extract_fn "$XRAY_GEN" "primary_dns_config" | grep -Fq 'xray_dns_server_address("doh"'; then
  fail "DoT must stay DoT; do not add a DoH twin for the same resolver"
fi
extract_fn "$XRAY_GEN" "primary_dns_config" | grep -Fq 'serveStale' ||
  fail "Xray DNS must serve stale answers when the DoT session drops"
extract_fn "$XRAY_GEN" "primary_dns_config" | grep -Fq 'disableCache: true' ||
  fail "FakeIP must not be stored in the shared DNS cache; outbound dials would reuse 198.18"
extract_fn "$XRAY_GEN" "primary_dns_config" | grep -Fq 'serveExpiredTTL' ||
  fail "real DNS cache must follow DNS Rewrite TTL via serveExpiredTTL"
extract_fn "$XRAY_GEN" "dns_cache_ttl" | grep -Fq 'dns_rewrite_ttl' ||
  fail "Xray DNS cache TTL must read dns_rewrite_ttl"
extract_fn "$XRAY_GEN" "primary_dns_config" | grep -Fq 'XRAY_DNS_REMOTE_TAG' ||
  fail "Xray DNS servers must be tagged so DoH can be routed through the proxy section"
extract_fn "$XRAY_GEN" "primary_dns_config" | grep -Fq 'bootstrap_dns_server' ||
  fail "Xray DoH hostnames must be resolved via bootstrap DNS"
extract_fn "$XRAY_GEN" "dns_proxy_target" | grep -Fq 'dns_detour_enabled' ||
  fail "DNS through proxy (BLESS) must be implemented on the Xray plane"
extract_fn "$XRAY_GEN" "generate_config" | grep -Fq 'apply_dns_client_routes' ||
  fail "DNS client routes must be applied after section outbounds exist"
extract_fn "$XRAY_GEO" "community_matchers" | grep -Fq 'v2fly_geosite_tag' ||
  fail "itdog lists must fall back to v2fly geosite.dat when allow-domains.dat is missing"
extract_fn "$XRAY_GEO" "community_matchers" | grep -Fq 'community_lst_readable' ||
  fail "itdog lists must fall back to cached RAW .lst when dat/geosite tags are missing"
extract_fn "$XRAY_GEO" "community_ext_candidates" | grep -Fq 'ITDOG_SITE_CODE' ||
  fail "itdog geosite.dat uses top-level YOUTUBE/BLOCK/DISCORD groups, not only russia-inside@attr"
grep -Fq 'ukraine_inside: "ukraine-inside"' "$XRAY_GEO" ||
  fail "itdog geosite code for Ukraine is UKRAINE-INSIDE"
extract_fn "$XRAY_GEO" "looks_like_itdog_dat" | grep -Fq '32768' ||
  fail "itdog geosite.dat is ~95KB; rejecting under 128KB drops the real file"
grep -Fq 'ADLIST_DAT_URL' "$XRAY_GEO" ||
  fail "hagezi must use adlist.dat for Xray, not a 1.7MB srs decompile"
grep -Fq 'ext:adlist.dat:' "$XRAY_GEO" ||
  fail "ads_hagezi_pro must emit ext:adlist.dat:hagezi-pro"
grep -Fq 'SUPERCELL_JSON_URL' "$XRAY_GEO" ||
  fail "supercell must use supercell.json on the Xray plane"
grep -Fq 'GITHUB_LIST_URL' "$XRAY_GEO" ||
  fail "github must fall back to MetaCubeX github.list when geosite.dat is missing"
grep -Fq 'ads_hagezi_pro: "category-ads-all"' "$XRAY_GEO" &&
  fail "hagezi must not map to v2fly category-ads-all; use adlist.dat"
extract_fn "$XRAY_GEO" "fetch_v2fly_geosite" | grep -Fq 'V2FLY_GEOSITE_DAT_URL' ||
  fail "missing v2fly geosite.dat must be fetched on list-update like allow-domains.dat"
extract_fn "$XRAY_GEO" "ensure_from_uci" | grep -Fq 'fetch_v2fly_geosite' ||
  fail "list-update must stage v2fly geosite.dat for github"
extract_fn "$XRAY_GEO" "ensure_from_uci" | grep -Fq 'fetch_adlist_dat' ||
  fail "list-update must stage adlist.dat for hagezi"
extract_fn "$XRAY_GEO" "ensure_from_uci" | grep -Fq 'native_xray_list_name' ||
  fail "Xray must not fetch .srs for ads/supercell/github"
grep -Fq 'google_ai: "google"' "$XRAY_GEO" &&
  fail "google_ai must not map to v2fly geosite:google (too broad; use Services/google_ai.lst)"
grep -Fq 'ITDOG_GEOSITE_ATTR' "$XRAY_GEO" ||
  fail "Xray must only emit documented itdog geosite attributes"
extract_fn "$XRAY_GEO" "itdog_ext_matcher_ok" | grep -Fq 'russia-inside' ||
  fail "ext:allow-domains.dat:block is not a real itdog code and must not be emitted"
awk '
  /^function itdog_ext_matcher_ok\(/ { i = NR }
  /^function dat_matcher_usable\(/ { d = NR }
  END { if (i == 0 || d == 0 || i > d) exit 1 }
' "$XRAY_GEO" ||
  fail "ucode binds names at definition time; itdog_ext_matcher_ok must be defined before dat_matcher_usable"
extract_fn "$XRAY_GEO" "looks_like_itdog_dat" | grep -Fq 'looks_like_html_or_json' ||
  fail "HTML/JSON GitHub dumps must not be treated as allow-domains.dat"
extract_fn "$XRAY_GEN" "primary_dns_config" | awk '
  /collect_dns_action_servers/ { a = NR }
  /address: "fakedns"/ { f = NR }
  END { if (!(a > 0 && f > 0 && a < f)) exit 1 }
' || fail "AdGuard DNS-action servers must run before FakeDNS so youtube gets a real IP"
extract_fn "$XRAY_GEO" "looks_like_itdog_dat" | grep -Fq 'geolocation-cn' &&
  fail "itdog allow-domains.dat must not be purged just because it also contains v2fly-like strings"
extract_fn "$XRAY_GEN" "collect_fake_dns_domains" | grep -Fq 'unmapped' ||
  fail "FakeDNS must scope to section domains unless an unmapped .srs list is present"
extract_fn "$XRAY_GEN" "section_domain_matchers" | grep -Fq 'section_converted_lists' ||
  fail "Xray plane must route converted community lists, not only inline domains"
grep -Fq 'russia-inside' "$XRAY_GEO" ||
  fail "russia_inside must map to itdoginfo geosite tag russia-inside"
grep -Fq 'Services/hdrezka.lst' "$XRAY_GEO" ||
  fail "hdrezka maps to itdoginfo Services/hdrezka.lst (subnets/dat, not JSON dump)"
grep -Fq 'rule-set", "decompile' "$XRAY_GEO" ||
  fail "custom/hagezi .srs must decompile via sing-box into Xray matchers"
grep -Fq 'ext:allow-domains.dat:' "$XRAY_GEO" ||
  fail "converted country lists must use ext:allow-domains.dat"
grep -Fq 'XRAY_LOCATION_ASSET' "$XRAY_CONST" ||
  fail "Xray must know the geodata asset directory"
grep -Fq 'ensure_from_uci' "$XRAY_RT" ||
  fail "Xray init-config must fetch converted lists before generating config"
extract_fn "$XRAY_GEN" "xray_query_strategy" | grep -Fq 'return "UseIPv4"' ||
  fail "dns_strategy=ipv4_only/prefer_ipv4 must map to UseIPv4 so FakeIP stays on IPv4"
extract_fn "$XRAY_GEN" "xray_query_strategy" | grep -Fq 'prefer_ipv4' ||
  fail "prefer_ipv4 must query A records only; AAAA FakeIP on fc00:: is why some sites never hit domain rules"
extract_fn "$XRAY_GEN" "xray_dial_strategy" | grep -Fq 'UseIPv4v6' ||
  fail "prefer_ipv4 must dial via sockopt.domainStrategy UseIPv4v6"
extract_fn "$XRAY_GEN" "xray_dial_strategy" | grep -Fq 'UseIPv6v4' ||
  fail "prefer_ipv6 must dial via sockopt.domainStrategy UseIPv6v4"
extract_fn "$XRAY_GEN" "apply_output_interface" | grep -Fq 'outbound_is_provider_direct' ||
  fail "Zapret and Zapret2 must keep their fwmark and must not be pinned to the WAN interface"
extract_fn "$SB_GEN" "add_zapret_outbound" | grep -Fq 'routing_mark' ||
  fail "sing-box Zapret outbound must use its route mark"
extract_fn "$SB_GEN" "add_zapret2_outbound" | grep -Fq 'routing_mark' ||
  fail "sing-box Zapret2 outbound must use its route mark"
extract_fn "$SB_GEN" "add_zapret_outbound" | grep -Fq 'bind_interface' &&
  fail "sing-box Zapret outbound must not bind the WAN interface"
extract_fn "$SB_GEN" "add_zapret2_outbound" | grep -Fq 'bind_interface' &&
  fail "sing-box Zapret2 outbound must not bind the WAN interface"
extract_fn "$XRAY_GEN" "apply_dial_strategy" | grep -Fq 'SINGBOX_SIDECAR_TAG' ||
  fail "sidecar SOCKS must keep AsIs so the domain is passed through"
extract_fn "$XRAY_GEN" "apply_dial_strategy" | grep -Fq '"AsIs"' ||
  fail "Xray-primary proxy outbounds must dial AsIs; UseIPv4v6 re-resolves FakeIP and 2ip.io times out"
extract_fn "$XRAY_GEN" "apply_dial_strategy" | grep -Fq 'explicit == "UseIP"' ||
  fail "interface freedom must set sockopt.domainStrategy so it dials a real IP, not 198.18"
extract_fn "$XRAY_GEN" "primary_dns_config" | grep -Fq 'push_interface_dial_dns' ||
  fail "interface dial must have a real DNS match after FakeDNS; otherwise UseIPv4v6 gets an empty answer"
extract_fn "$XRAY_GEN" "dns_outbound" | grep -Fq 'blockTypes' ||
  fail "dns-out must block HTTPS/SVCB query types (64/65) like sing-box reject"
extract_fn "$XRAY_GEN" "dns_outbound" | grep -Fq '64' ||
  fail "dns-out blockTypes must include SVCB (64)"
extract_fn "$XRAY_GEN" "dns_outbound" | grep -Fq '65' ||
  fail "dns-out blockTypes must include HTTPS (65)"
extract_fn "$XRAY_GEN" "dns_outbound" | grep -Fq 'nonIPQuery' ||
  fail "dns-out must drop non-A/AAAA so type-65 never hits 8.8.8.8"
extract_fn "$XRAY_GEN" "primary_dns_config" | grep -Fq 'skipFallback' ||
  fail "FakeDNS must skipFallback so HTTPS/SVCB queries are not answered by upstream"
if extract_fn "$XRAY_GEN" "primary_dns_config" | grep -Fq '!fake.unmapped'; then
  fail "unmapped itdog lists must not enable unrestricted FakeDNS (FakeIP 198.18 blackhole via sidecar)"
fi
extract_fn "$XRAY_GEN" "apply_primary_plane" | grep -Fq ', "::"' ||
  fail "Xray IPv6 tproxy must listen on :: not only ::1"
grep -Fq 'XRAY_PLANE_MIXED_INBOUND_TAG' "$LIB/singbox/route.uc" ||
  fail "sidecar must sniff xray-plane-mixed-in or FakeIP leaks as 198.18.x"
extract_fn "$LIB/singbox/generator.uc" "add_global_routing_exclusions" | grep -Fq 'is_xray_primary' ||
  fail "sidecar must skip LAN DNS-exclusion rules when Xray owns DNS"
extract_fn "$XRAY_GEN" "primary_dns_config" | grep -Fq 'disableFallbackIfMatch' ||
  fail "matched FakeDNS domains must not fall through to real DoH/HTTPS records"
extract_fn "$XRAY_GEN" "primary_dns_config" | grep -Fq 'use-application-dns.net' ||
  fail "Xray DNS must poison Chrome DoH canary use-application-dns.net"
if extract_fn "$XRAY_GEN" "primary_dns_config" | grep -Fq 'full:use-application-dns.net'; then
  fail "Xray DNS hosts keys cannot use routing prefixes like full:"
fi
grep -Fq 'filter-rr=HTTPS' "$LIB/dns/apply.uc" ||
  fail "dnsmasq must strip HTTPS records when Xray is the plane"
grep -Fq 'filter-rr=SVCB' "$LIB/dns/apply.uc" ||
  fail "dnsmasq must strip SVCB records"
extract_fn "$XRAY_GEN" "dns_outbound" | grep -Fq 'sockopt' ||
  fail "dns-out must set outbound mark so nft output does not TPROXY Xray DNS"
extract_fn "$XRAY_GEO" "dat_contains" | grep -Fq 'protobuf_country_codes' ||
  fail "geosite codes must be read from protobuf country_code fields"
if extract_fn "$XRAY_GEO" "dat_contains" | grep -Fq 'sprintf("%c"'; then
  fail "a 10-byte geosite code must not be grepped; the length byte is a newline and cloudfront matches cloudfront.net"
fi
extract_fn "$XRAY_GEO" "looks_like_itdog_dat" | grep -Fq 'looks_like_v2fly_dat' &&
  fail "looks_like_itdog_dat must not call looks_like_v2fly_dat (ucode forward-ref)"
extract_fn "$SB_GEN" "base_config" | grep -Fq 'is_xray_primary' ||
  fail "sidecar must skip FakeIP DNS when Xray owns FakeDNS"
extract_fn "$SB_GEN" "section_dns_server" | grep -Fq 'is_xray_primary' ||
  fail "sidecar section DNS must not FakeIP-resolve SOCKS domains when Xray is the plane"
extract_fn "$XRAY_GEN" "section_converted_lists" | grep -Fq 'catch' ||
  fail "community list conversion errors must not abort Xray generate-config"
awk '
  /^function dns_inbound_at\(/ { a = NR }
  /^function dns_inbound\(/ { d = NR }
  END { if (a == 0 || d == 0 || a > d) exit 1 }
' "$XRAY_GEN" ||
  fail "ucode binds names at definition time; dns_inbound_at must be defined before dns_inbound"
extract_fn "$LIB/singbox/route.uc" "config" | grep -Fq 'is_xray_primary' ||
  fail "sidecar must not hijack-dns when Xray owns DNS (missing fakeip record)"
awk '
  /^function purge_unusable_allow_domains_dat\(/ { p = NR }
  /^function stage_geosite_dat_inner\(/ { s = NR }
  END { if (p == 0 || s == 0 || p > s) exit 1 }
' "$XRAY_GEO" ||
  fail "ucode binds names at definition time; purge must be defined before stage_geosite_dat_inner"
extract_fn "$XRAY_GEO" "ensure_dir" | grep -Fq 'mkdir -p' ||
  fail "ensure_dir must use mkdir -p; fs.mkdir is not a function on some ucode builds"
pass "Xray plane DNS matches settings (DoH/DoT, scoped FakeDNS, geosite)"

# --- P0: sing-box sidecar must keep Xray leaves for community lists / dashboard ---
extract_fn "$SB_GEN" "add_outbound_for_section" | grep -Fq 'add_xray_sidecar_outbound' ||
  fail "sing-box must emit Xray SOCKS leaves"
if extract_fn "$SB_GEN" "add_outbound_for_section" | grep -Fq 'is_xray_primary'; then
  fail "skipping Xray sidecar outbounds when Xray is primary drops dashboard, probe, router-traffic and community-list hops"
fi
if extract_fn "$SB_GEN" "add_route_for_section" | grep -Fq 'is_xray_primary'; then
  fail "skipping Xray section routes on the mixed inbound breaks community lists (Xray cannot load sing-box .srs)"
fi
extract_fn "$SB_GEN" "tproxy_inbound_matcher" | grep -Fq 'XRAY_PLANE_MIXED_INBOUND_TAG' ||
  fail "when Xray is primary, sing-box routes must match mixed inbound 4536"
extract_fn "$SB_GEN" "base_config" | grep -Fq 'XRAY_PLANE_MIXED_INBOUND_PORT' ||
  fail "sing-box sidecar mixed inbound must listen on 4536"
if ! grep -A40 'if (!engine.is_xray_primary())' "$SB_GEN" | grep -Fq 'TPROXY_INBOUND_TAG'; then
  fail "base_config must emit tproxy inbounds when sing-box is the plane"
fi
if ! grep -A20 'if (!engine.is_xray_primary())' "$SB_GEN" | grep -A20 'else' | grep -Fq 'XRAY_PLANE_MIXED_INBOUND_TAG'; then
  fail "base_config must drop tproxy/DNS inbounds when Xray is primary and emit mixed :4536"
fi
pass "sing-box sidecar keeps Xray leaves and mixed inbound :4536"

# --- P1: plane listen ports even with zero xray sections ---
extract_fn "$XRAY_RT" "collect_listen_ports" | grep -Fq 'XRAY_TPROXY_FAKEIP_PORT' ||
  fail "FakeIP TPROXY :1605 must be in the listen-port set"
extract_fn "$XRAY_RT" "collect_listen_ports" | grep -Fq 'XRAY_DNS_PORT' ||
  fail "Xray plane DNS :53 must be in the listen-port set"
extract_fn "$XRAY_RT" "xray_needed" | grep -Fq 'is_xray_primary' ||
  fail "xray_needed must be true when Xray is the routing plane"
extract_fn "$XRAY_GEN" "apply_xray_servers" | grep -Fq 'xray_servers.build_inbound' ||
  fail "Xray plane must build server inbounds, not only the LuCI tab"
extract_fn "$XRAY_GEN" "apply_xray_server_route" | grep -Fq 'rule_targets_tproxy' ||
  fail "server routing mode rules must follow the same TPROXY routes"
extract_fn "$XRAY_GEN" "apply_xray_server_route" | grep -Fq 'routing_mode' ||
  fail "Xray servers must honor routing_mode direct/section/rules"
extract_fn "$XRAY_SERVERS" "apply_reality" | grep -Fq 'realitySettings' ||
  fail "Xray VLESS Reality inbounds must emit realitySettings"
extract_fn "$XRAY_SERVERS" "client_settings" | grep -Fq 'decryption: "none"' ||
  fail "Xray VLESS inbounds require decryption none"
extract_fn "$XRAY_SERVERS" "client_settings" | grep -Fq 'protocol == "hysteria2"' ||
  fail "Hysteria2 servers must be generated for Xray"
extract_fn "$XRAY_SERVERS" "supported" | grep -Fq 'tailscale' &&
  fail "Tailscale servers stay on sing-box"
extract_fn "$XRAY_SERVERS" "supported" | grep -Fq 'hysteria2' ||
  fail "Xray servers must support hysteria2"
extract_fn "$XRAY_SERVERS" "transport_spec" | grep -Fq 'method: "raw"' ||
  fail "Xray 26 server inbounds must set streamSettings.method raw, not only network"
extract_fn "$XRAY_SERVERS" "transport_spec" | grep -Fq 'kind: "http"' ||
  fail "removed HTTP transport must be rewritten to XHTTP or xray -test rejects the whole config"
extract_fn "$XRAY_SERVERS" "build_inbound" | grep -Fq 'REALITY only supports' ||
  fail "REALITY on WebSocket/HTTPUpgrade must be skipped instead of failing xray -test"
extract_fn "$XRAY_GEN" "apply_xray_servers" | grep -Fq 'already in use' ||
  fail "a server port that collides with TPROXY/API must be skipped, not take down Xray"
grep -Fq 'xray x25519' "$LIB/server/service.uc" ||
  fail "Reality keys must be generated by xray x25519 when sing-box is not installed"
grep -Fq 'openssl req -x509' "$LIB/server/service.uc" ||
  fail "TLS certificates for Trojan/Hysteria2 must not require sing-box"
grep -Fq 'runtime_config_path' "$LIB/diagnostics/runtime.uc" ||
  fail "inbound diagnostics must read the Xray config when Xray is primary"
awk '
  /^function apply_xray_servers\(/ { p = NR }
  /^function generate_config\(/ { a = NR }
  END { if (p == 0 || a == 0 || p > a) exit 1 }
' "$XRAY_GEN" ||
  fail "ucode binds names at definition time; apply_xray_servers must be defined before generate_config"
extract_fn "$SB_GEN" "generate_config" | grep -Fq 'is_xray_primary() ? [] : enabled_servers()' ||
  fail "sing-box sidecar must not bind server ports when Xray owns them"
extract_fn "$LIB/core/engine.uc" "need_singbox" | grep -Fq 'has_enabled_inbound_servers' &&
  fail "Xray servers must not force the sing-box process to start"
grep -Fq 'xrayServerEngine' "$ROOT_DIR/luci-app-forkop/htdocs/luci-static/resources/view/forkop/server.js" ||
  fail "Servers tab must hide sing-box-only protocols when Xray is selected"
pass "Xray servers listen on the Xray plane"

extract_fn "$XRAY_GEN" "add_byedpi_outbound" | grep -Fq 'protocol: "socks"' ||
  fail "ByeDPI on the Xray plane must be a local SOCKS outbound to ciadpi"
extract_fn "$XRAY_GEN" "section_policy_tproxy_target" | grep -Fq 'byedpi' ||
  fail "ByeDPI TPROXY matchers must stay on Xray, not the sidecar"
extract_fn "$XRAY_GEN" "collect_byedpi_real_dns_domains" | grep -Fq 'byedpi' ||
  fail "ByeDPI domains must be resolved by real DNS, not FakeIP, before ciadpi dials"
extract_fn "$XRAY_GEN" "primary_dns_config" | grep -Fq 'collect_byedpi_real_dns_domains' ||
  fail "ByeDPI real DNS server must be inserted before FakeDNS"
extract_fn "$XRAY_GEN" "collect_dns_action_servers" | grep -Fq 'dns_action_tag' ||
  fail "DNS action sections must become Xray DNS servers"
grep -Fq 'function need_singbox_sidecar' "$LIB/core/engine.uc" ||
  fail "sidecar must only start when a section still uses sing-box"
grep -Fq 'function need_singbox()' "$LIB/core/engine.uc" ||
  fail "need_singbox must skip the package when Xray-only"
grep -Fq 'function need_xray()' "$LIB/core/engine.uc" ||
  fail "need_xray must skip the package when sing-box-only"
grep -Fq 'sing-box sidecar is not required' "$LIFECYCLE" ||
  fail "Xray-only configs must skip starting sing-box"
grep -Fq 'sing-box is not required; Xray is the routing plane' "$LIB/config/validator.uc" ||
  fail "check-requirements must not abort on missing sing-box when Xray-only"
extract_fn "$LIB/config/validator.uc" "check_runtime_requirements" | grep -Fq 'need_singbox' ||
  fail "check_runtime_requirements must skip sing-box when Xray owns the plane"
extract_fn "$LIB/config/validator.uc" "check_runtime_requirements" | grep -Fq 'need_xray' ||
  fail "check_runtime_requirements must skip Xray when sing-box owns the plane"
extract_fn "$LIB/config/validator.uc" "check_runtime_requirements" | grep -Fq 'Install it from Components' ||
  fail "missing cores must be installed from Components, not as package dependencies"
extract_fn "$LIFECYCLE" "stop_sing_box_service" | grep -Fq 'file_exists' ||
  fail "stop must ignore a missing sing-box init script"
extract_fn "$LIFECYCLE" "start_main" | grep -Fq 'nft_populate_runtime_sets' ||
  fail "Xray-only start must populate nft fully_routed/source sets without sing-box init-config"
extract_fn "$STATE" "forkop_stably_running" | grep -Fq 'need_singbox' ||
  fail "wait-stable must not require sing-box when the sidecar is unused"

# --- P1: start order ---
grep -n 'Routing plane is Xray' "$LIFECYCLE" >/dev/null ||
  fail "lifecycle must log the inverted start order"
awk '
  /xray_primary/ { seen = 1 }
  seen && /sing-box.*start/ { sb = NR }
  seen && /start-runtime/ { xr = NR }
  END { if (!(sb > 0 && xr > sb)) exit 1 }
' "$LIFECYCLE" || fail "when Xray is primary, sing-box sidecar must start before Xray"
pass "lifecycle starts sing-box sidecar, then Xray plane"

extract_fn "$XRAY_RT" "can_reuse_generated_config" | grep -Fq 'persist_lists_locally' ||
  fail "config reuse must honour persist_lists_locally"
extract_fn "$XRAY_RT" "init_config" | grep -Fq 'reusing existing configuration' ||
  fail "unchanged UCI+DAT must skip Xray generate-config"
extract_fn "$XRAY_RT" "init_config" | grep -Fq 'skipping validation, config unchanged' ||
  fail "already-validated config.json must skip xray -test"
extract_fn "$XRAY_RT" "read_config_stamp" | grep -Fq 'XRAY_CONFIG_STAMP' ||
  fail "reuse must compare the saved fingerprint stamp"
grep -Fq 'list-update-if-missing' "$LIFECYCLE" ||
  fail "Xray start must not download lists when the flash cache is complete"

# wait-stable must require the Xray process when it owns the plane.
grep -Fq 'function xray_process_detected' "$STATE" ||
  fail "wait-stable must detect the Xray process"
grep -Fq 'function plane_ports_ready' "$STATE" ||
  fail "wait-stable must use plane_ports_ready so Xray tproxy/DNS count, not missing IPv6"
extract_fn "$STATE" "forkop_stably_running" | grep -Fq 'is_xray_primary' ||
  fail "forkop_stably_running must wait for Xray when it is the routing plane"
extract_fn "$STATE" "forkop_stably_running" | grep -Fq 'plane_ports_ready' ||
  fail "forkop_stably_running lost its port check"
extract_fn "$STATE" "plane_ports_ready" | grep -Fq 'is_xray_primary' ||
  fail "Xray plane must not require IPv6 tproxy ::1:1602"
extract_fn "$STATE" "plane_ports_ready" | grep -Fq 'listen_table_text' ||
  fail "plane_ports_ready must not call undefined command_output (LHS is not a function)"
extract_fn "$STATE" "wait_forkop_stable_start" | grep -Fq 'wait_forkop_stable_reason' ||
  fail "wait-stable must log which check failed after the timeout"
extract_fn "$STATE" "wait_forkop_stable_reason" | grep -Fq 'DNS' ||
  fail "wait-stable failure must name DNS 127.0.0.42:53"
extract_fn "$STATE" "wait_forkop_stable_reason" | grep -Fq 'TPROXY' ||
  fail "wait-stable failure must name TPROXY :1602"
grep -Fq 'XRAY_START_VERIFY_TIMEOUT' "$LIFECYCLE" ||
  fail "Xray start must wait longer than 20s — large dat makes bind slower than xray -test"
extract_fn "$LIFECYCLE" "start_main" | grep -Fq 'XRAY_START_VERIFY_TIMEOUT' ||
  fail "start_main wait-stable timeout for Xray must use XRAY_START_VERIFY_TIMEOUT (60s)"
if extract_fn "$LIFECYCLE" "start_main" | grep -Eq 'xray_primary \? 20'; then
  fail "Xray wait-stable timeout is still 20s; huge dat-backed configs abort after start-runtime"
fi
extract_fn "$LIFECYCLE" "start_main" | grep -Fq 'Waiting up to' ||
  fail "start_main must log the Xray wait-stable timeout so a stale copy is obvious"
extract_fn "$XRAY_RT" "start_runtime" | grep -Fq 'Starting Xray; waiting up to' ||
  fail "Xray start-runtime must log that it is waiting for DNS/TPROXY"
extract_fn "$XRAY_RT" "start_runtime" | grep -Fq 'plane_listen_ready' ||
  fail "Xray start-runtime must wait for DNS/TPROXY, not only pid"
extract_fn "$XRAY_RT" "plane_listen_ready" | grep -Fq 'XRAY_DNS_LISTEN' ||
  fail "Xray start-runtime ready check must require 127.0.0.42 DNS"
extract_fn "$XRAY_RT" "start_runtime" | grep -Fq 'FORKOP_XRAY_START_VERIFY_TIMEOUT' ||
  fail "Xray start-runtime must wait up to the same 60s window as wait-stable"
grep -A20 'function start_runtime' "$LIB/singbox/dns_failover.uc" | grep -Fq 'is_xray_primary' ||
  fail "DNS failover worker must not SIGHUP sing-box when Xray owns DNS"
pass "wait-stable waits for Xray; failover worker skips the Xray plane"

DIAG_RT="$LIB/diagnostics/runtime.uc"
extract_fn "$DIAG_RT" "check_dns_available" | grep -Fq 'is_xray_primary' ||
  fail "DNS diagnostic must not use sing-box health ports when Xray is primary"
extract_fn "$DIAG_RT" "check_sing_box" | grep -Fq 'sing_box_required' ||
  fail "sing-box diagnostic must report sidecar-not-required on Xray-only"
extract_fn "$DIAG_RT" "check_fakeip" | grep -Fq 'engine' ||
  fail "FakeIP diagnostic must report xray vs sing-box engine"
extract_fn "$DIAG_RT" "clash_api" | grep -Fq 'xray_proxy_latency_ok' ||
  fail "Clash latency API must probe Xray SOCKS when Xray is primary"
extract_fn "$XRAY_RT" "proxy_latency_json" | grep -Fq 'probe_socks_delay' ||
  fail "Xray proxy-latency must curl through the section SOCKS inbound"

printf 'xray primary-plane QA passed\n'
