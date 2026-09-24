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
