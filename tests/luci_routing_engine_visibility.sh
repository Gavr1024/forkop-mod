#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SECTION_JS="$ROOT_DIR/luci-app-forkop/htdocs/luci-static/resources/view/forkop/section.js"
SETTINGS_JS="$ROOT_DIR/luci-app-forkop/htdocs/luci-static/resources/view/forkop/settings.js"
FORKOP_JS="$ROOT_DIR/luci-app-forkop/htdocs/luci-static/resources/view/forkop/forkop.js"

node --input-type=module - "$SECTION_JS" "$SETTINGS_JS" "$FORKOP_JS" <<'EOF'
import { readFileSync, writeFileSync, unlinkSync } from "fs";
import { spawnSync } from "child_process";

const [sectionPath, settingsPath, forkopPath] = process.argv.slice(2);

for (const file of [sectionPath, settingsPath, forkopPath]) {
  const src = readFileSync(file, "utf8");
  const wrapped = "async function __forkopSyntaxCheck() {\n" + src + "\n}\n";
  const tmp = file + ".syntax-check.mjs";
  writeFileSync(tmp, wrapped);
  const check = spawnSync(process.execPath, ["--check", tmp], { encoding: "utf8" });
  unlinkSync(tmp);
  if (check.status !== 0) {
    console.error(check.stderr || check.stdout);
    throw new Error("syntax check failed for " + file);
  }
}

function extract(src, name) {
  const token = "function " + name;
  const start = src.indexOf(token);
  if (start < 0) {
    throw new Error("missing function " + name);
  }
  const brace = src.indexOf("{", src.indexOf(")", start));
  let depth = 0;
  for (let i = brace; i < src.length; i++) {
    if (src[i] === "{") depth++;
    else if (src[i] === "}") {
      depth--;
      if (depth === 0) return src.slice(start, i + 1);
    }
  }
  throw new Error("unclosed function " + name);
}

const section = readFileSync(sectionPath, "utf8");
const settings = readFileSync(settingsPath, "utf8");
const forkop = readFileSync(forkopPath, "utf8");
const urltest = extract(section, "addUrlTestItemOptions");

for (const key of ["name", "check_interval", "testing_url", "pin_dashboard"]) {
  const shared = new RegExp(
    'itemSection\\.option\\(\\s*form\\.\\w+,\\s*"' + key + '"',
  );
  const hidden = new RegExp(
    'restrictSectionEngine\\(\\s*itemSection\\.option\\(\\s*form\\.\\w+,\\s*"' + key + '"',
  );
  if (!shared.test(urltest) || hidden.test(urltest)) {
    throw new Error("URLTest " + key + " must stay visible on both cores");
  }
}

for (const key of [
  "tolerance",
  "idle_timeout",
  "interrupt_exist_connections",
  "filter_mode",
  "detect_server_country",
]) {
  const hidden = new RegExp(
    'restrictSectionEngine\\(\\s*itemSection\\.option\\([\\s\\S]{0,180}"' + key + '"',
  );
  if (!hidden.test(urltest)) {
    throw new Error("URLTest " + key + " must be hidden on Xray");
  }
}

for (const key of [
  "include_urltest_groups",
  "hide_urltest_group_outbounds",
  "hide_detour_outbounds",
  "domain_resolver_enabled",
  "domain_resolver_dns_type",
  "domain_resolver_dns_server",
  "priority_group",
  "mixed_proxy_enabled",
  "mixed_proxy_port",
  "mixed_proxy_auth_enabled",
  "mixed_proxy_username",
  "mixed_proxy_password",
  "resolve_real_ip_for_routing",
]) {
  const hidden = new RegExp(
    'restrictSectionEngine\\([\\s\\S]{0,260}"' + key + '"[\\s\\S]{0,260}"sing-box"',
  );
  if (!hidden.test(section)) {
    throw new Error(key + " must be sing-box only");
  }
}

for (const key of ["xray_finalmask", "xray_finalmask_length", "xray_finalmask_interval"]) {
  const hidden = new RegExp(
    'restrictSectionEngine\\([\\s\\S]{0,320}"' + key + '"[\\s\\S]{0,240}"xray"',
  );
  if (!hidden.test(section)) {
    throw new Error(key + " must be Xray only");
  }
}

for (const name of [
  "addPriorityLevelItemOptions",
  "addPriorityGroupItemOptions",
]) {
  if (!extract(section, name).includes('bindSectionEngine(itemSection, "sing-box"')) {
    throw new Error(name + " must hide every field on Xray");
  }
}

if (!extract(section, "addDashboardServerFilterOptions").includes(
  'return restrictSectionEngine(option, "sing-box")',
)) {
  throw new Error("dashboard filters must be sing-box only");
}

if (!extract(section, "addProxyParameterFilterOptions").includes(
  'restrictSectionEngine(',
)) {
  throw new Error("proxy parameter filters must follow the section core");
}

for (const key of ["proxy_core", "dns_type", "dns_server"]) {
  const hidden = new RegExp(
    'restrictSectionEngine\\([\\s\\S]{0,180}"' + key + '"',
  );
  if (hidden.test(section)) {
    throw new Error(key + " must stay visible on both cores");
  }
}

