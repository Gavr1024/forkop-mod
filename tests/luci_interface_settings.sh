#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SECTION_JS="$ROOT_DIR/luci-app-forkop/htdocs/luci-static/resources/view/forkop/section.js"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

grep -Fq 'function dnsTypeChoices() {' "$SECTION_JS" ||
  fail "network interface settings must define DNS protocol choices"
grep -Fq 'dnsTypeChoices().forEach((choice) => o.value(choice.value, choice.label));' "$SECTION_JS" ||
  fail "network interface settings must populate the DNS protocol field"
grep -Fq 'o.renderItemSettingsModal = showInterfaceSettingsModal;' "$SECTION_JS" ||
  fail "network interfaces must keep their settings modal handler"
awk '
  /InterfaceSettingsDynamicList,/ { iface = 1 }
  iface && /"outbound_jsons"/ { exit }
  iface && /effectiveSectionEngine\(this, section_id\) === "xray"/ { found = 1 }
  END { exit found ? 0 : 1 }
' "$SECTION_JS" ||
  fail "network interface settings button must be hidden when the section core is Xray"

printf 'LuCI network interface settings checks passed\n'
