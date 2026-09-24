#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/forkop/files/usr/lib"
GEO="$LIB/xray/geodata.uc"
CONST="$LIB/xray/constants.uc"
GEN="$LIB/xray/generator.uc"
RT="$LIB/xray/runtime.uc"
UPD="$LIB/components/updates.uc"
NFT_APPLY="$LIB/nft/apply.uc"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok  %s\n' "$1"
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

[ -r "$GEO" ] || fail "missing xray/geodata.uc"

grep -Fq 'ukraine_inside: "ukraine-inside"' "$GEO" ||
  fail "ukraine_inside must map to itdoginfo geosite tag ukraine-inside"
grep -Fq 'russia_inside: "russia-inside"' "$GEO" ||
  fail "russia_inside must map to geosite tag russia-inside"
grep -Fq 'russia_outside: "russia-outside"' "$GEO" ||
  fail "russia_outside must map to geosite tag russia-outside"
grep -Fq 'Services/hdrezka.lst' "$GEO" ||
  fail "hdrezka must have an itdoginfo RAW lst fallback"
grep -Fq 'Categories/hodca.lst' "$GEO" ||
  fail "hodca must convert from itdoginfo Categories lst"
grep -Fq 'ITDOG_RAW_BASE' "$GEO" ||
  fail "RAW lst URLs must come from itdoginfo/allow-domains"
pass "itdoginfo country and service lists are mapped"

grep -Fq 'ALLOW_DOMAINS_DAT_URL' "$CONST" ||
  fail "constants must name the itdoginfo geosite.dat URL"
grep -Fq 'geosite.dat' "$CONST" ||
  fail "itdoginfo release asset geosite.dat is missing from constants"
grep -Fq 'XRAY_LOCATION_ASSET' "$CONST" ||
  fail "Xray must search /usr/share/xray for ext:allow-domains.dat"
grep -Fq 'XRAY_LIST_CACHE_DIR' "$CONST" ||
  fail "converted lists must cache under /etc/forkop/list-cache/xray"
pass "asset paths point at itdoginfo geosite.dat"

extract_fn "$GEO" "community_matchers" | grep -Fq 'resolve_community_ext_tag' ||
  fail "ext:allow-domains.dat must be emitted only when the tag exists in the dat"
extract_fn "$GEO" "parse_dat_matcher" | grep -Fq 'geosite:' ||
  fail "dat_matcher_usable must validate geosite: codes against geosite.dat"
extract_fn "$GEO" "parse_dat_matcher" | grep -Fq 'geoip:' ||
  fail "dat_matcher_usable must validate geoip: codes against geoip.dat"
extract_fn "$GEO" "parse_dat_matcher" | grep -Fq 'ext:' ||
  fail "dat_matcher_usable must validate ext:file:code for every community/custom list"
extract_fn "$GEO" "dat_matcher_usable" | grep -Fq 'itdog_ext_matcher_ok' ||
  fail "ext:allow-domains.dat must require a real itdog dat, not a v2fly file with substring 'block'"
extract_fn "$GEN" "fake_dns_domain_usable" | grep -Fq 'dat_matcher_usable' ||
  fail "FakeDNS must use the global dat matcher filter"
extract_fn "$GEN" "usable_xray_matchers" | grep -Fq 'dat_matcher_usable' ||
  fail "routing domain/ip matchers must use the global dat matcher filter"
extract_fn "$GEN" "generate_config" | grep -Fq 'sanitize_generated_config' ||
  fail "generated Xray JSON must be sanitized before write/test"
extract_fn "$GEO" "community_matchers" | grep -Fq 'community_subnet_ips' ||
  fail "itdog IP lists (discord/telegram) must stay RAW CIDRs, not geosite"
extract_fn "$GEO" "community_matchers" | grep -Fq 'community_lst_path' ||
  fail "itdog RAW .lst remains a fallback when allow-domains.dat is missing"
extract_fn "$GEO" "community_matchers" | grep -Fq 'dat_matcher_usable' ||
  fail "community geosite:/ext: fallback must use the global tag check"
extract_fn "$GEO" "stage_geosite_dat_inner" | grep -Fq 'looks_like_itdog_dat' ||
  fail "itdoginfo geosite.dat must not be staged as v2fly geosite.dat"
extract_fn "$GEO" "salvage_itdog_dat" | grep -Fq 'allow-domains.dat' ||
  fail "itdoginfo geosite.dat at /etc/xray must become allow-domains.dat"
extract_fn "$GEO" "decompile_srs" | grep -Fq 'MAX_DECOMPILE_BYTES' ||
  fail "oversized .srs (russia-inside) must skip decompile instead of hanging start"
extract_fn "$GEO" "decompile_srs" | grep -Fq 'rule-set' ||
  fail "decompile_srs must call sing-box rule-set decompile"
extract_fn "$GEO" "decompile_srs" | grep -Fq 'timeout' ||
  fail "decompile_srs must be bounded by timeout(1)"
extract_fn "$GEO" "decompile_srs" | grep -Fq 'MAX_DECOMPILE_BYTES' ||
  fail "oversized .srs must skip decompile and stay on the sidecar"
