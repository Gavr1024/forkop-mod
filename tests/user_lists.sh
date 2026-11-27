#!/bin/sh
set -eu
ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
LIB="$ROOT/forkop/files/usr/lib"
SECTION="$ROOT/luci-app-forkop/htdocs/luci-static/resources/view/forkop/section.js"
DASH="$ROOT/luci-app-forkop/htdocs/luci-static/resources/view/forkop/dashboard.js"
fail() { echo "user lists: $*" >&2; exit 1; }
grep -Fxq '/etc/forkop/' "$ROOT/forkop/files/lib/upgrade/keep.d/forkop" || fail "backup must keep the whole forkop folder"
grep -Fq 'lib/upgrade/keep.d/forkop' "$ROOT/forkop/Makefile" || fail "package must install the backup keep file"
grep -Fq 'return choices || {}' "$SECTION" || fail "empty user lists must stay an empty menu"
grep -Fq 'user_list_save' "$DASH" || fail "dashboard must create lists"
grep -Fq 'data-list-edit' "$DASH" || fail "dashboard must edit custom lists"
grep -Fq 'Lists you created on the information panel' "$SECTION" || fail "section must offer created lists"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
printf '%s\n' 'forkop.secA=section' 'forkop.secA.domain_ip_lists=https://example.test/list.lst' > "$WORKDIR/uci"
FORKOP_USER_LIST_DIR="$WORKDIR/lists" \
FORKOP_UCI_STATE_FILE="$WORKDIR/uci" \
FORKOP_LIB="$LIB" \
ucode -L "$LIB" -e '
let lists = require("routing.user_lists");
let fs = require("fs");
let saved = lists.save("", "News", "example.com\n# skip\n1.2.3.0/24\nexample.com\n");
if (saved.ok != true) {
  warn("save failed\n");
  exit(1);
}
fs.writefile(saved.path + ".rev", "3\n");
let kept = lists.save(saved.id, "News", "example.com\n1.2.3.0/24\n");
if (kept.ok != true || fs.stat(saved.path + ".rev") != null) {
  warn("rev file created\n");
  exit(1);
}
let again = lists.read(saved.id);
if (again.ok != true || index(again.text, "example.com") < 0 || index(again.text, "1.2.3.0/24") < 0) {
  warn("read failed\n");
  exit(1);
}
if (index(again.text, "skip") >= 0) {
  warn("comment kept\n");
  exit(1);
}
let bad = lists.save(saved.id, "News", "two words");
if (bad.error != "bad-line") {
  warn("bad line accepted\n");
  exit(1);
}
let replaced = lists.replace_reference("https://example.test/list.lst", "https://example.test/new.lst");
if (replaced.ok != true) {
  warn("replace failed\n");
  exit(1);
}
let removed = lists.remove(saved.id);
if (removed.ok != true) {
  warn("delete failed\n");
  exit(1);
}
' || fail "ucode user lists"
grep -Fq 'setsid " + shell_quote(SERVICE_INIT) + " reload' "$ROOT/forkop/files/usr/lib/components/updates.uc" || fail "list save must not wait for reload"
grep -Fq 'https://example.test/new.lst' "$WORKDIR/uci" || fail "section address was not updated"
echo "user lists checks passed"
