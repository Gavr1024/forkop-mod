#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FORKOP_LIB="$ROOT_DIR/forkop/files/usr/lib"
CACHE="$FORKOP_LIB/routing/list_cache.uc"
VIEW="$ROOT_DIR/luci-app-forkop/htdocs/luci-static/resources/view/forkop/forkop.js"
WORK_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

: >"$WORK_DIR/empty.list"
printf '%s\n' 'example.com' >"$WORK_DIR/ok.list"

cat >"$WORK_DIR/state" <<EOF
forkop.settings=settings
forkop.settings.persist_lists_locally=1
forkop.empty=section
forkop.empty.enabled=1
forkop.empty.local_domain_lists=$WORK_DIR/empty.list
forkop.gone=section
forkop.gone.enabled=0
forkop.gone.remote_domain_lists=https://example.com/missing-domains.lst
forkop.ok=section
forkop.ok.enabled=1
forkop.ok.local_domain_lists=$WORK_DIR/ok.list
EOF

OUT="$(
  FORKOP_UCI_STATE_FILE="$WORK_DIR/state" \
  FORKOP_LIST_CACHE_DIR="$WORK_DIR/cache" \
    ucode -L "$FORKOP_LIB" "$CACHE" section-warnings
)"
printf '%s\n' "$OUT" | grep -Fq '"section": "empty"' || fail "empty list file must be reported: $OUT"
printf '%s\n' "$OUT" | grep -Fq "$WORK_DIR/empty.list" || fail "empty file path missing: $OUT"
printf '%s\n' "$OUT" | grep -Fq '"section": "gone"' || fail "a disabled section must still report a missing list: $OUT"
printf '%s\n' "$OUT" | grep -Fq 'missing-domains.lst' || fail "missing download must be named: $OUT"
if printf '%s\n' "$OUT" | grep -Fq '"section": "ok"'; then
  fail "a readable list must stay quiet: $OUT"
fi

cat >"$WORK_DIR/state-off" <<EOF
forkop.settings=settings
forkop.settings.persist_lists_locally=0
forkop.gone=section
forkop.gone.remote_domain_lists=https://example.com/missing-domains.lst
forkop.empty=section
forkop.empty.local_domain_lists=$WORK_DIR/empty.list
EOF
OFF="$(
  FORKOP_UCI_STATE_FILE="$WORK_DIR/state-off" \
  FORKOP_LIST_CACHE_DIR="$WORK_DIR/cache" \
    ucode -L "$FORKOP_LIB" "$CACHE" section-warnings
)"
printf '%s\n' "$OFF" | grep -Fq 'missing-domains.lst' && fail "cache off is not a failed download: $OFF"
printf '%s\n' "$OFF" | grep -Fq '"section": "empty"' || fail "an empty local file is still empty when cache is off: $OFF"

grep -Fq 'data-fkp-list-warn' "$VIEW" || fail "section row must show the list warning"
grep -Fq 'List has not downloaded: %s' "$VIEW" || fail "section row must name a list that did not download"
grep -Fq 'List file is empty: %s' "$VIEW" || fail "section row must name an empty list file"
grep -Fq 'section_warnings' "$CACHE" || fail "list status must include per-section warnings"

printf 'section list warnings passed\n'
