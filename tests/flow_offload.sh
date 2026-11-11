#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/forkop/files/usr/lib/nft/flow_offload.uc"
INITD="$ROOT_DIR/forkop/files/usr/lib/service/initd.uc"
LIFECYCLE="$ROOT_DIR/forkop/files/usr/lib/service/lifecycle.uc"
WORK_DIR="$(mktemp -d)"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  cat "$WORK_DIR/nft.log" >&2 2>/dev/null || true
  exit 1
}

cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT

mkdir -p "$WORK_DIR/bin"
cat >"$WORK_DIR/bin/nft" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "${NFT_LOG:?}"
if [ "$1" = "list" ]; then
  exit 0
fi
if [ "$1" = "-a" ]; then
  cat <<'CHAIN'
table inet fw4 {
	chain forward {
		type filter hook forward priority filter; policy drop;
		meta l4proto { tcp, udp } flow add @ft # handle 45
		ct mark 0 meta l4proto { tcp, udp } flow add @other # handle 46
	}
}
CHAIN
  exit 0
fi
exit 0
EOF
chmod 0755 "$WORK_DIR/bin/nft"

: >"$WORK_DIR/nft.log"
PATH="$WORK_DIR/bin:$PATH" NFT_LOG="$WORK_DIR/nft.log" FORKOP_NFT_BIN="$WORK_DIR/bin/nft" \
  ucode "$SCRIPT" || fail "flow offload patch should succeed"
grep -Fq 'replace rule inet fw4 forward handle 45 ct mark 0 meta l4proto { tcp, udp } flow add @ft' "$WORK_DIR/nft.log" ||
  fail "unprotected flow add must be limited to unmarked connections"
if grep -Fq 'handle 46' "$WORK_DIR/nft.log"; then
  fail "an already guarded flow rule must be left alone"
fi

grep -Fq 'patch_flow_offload' "$INITD" || fail "firewall reload must reapply the flow guard"
grep -Fq 'flow_offload.uc' "$LIFECYCLE" || fail "nft rebuild must reapply the flow guard"

printf 'flow offload checks passed\n'
