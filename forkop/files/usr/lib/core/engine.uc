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
    return need_singbox_sidecar();
}

function flag_enabled(value) {
    value = as_string(value);
    return value == "1" || value == "true" || value == "yes" || value == "on";
}

function settings_object() {
    if (!uci_core.available())
        return {};
    let rows = uci_core.section_objects("forkop", "settings");
    return length(rows) > 0 ? object_or_empty(rows[0]) : {};
}

function section_is_dns_detour_target(name) {
    name = as_string(name);
    if (name == "" || !uci_core.available())
        return false;
    let settings = settings_object();
    if (flag_enabled(settings.dns_detour_enabled) && as_string(settings.dns_detour_section || "") == name)
        return true;
    for (let section in uci_core.section_objects("forkop", "section")) {
        section = object_or_empty(section);
        if (as_string(section.action || "") != "dns")
            continue;
        if (!flag_enabled(section.dns_detour_enabled))
            continue;
        if (as_string(section.dns_detour_section || "") == name)
            return true;
    }
    return false;
}

function section_has_fully_routed(section) {
    let value = object_or_empty(section).fully_routed_ips;
    if (type(value) == "array") {
        for (let item in value)
            if (trim(as_string(item)) != "")
                return true;
        return false;
    }
    return trim(as_string(value)) != "";
}

function fullroute_sidecar_specs() {
    if (!is_xray_primary() || !uci_core.available())
        return [];
    let specs = [];
    for (let section in uci_core.section_objects("forkop", "section")) {
        section = object_or_empty(section);
        let enabled = section.enabled == null ? "1" : as_string(section.enabled);
        if (enabled == "0")
            continue;
        if (!connections.is_connections_action(option(section, "action", "")))
            continue;
        if (connections.proxy_core(section) != "sing-box")
            continue;
        let name = as_string(section[".name"] || "");
        if (name == "")
            continue;
        if (!section_has_fully_routed(section) && !section_is_dns_detour_target(name))
            continue;
        let index = length(specs);
        push(specs, {
            name: name,
            port: 4600 + index,
            inbound_tag: "fullroute-in-" + name,
            outbound_tag: "sb-full-" + name
        });
    }
    return specs;
}

function fullroute_sidecar_spec(section_name) {
    section_name = as_string(section_name);
    for (let spec in fullroute_sidecar_specs())
        if (spec.name == section_name)
            return spec;
    return null;
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
        need_xray,
        fullroute_sidecar_specs,
        fullroute_sidecar_spec
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
