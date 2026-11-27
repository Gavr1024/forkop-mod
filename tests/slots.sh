#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SLOTS_UC="$ROOT_DIR/forkop/files/usr/lib/config/slots.uc"
BIN="$ROOT_DIR/forkop/files/usr/bin/forkop"
FORKOP_JS="$ROOT_DIR/luci-app-forkop/htdocs/luci-static/resources/view/forkop/forkop.js"
SLOTS_JS="$ROOT_DIR/luci-app-forkop/htdocs/luci-static/resources/view/forkop/slots.js"
CONFIG="$ROOT_DIR/forkop/files/etc/config/forkop"
LIFECYCLE="$ROOT_DIR/forkop/files/usr/lib/service/lifecycle.uc"
PO_SRC="$ROOT_DIR/fe-app-forkop/locales/forkop.ru.po"
PO_PKG="$ROOT_DIR/luci-app-forkop/po/ru/forkop.po"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

require_text() {
  grep -Fq "$2" "$1" || fail "$1 must contain: $2"
}

require_text "$SLOTS_UC" "/etc/forkop/slots"
require_text "$SLOTS_UC" "ping"
require_text "$SLOTS_UC" "slots_auto_switch"
require_text "$SLOTS_UC" "slots_probe_backend"
require_text "$SLOTS_UC" "function sync_scheduler"
require_text "$SLOTS_UC" "function probe_worker"
require_text "$SLOTS_UC" "function stop_worker"
require_text "$SLOTS_UC" "echo \$!"
require_text "$SLOTS_UC" "probe-worker"
require_text "$BIN" "slot_status"
require_text "$BIN" "slot_save"
require_text "$BIN" "slot_apply"
require_text "$BIN" "slot_probe_if_due"
require_text "$BIN" 'slot_configure: [ "config/slots.uc", "configure", 6 ]'
require_text "$FORKOP_JS" "view.forkop.slots"
require_text "$FORKOP_JS" "Config slots"
require_text "$SLOTS_JS" "Save current config"
require_text "$SLOTS_JS" "Slot applied. Forkop is reloading in the background."
require_text "$SLOTS_JS" "Enable auto-switch"
require_text "$SLOTS_JS" "Ping scheduler"
require_text "$SLOTS_JS" "Built-in worker"
require_text "$SLOTS_JS" "System cron"
require_text "$SLOTS_JS" "scheduler="
require_text "$CONFIG" "slots_probe_backend"
require_text "$LIFECYCLE" "stop-worker"
require_text "$PO_SRC" "Встроенный воркер"
require_text "$PO_PKG" "Встроенный воркер"
require_text "$PO_SRC" "Системный cron"
require_text "$PO_PKG" "Системный cron"
require_text "$SLOTS_JS" "confirmSlotSave"
require_text "$SLOTS_JS" "Overwrite this slot with the current Forkop config?"
require_text "$SLOTS_JS" "fkp-slots__btn"
require_text "$SLOTS_JS" "button type=\"button\""
require_text "$SLOTS_JS" "handleSlotClick"
require_text "$SLOTS_JS" "text-align: center"
require_text "$SLOTS_JS" "__forkopSlotsAct"
require_text "$SLOTS_JS" "forkop-slots-ax6000-2"
require_text "$SLOTS_JS" "window.confirm"
require_text "$SLOTS_JS" "onclick="
require_text "$CONFIG" "slots_ping_host"
require_text "$CONFIG" "slots_ping_host_backup"
require_text "$SLOTS_UC" "collect_hosts"
require_text "$SLOTS_UC" "sync_switch_settings_to_slots"
require_text "$SLOTS_JS" "Backup host to ping"
require_text "$LIFECYCLE" "config/slots.uc"
require_text "$PO_SRC" "Слоты конфига"
require_text "$PO_PKG" "Слоты конфига"
require_text "$PO_SRC" "Включить автопереключение"
require_text "$PO_PKG" "Включить автопереключение"
require_text "$SLOTS_UC" "reload_package"
require_text "$SLOTS_UC" "function preview_slot"
require_text "$SLOTS_UC" "function set_reserve_label"
require_text "$BIN" "slot_preview"
require_text "$BIN" "slot_label"
require_text "$SLOTS_JS" "data-slot-preview"
require_text "$SLOTS_JS" "Show contents"
require_text "$SLOTS_JS" "Apply this reserve?"
require_text "$PO_SRC" "Состав"
require_text "$PO_PKG" "Состав"

