#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FORKOP_JS="$ROOT_DIR/luci-app-forkop/htdocs/luci-static/resources/view/forkop/forkop.js"
VIEW_JS="$ROOT_DIR/luci-app-forkop/htdocs/luci-static/resources/view/forkop/byedpi_strategy.js"
TEST_UC="$ROOT_DIR/forkop/files/usr/lib/providers/byedpi/strategy_test.uc"
DATA_DIR="$ROOT_DIR/forkop/files/usr/lib/providers/byedpi/strategy-data"
BIN="$ROOT_DIR/forkop/files/usr/bin/forkop"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

node --check "$FORKOP_JS"
node --check "$VIEW_JS"

grep -Fq 'function syncByedpiStrategyTab()' "$FORKOP_JS" ||
  fail "Forkop must hide the ByeDPI strategy tab when ciadpi is missing"
grep -Fq 'uiCapabilities.byedpiInstalled === true' "$FORKOP_JS" ||
  fail "ByeDPI strategy tab visibility must follow byedpiInstalled"
grep -Fq '.cbi-tabmenu [data-tab="byedpi_strategy"]' "$FORKOP_JS" ||
  fail "ByeDPI strategy tab must use the byedpi_strategy section id"
grep -Fq 'byedpiStrategy.createByedpiStrategyContent' "$FORKOP_JS" ||
  fail "ByeDPI strategy tab must be registered"
grep -Fq 'forkop:action-providers-availability' "$VIEW_JS" ||
  fail "strategy tab must stop when ByeDPI is removed"
grep -Fq 'byedpi_strategy_start' "$BIN" ||
  fail "forkop must dispatch byedpi_strategy_start"
grep -Fq 'byedpi_strategy_sites' "$BIN" ||
  fail "forkop must dispatch byedpi_strategy_sites"
grep -Fq 'start-stop-daemon' "$TEST_UC" ||
  fail "strategy worker must detach from the LuCI exec request"
grep -Fq 'normalize_site("googleapis.com")' "$TEST_UC" ||
  fail "domain filter must keep names that contain the letter s"
grep -Fq 'byedpi_strategy_sites' "$VIEW_JS" ||
  fail "strategy details must be loaded per strategy"
grep -Fq 'This is an old result, %d domains' "$VIEW_JS" ||
  fail "an old run must be labeled with its own domain count"
grep -Fq 'providers/byedpi/strategy_test.uc' "$BIN" ||
  fail "strategy check must live in providers/byedpi/strategy_test.uc"

[ -s "$DATA_DIR/proxytest_strategies.list" ] || fail "built-in strategy list is missing"
[ -s "$DATA_DIR/proxytest_youtube.sites" ] || fail "youtube domain list is missing"
[ "$(grep -cve '^$' "$DATA_DIR/proxytest_strategies.list")" -ge 50 ] ||
  fail "built-in strategy list is too short"

if command -v ucode >/dev/null 2>&1; then
  BYEDPI_STRATEGY_DATA="$DATA_DIR" \
    ucode -L "$ROOT_DIR/forkop/files/usr/lib" "$TEST_UC" self-check ||
    fail "ByeDPI strategy self-check failed"
else
  printf 'ucode is not installed; skipped strategy_test.uc self-check\n' >&2
fi

printf 'ByeDPI strategy tab checks passed\n'
