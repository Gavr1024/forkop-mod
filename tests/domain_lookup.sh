#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FORKOP_LIB="$ROOT_DIR/forkop/files/usr/lib"
LOOKUP="$FORKOP_LIB/diagnostics/domain_lookup.uc"
WORK_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

lookup() {
  FORKOP_UCI_STATE_FILE="$WORK_DIR/state" \
  FORKOP_ADLIST_DAT="$WORK_DIR/adlist.dat" \
    ucode -L "$FORKOP_LIB" "$LOOKUP" lookup "$1" "${2:-}"
}

grep -Fq 'lookup_domain:' "$ROOT_DIR/forkop/files/usr/bin/forkop" ||
  fail "forkop command must expose lookup_domain"
grep -Fq 'Where a site goes' \
  "$ROOT_DIR/luci-app-forkop/htdocs/luci-static/resources/view/forkop/dashboard.js" ||
  fail "dashboard must ask where a site goes"

printf '%s\n' 'news.example' 'other.test' >"$WORK_DIR/news.lst"

cat >"$WORK_DIR/state" <<EOF
forkop.home=section
forkop.home.enabled=1
forkop.home.action=connection
forkop.home.label=Home
forkop.home.domain_suffix=example.com
forkop.home.source_ip_cidr=192.168.1.10
forkop.news=section
forkop.news.enabled=1
forkop.news.action=bypass
forkop.news.label=News
forkop.news.domain_ip_lists=$WORK_DIR/news.lst
forkop.old=section
forkop.old.enabled=0
forkop.old.action=block
forkop.old.label=Old
forkop.old.domain=news.example
forkop.words=section
forkop.words.enabled=1
forkop.words.action=connection
forkop.words.label=Words
forkop.words.domain_keyword=tracker
forkop.rest=section
forkop.rest.enabled=1
forkop.rest.action=bypass
forkop.rest.label=Rest
forkop.rest.domain_suffix=example.com
EOF

home="$(lookup 'https://www.example.com/watch')"
printf '%s\n' "$home" | grep -Fq '"status": "match"' || fail "suffix should match: $home"
printf '%s\n' "$home" | grep -Fq '"label": "Home"' || fail "first section should win: $home"
printf '%s\n' "$home" | grep -Fq '"reason_kind": "suffix"' || fail "reason should be the suffix: $home"
printf '%s\n' "$home" | grep -Fq '"source_limited": true' || fail "device limit should be reported: $home"
printf '%s\n' "$home" | grep -Fq '"fallback_label": "Rest"' || fail "other devices should fall through: $home"

keyword="$(lookup tracker.invalid)"
printf '%s\n' "$keyword" | grep -Fq '"label": "Words"' || fail "keyword should match: $keyword"
printf '%s\n' "$keyword" | grep -Fq '"reason_kind": "keyword"' || fail "keyword reason missing: $keyword"

news="$(lookup other.test)"
printf '%s\n' "$news" | grep -Fq '"label": "News"' || fail "downloaded list should match: $news"
printf '%s\n' "$news" | grep -Fq '"action": "bypass"' || fail "list section action should be kept: $news"

plain="$(lookup unknown.test)"
printf '%s\n' "$plain" | grep -Fq '"status": "none"' || fail "unknown site should stay outside the rules: $plain"

bad="$(lookup 'not a domain')"
printf '%s\n' "$bad" | grep -Fq '"status": "bad"' || fail "bad input should be rejected: $bad"

cat >"$WORK_DIR/state" <<EOF
forkop.pending=section
forkop.pending.enabled=1
forkop.pending.action=connection
forkop.pending.label=Pending
forkop.pending.community_lists=youtube
forkop.later=section
forkop.later.enabled=1
forkop.later.action=bypass
forkop.later.label=Later
forkop.later.domain=www.youtube.com
EOF

pending="$(lookup www.youtube.com)"
printf '%s\n' "$pending" | grep -Fq '"status": "unknown"' || fail "missing list must not pretend a lower section wins: $pending"
printf '%s\n' "$pending" | grep -Fq '"label": "Pending"' || fail "unknown result should name the higher section: $pending"
printf '%s\n' "$pending" | grep -Fq '"reason_kind": "missing"' || fail "missing list should be the reason: $pending"

printf '%s\n' 'noise livetv886.me more' >"$WORK_DIR/adlist.dat"
cat >"$WORK_DIR/state" <<EOF
forkop.ads=section
forkop.ads.enabled=1
forkop.ads.action=block
forkop.ads.label=Ads
forkop.ads.community_lists=ads_hagezi_pro
EOF

