#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ACTION="$ROOT_DIR/forkop/files/usr/lib/components/action.uc"
UI="$ROOT_DIR/fe-app-forkop/src/forkop/tabs/updates/initController.ts"
MAIN="$ROOT_DIR/luci-app-forkop/htdocs/luci-static/resources/view/forkop/main.js"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok  %s\n' "$1"
}

[ -r "$ACTION" ] || fail "missing components/action.uc"
[ -r "$UI" ] || fail "missing updates initController.ts"
[ -r "$MAIN" ] || fail "missing prebuilt main.js"

grep -Fq 'function sing_box_list_variant()' "$ACTION" ||
  fail "version list must follow the installed sing-box variant"
grep -Fq 'function list_sing_box_official_tags()' "$ACTION" ||
  fail "stable sing-box versions must come from official releases"
grep -Fq 'https://api.github.com/repos/SagerNet/sing-box/tags?per_page=100' "$ACTION" ||
  fail "stable version list must read SagerNet/sing-box tags"
grep -Fq 'function list_sing_box_tiny_versions()' "$ACTION" ||
  fail "tiny sing-box versions must come from the OpenWrt package"
grep -Fq 'return list_sing_box_extended_tags();' "$ACTION" ||
  fail "extended and extended-compressed must keep the extended tag list"
grep -Fq 'install_sing_box_official(action, tag);' "$ACTION" ||
  fail "install_stable@tag must install that official sing-box release"
grep -Fq 'index(action, "install_stable@") == 0' "$ACTION" ||
  fail "component action allowlist must accept install_stable@tag"
grep -Fq 'index(action, "install_tiny@") == 0' "$ACTION" ||
  fail "component action allowlist must accept install_tiny@tag"
grep -Fq 'arch_suffix + "-musl.tar.gz"' "$ACTION" ||
  fail "official sing-box download must prefer the musl build used by OpenWrt"
grep -Fq 'variant,' "$ACTION" ||
  fail "list_versions response must name the sing-box variant"

grep -Fq 'https://api.github.com/repos/SagerNet/sing-box/tags?per_page=100' "$UI" ||
  fail "UI stable version list must read SagerNet/sing-box tags"
grep -Fq 'install_stable@${normalized}' "$UI" ||
  fail "UI must install the selected stable tag"
grep -Fq 'install_tiny@${normalized}' "$UI" ||
  fail "UI must install the selected tiny package version"
grep -Fq 'install_extended_compressed@${normalized}' "$UI" ||
  fail "compressed sing-box must keep its own tagged install"
grep -Fq 'install_extended@${normalized}' "$UI" ||
  fail "extended sing-box must keep its own tagged install"
grep -Fq 'Only the OpenWrt package version is available for tiny.' "$UI" ||
  fail "tiny version picker must explain that only the feed version exists"

grep -Fq 'install_stable@' "$MAIN" ||
  fail "prebuilt UI must install the selected stable tag"
grep -Fq 'install_tiny@' "$MAIN" ||
  fail "prebuilt UI must install the selected tiny package version"
grep -Fq 'SagerNet/sing-box/tags?per_page=100' "$MAIN" ||
  fail "prebuilt UI must load official stable tags"
grep -Fq 'Only the OpenWrt package version is available for tiny.' "$MAIN" ||
  fail "prebuilt UI must explain the tiny version list"

pass "sing-box version list follows the installed variant"