python3 - "$SLOTS_UC" <<'PY' || fail "ucode binds callee names at definition time; slot functions must not call later functions"
import re, sys
from pathlib import Path
text = Path(sys.argv[1]).read_text()
funcs = []
for m in re.finditer(r'^function ([A-Za-z_][A-Za-z0-9_]*)\(', text, re.M):
    funcs.append((m.group(1), text[:m.start()].count('\n') + 1))
by = {}
for name, line in funcs:
    by.setdefault(name, line)
lines = text.splitlines()
bad = []
for i, (name, start) in enumerate(funcs):
    end = funcs[i + 1][1] - 1 if i + 1 < len(funcs) else len(lines)
    body = "\n".join(lines[start:end])
    for callee in sorted(set(re.findall(r'\b([A-Za-z_][A-Za-z0-9_]*)\s*\(', body))):
        if callee in by and by[callee] > start:
            bad.append(f"{name} -> {callee}")
if bad:
    print("\n".join(bad), file=sys.stderr)
    raise SystemExit(1)
PY

python3 - "$SLOTS_JS" <<'PY'
from pathlib import Path
import sys
text = Path(sys.argv[1]).read_text()
if "function escapeHtml" not in text:
    raise SystemExit("slots.js must define escapeHtml")
if ("&" + "quot;") not in text:
    raise SystemExit("escapeHtml must keep quote entities (broken JS if decoded)")
print("escapeHtml entities ok")
PY

if grep -Fq "all: unset" "$SLOTS_JS"; then
  fail "slots.js must not use all: unset (breaks Argon / AX6000 buttons)"
fi
if grep -Eq "\\.finally[[:space:]]*\\(" "$SLOTS_JS"; then
  fail "slots.js must not use Promise.finally (missing on some LuCI)"
fi
if grep -Fq "ui.showModal" "$SLOTS_JS"; then
  fail "slots.js must use window.confirm, not ui.showModal (Argon hides the modal)"
fi

if command -v node >/dev/null 2>&1; then
  node -e 'new Function(require("fs").readFileSync(process.argv[1], "utf8"))' "$SLOTS_JS" \
    || fail "slots.js must parse as a LuCI module"
fi

cmp -s "$PO_SRC" "$PO_PKG" || fail "Russian catalogs must stay synchronized"

printf 'slots checks passed\n'
require_text "$SLOTS_UC" "parse_ping_ms"
require_text "$SLOTS_JS" "Host is unreachable"
require_text "$SLOTS_UC" "prepare_boot_slot"
require_text "$SLOTS_UC" "try_fallback_slot"
require_text "$SLOTS_UC" "restart_after_apply"
require_text "$SLOTS_UC" "1000>&-"
require_text "$SLOTS_UC" "setsid "
require_text "$LIFECYCLE" "prepare-boot-slot"
require_text "$LIFECYCLE" "try-fallback-slot"
require_text "$LIFECYCLE" "sync-cron-only"
require_text "$LIFECYCLE" "sync-scheduler"
require_text "$SLOTS_UC" "start.busy"
require_text "$SLOTS_UC" "stop.busy"
require_text "$SLOTS_UC" "FORKOP_SLOT_RESTART"
require_text "$SLOTS_UC" "sync_cron_only"

if command -v ucode >/dev/null 2>&1; then
  WORK="$(mktemp -d)"
  cat >"$WORK/r1" <<'EOF'
package forkop

config section 'yt'
	option label 'it'\''s'
	option enabled '1'
	option action 'connection'
	option domain 'youtube.com
www.youtube.com
keyword:music
full:exact.com
one
two'
	option domain_keyword 'legacy-word'
	list community_lists 'youtube'
	list rule_set 'https://example.com/a.srs'
	list rule_set 'https://example.com/c.srs'
	list rule_set 'https://example.com/d.srs'
	list rule_set 'https://example.com/e.srs'
	list rule_set 'https://example.com/f.srs'
	list rule_set 'https://example.com/g.srs'
	list rule_set 'https://example.com/h.srs'
	list rule_set_with_subnets '/etc/forkop/b.srs'
	list fully_routed_ips '192.168.1.10'
	option ip_cidr '1.1.1.1
10.0.0.0/8'
	list ports '443'
	list ports '80-90'
	option proxy_core 'xray'
	option dns_type 'doh'
	option dns_server 'https://dns.example/dns-query'
	option dns_answer 'route'
	option dns_detour_enabled '1'
	option dns_detour_section 'off'
	option xray_fallback_target 'off\t__balancer__'
	list selector_proxy_links 'vless://uuid-secret@node.example:443?flow=xtls#Name'
	option password 'hidden'
	option xray_mux_enabled '1'
	option xray_finalmask '1'
	option outbound_detour_enabled '1'
	option outbound_detour_section 'off'
	list outbound_jsons '{"tag":"json-a","password":"secret-json"}'
	list xdrive_outbounds '{"name":"drive-a","refresh_token":"token-secret"}'

