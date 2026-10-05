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
require_text "$GENERATOR" 'update_interval == "never"'
require_text "$SETTINGS_JS" "Never"
require_text "$SETTINGS_JS" "List update interval"
require_text "$UPDATES" "list_update_if_due"
require_text "$DASHBOARD_JS" "list_cache_status"
require_text "$DASHBOARD_JS" "Local list cache"
require_text "$DASHBOARD_JS" "list_cache_persist"
require_text "$DASHBOARD_JS" "list_cache_show"
require_text "$DASHBOARD_JS" "data-list-id"
require_text "$BIN" "list_cache_show"
require_text "$UPDATES" "list-cache-show"
require_text "$CACHE_UC" "preview_selected"
require_text "$CACHE_UC" "preview_page"
require_text "$CACHE_UC" "preview_close"
require_text "$CACHE_UC" "prefix_preview_lines"
require_text "$BIN" "list_cache_show_page"
require_text "$BIN" "list_cache_show_close"
require_text "$DASHBOARD_JS" "list_cache_show_page"
require_text "$DASHBOARD_JS" "data-list-page"
require_text "$CACHE_UC" "subnets.txt"
require_text "$CACHE_UC" "has_subnets"
require_text "$DASHBOARD_JS" "has_subnets"
require_text "$DASHBOARD_JS" "Your lists"
require_text "$DASHBOARD_JS" "Not a built-in list"
require_text "$CACHE_UC" "separate_custom_preview"
require_text "$CACHE_UC" "local_item"
require_text "$BIN" "domains|subnets"
require_text "$DASHBOARD_JS" "payload.running"
require_text "$UPDATES" "list-cache-persist-run"
require_text "$DASHBOARD_JS" "Download lists now"
require_text "$BIN" "list_cache_status"
require_text "$BIN" "list_cache_persist"
require_text "$GENERATOR" "register_remote_or_cached_ruleset"
require_text "$GENERATOR" "empty-ruleset.json"
require_text "$GENERATOR" "routing.list_cache"
require_text "$UPDATES" "persist_selected_lists"
require_text "$UPDATES" "Refreshing Xray configuration after list download"
require_text "$UPDATES" "ensure_download_section_up"
require_text "$UPDATES" "stop_download_socks"
require_text "$UPDATES" "finish_list_update"
require_text "$UPDATES" "Forkop is stopped; downloaded lists stay on disk until the next start"
require_text "$CACHE_UC" "ensure_download_section_up"
require_text "$CACHE_UC" "stop_download_socks"
require_text "$CACHE_UC" "start_download_socks"
require_text "$CACHE_UC" "download-socks"
require_text "$CACHE_UC" "38901"
require_text "$CACHE_UC" "socks5h://"
grep -Fq "tr '\\\\000'" "$CACHE_UC" || fail "cmdline must be read with tr NUL"
require_text "$CACHE_UC" "setsid "
require_text "$CACHE_UC" "Forkop is stopped and download socks is not listening"
require_text "$ROOT_DIR/forkop/files/usr/lib/xray/generator.uc" "prefer_resolvable_download_tags"
require_text "$ROOT_DIR/forkop/files/usr/lib/xray/generator.uc" "skipped unresolved server"
require_text "$GENERATOR" "generate_download_socks"
require_text "$GENERATOR" "forkop-download"
require_text "$GENERATOR" "download-socks"
require_text "$ROOT_DIR/forkop/files/usr/lib/xray/generator.uc" "generate_download_socks"
require_text "$ROOT_DIR/forkop/files/usr/lib/xray/generator.uc" "forkop-download"
if grep -Fq 'SERVICE_INIT, "start"' "$CACHE_UC"; then
  fail "list download must not start the full Forkop service"
fi
extract_fn() {
  awk -v fn="$2" '
    $0 ~ "^function " fn "\\(" { found=1 }
    found && !first && /^function / { first=NR }
    found && first && NR>first && /^function / { exit }
    found { print }
  ' "$1"
}
sb_fn="$(extract_fn "$GENERATOR" generate_download_socks)"
printf '%s\n' "$sb_fn" | grep -Fq 'forkop-download' || fail "sing-box download socks must expose forkop-download"
printf '%s\n' "$sb_fn" | grep -Fq 'tproxy' && fail "sing-box download socks must not open TPROXY"
printf '%s\n' "$sb_fn" | grep -Fq 'strip_download_routing_marks' || fail "sing-box download socks must drop routing marks"
xray_fn="$(extract_fn "$ROOT_DIR/forkop/files/usr/lib/xray/generator.uc" generate_download_socks)"
printf '%s\n' "$xray_fn" | grep -Fq 'apply_primary_plane' && fail "xray download socks must not build the routing plane"
printf '%s\n' "$xray_fn" | grep -Fq 'strip_download_marks' || fail "xray download socks must drop packet marks"
printf '%s\n' "$xray_fn" | grep -Fq 'download_bootstrap_addresses' || fail "xray download socks must resolve names through bootstrap DNS"
printf '%s\n' "$sb_fn" | grep -Fq 'download_bootstrap_servers' || fail "sing-box download socks must resolve names through bootstrap DNS"
require_text "$CACHE_UC" "/etc/forkop/list-cache"
require_text "$CACHE_UC" '"/sing-box"'
require_text "$CACHE_UC" "gzip_file"
require_text "$CACHE_UC" "cache_ram_rel"
require_text "$CACHE_UC" "/tmp/forkop-stage"
require_text "$CACHE_UC" "lists_proxy_address"
require_text "$CACHE_UC" "download_proxy_address"
require_text "$CACHE_UC" "socks5h://"
if grep -A6 'function cache_path_for_url' "$CACHE_UC" | grep -Fq 'is_xray_primary'; then
  fail "srs files must live in sing-box/ for both engines"
fi
if grep -A8 'function usable_local_path' "$CACHE_UC" | grep -Fq 'is_xray_primary'; then
  fail "root srs copies must move into sing-box/ even when Xray is active"
fi
require_text "$CACHE_UC" "discard_cache_copy"
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
