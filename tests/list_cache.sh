#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CACHE_UC="$ROOT_DIR/forkop/files/usr/lib/routing/list_cache.uc"
GENERATOR="$ROOT_DIR/forkop/files/usr/lib/singbox/generator.uc"
UPDATES="$ROOT_DIR/forkop/files/usr/lib/components/updates.uc"
BIN="$ROOT_DIR/forkop/files/usr/bin/forkop"
SETTINGS_JS="$ROOT_DIR/luci-app-forkop/htdocs/luci-static/resources/view/forkop/settings.js"
DASHBOARD_JS="$ROOT_DIR/luci-app-forkop/htdocs/luci-static/resources/view/forkop/dashboard.js"
CONFIG="$ROOT_DIR/forkop/files/etc/config/forkop"
PO_SRC="$ROOT_DIR/fe-app-forkop/locales/forkop.ru.po"
PO_PKG="$ROOT_DIR/luci-app-forkop/po/ru/forkop.po"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

require_file() {
  [ -r "$1" ] || fail "missing $1"
}

require_text() {
  local file="$1"
  local text="$2"
  grep -Fq "$text" "$file" || fail "$file must contain: $text"
}

require_file "$CACHE_UC"
require_file "$GENERATOR"
require_file "$UPDATES"
require_file "$BIN"
require_file "$SETTINGS_JS"
require_file "$DASHBOARD_JS"
require_file "$CONFIG"

require_text "$CONFIG" "option persist_lists_locally '1'"
require_text "$SETTINGS_JS" "o.default = \"1\""
require_text "$CACHE_UC" "is_xray_primary"
require_text "$SETTINGS_JS" "persist_lists_locally"
require_text "$SETTINGS_JS" "Every 3 hours"
require_text "$SETTINGS_JS" "Every 6 hours"
require_text "$SETTINGS_JS" "Every 12 hours"
require_text "$SETTINGS_JS" "Every 3 days"
require_text "$SETTINGS_JS" "Every 7 days"
require_text "$SETTINGS_JS" "never"
require_text "$SETTINGS_JS" "Never"
require_text "$SETTINGS_JS" "List update interval"
require_text "$UPDATES" "list_update_if_due"
require_text "$DASHBOARD_JS" "list_cache_status"
require_text "$DASHBOARD_JS" "Local list cache"
require_text "$DASHBOARD_JS" "list_cache_persist"
require_text "$DASHBOARD_JS" "payload.running"
require_text "$UPDATES" "list-cache-persist-run"
require_text "$DASHBOARD_JS" "Download lists now"
require_text "$BIN" "list_cache_status"
require_text "$BIN" "list_cache_persist"
require_text "$GENERATOR" "register_remote_or_cached_ruleset"
require_text "$GENERATOR" "routing.list_cache"
require_text "$UPDATES" "persist_selected_lists"
require_text "$UPDATES" "ensure_download_section_up"
require_text "$CACHE_UC" "ensure_download_section_up"
require_text "$CACHE_UC" "/etc/forkop/list-cache"
require_text "$CACHE_UC" "gzip_file"
require_text "$CACHE_UC" "install_download"
require_text "$CACHE_UC" "/tmp/forkop-stage"
require_text "$CACHE_UC" "lists_proxy_address"
require_text "$CACHE_UC" "download_proxy_address"
require_text "$CACHE_UC" "socks5h://"
require_text "$CACHE_UC" "is_xray_primary"
require_text "$CACHE_UC" "curl_proxy_spec"
require_text "$UPDATES" "download_proxy_address"

for po in "$PO_SRC" "$PO_PKG"; do
  require_text "$po" "Save selected lists locally"
  require_text "$po" "Сохранять выбранные списки локально"
  require_text "$po" "List update interval"
  require_text "$po" "Интервал обновления списков"
  require_text "$po" "Every 3 hours"
  require_text "$po" "Каждые 3 часа"
done

cmp -s "$PO_SRC" "$PO_PKG" || fail "Russian catalogs drifted after list-cache strings"

printf 'list cache checks passed\n'