extract_fn "$GEO" "ingest_rule_object" | grep -Fq 'full:' ||
  fail "decompiled domain entries must become Xray full: matchers"
extract_fn "$GEO" "ingest_rule_object" | grep -Fq 'keyword:' ||
  fail "decompiled domain_keyword must become Xray keyword: matchers"
extract_fn "$GEO" "community_ext_candidates" | grep -Fq 'replace(name, "_", "-")' ||
  fail "google_ai / google_play must become google-ai / google-play geosite tags"
pass "itdoginfo country and service lists use geosite.dat tags"

extract_fn "$GEO" "ensure_from_uci" | grep -Fq 'needed_references' ||
  fail "ensure_from_uci must also convert custom rule_set / domain_ip_lists"
extract_fn "$GEO" "needed_references" | grep -Fq 'rule_sets_with_subnets' ||
  fail "subnet rule-sets must be converted, not only domain rule-sets"
extract_fn "$GEO" "ensure_from_uci" | grep -Fq 'is_xray_primary' ||
  fail "conversion must run only when Xray owns the plane"
if extract_fn "$GEO" "ensure_from_uci" | grep -Fq 'fetch_url_quick'; then
  fail "start must not probe GitHub for geosite.dat; use cache then list-update"
fi
extract_fn "$GEO" "ensure_from_uci" | grep -Fq 'from cache' ||
  fail "init-config must convert from cache, not download_to_file (45s x 3)"
if extract_fn "$GEO" "ensure_from_uci" | grep -Fq 'decompile_srs'; then
  fail "ensure_from_uci must not decompile community .srs during start"
fi
grep -Fq 'ensure_from_uci' "$RT" ||
  fail "runtime init-config must fetch converted lists before generate-config"
extract_fn "$RT" "init_config" | grep -Fq 'continuing without converted lists' ||
  fail "list conversion errors must not abort Xray start"
grep -Fq 'timeout' "$RT" ||
  fail "xray -test must be bounded so a bad config cannot hang forkop start"
grep -Fq 'Refreshing Xray configuration after list conversion' "$UPD" ||
  fail "list-update must reload Xray after geosite.dat is fetched"
grep -Fq 'download_proxy_address' "$UPD" ||
  fail "list-update must fetch GitHub lists through the selected Xray section SOCKS"
grep -Fq 'socks5h://' "$ROOT_DIR/forkop/files/usr/lib/routing/list_cache.uc" ||
  fail "Xray list downloads must use socks5h so DNS also goes through the section"
grep -Fq 'XRAY_LOCATION_ASSET' "$RT" ||
  fail "managed xray init must export XRAY_LOCATION_ASSET so ext: dat resolves"
extract_fn "$RT" "check_config" | grep -Fq 'XRAY_LOCATION_ASSET' ||
  fail "xray -test must set XRAY_LOCATION_ASSET or it looks for /usr/bin/geosite.dat"
extract_fn "$GEO" "stage_geosite_dat_inner" | grep -Fq 'geosite.dat' ||
  fail "geosite.dat from v2ray/etc must be staged into /usr/share/xray"
extract_fn "$GEN" "fake_dns_domain_usable" | grep -Fq 'dat_matcher_usable' ||
  fail "FakeDNS must not emit geosite:/ext: matchers when the code is missing from dat"
pass "init and list-update pull converted lists"

extract_fn "$GEO" "restore_flash_dat" | grep -Fq 'allow-domains.dat' ||
  fail "Xray DAT must restore allow-domains.dat from flash cache on start"
extract_fn "$GEO" "persist_dat_to_flash" | grep -Fq 'persist_enabled' ||
  fail "DAT must not be copied to flash when persist_lists_locally is off"
extract_fn "$GEO" "persist_dat_to_flash" | grep -Fq 'gzip_file' ||
  fail "DAT flash cache must be gzip, not a second full copy"
grep -Fq 'const GEODATA_RAM_DIR = "/tmp/forkop-geodata"' "$GEO" ||
  fail "v2fly geosite download must land in /tmp, not on the flash cache"
extract_fn "$GEO" "fetch_v2fly_geosite" | grep -Fq 'download_scratch' ||
  fail "v2fly geosite must be fetched through the tmp scratch path"
extract_fn "$GEO" "forget_v2fly_scratch" | grep -Fq 'v2fly-geosite.dat' ||
  fail "leftover v2fly-geosite.dat must be removed from flash after the gzip cache exists"
extract_fn "$GEO" "restore_flash_dat" | grep -Fq 'persist_enabled' ||
  fail "flash DAT restore must honour persist_lists_locally"
extract_fn "$UPD" "list_update_if_missing" | grep -Fq 'persist_enabled' ||
  fail "start must download lists every boot when persist_lists_locally is off"
extract_fn "$GEO" "assets_present_for_uci" | grep -Fq 'allow_domains_dat_present' ||
  fail "start must force list-update when required DAT is missing"
extract_fn "$GEO" "restore_flash_dat" | grep -Fq 'persist_dat_to_flash' ||
  fail "existing DAT in /usr/share/xray must be copied onto flash cache"
