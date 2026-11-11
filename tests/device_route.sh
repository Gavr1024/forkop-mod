#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FORKOP_LIB="$ROOT_DIR/forkop/files/usr/lib"
ROUTE="$FORKOP_LIB/service/device_route.uc"
WORK_DIR="$(mktemp -d)"
NFT_LOG="$WORK_DIR/nft.log"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

mkdir -p "$WORK_DIR/bin"
cat >"$WORK_DIR/bin/nft" <<'NFT'
#!/usr/bin/env bash
{
  printf 'nft'
  for arg in "$@"; do
    printf ' %s' "$arg"
  done
  printf '\n'
} >>"$FORKOP_NFT_LOG"
exit 0
NFT
chmod 0755 "$WORK_DIR/bin/nft"

cat >"$WORK_DIR/state" <<EOF
forkop.home=section
forkop.home.enabled=1
forkop.home.action=connection
forkop.home.label=Home
forkop.dns=section
forkop.dns.enabled=1
forkop.dns.action=dns
forkop.dns.label=DNS
forkop.off=section
forkop.off.enabled=0
forkop.off.action=bypass
forkop.off.label=Off
forkop.direct=section
forkop.direct.enabled=1
forkop.direct.action=bypass
forkop.direct.label=Direct
forkop.capped=section
forkop.capped.enabled=1
forkop.capped.action=byedpi
forkop.capped.label=Capped
forkop.capped.speed_limit_down_mbit=3
forkop.capped.speed_limit_up_mbit=1
EOF

cat >"$WORK_DIR/singbox.json" <<'EOF'
{
  "inbounds": [{ "type": "tproxy", "tag": "tproxy-in" }],
  "outbounds": [
    { "type": "direct", "tag": "home-out" },
    { "type": "direct", "tag": "higher-out" }
  ],
  "route": {
    "rules": [
      { "action": "route", "domain": ["youtube.com"], "outbound": "higher-out" }
    ]
  }
}
EOF

route() {
  FORKOP_UCI_STATE_FILE="$WORK_DIR/state" \
  FORKOP_DEVICE_ROUTE_FILE="$WORK_DIR/routes.json" \
  FORKOP_DEVICE_ROUTE_JUMP="$WORK_DIR/jump" \
  FORKOP_DEVICE_PAUSE_FILE="$WORK_DIR/pauses.json" \
  FORKOP_DEVICE_ROUTE_NO_TIMER=1 \
  FORKOP_DEVICE_ROUTE_NO_RELOAD=1 \
  FORKOP_DEVICE_ROUTE_PIN=17022 \
  FORKOP_SINGBOX_CONFIG="$WORK_DIR/singbox.json" \
  FORKOP_XRAY_CONFIG="$WORK_DIR/missing-xray.json" \
  FORKOP_NFT_LOG="$NFT_LOG" \
  PATH="$WORK_DIR/bin:$PATH" \
    ucode -L "$FORKOP_LIB" "$ROUTE" "$@"
}

grep -Fq 'route_device_add:' "$ROOT_DIR/forkop/files/usr/bin/forkop" ||
  fail "forkop command must expose route_device_add"
grep -Fq 'Temporary full routing' \
  "$ROOT_DIR/luci-app-forkop/htdocs/luci-static/resources/view/forkop/dashboard.js" ||
  fail "dashboard must offer temporary full routing"

added="$(route add 192.168.1.20 60 home Phone)"
printf '%s\n' "$added" | grep -Fq '"ok": true' || fail "route should be stored: $added"
printf '%s\n' "$added" | grep -Fq '"section": "home"' || fail "section missing: $added"
printf '%s\n' "$added" | grep -Fq '"section_label": "Home"' || fail "section name missing: $added"
grep -Fq 'nft insert rule inet ForkopTable priority_rules jump forkop_temp' "$NFT_LOG" ||
  fail "temporary route should jump ahead of the other rules"