ads="$(lookup ads.livetv886.me)"
printf '%s\n' "$ads" | grep -Fq '"label": "Ads"' || fail "adlist.dat should match the block section: $ads"
printf '%s\n' "$ads" | grep -Fq '"reason_value": "ads_hagezi_pro"' || fail "ad list name missing: $ads"
printf '%s\n' "$ads" | grep -Fq '"action": "block"' || fail "block action missing: $ads"

python3 - "$WORK_DIR/supercell.srs" <<'PY'
import sys
open(sys.argv[1], "wb").write(b"SRS\x02not-text")
PY
mkdir -p "$WORK_DIR/bin"
cat >"$WORK_DIR/bin/sing-box" <<'EOF'
#!/bin/sh
out=""
prev=""
for arg in "$@"; do
  if [ "$prev" = "-o" ]; then
    out=$arg
  fi
  prev=$arg
done
printf '%s\n' '{"rules":[{"domain_suffix":["supercell.com","clashofclans.com"]}]}' >"$out"
EOF
chmod 0755 "$WORK_DIR/bin/sing-box"
cat >"$WORK_DIR/state" <<EOF
forkop.games=section
forkop.games.enabled=1
forkop.games.action=connection
forkop.games.label=Games
forkop.games.domain_ip_lists=$WORK_DIR/supercell.srs
forkop.later=section
forkop.later.enabled=1
forkop.later.action=bypass
forkop.later.label=Later
forkop.later.domain=wwe.com
EOF

inside="$(SING_BOX_BIN="$WORK_DIR/bin/sing-box" lookup clashofclans.com)"
printf '%s\n' "$inside" | grep -Fq '"label": "Games"' || fail "compressed ruleset should match a domain inside it: $inside"
outside="$(SING_BOX_BIN="$WORK_DIR/bin/sing-box" lookup wwe.com)"
printf '%s\n' "$outside" | grep -Fq '"label": "Later"' || fail "compressed ruleset must not hide a lower section: $outside"
printf '%s\n' "$outside" | grep -Fq '"status": "unknown"' && fail "downloaded ruleset must not be reported as missing: $outside"

python3 - "$WORK_DIR/wide.lst" "$WORK_DIR/binary.lst" <<'PY'
import sys
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    handle.write("a" * 65530)
    handle.write("\nfootball.kulichki.net\n")
with open(sys.argv[2], "wb") as handle:
    handle.write(b"before\0youtube.ru\nafter\n")
PY
cat >"$WORK_DIR/state" <<EOF
forkop.wide=section
forkop.wide.enabled=1
forkop.wide.action=bypass
forkop.wide.label=Wide
forkop.wide.domain_ip_lists=$WORK_DIR/wide.lst
forkop.blob=section
forkop.blob.enabled=1
forkop.blob.action=block
forkop.blob.label=Blob
forkop.blob.domain_ip_lists=$WORK_DIR/binary.lst
forkop.later=section
forkop.later.enabled=1
forkop.later.action=connection
forkop.later.label=Later
forkop.later.domain=youtube.ru
EOF

wide="$(lookup football.kulichki.net)"
printf '%s\n' "$wide" | grep -Fq '"label": "Wide"' || fail "a long list should still match: $wide"
miss="$(lookup not-listed.example)"
printf '%s\n' "$miss" | grep -Fq '"status": "none"' || fail "a site outside every list should stay outside: $miss"
printf '%s\n' "$miss" | grep -Fq '"status": "unknown"' && fail "a readable list must not block the answer: $miss"
later="$(lookup youtube.ru)"
printf '%s\n' "$later" | grep -Fq '"label": "Later"' || fail "a binary list must not abort the check: $later"

cat >"$WORK_DIR/state" <<EOF
forkop.dnsreal=section
forkop.dnsreal.enabled=1
forkop.dnsreal.action=dns
forkop.dnsreal.label=AdsDNS
forkop.dnsreal.dns_type=doh
forkop.dnsreal.dns_server=https://dns.google/dns-query
forkop.dnsreal.dns_answer=real
forkop.dnsreal.domain_suffix=youtube.ru
forkop.proxy=section
forkop.proxy.enabled=1
forkop.proxy.action=connection
forkop.proxy.label=Proxy
forkop.proxy.domain_suffix=youtube.ru
EOF