grep -Fq 'list-update-if-missing' "$ROOT_DIR/forkop/files/usr/lib/service/lifecycle.uc" ||
  fail "start must not download lists every boot; use list-update-if-missing"
grep -Fq '/etc/forkop/list-update.timestamp' "$UPD" ||
  fail "list-update timestamp must live on flash so reboot does not re-download"
extract_fn "$UPD" "list_update_if_missing" | grep -Fq 'list_update_if_due' ||
  fail "start must download lists only when the configured interval has elapsed"
extract_fn "$UPD" "list_update" | grep -Fq 'skip reload' ||
  fail "list-update must not reload Xray when config.json did not change"

extract_fn "$GEN" "section_converted_lists" | grep -Fq 'community_matchers' ||
  fail "generator must consume converted community lists"
extract_fn "$GEN" "section_domain_matchers" | grep -Fq 'section_converted_lists' ||
  fail "TPROXY domain rules must include converted lists"
extract_fn "$GEN" "section_ip_matchers" | grep -Fq 'section_converted_lists' ||
  fail "TPROXY IP rules must include converted CIDRs from lists"
extract_fn "$GEN" "section_has_unmapped_domain_list" | grep -Fq 'unmapped' ||
  fail "FakeDNS stays broad only when a list failed to convert"
extract_fn "$GEO" "community_matchers" | grep -Fq 'native_xray_list_name' ||
  fail "ads/supercell/github must not decompile .srs on the Xray plane"
extract_fn "$GEO" "community_matchers" | grep -Fq 'ext:adlist.dat:' ||
  fail "hagezi must use adlist.dat on the Xray plane"
extract_fn "$GEO" "community_matchers" | grep -Fq 'supercell_json_path' ||
  fail "supercell must use supercell.json on the Xray plane"
extract_fn "$GEO" "lst_to_matchers" | grep -Fq 'domain:' ||
  fail "RAW lst domains must be emitted as Xray domain: suffix matchers"
extract_fn "$NFT_APPLY" "write_xray_dnsmasq_nftset_conf" | grep -Fq 'section_list_nftset_domains' ||
  fail "community list hosts must go into dnsmasq nftset so facebook.com is intercepted"
extract_fn "$NFT_APPLY" "section_has_xray_domain_nft" | grep -Fq 'community_lists' ||
  fail "community list nftset lines must have matching forkop_rule_*_subnets sets"
extract_fn "$NFT_APPLY" "section_list_nftset_domains" | grep -Fq 'catch' ||
  fail "missing xray.geodata must not abort nft rebuild"
extract_fn "$NFT_APPLY" "section_list_nftset_domains" | grep -Fq 'section_domain_ip_list_parsed' ||
  fail "custom domain/IP lists must be written to dnsmasq nftset"
extract_fn "$NFT_APPLY" "section_domain_ip_list_parsed" | grep -Fq 'domain_ip_lists' ||
  fail "custom domain/IP lists must be read from the section field"
extract_fn "$GEO" "plain_list_parsed" | grep -Fq 'list_file_matchers' ||
  fail "custom lists must use the same parser as Xray routing rules"
extract_fn "$NFT_APPLY" "nft_populate_runtime_set_for_section" | grep -Fq 'section_domain_ip_list_parsed' ||
  fail "custom list subnets must be loaded into nft on start, not only during list-update"
grep -Fq 'nft-write-xray-nftset-conf' "$UPD" ||
  fail "list-update must rewrite Xray nftset after fetching RAW lst"
pass "Xray routing/FakeDNS consume converted matchers"

python3 - "$GEO" "$GEN" "$RT" "$ROOT_DIR/forkop/files/usr/lib/xray/outbound.uc" <<'PY' || fail "ucode binds callee names at definition time; no function may call a later function in the same file"
import re, sys
from pathlib import Path
for path in sys.argv[1:]:
    text = Path(path).read_text()
    funcs = []
    for m in re.finditer(r'^function ([A-Za-z_][A-Za-z0-9_]*)\(', text, re.M):
        funcs.append((m.group(1), text[:m.start()].count('\n') + 1))
    by = {n: ln for n, ln in funcs}
    lines = text.splitlines()
    bad = []
    for i, (name, start) in enumerate(funcs):
        end = funcs[i + 1][1] - 1 if i + 1 < len(funcs) else len(lines)
        body = '\n'.join(lines[start:end])
        for c in sorted(set(re.findall(r'\b([A-Za-z_][A-Za-z0-9_]*)\s*\(', body))):
            if c in by and by[c] > start:
                bad.append(f"{path}:{name} -> {c}")
    if bad:
        print('\n'.join(bad), file=sys.stderr)
        raise SystemExit(1)
PY
pass "no ucode forward function calls in xray geodata/generator/runtime/outbound"

grep -R -n 'fs\.mkdir' "$ROOT_DIR/forkop/files/usr/lib/xray" &&
  fail "xray ucode must not call fs.mkdir (not a function on OpenWrt ucode)"
pass "xray libs do not call fs.mkdir"

printf 'xray geodata conversion checks passed\n'
