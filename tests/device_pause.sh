#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FORKOP_LIB="$ROOT_DIR/forkop/files/usr/lib"
PAUSE="$FORKOP_LIB/service/device_pause.uc"
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

pause() {
  FORKOP_DEVICE_PAUSE_FILE="$WORK_DIR/pauses.json" \
  FORKOP_DEVICE_PAUSE_NO_TIMER=1 \
  FORKOP_NFT_LOG="$NFT_LOG" \
  PATH="$WORK_DIR/bin:$PATH" \
    ucode -L "$FORKOP_LIB" "$PAUSE" "$@"
}

grep -Fq 'pause_device_add:' "$ROOT_DIR/forkop/files/usr/bin/forkop" ||
  fail "forkop command must expose pause_device_add"
grep -Fq 'Pause a device' \
  "$ROOT_DIR/luci-app-forkop/htdocs/luci-static/resources/view/forkop/dashboard.js" ||
  fail "dashboard must offer a device pause"
grep -Fq 'ui.Dropdown' \
  "$ROOT_DIR/luci-app-forkop/htdocs/luci-static/resources/view/forkop/dashboard.js" ||
  fail "pause must list connected devices"
for label in "5 minutes" "15 minutes" "30 minutes" "2 hours" "4 hours"; do
  grep -Fq "$label" \
    "$ROOT_DIR/luci-app-forkop/htdocs/luci-static/resources/view/forkop/dashboard.js" ||
    fail "pause durations must include $label"
done

added="$(pause add 192.168.1.20 60 Phone)"
printf '%s\n' "$added" | grep -Fq '"ok": true' || fail "pause should be stored: $added"
printf '%s\n' "$added" | grep -Fq '"ip": "192.168.1.20"' || fail "paused address missing: $added"
grep -Fq 'nft add element inet ForkopTable forkop_paused { 192.168.1.20 }' "$NFT_LOG" ||
  fail "pause should update nft immediately"

listed="$(pause list)"
printf '%s\n' "$listed" | grep -Fq '"label": "Phone"' || fail "pause label missing: $listed"

bad="$(pause add not-an-ip 60 '' || true)"
printf '%s\n' "$bad" | grep -Fq '"error": "bad-ip"' || fail "bad address should be rejected: $bad"

printf '%s\n' '{ "items": [ { "ip": "192.168.1.30", "until": 1, "label": "Old" } ] }' >"$WORK_DIR/pauses.json"
expired="$(pause list)"
printf '%s\n' "$expired" | grep -Fq '192.168.1.30' &&
  fail "expired pause should disappear: $expired"

pause add 2001:db8::20 0 '' >/dev/null
cleared="$(pause clear 2001:db8::20)"
printf '%s\n' "$cleared" | grep -Fq '2001:db8::20' &&
  fail "clear should remove the pause: $cleared"
grep -Fq 'nft delete element inet ForkopTable forkop_paused6 { 2001:db8::20 }' "$NFT_LOG" ||
  fail "clear should remove the nft element"

printf 'device pause checks passed\n'
