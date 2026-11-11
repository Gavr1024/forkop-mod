#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SECTION_JS="$ROOT_DIR/luci-app-forkop/htdocs/luci-static/resources/view/forkop/section.js"
FORKOP_JS="$ROOT_DIR/luci-app-forkop/htdocs/luci-static/resources/view/forkop/forkop.js"
PO_SRC="$ROOT_DIR/fe-app-forkop/locales/forkop.ru.po"
PO_PKG="$ROOT_DIR/luci-app-forkop/po/ru/forkop.po"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

grep -Fq 'function cloneRoutingSection' "$SECTION_JS" || fail "section copy helper missing"
grep -Fq 'cloneRoutingSection' "$FORKOP_JS" || fail "section table must call the copy helper"
grep -Fq 'const copyLabel = "Копировать"' "$FORKOP_JS" || fail "section row must show a copy button"
grep -Fq 'msgid "Copy section"' "$PO_SRC" || fail "Copy section is not translated"
grep -Fq 'msgstr "Копировать"' "$PO_SRC" || fail "Copy section Russian text missing"
grep -Fq 'msgid "Copy of %s"' "$PO_PKG" || fail "copy label is not translated"
cmp -s "$PO_SRC" "$PO_PKG" || fail "Russian catalogs drifted after section copy strings"

node - "$SECTION_JS" <<'NODE'
const fs = require("fs");
const assert = require("assert");
const source = fs.readFileSync(process.argv[2], "utf8");
const start = source.indexOf("const SECTION_COPY_CHILD_TYPES");
const end = source.indexOf("function configureSectionSection");
assert(start > 0 && end > start, "copy helpers not found");
const UCI_PACKAGE = "forkop";
const db = {
  section: {
    home: {
      ".name": "home",
      ".type": "section",
      label: "Home",
      enabled: "1",
      community_lists: ["russia_inside"],
      selector_proxy_links: ["vless://a"],
    },
  },
  subscription_url: {
    sub1: { ".name": "sub1", ".type": "subscription_url", section: "home", url: "https://example/sub" },
  },
  priority_group: {
    grp1: { ".name": "grp1", ".type": "priority_group", section: "home", name: "Fast" },
  },
  priority_level: {
    lvl1: { ".name": "lvl1", ".type": "priority_level", group: "grp1", order: "1" },
  },
  warp: {},
  masque: {},
  urltest: {},
  openconnect: {},
  openvpn: {},
  section_interface: {},
  server: {},
  settings: {},
};
function bucket(typeName) {
  if (!db[typeName]) db[typeName] = {};
  return db[typeName];
}
function findRecord(id) {
  for (const typeName of Object.keys(db)) {
    if (db[typeName][id]) return db[typeName][id];
  }
  return null;
}
const uci = {
  sections(_pkg, typeName) {
    return Object.keys(bucket(typeName)).map((id) => bucket(typeName)[id]);
  },
  get(_pkg, id, key) {
    const record = findRecord(id);
    if (!record) return null;
    return key ? record[key] : record;
  },
  add(_pkg, typeName, id) {
    bucket(typeName)[id] = { ".name": id, ".type": typeName };
    return id;
  },
  set(_pkg, id, key, value) {
    const record = findRecord(id);
    assert(record, `missing ${id}`);
    record[key] = value;
  },
};
function getChildItemIds(sectionId, typeName, ownerOption) {
  const ownerKey = ownerOption || "section";
  return uci.sections(UCI_PACKAGE, typeName)
    .filter((item) => item[ownerKey] === sectionId)
    .map((item) => item[".name"]);
}
function _(value) {
  const text = new String(value);
  text.format = function format(arg) {
    return `${this}`.replace("%s", arg);
  };
  return text;
}
eval(source.slice(start, end));
const copied = cloneRoutingSection("home");
assert.strictEqual(copied, "home_copy");
assert.strictEqual(uci.get(UCI_PACKAGE, "home_copy", "label"), "Copy of Home");
assert.deepStrictEqual(uci.get(UCI_PACKAGE, "home_copy", "community_lists"), ["russia_inside"]);
assert.deepStrictEqual(uci.get(UCI_PACKAGE, "home", "community_lists"), ["russia_inside"]);
uci.get(UCI_PACKAGE, "home_copy", "community_lists").push("extra");
assert.deepStrictEqual(uci.get(UCI_PACKAGE, "home", "community_lists"), ["russia_inside"]);
assert.strictEqual(uci.get(UCI_PACKAGE, "sub1_copy", "section"), "home_copy");
assert.strictEqual(uci.get(UCI_PACKAGE, "sub1_copy", "url"), "https://example/sub");
assert.strictEqual(uci.get(UCI_PACKAGE, "sub1", "section"), "home");
assert.strictEqual(uci.get(UCI_PACKAGE, "grp1_copy", "section"), "home_copy");
assert.strictEqual(uci.get(UCI_PACKAGE, "lvl1_copy", "group"), "grp1_copy");
assert.strictEqual(uci.get(UCI_PACKAGE, "lvl1", "group"), "grp1");
assert.strictEqual(uci.get(UCI_PACKAGE, "home_copy", "selector_proxy_links")[0], "vless://a");
const second = cloneRoutingSection("home");
assert.strictEqual(second, "home_copy2");
assert.strictEqual(uci.get(UCI_PACKAGE, "home_copy2", "label"), "Copy of Home 2");
assert.strictEqual(cloneRoutingSection("missing"), "");
console.log("section copy checks passed");
NODE
