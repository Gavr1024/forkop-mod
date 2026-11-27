#!/bin/sh
set -eu
ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
HOOK="$ROOT/forkop/files/lib/upgrade/zz-forkop.sh"
MAKEFILE="$ROOT/forkop/Makefile"
fail() { echo "backup keep: $*" >&2; exit 1; }
grep -Fq 'zz-forkop.sh' "$MAKEFILE" || fail "package must install the backup hook"
grep -Fq '/etc/forkop/' "$MAKEFILE" || fail "package install must record the forkop folder"
grep -Fq 'sysupgrade.conf' "$MAKEFILE" && fail "package must not edit the user's backup list"
grep -Fq 'sysupgrade.conf' "$ROOT/forkop/files/etc/init.d/forkop" && fail "service start must not edit the user's backup list"
[ -f "$HOOK" ] || fail "backup hook is missing"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
mkdir -p "$WORKDIR/data/nested"
printf '%s\n' one > "$WORKDIR/data/mwen.lst"
printf '%s\n' two > "$WORKDIR/data/nested/extra.lst"
printf '%s\n' '/etc/config/forkop' > "$WORKDIR/list"
add_conffiles() {
    cat "$WORKDIR/list" > "$1"
}
run_hooks() {
    local arg="$1"
    shift
    for func in "$@"; do
        "$func" "$arg"
    done
}
sysupgrade_init_conffiles="add_conffiles"
export FORKOP_BACKUP_DIR="$WORKDIR/data"
# shellcheck disable=SC1090
. "$HOOK"
out="$WORKDIR/saved"
run_hooks "$out" $sysupgrade_init_conffiles
grep -qxF '/etc/config/forkop' "$out" || fail "ordinary config was dropped"
grep -qxF "$WORKDIR/data/mwen.lst" "$out" || fail "own list was not added"
grep -qxF "$WORKDIR/data/nested/extra.lst" "$out" || fail "nested file was not added"
echo "backup keep checks passed"