config settings 'settings'
	option slots_ping_host '1.1.1.1'

config section_interface 'if1'
	option section 'yt'
	option name 'wan'

config warp 'w1'
	option section 'yt'
	option name 'home'
	option private_key 'secret-key'

config openconnect 'oc1'
	option section 'yt'
	option name 'work'
	option password 'secret-pass'

config openvpn 'ov1'
	option section 'yt'
	option name 'office'

config section 'off'
	option label 'Spare'
	option enabled '0'
	option action 'bypass'
	list domain 'example.com'

config subscription_url 'sub1'
	option section 'yt'
	option url 'https://user:token@sub.example/path/secret'

config section 'esc'
	option action 'connection'
	option domain 'a.com\nb.com'
	option mixed_proxy_enabled '1'
	option resolve_real_ip_for_routing '1'
	option sort_by_latency '1'
	option dashboard_filter_mode 'include'

config urltest 'u1'
	option section 'esc'
	option name 'fast'

config priority_group 'p1'
	option section 'esc'
	option name 'main'

config masque 'm1'
	option section 'esc'
	option name 'cloud'
	option license 'secret-license'
EOF
  EXPECT_LABEL="$(printf "it\\047s")"
  FORKOP_SLOTS_DIR="$WORK" EXPECT_LABEL="$EXPECT_LABEL" ucode -L "$ROOT_DIR/forkop/files/usr/lib" -e '
let slots = require("config.slots");
let preview = slots.preview_slot("r1");
if (preview == null || length(preview.sections) != 3)
    exit(1);
let first = preview.sections[0];
if (first.label != getenv("EXPECT_LABEL"))
    exit(1);
if (first.domains[0] != "youtube.com" || first.domains[2] != "keyword:music" || first.domains[3] != "full:exact.com")
    exit(1);
if (first.domain_count != 7)
    exit(1);
if (first.lists[0] != "youtube" || first.lists[1] != "https://example.com/a.srs" || first.list_count != 8 || length(first.lists) != 8)
    exit(1);
if (first.subnet_lists[0] != "/etc/forkop/b.srs" || first.subnet_count != 1)
    exit(1);
if (first.core != "xray" || first.dns_type != "doh" || first.dns_server != "dns.example" || first.dns_answer != "route")
    exit(1);
if (first.dns_via != "Spare" || first.fallback != "Spare" || first.fallback_tag != "__balancer__")
    exit(1);
if (first.servers[0] != "vless node.example:443" || first.subscriptions[0] != "sub.example")
    exit(1);
if (first.full[0] != "192.168.1.10")
    exit(1);
if (first.ip_count != 2 || first.ips[0] != "1.1.1.1" || first.ips[1] != "10.0.0.0/8")
    exit(1);
if (first.port_count != 2 || first.ports[0] != "443" || first.ports[1] != "80-90")
    exit(1);
if (first.interfaces[0] != "wan" || first.warp[0] != "home" || first.openconnect[0] != "work" || first.openvpn[0] != "office")
    exit(1);
if (first.jsons[0] != "json-a" || first.xdrives[0] != "drive-a" || first.mux != true || first.finalmask != true || first.cascade != "Spare")
    exit(1);
if (preview.sections[2].mixed != true || preview.sections[2].realip != true || preview.sections[2].sort != true || preview.sections[2].dashboard != "include")
    exit(1);
if (preview.sections[2].urltest[0] != "fast" || preview.sections[2].priority[0] != "main" || preview.sections[2].masque[0] != "cloud")
    exit(1);
let dumped = sprintf("%J", preview);
if (index(dumped, "hidden") >= 0 || index(dumped, "nope") >= 0)
    exit(1);
if (index(dumped, "uuid-secret") >= 0 || index(dumped, "token") >= 0 || index(dumped, "flow=xtls") >= 0)
    exit(1);
if (index(dumped, "secret-json") >= 0 || index(dumped, "secret-key") >= 0 || index(dumped, "secret-pass") >= 0 || index(dumped, "secret-license") >= 0)
    exit(1);
if (preview.sections[1].domains[0] != "example.com" || preview.sections[1].enabled != false)
    exit(1);
if (preview.sections[2].domain_count != 2 || preview.sections[2].domains[1] != "b.com" || preview.sections[2].core != "settings")
    exit(1);
' || fail "reserve preview must keep wrapped domains and custom lists"
  rm -rf "$WORK"
fi