real="$(lookup youtube.ru)"
printf '%s\n' "$real" | grep -Fq '"status": "dns"' || fail "a real DNS section should answer the site: $real"
printf '%s\n' "$real" | grep -Fq '"dns_mode": "real"' || fail "real DNS mode should be reported: $real"
printf '%s\n' "$real" | grep -Fq '"dns_label": "AdsDNS"' || fail "real DNS section name missing: $real"
printf '%s\n' "$real" | grep -Fq '"dns_server": "https://dns.google/dns-query"' || fail "real DNS server missing: $real"
printf '%s\n' "$real" | grep -Fq '"dns_type": "doh"' || fail "real DNS protocol missing: $real"
printf '%s\n' "$real" | grep -Fq '"label": "Proxy"' && fail "a real DNS section must bypass the section below: $real"

cat >"$WORK_DIR/state" <<EOF
forkop.dnsroute=section
forkop.dnsroute.enabled=1
forkop.dnsroute.action=dns
forkop.dnsroute.label=TunnelDNS
forkop.dnsroute.dns_type=udp
forkop.dnsroute.dns_server=1.1.1.1
forkop.dnsroute.dns_answer=route
forkop.dnsroute.dns_detour_enabled=1
forkop.dnsroute.dns_detour_section=proxy
forkop.dnsroute.domain=football.kulichki.net
forkop.proxy=section
forkop.proxy.enabled=1
forkop.proxy.action=connection
forkop.proxy.label=Proxy
forkop.proxy.domain=football.kulichki.net
EOF

routed="$(lookup football.kulichki.net)"
printf '%s\n' "$routed" | grep -Fq '"status": "match"' || fail "route DNS should still let the lower section take the site: $routed"
printf '%s\n' "$routed" | grep -Fq '"label": "Proxy"' || fail "lower section should stay the path: $routed"
printf '%s\n' "$routed" | grep -Fq '"dns_mode": "route"' || fail "route DNS mode should be reported: $routed"
printf '%s\n' "$routed" | grep -Fq '"dns_server": "1.1.1.1"' || fail "route DNS server missing: $routed"
printf '%s\n' "$routed" | grep -Fq '"dns_detour": "Proxy"' || fail "DNS detour section missing: $routed"

cat >"$WORK_DIR/state" <<EOF
forkop.proxy=section
forkop.proxy.enabled=1
forkop.proxy.action=connection
forkop.proxy.label=Proxy
forkop.proxy.domain=youtube.ru
forkop.dnsbelow=section
forkop.dnsbelow.enabled=1
forkop.dnsbelow.action=dns
forkop.dnsbelow.label=Below
forkop.dnsbelow.dns_server=9.9.9.9
forkop.dnsbelow.dns_answer=real
forkop.dnsbelow.domain=youtube.ru
EOF

above="$(lookup youtube.ru)"
printf '%s\n' "$above" | grep -Fq '"label": "Proxy"' || fail "a DNS section below must not steal the site: $above"
printf '%s\n' "$above" | grep -Fq '"dns_mode": ""' || fail "a DNS section below must not be reported: $above"

grep -Fq 'The tunnel resolves the name with DNS section %s, server %s.' \
  "$ROOT_DIR/luci-app-forkop/htdocs/luci-static/resources/view/forkop/dashboard.js" ||
  fail "dashboard must explain which DNS the tunnel uses"
grep -Fq 'Device %s still goes to section %s, including this site, and is sent %s.' \
  "$ROOT_DIR/luci-app-forkop/htdocs/luci-static/resources/view/forkop/dashboard.js" ||
  fail "dashboard must explain full device routing"

cat >"$WORK_DIR/state" <<EOF
forkop.home=section
forkop.home.enabled=1
forkop.home.action=connection
forkop.home.label=Home
forkop.home.fully_routed_ips=192.168.1.50
EOF

one="$(lookup youtube.ru)"
printf '%s\n' "$one" | grep -Fq '"status": "none"' || fail "a site outside lists should stay outside: $one"
printf '%s\n' "$one" | grep -Fq '"192.168.1.50"' || fail "one fully routed device should be named: $one"
printf '%s\n' "$one" | grep -Fq '"label": "Home"' || fail "full routing section should be named: $one"

cat >"$WORK_DIR/state" <<EOF
forkop.lan=section
forkop.lan.enabled=1
forkop.lan.action=bypass
forkop.lan.label=Lan
forkop.lan.fully_routed_ips=192.168.1.0/24 192.168.1.50
EOF

many="$(lookup youtube.ru)"
printf '%s\n' "$many" | grep -Fq '192.168.1.0/24' || fail "a fully routed subnet should be reported: $many"
printf '%s\n' "$many" | grep -Fq '192.168.1.50' || fail "a second fully routed device should be reported: $many"
printf '%s\n' "$many" | grep -Fq '"action": "bypass"' || fail "full routing should keep the section action: $many"

