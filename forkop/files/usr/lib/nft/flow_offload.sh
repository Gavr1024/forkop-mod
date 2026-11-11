#!/bin/sh
# Ordinary traffic may stay in firewall flow offload.
# Connections Forkop marked for a section speed limit must not: offload
# skips mangle, so the limit would only see the first packets.
# ct mark 0 is the default, so this does not change unmarked flows.

set -f

NFT="${FORKOP_NFT_BIN:-nft}"
WAIT="${1:-}"

if ! command -v "$NFT" >/dev/null 2>&1; then
	exit 0
fi

tries=1
if [ "$WAIT" = "wait" ]; then
	tries=8
fi

i=0
while [ "$i" -lt "$tries" ]; do
	if "$NFT" list chain inet fw4 forward >/dev/null 2>&1; then
		break
	fi
	i=$((i + 1))
	[ "$i" -lt "$tries" ] || exit 0
	sleep 1
done

"$NFT" -a list chain inet fw4 forward 2>/dev/null | while IFS= read -r line; do
	case "$line" in
	*"flow add @"*|*"flow offload @"*) ;;
	*) continue ;;
	esac
	case "$line" in
	*"ct mark 0"*) continue ;;
	esac
	handle=$(printf '%s\n' "$line" | sed -n 's/.*# handle \([0-9][0-9]*\).*/\1/p')
	[ -n "$handle" ] || continue
	setname=$(printf '%s\n' "$line" | sed -n 's/.*flow \(add\|offload\) @\([A-Za-z0-9_]*\).*/\2/p')
	[ -n "$setname" ] || setname=ft
	"$NFT" replace rule inet fw4 forward handle "$handle" \
		ct mark 0 meta l4proto { tcp, udp } flow add @"$setname" || true
done

exit 0
