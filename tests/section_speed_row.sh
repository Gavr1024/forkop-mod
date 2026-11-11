#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VIEW="$ROOT_DIR/luci-app-forkop/htdocs/luci-static/resources/view/forkop/forkop.js"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

VIEW="$VIEW" node <<'JS'
const fs = require("fs");
const src = fs.readFileSync(process.env.VIEW, "utf8");
const start = src.indexOf("function speedLimitNumber");
const end = src.indexOf("function renderSectionAdd");
if (start < 0 || end < start) {
  console.error("speed row helpers missing");
  process.exit(1);
}
const store = {};
const uci = {
  get(_pkg, id, key) {
    const row = store[id] || {};
    return row[key];
  },
};
const UCI_PACKAGE = "forkop";
function _(text) {
  return text;
}
String.prototype.format = function format() {
  const args = arguments;
  let index = 0;
  return this.replace(/%s/g, () => args[index++]);
};
eval(src.slice(start, end));

function check(id, values, expected) {
  store[id] = values;
  const actual = sectionSpeedText(id);
  if (actual !== expected) {
    console.error(`${id}: expected '${expected}', got '${actual}'`);
    process.exit(1);
  }
}

check("down", { action: "proxy", speed_limit_down_mbit: "20" }, "Limit: download 20 Mbit/s, upload no limit");
check("up", { action: "vpn", speed_limit_up_mbit: "5" }, "Limit: download no limit, upload 5 Mbit/s");
check(
  "both",
  { action: "zapret", speed_limit_down_mbit: "20", speed_limit_up_mbit: "5" },
  "Limit: download 20 Mbit/s, upload 5 Mbit/s",
);
check("legacy", { action: "connection", speed_limit_mbit: "10" }, "Limit: download 10 Mbit/s, upload 10 Mbit/s");
check(
  "legacy-kept",
  { action: "proxy", speed_limit_down_mbit: "20", speed_limit_mbit: "10" },
  "Limit: download 20 Mbit/s, upload no limit",
);
check("bypass", { action: "bypass", speed_limit_mbit: "10" }, "");
check("block", { action: "block", speed_limit_down_mbit: "20", speed_limit_up_mbit: "5" }, "");
check("none", { action: "proxy" }, "");
check("bad", { action: "proxy", speed_limit_down_mbit: "0" }, "");
JS

grep -Fq 'fkp-section-speed' "$VIEW" || fail "section row must show the speed line"
grep -Fq 'Limit: download %s, upload %s' "$VIEW" || fail "speed line must name both directions"
grep -Fq 'speed_limit_mbit' "$VIEW" || fail "old shared limit must still fill both directions"

printf 'section speed row checks passed\n'
