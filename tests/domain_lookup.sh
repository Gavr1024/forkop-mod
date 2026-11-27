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
  FORKOP_GEOSITE_DAT="$WORK_DIR/geosite.dat" \
    ucode -L "$FORKOP_LIB" "$LOOKUP" lookup "$1" "${2:-}"
}

lookup_mode() {
  FORKOP_UCI_STATE_FILE="$WORK_DIR/state" \
  FORKOP_ADLIST_DAT="$WORK_DIR/adlist.dat" \
  FORKOP_GEOSITE_DAT="$WORK_DIR/geosite.dat" \
    ucode -L "$FORKOP_LIB" "$LOOKUP" "$@"
}

grep -Fq 'lookup_domain:' "$ROOT_DIR/forkop/files/usr/bin/forkop" ||
  fail "forkop command must expose lookup_domain"
grep -Fq 'lookup_domain_start:' "$ROOT_DIR/forkop/files/usr/bin/forkop" ||
  fail "forkop command must start a background site check"
grep -Fq 'lookup_domain_status' \
  "$ROOT_DIR/luci-app-forkop/htdocs/luci-static/resources/view/forkop/dashboard.js" ||
  fail "dashboard must wait for the background site check"
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

cat >"$WORK_DIR/state" <<EOF
forkop.intel=section
forkop.intel.enabled=1
forkop.intel.action=connection
forkop.intel.label=Intel
forkop.intel.domain=intel.com
EOF

subdomain="$(lookup www.intel.com)"
printf '%s\n' "$subdomain" | grep -Fq '"label": "Intel"' || fail "a plain domain must cover its subdomains: $subdomain"
printf '%s\n' "$subdomain" | grep -Fq '"reason_kind": "suffix"' || fail "a plain domain must be a suffix: $subdomain"
itself="$(lookup intel.com)"
printf '%s\n' "$itself" | grep -Fq '"label": "Intel"' || fail "a plain domain must still match itself: $itself"
stranger="$(lookup intel.com.evil.com)"
printf '%s\n' "$stranger" | grep -Fq '"status": "none"' || fail "a foreign site must not inherit the suffix: $stranger"

cat >"$WORK_DIR/state" <<EOF
forkop.exact=section
forkop.exact.enabled=1
forkop.exact.action=connection
forkop.exact.label=Exact
forkop.exact.domain=full:intel.com
EOF

exact="$(lookup intel.com)"
printf '%s\n' "$exact" | grep -Fq '"label": "Exact"' || fail "full: must match the exact name: $exact"
printf '%s\n' "$exact" | grep -Fq '"reason_kind": "domain"' || fail "full: must stay an exact match: $exact"
wider="$(lookup www.intel.com)"
printf '%s\n' "$wider" | grep -Fq '"status": "none"' || fail "full: must not cover subdomains: $wider"

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
forkop.settings=settings
forkop.settings.routing_engine=xray
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
printf '%s\n' "$miss" | grep -Fq '"status": "unknown"' || fail "an unreadable list must not look like a miss: $miss"
printf '%s\n' "$miss" | grep -Fq '"label": "Blob"' || fail "an unreadable list must stay on its own section: $miss"
later="$(lookup youtube.ru)"
printf '%s\n' "$later" | grep -Fq '"status": "unknown"' || fail "a binary list must not hand the site to a lower section: $later"
printf '%s\n' "$later" | grep -Fq '"label": "Blob"' || fail "a binary list must name its own section: $later"

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
forkop.dns=section
forkop.dns.enabled=1
forkop.dns.action=dns
forkop.dns.label=DNS
forkop.dns.dns_type=doh
forkop.dns.dns_server=77.88.8.8:443
forkop.dns.dns_answer=route
forkop.dns.domain=youtube.com
forkop.all=section
forkop.all.enabled=1
forkop.all.action=connection
forkop.all.label=ALL
forkop.all.fully_routed_ips=192.168.1.50
EOF

