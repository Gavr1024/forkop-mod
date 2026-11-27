#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/forkop/files/usr/lib"
FOREIGN="$LIB/routing/foreign_dns.uc"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

[ -r "$FOREIGN" ] || fail "missing foreign dns module"
grep -Fq 'block_foreign_dns' "$ROOT_DIR/luci-app-forkop/htdocs/luci-static/resources/view/forkop/settings.js" ||
  fail "settings must offer the foreign DNS switch"
grep -Fq 'nft_install_foreign_dns' "$LIB/nft/apply.uc" ||
  fail "nft must install the foreign DNS rules"
grep -Fq 'sinkhole_names' "$LIB/xray/generator.uc" ||
  fail "Xray must sinkhole blocked DNS names"
grep -Fq 'foreign_dns.blocked_names' "$LIB/singbox/generator.uc" ||
  fail "sing-box DNS must reject blocked names"
grep -Fq 'domain_suffix: names' "$LIB/singbox/route.uc" ||
  fail "sniffed protected DNS names must be rejected"

OUT="$(ucode -L "$LIB" -e '
let f = require("routing.foreign_dns");
function has(list, item) {
  for (let value in list)
    if (value == item)
      return true;
  return false;
}
let off = f.blocked_names({ block_foreign_dns: "0" });
if (length(off) != 0)
  die("off");
let on = { block_foreign_dns: "1" };
if (!has(f.blocked_names(on), "dns.google") || !has(f.blocked_v4(on), "8.8.8.8") || !has(f.blocked_v4(on), "1.1.1.1"))
  die("catalog");
let kept = { block_foreign_dns: "1", block_foreign_dns_except: ["cloudflare-dns.com"] };
if (has(f.blocked_names(kept), "cloudflare-dns.com") || has(f.blocked_names(kept), "one.one.one.one") || has(f.blocked_v4(kept), "1.1.1.1"))
  die("except-cloudflare");
if (!has(f.blocked_v4(kept), "8.8.8.8") || !has(f.allowed_v4(kept), "1.1.1.1"))
  die("except-keeps-google");
let child = { block_foreign_dns: "1", block_foreign_dns_except: ["aaaa.dns.nextdns.io"] };
if (has(f.blocked_names(child), "dns.nextdns.io") || !has(f.allowed_v4(child), "45.90.28.167"))
  die("subdomain");
let own = { block_foreign_dns: "1", dns_server: "https://dns.google/dns-query" };
if (has(f.sinkhole_names(own), "dns.google") || !has(f.blocked_names(own), "dns.google"))
  die("own-resolver");
if (f.name_valid("dns.example.net") != true || f.name_valid("bad name") == true || f.name_valid("8.8.8.8") == true)
  die("name");
print("ok\n");
')" || fail "foreign dns ucode check failed"
[ "$OUT" = "ok" ] || fail "unexpected ucode result: $OUT"

cmp -s "$ROOT_DIR/luci-app-forkop/po/ru/forkop.po" "$ROOT_DIR/fe-app-forkop/locales/forkop.ru.po" ||
  fail "Russian catalogs diverged"

echo "foreign dns checks passed"