printf '%s\n' "$added" | grep -Fq '"applied": true' || fail "route should switch the tunnel: $added"
grep -Fq 'nft insert rule inet ForkopTable proxy jump forkop_temp_proxy' "$NFT_LOG" ||
  fail "temporary route must run before section pins"
grep -Fq 'nft add rule inet ForkopTable forkop_temp_proxy ip saddr 192.168.1.20 ip daddr != @localv4 meta l4proto tcp tproxy ip to :17022 counter accept' "$NFT_LOG" ||
  fail "device must be sent to the section pin"
grep -Fq 'nft add rule inet ForkopTable forkop_temp ip saddr 192.168.1.20 ip daddr != @localv4 meta l4proto tcp meta mark set 0x04000000 counter accept' "$NFT_LOG" ||
  fail "temporary route should mark the device immediately"
grep -Fq 'forkop_lim_' "$NFT_LOG" &&
  fail "a section without a limit must not shape the temporary route"
grep -Fq 'fully_routed' "$WORK_DIR/state" && fail "temporary route must not change saved settings"

: >"$NFT_LOG"
capped="$(route add 192.168.1.50 60 capped Phone)"
printf '%s\n' "$capped" | grep -Fq '"applied": true' || fail "limited section should still switch: $capped"
grep -Fq 'nft add rule inet ForkopTable forkop_temp ip saddr 192.168.1.50 ip daddr != @localv4 meta l4proto tcp ct mark set 1264 jump forkop_lim_capped_up' "$NFT_LOG" ||
  fail "temporary route should enter the section upload limit"
grep -Fq 'nft add rule inet ForkopTable forkop_temp ip saddr 192.168.1.50 ip daddr != @localv4 meta l4proto tcp meta mark set 0x04000000 counter accept' "$NFT_LOG" ||
  fail "temporary route should still mark the limited device"

bad="$(route add 192.168.1.20 60 dns Phone || true)"
printf '%s\n' "$bad" | grep -Fq '"error": "bad-section"' || fail "a DNS section must be rejected: $bad"

off="$(route add 192.168.1.21 15 off Phone || true)"
printf '%s\n' "$off" | grep -Fq '"error": "bad-section"' || fail "a disabled section must be rejected: $off"

printf '%s\n' '{ "items": [ { "ip": "192.168.1.30", "until": 1, "label": "Old", "section": "home", "section_label": "Home", "action": "connection" } ] }' >"$WORK_DIR/routes.json"
expired="$(route list)"
printf '%s\n' "$expired" | grep -Fq '192.168.1.30' &&
  fail "expired route should disappear: $expired"

route add 192.168.1.20 0 home '' >/dev/null
cleared="$(route clear 192.168.1.20)"
printf '%s\n' "$cleared" | grep -Fq '192.168.1.20' &&
  fail "clear should remove the route: $cleared"
grep -Fq 'nft flush chain inet ForkopTable forkop_temp' "$NFT_LOG" ||
  fail "clear should refresh the temporary rules"

bypass="$(route add 192.168.1.40 60 direct Phone)"
printf '%s\n' "$bypass" | grep -Fq '"applied": true' || fail "bypass should be applied: $bypass"
grep -Fq 'nft insert rule inet ForkopTable mangle jump forkop_temp_early' "$NFT_LOG" ||
  fail "bypass must run before the mark and QUIC rules"
grep -Fq 'nft add rule inet ForkopTable forkop_temp_early ip saddr 192.168.1.40 counter accept' "$NFT_LOG" ||
  fail "bypass should leave the tunnel in mangle"
grep -Fq 'nft add rule inet ForkopTable forkop_temp_proxy ip saddr 192.168.1.40 counter accept' "$NFT_LOG" ||
  fail "bypass should leave the tunnel before section pins"
grep -Fq 'nft add rule inet ForkopTable forkop_temp_proxy ip saddr 192.168.1.40 ip daddr' "$NFT_LOG" &&
  fail "bypass must not be sent to a section port"