full_dns="$(lookup youtube.com 192.168.1.50)"
printf '%s\n' "$full_dns" | grep -Fq '"via": "full"' || fail "a fully routed device must stay on full routing: $full_dns"
printf '%s\n' "$full_dns" | grep -Fq '"label": "ALL"' || fail "full routing section must win: $full_dns"
printf '%s\n' "$full_dns" | grep -Fq '"dns_via": "domain"' || fail "a listed DNS name must not be treated as every name: $full_dns"
printf '%s\n' "$full_dns" | grep -Fq '"dns_label": "DNS"' || fail "the DNS section must still be named: $full_dns"
outside_dns="$(lookup example.com 192.168.1.50)"
printf '%s\n' "$outside_dns" | grep -Fq '"dns_label": ""' || fail "a name outside the DNS list must not use that DNS section: $outside_dns"

cat >"$WORK_DIR/state" <<EOF
forkop.dns=section
forkop.dns.enabled=1
forkop.dns.action=dns
forkop.dns.label=DNS
forkop.dns.dns_type=doh
forkop.dns.dns_server=77.88.8.8:443
forkop.dns.dns_answer=route
forkop.dns.domain=2ip.ru
forkop.dns.fully_routed_ips=192.168.1.50
forkop.all=section
forkop.all.enabled=1
forkop.all.action=connection
forkop.all.label=ALL
forkop.all.fully_routed_ips=192.168.1.50
EOF

every_dns="$(lookup example.com 192.168.1.50)"
printf '%s\n' "$every_dns" | grep -Fq '"dns_via": "full"' || fail "a device fully routed inside the DNS section must cover every name: $every_dns"
printf '%s\n' "$every_dns" | grep -Fq '"label": "ALL"' || fail "the routing section must still take the connection: $every_dns"

grep -Fq 'data.dns_via === "full"' \
  "$ROOT_DIR/luci-app-forkop/htdocs/luci-static/resources/view/forkop/dashboard.js" ||
  fail "every-name DNS text must require full DNS routing"

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

cat >"$WORK_DIR/state" <<EOF
forkop.settings=settings
forkop.settings.routing_excluded_ips=192.168.1.77
forkop.home=section
forkop.home.enabled=1
forkop.home.action=connection
forkop.home.label=Home
forkop.home.domain=youtube.ru
forkop.home.fully_routed_ips=192.168.1.77
EOF

kept="$(lookup youtube.ru 192.168.1.77)"
printf '%s\n' "$kept" | grep -Fq '"status": "excluded"' || fail "a settings exclusion must win over sections: $kept"
printf '%s\n' "$kept" | grep -Fq '"via": "settings"' || fail "a settings exclusion must be named as settings: $kept"
open="$(lookup youtube.ru 192.168.1.78)"
printf '%s\n' "$open" | grep -Fq '"label": "Home"' || fail "another device should still match the section: $open"

grep -Fq 'Device %s is fully excluded in settings. Sections do not see its traffic.' \
  "$ROOT_DIR/luci-app-forkop/htdocs/luci-static/resources/view/forkop/dashboard.js" ||
  fail "dashboard must explain a settings exclusion"
grep -Fq 'Показать конфигурацию sing-box' \
  "$ROOT_DIR/luci-app-forkop/po/ru/forkop.po" \
  "$ROOT_DIR/fe-app-forkop/locales/forkop.ru.po" ||
  fail "sing-box config label must use the same word order as Xray"
grep -Fq 'Устройство %s полностью исключено в настройках. Секции его трафик не видят.' \
  "$ROOT_DIR/luci-app-forkop/po/ru/forkop.po" ||
  fail "settings exclusion sentence must be translated"

grep -Fq 'Any device' \
  "$ROOT_DIR/luci-app-forkop/htdocs/luci-static/resources/view/forkop/dashboard.js" ||
  fail "dashboard must offer a device choice next to the site"

python3 - "$WORK_DIR/geosite.dat" <<'PY'
import sys

def varint(n):
    out = bytearray()
    while True:
        b = n & 0x7F
        n >>= 7
        if n:
            out.append(b | 0x80)
        else:
            out.append(b)
            return bytes(out)

def field_bytes(field, data):
    return bytes([(field << 3) | 2]) + varint(len(data)) + data

def field_varint(field, n):
    return bytes([(field << 3) | 0]) + varint(n)

def domain(kind, value):
    return field_varint(1, kind) + field_bytes(2, value.encode())

def entry(code, domains):
    body = field_bytes(1, code.encode())
    for item in domains:
        body += field_bytes(2, item)
    return field_bytes(1, body)