for (const [key, engine] of [
  ["xray_freedom_fragment", "xray"],
  ["dns_check_interval", "sing-box"],
  ["dns_recovery_check_interval", "sing-box"],
  ["dns_check_timeout", "sing-box"],
  ["dns_rewrite_ttl", "sing-box"],
  ["enable_yacd", "sing-box"],
  ["config_path", "sing-box"],
  ["cache_path", "sing-box"],
]) {
  const at = settings.indexOf('"' + key + '"');
  if (at < 0) throw new Error("missing settings option " + key);
  const window = settings.slice(at, at + 2500);
  if (!window.includes('restrictRoutingEngine(o, "' + engine + '")')) {
    throw new Error(key + " must be restricted to " + engine);
  }
}

for (const key of ["disable_quic", "log_level", "exclude_bittorrent", "dns_strategy"]) {
  const at = settings.indexOf('"' + key + '"');
  if (at < 0) throw new Error("missing settings option " + key);
  const window = settings.slice(at, at + 700);
  if (window.includes("restrictRoutingEngine(")) {
    throw new Error(key + " must stay visible on both cores");
  }
}

if (!forkop.includes("function syncRoutingEngineTabs()") ||
    forkop.includes('li[data-tab="server"]') ||
    !forkop.includes("forkopMap.checkDepends") ||
    !forkop.includes("forkopMap.render")) {
  throw new Error("Servers tab must stay available on Xray and still refresh engine-dependent options");
}

const throughBind = section.slice(
  section.indexOf("const PROXY_CORE_ACTIONS"),
  section.indexOf("function addProxyParameterFilterOptions"),
);
const uciStore = {};
let currentEngine = "sing-box";
const widgets = {};
const uci = {
  get(_pkg, sectionId, key) {
    const row = uciStore[sectionId];
    return row ? row[key] : undefined;
  },
};
const settingsApi = {
  isXrayRoutingEngine(value) {
    const engine = `${value || ""}`.trim().toLowerCase();
    return engine === "xray" || engine === "xray-core";
  },
  currentRoutingEngine() {
    return currentEngine;
  },
  liveFormValue() {
    return null;
  },
};
const document = {
  getElementById(id) {
    return widgets[id] || null;
  },
};
const fn = new Function(
  "uci",
  "settings",
  "document",
  "UCI_PACKAGE",
  throughBind + "\nreturn { restrictSectionEngine };",
);
const api = fn(uci, settingsApi, document, "forkop");

function dropdown(value) {
  return {
    classList: { contains: (name) => name === "cbi-dropdown" },
    querySelectorAll: () => [{ value }],
    querySelector: () => null,
    value: null,
  };
}

function optionFor(engine, parent) {
  return api.restrictSectionEngine({ checkDepends: () => true }, engine, parent);
}

uciStore.cfg = { ".type": "section", action: "connection", proxy_core: "" };
currentEngine = "xray";
if (optionFor("sing-box").checkDepends("cfg") !== false) {
  throw new Error("empty proxy core must follow the Xray primary");
}
if (optionFor("xray").checkDepends("cfg") !== true) {
  throw new Error("Xray options must stay visible when the primary is Xray");
}

uciStore.cfg.proxy_core = "sing-box";
currentEngine = "xray";
if (optionFor("sing-box").checkDepends("cfg") !== true) {
  throw new Error("a sing-box sidecar section must keep sing-box options");
}
if (optionFor("xray").checkDepends("cfg") !== false) {
  throw new Error("a sing-box sidecar section must hide Xray options");
}

uciStore.cfg = { ".type": "section", action: "byedpi", proxy_core: "xray" };
currentEngine = "sing-box";
if (optionFor("sing-box").checkDepends("cfg") !== true) {
  throw new Error("byedpi must follow the primary core, not a stale proxy_core");
}

widgets["cbid.forkop.cfg.action"] = dropdown("connection");
widgets["cbid.forkop.cfg.proxy_core"] = dropdown("");
uciStore.cfg = { ".type": "section", action: "connection", proxy_core: "xray" };
currentEngine = "sing-box";
if (optionFor("xray").checkDepends("cfg") !== false) {
  throw new Error("a cleared proxy core widget must not keep the stale UCI core");
}

const nested = api.restrictSectionEngine(
  { checkDepends: () => false },
  "sing-box",
  () => "cfg",
);
widgets["cbid.forkop.cfg.proxy_core"] = dropdown("sing-box");
if (nested.checkDepends("settings") !== false) {
  throw new Error("engine visibility must still honor the field's own dependencies");
}
if (nested.retain !== true) {
  throw new Error("hidden engine options must keep their saved values");
}

delete widgets["cbid.forkop.cfg.action"];
delete widgets["cbid.forkop.cfg.proxy_core"];
uciStore.level = { ".type": "priority_level", group: "grp" };
uciStore.grp = { ".type": "priority_group", section: "cfg" };
uciStore.cfg = { ".type": "section", action: "connection", proxy_core: "xray" };
if (optionFor("xray").checkDepends("level") !== true) {
  throw new Error("nested priority fields must follow the parent section core");
}

console.log("routing engine visibility checks passed");
EOF