cat >"$WORK_DIR/state" <<EOF
forkop.home=section
forkop.home.enabled=1
forkop.home.action=connection
forkop.home.label=Home
forkop.home.fully_routed_ips=192.168.1.50
forkop.proxy=section
forkop.proxy.enabled=1
forkop.proxy.action=connection
forkop.proxy.label=Proxy
forkop.proxy.domain=youtube.ru
EOF

higher="$(lookup youtube.ru)"
printf '%s\n' "$higher" | grep -Fq '"label": "Proxy"' || fail "the lower domain section should still match: $higher"
printf '%s\n' "$higher" | grep -Fq '"192.168.1.50"' || fail "a higher full route should still be reported: $higher"

cat >"$WORK_DIR/state" <<EOF
forkop.proxy=section
forkop.proxy.enabled=1
forkop.proxy.action=connection
forkop.proxy.label=Proxy
forkop.proxy.domain=youtube.ru
forkop.home=section
forkop.home.enabled=1
forkop.home.action=connection
forkop.home.label=Home
forkop.home.fully_routed_ips=192.168.1.50
EOF

lower="$(lookup youtube.ru)"
printf '%s\n' "$lower" | grep -Fq '"label": "Proxy"' || fail "the higher domain section should win: $lower"
printf '%s\n' "$lower" | grep -Fq '192.168.1.50' && fail "a lower full route must not take a site already claimed above: $lower"

cat >"$WORK_DIR/state" <<EOF
forkop.home=section
forkop.home.enabled=1
forkop.home.action=connection
forkop.home.label=Home
forkop.home.fully_routed_ips=192.168.1.50
forkop.proxy=section
forkop.proxy.enabled=1
forkop.proxy.action=connection
forkop.proxy.label=Proxy
forkop.proxy.domain=youtube.ru
EOF

phone="$(lookup youtube.ru 192.168.1.50)"
printf '%s\n' "$phone" | grep -Fq '"via": "full"' || fail "the selected device should follow full routing: $phone"
printf '%s\n' "$phone" | grep -Fq '"label": "Home"' || fail "full routing should name the device section: $phone"
printf '%s\n' "$phone" | grep -Fq '"device": "192.168.1.50"' || fail "the answer should name the device: $phone"

other="$(lookup youtube.ru 192.168.1.10)"
printf '%s\n' "$other" | grep -Fq '"via": "domain"' || fail "another device should follow the domain section: $other"
printf '%s\n' "$other" | grep -Fq '"label": "Proxy"' || fail "the domain section should take the other device: $other"

cat >"$WORK_DIR/state" <<EOF
forkop.home=section
forkop.home.enabled=1
forkop.home.action=connection
forkop.home.label=Home
forkop.home.domain=youtube.ru
forkop.home.source_ip_cidr=192.168.1.10
forkop.rest=section
forkop.rest.enabled=1
forkop.rest.action=bypass
forkop.rest.label=Rest
forkop.rest.domain=youtube.ru
EOF

mine="$(lookup youtube.ru 192.168.1.10)"
printf '%s\n' "$mine" | grep -Fq '"label": "Home"' || fail "the selected device should stay in its filtered section: $mine"
printf '%s\n' "$mine" | grep -Fq '"fallback_label": "Rest"' && fail "a device answer must not talk about other devices: $mine"

theirs="$(lookup youtube.ru 192.168.1.20)"
printf '%s\n' "$theirs" | grep -Fq '"label": "Rest"' || fail "a device outside the filter should use the next section: $theirs"

cat >"$WORK_DIR/state" <<EOF
forkop.lan=section
forkop.lan.enabled=1
forkop.lan.action=bypass
forkop.lan.label=Lan
forkop.lan.fully_routed_ips=192.168.1.0/24
forkop.proxy=section
forkop.proxy.enabled=1
forkop.proxy.action=connection
forkop.proxy.label=Proxy
forkop.proxy.domain=youtube.ru
EOF
inside="$(lookup youtube.ru 192.168.1.20)"
printf '%s\n' "$inside" | grep -Fq '"via": "full"' || fail "a device inside the subnet should be fully routed: $inside"
printf '%s\n' "$inside" | grep -Fq '"label": "Lan"' || fail "the subnet section should win for that device: $inside"
outside="$(lookup youtube.ru 10.0.0.8)"
printf '%s\n' "$outside" | grep -Fq '"label": "Proxy"' || fail "a device outside the subnet should use the domain section: $outside"

grep -Fq 'Any device' \
  "$ROOT_DIR/luci-app-forkop/htdocs/luci-static/resources/view/forkop/dashboard.js" ||
  fail "dashboard must offer a device choice next to the site"

printf 'domain lookup checks passed\n'