blob = entry("other", [domain(3, "example.com")]) + entry("youtube", [domain(2, "youtube.com")])
open(sys.argv[1], "wb").write(blob)
PY

cat >"$WORK_DIR/state" <<EOF
forkop.lists=section
forkop.lists.enabled=1
forkop.lists.action=connection
forkop.lists.label=Lists
forkop.lists.community_lists=youtube
forkop.later=section
forkop.later.enabled=1
forkop.later.action=bypass
forkop.later.label=Later
forkop.later.domain=www.youtube.com
forkop.settings=settings
forkop.settings.routing_engine=xray
EOF

fromdat="$(lookup www.youtube.com)"
printf '%s\n' "$fromdat" | grep -Fq '"label": "Lists"' || fail "a site inside geosite.dat must use that section: $fromdat"
printf '%s\n' "$fromdat" | grep -Fq '"reason_kind": "community"' || fail "geosite.dat match must name the list: $fromdat"
otherdat="$(lookup example.com)"
printf '%s\n' "$otherdat" | grep -Fq '"status": "none"' || fail "a site from another list code must not match: $otherdat"

python3 - "$WORK_DIR/geosite.dat" <<'PY'
import sys

def varint(n):
    out = bytearray()
    while True:
        b = n & 0x7F
        n >>= 7
        if n:
            out.append(b | 0x80)
        else:
            out.append(b)
            return bytes(out)

def field_bytes(field, data):
    return bytes([(field << 3) | 2]) + varint(len(data)) + data

def field_varint(field, n):
    return bytes([(field << 3) | 0]) + varint(n)

def domain(kind, value):
    return field_varint(1, kind) + field_bytes(2, value.encode())

def entry(code, domains):
    body = field_bytes(1, code.encode())
    for item in domains:
        body += field_bytes(2, item)
    return field_bytes(1, body)

domains = [domain(2, "pad%d.example" % i) for i in range(30)]
domains.append(domain(2, "intel.com"))
wide = entry("youtube", domains)
if len(wide) <= 127:
    raise SystemExit("wide entry should need a long length")
open(sys.argv[1], "wb").write(entry("other", [domain(3, "example.com")]) + wide + b"\x00" * 32)
PY

widehit="$(lookup www.intel.com)"
printf '%s\n' "$widehit" | grep -Fq '"label": "Lists"' || fail "a long geosite entry should still match: $widehit"
widemiss="$(lookup not-in-list.example)"
printf '%s\n' "$widemiss" | grep -Fq '"status": "none"' || fail "a long geosite entry must not take every site: $widemiss"
rm -f "$WORK_DIR/geosite.dat"

python3 - "$WORK_DIR/allow.dat" <<'PY'
import sys

def varint(n):
    out = bytearray()
    while True:
        b = n & 0x7F
        n >>= 7
        if n:
            out.append(b | 0x80)
        else:
            out.append(b)
            return bytes(out)

def field_bytes(field, data):
    return bytes([(field << 3) | 2]) + varint(len(data)) + data

def field_varint(field, n):
    return bytes([(field << 3) | 0]) + varint(n)

def domain(kind, value):
    return field_varint(1, kind) + field_bytes(2, value.encode())

def entry(code, domains):
    body = field_bytes(1, code.encode())
    for item in domains:
        body += field_bytes(2, item)
    return field_bytes(1, body)

blob = entry("youtube", [domain(2, "youtube.com")]) + entry("russia-inside", [domain(2, "inside.example")])
blob += b"\x00" * (32768 - len(blob))
open(sys.argv[1], "wb").write(blob)
PY
mkdir -p /usr/share/xray
saved_allow=""
if [ -f /usr/share/xray/allow-domains.dat ]; then
  saved_allow="$WORK_DIR/allow-domains.saved"
  cp /usr/share/xray/allow-domains.dat "$saved_allow"
fi
cp "$WORK_DIR/allow.dat" /usr/share/xray/allow-domains.dat
mixed="$(lookup inside.example)"
printf '%s\n' "$mixed" | grep -Fq '"label": "Lists"' && fail "another code in the same dat must not count as this list: $mixed"
printf '%s\n' "$mixed" | grep -Fq '"status": "none"' || fail "a site from another code must stay outside this list: $mixed"
still="$(lookup www.youtube.com)"
printf '%s\n' "$still" | grep -Fq '"label": "Lists"' || fail "the selected code must still match: $still"
if [ -n "$saved_allow" ]; then
  mv "$saved_allow" /usr/share/xray/allow-domains.dat
