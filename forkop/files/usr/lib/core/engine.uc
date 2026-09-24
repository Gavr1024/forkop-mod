#!/usr/bin/env ucode

let uci_core = require("core.uci");
let connections = require("config.connections");

function as_string(value) {
    return value == null ? "" : "" + value;
}

function trim(value) {
    return replace(as_string(value), /^[ \t\r\n]+|[ \t\r\n]+$/g, "");
}

function object_or_empty(value) {
    return type(value) == "object" ? value : {};
}

function option(section, key, fallback) {
    let value = object_or_empty(section)[key];
    if (value == null || value == "")
        return fallback;
    return as_string(value);
}

function settings_engine_raw() {
    if (!uci_core.available())
        return "";

    let path = (getenv("FORKOP_CONFIG_NAME") || "forkop") + ".settings.routing_engine";
    if (!uci_core.exists(path))
        return "";
    return trim(uci_core.get(path));
}

function normalize_engine(value) {
    value = lc(trim(as_string(value)));
    if (value == "xray" || value == "xray-core")
        return "xray";
    return "sing-box";
}

function routing_engine() {
    return normalize_engine(settings_engine_raw());
}

function is_xray_primary() {
    return routing_engine() == "xray";
}

function is_singbox_primary() {
    return !is_xray_primary();
}

function sidecar_engine() {
    return is_xray_primary() ? "sing-box" : "xray";
}

function plane_owns_tproxy() {
    return routing_engine();
}

function has_enabled_inbound_servers() {
    if (!uci_core.available())
        return false;
    for (let section in uci_core.section_objects("forkop", "server")) {
        section = object_or_empty(section);
        let enabled = section.enabled == null ? "0" : as_string(section.enabled);
        if (enabled != "0" && enabled != "")
            return true;
    }
    return false;
}

function need_singbox_sidecar() {
    if (!is_xray_primary())
        return false;
    if (!uci_core.available())
        return false;
    for (let section in uci_core.section_objects("forkop", "section")) {
        section = object_or_empty(section);
        let enabled = section.enabled == null ? "1" : as_string(section.enabled);
        if (enabled == "0")
            continue;
        if (!connections.is_connections_action(option(section, "action", "")))
            continue;
        if (connections.proxy_core(section) != "xray")
            return true;
    }
    return false;
}

function need_xray_sidecar() {
    if (!is_singbox_primary())
        return false;
    if (!uci_core.available())
        return false;
    for (let section in uci_core.section_objects("forkop", "section")) {
        section = object_or_empty(section);
        let enabled = section.enabled == null ? "1" : as_string(section.enabled);
        if (enabled == "0")
            continue;
        if (!connections.is_connections_action(option(section, "action", "")))
            continue;
        if (connections.proxy_core(section) == "xray")
            return true;
    }
    return false;
}

function need_xray() {
    if (is_xray_primary())
        return true;
    return need_xray_sidecar();
}

function need_singbox() {
    if (is_singbox_primary())
        return true;
    if (need_singbox_sidecar())
        return true;
    return has_enabled_inbound_servers();
}

function module_exports() {
    return {
        normalize_engine,
        routing_engine,
        is_xray_primary,
        is_singbox_primary,
        sidecar_engine,
        plane_owns_tproxy,
        need_singbox_sidecar,
        need_xray_sidecar,
        has_enabled_inbound_servers,
        need_singbox,
        need_xray
    };
}

if (sourcepath(1) != null && sourcepath(1) != "")
    return module_exports();

let mode = ARGV[0] || "";
if (mode == "routing-engine") {
    print(routing_engine(), "\n");
    exit(0);
}
if (mode == "sidecar-engine") {
    print(sidecar_engine(), "\n");
    exit(0);
}
if (mode == "need-sidecar") {
    print(need_singbox_sidecar() ? "1" : "0", "\n");
    exit(0);
}
if (mode == "need-singbox") {
    print(need_singbox() ? "1" : "0", "\n");
    exit(0);
}
if (mode == "need-xray") {
    print(need_xray() ? "1" : "0", "\n");
    exit(0);
}
if (mode == "need-xray-sidecar") {
    print(need_xray_sidecar() ? "1" : "0", "\n");
    exit(0);
}

return module_exports();