cat >"$WORK_DIR/door-state" <<'EOF'
forkop.home=section
forkop.home.enabled=1
forkop.home.action=connection
forkop.home.label=Home
forkop.home.proxy_core=sing-box
forkop.settings=settings
forkop.settings.routing_engine=xray
EOF

cat >"$WORK_DIR/xray.json" <<'EOF'
{
  "inbounds": [{ "tag": "tproxy-in", "port": 1602 }],
  "outbounds": [
    { "tag": "sb-full-home" },
    { "tag": "higher-out" }
  ],
  "routing": {
    "rules": [
      { "type": "field", "domain": ["youtube.com"], "outboundTag": "higher-out" }
    ]
  }
}
EOF

door="$(
  FORKOP_UCI_STATE_FILE="$WORK_DIR/door-state" \
  FORKOP_DEVICE_ROUTE_FILE="$WORK_DIR/door-routes.json" \
  FORKOP_DEVICE_ROUTE_JUMP="$WORK_DIR/door-jump" \
  FORKOP_DEVICE_PAUSE_FILE="$WORK_DIR/door-pauses.json" \
  FORKOP_DEVICE_ROUTE_NO_TIMER=1 \
  FORKOP_DEVICE_ROUTE_NO_RELOAD=1 \
  FORKOP_XRAY_CONFIG="$WORK_DIR/xray.json" \
  FORKOP_NFT_LOG="$WORK_DIR/door-nft.log" \
  PATH="$WORK_DIR/bin:$PATH" \
    ucode -L "$FORKOP_LIB" "$ROUTE" add 192.168.1.20 60 home Phone
)"
printf '%s\n' "$door" | grep -Fq '"applied": true' || fail "a section without a pin should still switch: $door"
python3 - "$WORK_DIR/xray.json" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1]))
rules = cfg["routing"]["rules"]
first = json.dumps(rules[0], ensure_ascii=False)
if "192.168.1.20/32" not in first or "sb-full-home" not in first:
    raise SystemExit("device rule is not first: " + first)
if rules[1].get("outboundTag") != "higher-out":
    raise SystemExit("higher section must stay below the device")
PY
grep -Fq 'nft add rule inet ForkopTable forkop_temp_proxy ip saddr 192.168.1.20 ip daddr != @localv4 meta l4proto tcp tproxy ip to :1602 counter accept' "$WORK_DIR/door-nft.log" ||
  fail "a section without a pin must still be taken before other sections"
grep -Fq 'tproxy ip to :17022' "$WORK_DIR/door-nft.log" &&
  fail "a section without a pin must not use another section port"

cleared_door="$(
  FORKOP_UCI_STATE_FILE="$WORK_DIR/door-state" \
  FORKOP_DEVICE_ROUTE_FILE="$WORK_DIR/door-routes.json" \
  FORKOP_DEVICE_ROUTE_JUMP="$WORK_DIR/door-jump" \
  FORKOP_DEVICE_PAUSE_FILE="$WORK_DIR/door-pauses.json" \
  FORKOP_DEVICE_ROUTE_NO_TIMER=1 \
  FORKOP_DEVICE_ROUTE_NO_RELOAD=1 \
  FORKOP_XRAY_CONFIG="$WORK_DIR/xray.json" \
  FORKOP_NFT_LOG="$WORK_DIR/door-nft.log" \
  PATH="$WORK_DIR/bin:$PATH" \
    ucode -L "$FORKOP_LIB" "$ROUTE" clear 192.168.1.20
)"
printf '%s\n' "$cleared_door" | grep -Fq '"applied": true' || fail "clearing the door should succeed: $cleared_door"
grep -Fq '192.168.1.20/32' "$WORK_DIR/xray.json" &&
  fail "clear should remove the Xray rule"

printf 'device route checks passed\n'