else
  rm -f /usr/share/xray/allow-domains.dat
fi

python3 - "$WORK_DIR/broken.dat" <<'PY'
import sys
open(sys.argv[1], "wb").write(b"\x00\x01not-a-list")
PY
cat >"$WORK_DIR/state" <<EOF
forkop.broken=section
forkop.broken.enabled=1
forkop.broken.action=connection
forkop.broken.label=Broken
forkop.broken.domain_ip_lists=$WORK_DIR/broken.dat
forkop.later=section
forkop.later.enabled=1
forkop.later.action=bypass
forkop.later.label=Later
forkop.later.domain=www.youtube.com
EOF

broken="$(lookup www.youtube.com)"
printf '%s\n' "$broken" | grep -Fq '"status": "unknown"' || fail "an unreadable list must not hand the site to a lower section: $broken"
printf '%s\n' "$broken" | grep -Fq '"label": "Broken"' || fail "an unreadable list must name its own section: $broken"

cat >"$WORK_DIR/state" <<EOF
forkop.web=section
forkop.web.enabled=1
forkop.web.action=bypass
forkop.web.label=Web
forkop.web.domain=youtube.com
forkop.web.ports=443
EOF

ports="$(lookup youtube.com)"
printf '%s\n' "$ports" | grep -Fq '"ports": "443"' || fail "a port limit must be reported: $ports"
printf '%s\n' "$ports" | grep -Fq '"label": "Web"' || fail "the ported section must still match: $ports"

grep -Fq 'This match is only for ports %s.' \
  "$ROOT_DIR/luci-app-forkop/htdocs/luci-static/resources/view/forkop/dashboard.js" ||
  fail "dashboard must mention the port limit"
grep -Fq 'Это только для портов %s.' \
  "$ROOT_DIR/luci-app-forkop/po/ru/forkop.po" \
  "$ROOT_DIR/fe-app-forkop/locales/forkop.ru.po" ||
  fail "port limit sentence must be translated"

cat >"$WORK_DIR/state" <<EOF
forkop.home=section
forkop.home.enabled=1
forkop.home.action=connection
forkop.home.label=Home
forkop.home.domain=youtube.ru
EOF

started="$(FORKOP_LOOKUP_JOB_DIR="$WORK_DIR/jobs" lookup_mode start youtube.ru)"
printf '%s\n' "$started" | grep -Fq '"running": true' || fail "a site check must start in the background: $started"
job_id="$(printf '%s\n' "$started" | sed -n 's/.*"id": "\([^"]*\)".*/\1/p')"
test -n "$job_id" || fail "a background site check must return an id: $started"
finished=0
last_status=""
for _try in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  last_status="$(FORKOP_LOOKUP_JOB_DIR="$WORK_DIR/jobs" lookup_mode status "$job_id")"
  if printf '%s\n' "$last_status" | grep -Fq '"running": false'; then
    finished=1
    break
  fi
  sleep 0.2
done
test "$finished" = 1 || fail "a background site check did not finish: $last_status"
printf '%s\n' "$last_status" | grep -Fq '"label": "Home"' || fail "a background site check must keep the section: $last_status"
test ! -e "$WORK_DIR/jobs/$job_id.json" || fail "a finished site check must remove its result file"
test ! -e "$WORK_DIR/jobs/$job_id.pid" || fail "a finished site check must remove its pid file"
test ! -e "$WORK_DIR/jobs/$job_id.part" || fail "a finished site check must remove its temporary output"
test ! -e "$WORK_DIR/jobs/$job_id.started" || fail "a finished site check must remove its start mark"

lookup_cached() {
  FORKOP_UCI_STATE_FILE="$WORK_DIR/state" \
  FORKOP_ADLIST_DAT="$WORK_DIR/adlist.dat" \
  FORKOP_GEOSITE_DAT="$WORK_DIR/geosite.dat" \
  FORKOP_LIST_CACHE_DIR="$WORK_DIR/cache" \
  FORKOP_XRAY_LIST_CACHE_DIR="$WORK_DIR/xray" \
  SING_BOX_BIN="$WORK_DIR/bin/sing-box" \
    ucode -L "$FORKOP_LIB" "$LOOKUP" lookup "$1"
}

mkdir -p "$WORK_DIR/xray"
printf '%s\n' '{"version":3,"rules":[{"domain_suffix":["supercell.com","clashofclans.com"]}]}' >"$WORK_DIR/xray/supercell.json"
cat >"$WORK_DIR/state" <<EOF
forkop.settings=settings
forkop.settings.routing_engine=xray
forkop.games=section
forkop.games.enabled=1
forkop.games.action=connection
forkop.games.label=Games
forkop.games.community_lists=supercell
forkop.later=section
forkop.later.enabled=1
forkop.later.action=bypass
forkop.later.label=Later
forkop.later.domain=inteloos.com
EOF

from_json="$(lookup_cached clashofclans.com)"
printf '%s\n' "$from_json" | grep -Fq '"label": "Games"' || fail "Xray supercell.json must be read from the local reserve: $from_json"
not_there="$(lookup_cached inteloos.com)"
printf '%s\n' "$not_there" | grep -Fq '"label": "Later"' || fail "a site missing from supercell.json must reach the lower section: $not_there"
printf '%s\n' "$not_there" | grep -Fq '"status": "unknown"' && fail "a present supercell.json must not be reported as missing: $not_there"

rm -f "$WORK_DIR/xray/supercell.json"
srs_base="$(ucode -L "$FORKOP_LIB" -e 'let rules = require("singbox.rulesets"); let url = rules.community_url("supercell"); print(rules.hash12(url) + ".srs\n");')"
mkdir -p "$WORK_DIR/cache/sing-box"
cp "$WORK_DIR/supercell.srs" "$WORK_DIR/cache/sing-box/$srs_base"
cat >"$WORK_DIR/state" <<EOF
forkop.settings=settings
forkop.settings.routing_engine=sing-box
forkop.games=section
forkop.games.enabled=1
forkop.games.action=connection
forkop.games.label=Games
forkop.games.community_lists=supercell
forkop.later=section
forkop.later.enabled=1
forkop.later.action=bypass
forkop.later.label=Later
forkop.later.domain=inteloos.com
EOF
from_srs="$(lookup_cached clashofclans.com)"
printf '%s\n' "$from_srs" | grep -Fq '"label": "Games"' || fail "sing-box supercell.srs must be read from the local reserve: $from_srs"
not_in_srs="$(lookup_cached inteloos.com)"
printf '%s\n' "$not_in_srs" | grep -Fq '"label": "Later"' || fail "a site missing from supercell.srs must reach the lower section: $not_in_srs"
printf '%s\n' "$not_in_srs" | grep -Fq '"status": "unknown"' && fail "a present supercell.srs must not be reported as missing: $not_in_srs"

printf '%s\n' '{"version":3,"rules":[{"domain_suffix":["json-only.example"]}]}' >"$WORK_DIR/xray/supercell.json"
cat >"$WORK_DIR/state" <<EOF
forkop.settings=settings
forkop.settings.routing_engine=xray
forkop.games=section
forkop.games.enabled=1
forkop.games.action=connection
forkop.games.label=Games
forkop.games.community_lists=supercell
forkop.later=section
forkop.later.enabled=1
forkop.later.action=bypass
forkop.later.label=Later
forkop.later.domain=clashofclans.com
EOF
json_only="$(lookup_cached json-only.example)"
printf '%s\n' "$json_only" | grep -Fq '"label": "Games"' || fail "Xray must follow supercell.json when the srs is also present: $json_only"
not_json="$(lookup_cached clashofclans.com)"
printf '%s\n' "$not_json" | grep -Fq '"label": "Later"' || fail "Xray must not take a domain that is only in the srs: $not_json"
cat >"$WORK_DIR/state" <<EOF
forkop.settings=settings
forkop.settings.routing_engine=sing-box
forkop.games=section
forkop.games.enabled=1
forkop.games.action=connection
forkop.games.label=Games
forkop.games.community_lists=supercell
forkop.later=section
forkop.later.enabled=1
forkop.later.action=bypass
forkop.later.label=Later
forkop.later.domain=json-only.example
EOF
srs_only="$(lookup_cached clashofclans.com)"
printf '%s\n' "$srs_only" | grep -Fq '"label": "Games"' || fail "sing-box must follow supercell.srs when the json is also present: $srs_only"
not_srs="$(lookup_cached json-only.example)"
printf '%s\n' "$not_srs" | grep -Fq '"label": "Later"' || fail "sing-box must not take a domain that is only in the json: $not_srs"

python3 - "$WORK_DIR/kinds.srs" <<'PY'
import sys
open(sys.argv[1], "wb").write(b"SRS\x02not-text")
PY
cat >"$WORK_DIR/bin/sing-box-kinds" <<'EOF'
#!/bin/sh
out=""
prev=""
for arg in "$@"; do
  if [ "$prev" = "-o" ]; then
    out=$arg
  fi
  prev=$arg
done
printf '%s\n' '{"rules":[{"domain":["Exact.Example"],"domain_suffix":["Suffix.Example"],"domain_keyword":["Needle"],"domain_regex":["^re[.]example$"]}]}' >"$out"
EOF
chmod 0755 "$WORK_DIR/bin/sing-box-kinds"
cat >"$WORK_DIR/state" <<EOF
forkop.settings=settings
forkop.settings.routing_engine=xray
forkop.kinds=section
forkop.kinds.enabled=1
forkop.kinds.action=connection
forkop.kinds.label=Kinds
forkop.kinds.domain_ip_lists=$WORK_DIR/kinds.srs
forkop.later=section
forkop.later.enabled=1
forkop.later.action=bypass
forkop.later.label=Later
forkop.later.domain=www.exact.example
EOF
export FORKOP_SING_BOX_BIN="$WORK_DIR/bin/sing-box-kinds"
exact="$(lookup_cached exact.example)"
printf '%s\n' "$exact" | grep -Fq '"label": "Kinds"' || fail "Xray must keep an exact name from an srs link: $exact"
wider="$(lookup_cached www.exact.example)"
printf '%s\n' "$wider" | grep -Fq '"label": "Later"' || fail "Xray must not widen an exact name from an srs link: $wider"
suffix="$(lookup_cached www.suffix.example)"
printf '%s\n' "$suffix" | grep -Fq '"label": "Kinds"' || fail "Xray must keep a suffix from an srs link: $suffix"
keyword="$(lookup_cached foo-needle.test)"
printf '%s\n' "$keyword" | grep -Fq '"label": "Kinds"' || fail "Xray must keep a keyword from an srs link: $keyword"
regex="$(lookup_cached re.example)"
printf '%s\n' "$regex" | grep -Fq '"label": "Kinds"' || fail "Xray must keep a regular expression from an srs link: $regex"
find "$WORK_DIR/xray" -name '*.xray.json' | grep -q . || fail "Xray must save the unpacked srs json"
printf '%s\n' '#!/bin/sh' 'exit 1' >"$WORK_DIR/bin/sing-box-kinds"
cached="$(lookup_cached www.suffix.example)"
printf '%s\n' "$cached" | grep -Fq '"label": "Kinds"' || fail "Xray must reuse the saved srs json: $cached"
unset FORKOP_SING_BOX_BIN

python3 - "$WORK_DIR/broken.srs" <<'PY'
import sys
open(sys.argv[1], "wb").write(b"SRS\x02not-text")
PY
cat >"$WORK_DIR/state" <<EOF
forkop.settings=settings
forkop.settings.routing_engine=xray
forkop.broken=section
forkop.broken.enabled=1
forkop.broken.action=connection
forkop.broken.label=Broken
forkop.broken.domain_ip_lists=$WORK_DIR/broken.srs
forkop.later=section
forkop.later.enabled=1
forkop.later.action=bypass
forkop.later.label=Later
forkop.later.domain=other.example
EOF
export FORKOP_SING_BOX_BIN="$WORK_DIR/bin/sing-box-kinds"
skipped="$(lookup_cached other.example)"
printf '%s\n' "$skipped" | grep -Fq '"label": "Later"' || fail "an srs Xray did not apply must not block the next section: $skipped"
printf '%s\n' "$skipped" | grep -Fq '"status": "unknown"' && fail "an unapplied srs must not be reported as missing: $skipped"
unset FORKOP_SING_BOX_BIN

printf 'domain lookup checks passed\n'
