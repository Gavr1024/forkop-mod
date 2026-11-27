#!/usr/bin/env ucode

let fs = require("fs");
let core_ip = require("core.ip");
let uci_core = require("core.uci");
let connections = require("config.connections");
let device_pause = require("service.device_pause");
let engine = require("core.engine");

const ROUTE_FILE = getenv("FORKOP_DEVICE_ROUTE_FILE") || "/var/run/forkop/device-routes.json";
const JUMP_FILE = getenv("FORKOP_DEVICE_ROUTE_JUMP") || "/var/run/forkop/device-route.jump";
const SINGBOX_CONFIG = getenv("FORKOP_SINGBOX_CONFIG") || "/etc/sing-box/config.json";
const XRAY_CONFIG = getenv("FORKOP_XRAY_CONFIG") || "/etc/xray/config.json";
const NFT_TABLE = getenv("NFT_TABLE_NAME") || "ForkopTable";
const FAKEIP_MARK = getenv("NFT_FAKEIP_MARK") || "0x04000000";
const MARKER_V4 = "192.0.2.255/32";
const MARKER_V6 = "2001:db8::ff/128";
const MAX_ROUTES = 32;
const MAX_MINUTES = 10080;

function as_string(value) {
    return value == null ? "" : "" + value;
}

function trim(value) {
    return replace(as_string(value), /^[ \t\r\n]+|[ \t\r\n]+$/g, "");
}

function shell_quote(value) {
    return "'" + replace(as_string(value), /'/g, "'\\''") + "'";
}

function now_time() {
    let value = time();
    return value == null ? 0 : int(value);
}

function parent_dir(path) {
    let slash = rindex(path, "/");
    return slash > 0 ? substr(path, 0, slash) : "";
}

function ensure_dir(path) {
    let dir = parent_dir(path);
    if (dir != "")
        system("mkdir -p " + shell_quote(dir) + " >/dev/null 2>&1");
}

function read_state() {
    let data = fs.readfile(ROUTE_FILE);
    if (data == null || trim(data) == "")
        return { items: [] };
    let parsed = null;
    try {
        parsed = json(as_string(data));
    }
    catch (e) {
        return { items: [] };
    }
    if (type(parsed) != "object" || type(parsed.items) != "array")
        return { items: [] };
    return parsed;
}

function write_state(items) {
    ensure_dir(ROUTE_FILE);
    return fs.writefile(ROUTE_FILE, sprintf("%J\n", { items: items })) != null;
}

function clean_label(value) {
    value = trim(value);
    value = replace(value, /[\r\n\t]+/g, " ");
    if (length(value) > 40)
        value = substr(value, 0, 40);
    return value;
}

function normalize_ip(value) {
    value = trim(value);
    if (index(value, "/") >= 0 || index(value, " ") >= 0)
        return "";
    if (!core_ip.valid_ip(value))
        return "";
    return index(value, ":") >= 0 ? lc(value) : value;
}

function section_name_ok(value) {
    return match(value, /^[A-Za-z0-9_]+$/) != null;
}

function routing_action(action) {
    return action == "connection" || action == "bypass" || action == "block" ||
        action == "zapret" || action == "zapret2" || action == "byedpi";
}

function speed_number(section, key) {
    let raw = trim(as_string(section[key]));
    if (match(raw, /^[0-9]+$/) == null)
        return 0;
    let value = int(raw);
    if (value < 1 || value > 10000)
        return 0;
    return value;
}

function speed_down(section) {
    let down = speed_number(section, "speed_limit_down_mbit");
    let up = speed_number(section, "speed_limit_up_mbit");
    if (down > 0)
        return down;
    if (up > 0)
        return 0;
    return speed_number(section, "speed_limit_mbit");
}

function speed_up(section) {
    let down = speed_number(section, "speed_limit_down_mbit");
    let up = speed_number(section, "speed_limit_up_mbit");
    if (up > 0)
        return up;
    if (down > 0)
        return 0;
    return speed_number(section, "speed_limit_mbit");
}

function speed_mark(name) {
    let hash = 0;
    let i = 0;
    while (i < length(name)) {
        hash = (hash * 33 + ord(substr(name, i, 1))) % 4095;
        i++;
    }
    if (hash < 1)
        hash = 1;
    return hash;
}

function speed_chain(name, direction) {
    let clean = replace(name, /[^A-Za-z0-9_]/g, "");
    if (clean == "")
        clean = "section";
    if (length(clean) > 20)
        clean = substr(clean, 0, 20);
    return "forkop_lim_" + clean + "_" + direction;
}

function section_record(name) {
    if (!section_name_ok(name))
        return null;
    for (let section in uci_core.section_objects("forkop", "section")) {
        section = type(section) == "object" ? section : {};
        if (as_string(section[".name"]) == name)
            return section;
    }
    return null;
}

function find_section(name) {
    if (!section_name_ok(name))
        return null;
    for (let section in uci_core.section_objects("forkop", "section")) {
        section = type(section) == "object" ? section : {};
        if (as_string(section[".name"]) != name)
            continue;
        if (as_string(section.enabled) == "0")
            return null;
        let action = connections.action(section);
        if (!routing_action(action))
            return null;
        let label = trim(section.label);
        if (label == "")
            label = name;
        return { name: name, label: label, action: action };
    }
    return null;
}

function item_alive(item, now) {
    if (type(item) != "object")
        return false;
    if (normalize_ip(item.ip) == "" || !section_name_ok(trim(item.section)))
        return false;
    if (!routing_action(trim(item.action)))
        return false;
    let until = int(item.until || 0);
    if (until < 0)
        return false;
    if (until > 0 && now > 0 && until <= now)
        return false;
    return true;
}

function public_item(item) {
    return {
        ip: normalize_ip(item.ip),
        until: int(item.until || 0),
        label: clean_label(item.label),
        section: trim(item.section),
        section_label: clean_label(item.section_label),
        action: trim(item.action)
    };
}

function nft_ok() {
    return match(NFT_TABLE, /^[A-Za-z0-9_]+$/) != null &&
        match(FAKEIP_MARK, /^0x[0-9a-fA-F]+$/) != null;
}

function nft_run(args) {
    if (!nft_ok())
        return;
    // nft arguments are literal. A shell glob would turn [::1]:1605 into a filename.
    system("set -f; nft " + args + " >/dev/null 2>&1");
}

function jump_installed() {
    return fs.readfile(JUMP_FILE) != null;
}

function mark_jump() {
    ensure_dir(JUMP_FILE);
    fs.writefile(JUMP_FILE, "1\n");
}

function chain_text(name) {
    let text = "";
    try {
        let proc = fs.popen("nft list chain inet " + NFT_TABLE + " " + name + " 2>/dev/null");
        if (proc != null) {
            text = as_string(proc.read("all"));
            proc.close();
        }
    }
    catch (e) {
        text = "";
    }
    return text;
}

function pin_port(section_name) {
    let override = getenv("FORKOP_DEVICE_ROUTE_PIN");
    if (override != null && trim(as_string(override)) != "")
        return trim(as_string(override));
    section_name = trim(section_name);
    if (section_name == "")
        return "";
    if (!engine.is_xray_primary()) {
        let spec = engine.singbox_section_pin_spec(section_name);
        return spec == null ? "" : as_string(spec.port || "");
    }
    try {
        let specs = require("xray.constants").section_pin_specs();
        for (let spec in specs)
            if (as_string(spec.name || "") == section_name)
                return as_string(spec.port || "");
    }
    catch (e) {
        return "";
    }
    return "";
}

function chain_text_with_handles(name) {
    let text = "";
    try {
        let proc = fs.popen("nft -a list chain inet " + NFT_TABLE + " " + name + " 2>/dev/null");
        if (proc != null) {
            text = as_string(proc.read("all"));
            proc.close();
        }
    }
    catch (e) {
        text = "";
    }
    return text;
}

function first_rule_line(text) {
    let lines = split(as_string(text), "\n");
    for (let line in lines) {
        if (index(line, "# handle ") < 0)
            continue;
        if (index(trim(line), "chain ") == 0)
            continue;
        return line;
    }
    return "";
}

function line_has_jump(line, jump_name) {
    let needle = "jump " + jump_name;
    let from = 0;
    while (from < length(line)) {
        let at = index(substr(line, from), needle);
        if (at < 0)
            return false;
        at = from + at;
        let next = at + length(needle);
        let after = next >= length(line) ? "" : substr(line, next, 1);
        if (after == "" || after == " " || after == "\t" || after == "#")
            return true;
        from = at + length(needle);
    }
    return false;
}

function jump_handles(text, jump_name) {
    let handles = [];
    let lines = split(as_string(text), "\n");
    for (let line in lines) {
        if (!line_has_jump(line, jump_name))
            continue;
        let pos = index(line, "# handle ");
        if (pos < 0)
            continue;
        let handle = trim(substr(line, pos + 9));
        let space = index(handle, " ");
        if (space >= 0)
            handle = substr(handle, 0, space);
        if (match(handle, /^[0-9]+$/) != null)
            push(handles, handle);
    }
    return handles;
}

function ensure_front_jump(chain, jump_name) {
    let text = chain_text_with_handles(chain);
    let handles = jump_handles(text, jump_name);
    let first = first_rule_line(text);
    if (length(handles) == 1 && line_has_jump(first, jump_name))
        return;
    for (let handle in handles)
        nft_run("delete rule inet " + NFT_TABLE + " " + chain + " handle " + handle);
    nft_run("insert rule inet " + NFT_TABLE + " " + chain + " jump " + jump_name);
}

function shared_tproxy_port() {
    let override = getenv("FORKOP_TPROXY_PORT");
    if (override != null && match(trim(as_string(override)), /^[0-9]+$/) != null)
        return trim(as_string(override));
    try {
        let port = require("xray.constants").XRAY_TPROXY_PORT;
        if (match(as_string(port), /^[0-9]+$/) != null)
            return as_string(port);
    }
    catch (e) {
    }
    return "1602";
}

function fakeip_tproxy_port() {
    try {
        let port = require("xray.constants").XRAY_TPROXY_FAKEIP_PORT;
        if (match(as_string(port), /^[0-9]+$/) != null)
            return as_string(port);
    }
    catch (e) {
    }
    return "1605";
}

function fakeip_dest_range(v6) {
    try {
        let constants = require("xray.constants");
        let range = trim(as_string(v6 ? constants.FAKEIP_INET6_RANGE : constants.FAKEIP_INET4_RANGE));
        if (range != "")
            return range;
    }
    catch (e) {
    }
    return v6 ? "fc00::/18" : "198.18.0.0/15";
}

function install_jump(force) {
    nft_run("add chain inet " + NFT_TABLE + " forkop_temp");
    nft_run("add chain inet " + NFT_TABLE + " forkop_temp_early");
    nft_run("add chain inet " + NFT_TABLE + " forkop_temp_dns");
    nft_run("add chain inet " + NFT_TABLE + " forkop_temp_proxy");
    ensure_front_jump("mangle", "forkop_temp_early");
    ensure_front_jump("priority_rules", "forkop_temp");
    ensure_front_jump("dns_redirect", "forkop_temp_dns");
    ensure_front_jump("proxy", "forkop_temp_proxy");
}

function add_item_rules(item) {
    let ip = item.ip;
    let v6 = index(ip, ":") >= 0;
    let family = v6 ? "ip6" : "ip";
    let local_set = v6 ? "@localv6" : "@localv4";
    if (item.action == "bypass") {
        nft_run("add rule inet " + NFT_TABLE + " forkop_temp_early " + family + " saddr " + ip + " counter accept");
        nft_run("add rule inet " + NFT_TABLE + " forkop_temp " + family + " saddr " + ip + " counter accept");
        nft_run("add rule inet " + NFT_TABLE + " forkop_temp_proxy " + family + " saddr " + ip + " counter accept");
        nft_run("add rule inet " + NFT_TABLE + " forkop_temp_dns " + family + " saddr " + ip + " tcp dport 53 counter return");
        nft_run("add rule inet " + NFT_TABLE + " forkop_temp_dns " + family + " saddr " + ip + " udp dport 53 counter return");
        return;
    }
    if (item.action == "block") {
        nft_run("add rule inet " + NFT_TABLE + " forkop_temp " + family + " saddr " + ip + " " + family + " daddr != " + local_set + " counter reject");
        return;
    }
    let record = section_record(item.section);
    let egress = record != null && trim(as_string(record.speed_limit_place)) == "egress";
    let up = record == null || egress ? 0 : speed_up(record);
    let down = record == null || egress ? 0 : speed_down(record);
    let shaped = "";
    if (down > 0)
        shaped = "ct mark set " + speed_mark(item.section) + " ";
    if (up > 0) {
        let chain = speed_chain(item.section, "up");
        nft_run("add rule inet " + NFT_TABLE + " forkop_temp " + family + " saddr " + ip + " " + family + " daddr != " + local_set + " meta l4proto tcp " + shaped + "jump " + chain);
        nft_run("add rule inet " + NFT_TABLE + " forkop_temp " + family + " saddr " + ip + " " + family + " daddr != " + local_set + " meta l4proto udp " + shaped + "jump " + chain);
        shaped = "";
    }
    nft_run("add rule inet " + NFT_TABLE + " forkop_temp " + family + " saddr " + ip + " " + family + " daddr != " + local_set + " meta l4proto tcp " + shaped + "meta mark set " + FAKEIP_MARK + " counter accept");
    nft_run("add rule inet " + NFT_TABLE + " forkop_temp " + family + " saddr " + ip + " " + family + " daddr != " + local_set + " meta l4proto udp " + shaped + "meta mark set " + FAKEIP_MARK + " counter accept");
    let port = pin_port(item.section);
    let pinned = match(port, /^[0-9]+$/) != null;
    if (!pinned)
        port = shared_tproxy_port();
    let override = getenv("FORKOP_DEVICE_ROUTE_PIN");
    let local_pin = !engine.is_xray_primary() && (override == null || trim(as_string(override)) == "");
    let target = v6 ? core_ip.format_ipv6_tproxy_target("::1", port) : (local_pin ? ("127.0.0.1:" + port) : (":" + port));
    // A section pin already owns every packet from the device. Moving only the
    // service address to :1605 would drop that ownership. Without a pin the
    // normal door keeps the address, so it goes to the second inbound, which
    // puts the site name back before the section dials.
    if (engine.is_xray_primary() && !pinned) {
        let fake_port = fakeip_tproxy_port();
        let fake_target = v6 ? core_ip.format_ipv6_tproxy_target("::1", fake_port) : (":" + fake_port);
        let fake_range = fakeip_dest_range(v6);
        nft_run("add rule inet " + NFT_TABLE + " forkop_temp_proxy " + family + " saddr " + ip + " " + family + " daddr " + fake_range + " meta l4proto tcp tproxy " + family + " to " + fake_target + " counter accept");
        nft_run("add rule inet " + NFT_TABLE + " forkop_temp_proxy " + family + " saddr " + ip + " " + family + " daddr " + fake_range + " meta l4proto udp tproxy " + family + " to " + fake_target + " counter accept");
    }
    nft_run("add rule inet " + NFT_TABLE + " forkop_temp_proxy " + family + " saddr " + ip + " " + family + " daddr != " + local_set + " meta l4proto tcp tproxy " + family + " to " + target + " counter accept");
    nft_run("add rule inet " + NFT_TABLE + " forkop_temp_proxy " + family + " saddr " + ip + " " + family + " daddr != " + local_set + " meta l4proto udp tproxy " + family + " to " + target + " counter accept");
}

function apply_nft(items, force_jump) {
    install_jump(force_jump);
    nft_run("flush chain inet " + NFT_TABLE + " forkop_temp");
    nft_run("flush chain inet " + NFT_TABLE + " forkop_temp_early");
    nft_run("flush chain inet " + NFT_TABLE + " forkop_temp_dns");
    nft_run("flush chain inet " + NFT_TABLE + " forkop_temp_proxy");
    for (let item in items)
        add_item_rules(item);
}

function tag_present(text, tag) {
    return index(text, '"' + tag + '"') >= 0;
}

function section_proxy_core(name) {
    for (let section in uci_core.section_objects("forkop", "section")) {
        section = type(section) == "object" ? section : {};
        if (as_string(section[".name"]) != name)
            continue;
        return connections.proxy_core(section);
    }
    return "xray";
}

function door_tag(item) {
    if (item.action == "connection" && section_proxy_core(item.section) == "sing-box")
        return "sb-full-" + item.section;
    return "xray-" + item.section;
}

function json_string_field(object_text, field) {
    let needle = "\"" + field + "\"";
    let at = index(object_text, needle);
    if (at < 0)
        return "";
    let rest = substr(object_text, at + length(needle));
    let colon = index(rest, ":");
    if (colon < 0)
        return "";
    rest = substr(rest, colon + 1);
    let quote = index(rest, "\"");
    if (quote < 0)
        return "";
    rest = substr(rest, quote + 1);
    let end = index(rest, "\"");
    if (end <= 0)
        return "";
    return substr(rest, 0, end);
}

function object_around(text, at) {
    let depth = 0;
    let start = -1;
    let i = at;
    while (i >= 0) {
        let ch = substr(text, i, 1);
        if (ch == "}")
            depth++;
        else if (ch == "{") {
            if (depth == 0) {
                start = i;
                break;
            }
            depth--;
        }
        i--;
    }
    if (start < 0)
        return "";
    depth = 0;
    let in_str = false;
    let escaped = false;
    i = start;
    while (i < length(text)) {
        let ch = substr(text, i, 1);
        if (in_str) {
            if (escaped)
                escaped = false;
            else if (ch == "\\")
                escaped = true;
            else if (ch == "\"")
                in_str = false;
        }
        else if (ch == "\"")
            in_str = true;
        else if (ch == "{")
            depth++;
        else if (ch == "}") {
            depth--;
            if (depth == 0)
                return substr(text, start, i - start + 1);
        }
        i++;
    }
    return "";
}

function socks_route_target(text, section_name) {
    let needle = "\"socks-in-" + section_name + "\"";
    let from = 0;
    let needle_len = length(needle);
    while (from < length(text)) {
        let at = index(substr(text, from), needle);
        if (at < 0)
            return "";
        at = from + at;
        let obj = object_around(text, at);
        let balancer = json_string_field(obj, "balancerTag");
        if (balancer == "balancer-" + section_name)
            return "balancer:" + section_name;
        let outbound = json_string_field(obj, "outboundTag");
        if (outbound != "")
            return outbound;
        from = at + needle_len;
    }
    return "";
}

function xray_outbound_for(text, item) {
    if (item.action == "bypass")
        return tag_present(text, "direct") ? "direct" : "";
    if (item.action == "block")
        return tag_present(text, "block") ? "block" : "";
    let socks = socks_route_target(text, item.section);
    if (socks != "")
        return socks;
    if (tag_present(text, "balancer-" + item.section))
        return "balancer:" + item.section;
    let tag = door_tag(item);
    if (tag_present(text, tag))
        return tag;
    if (tag != "xray-" + item.section && tag_present(text, "xray-" + item.section))
        return "xray-" + item.section;
    return "";
}

function quoted_inbounds(text) {
    let tags = [ "tproxy-in", "tproxy6-in", "tproxy-fakeip-in", "tproxy-fakeip6-in" ];
    let found = [];
    for (let tag in tags)
        if (tag_present(text, tag))
            push(found, '"' + tag + '"');
    return join(",", found);
}

function xray_rule_text(item, outbound, inbounds) {
    let v6 = index(item.ip, ":") >= 0;
    let cidr = v6 ? item.ip + "/128" : item.ip + "/32";
    let marker = v6 ? MARKER_V6 : MARKER_V4;
    let target = index(outbound, "balancer:") == 0
        ? '"balancerTag":"balancer-' + substr(outbound, 9) + '"'
        : '"outboundTag":"' + outbound + '"';
    return '{"type":"field","inboundTag":[' + inbounds + '],"source":["' + cidr + '","' + marker + '"],' + target + '}';
}

function strip_marker_rules(text) {
    text = replace(text, /,?\s*\{[^{}]*192\.0\.2\.255\/32[^{}]*\}/g, "");
    text = replace(text, /,?\s*\{[^{}]*2001:db8::ff\/128[^{}]*\}/g, "");
    text = replace(text, /\[\s*,/g, "[");
    text = replace(text, /,\s*,/g, ",");
    text = replace(text, /,\s*\]/g, "]");
    return text;
}

function insert_rule_after_routing(text, rule_text) {
    let found = index(text, '"routing"');
    if (found < 0 || rule_text == "")
        return "";
    let rules_at = index(substr(text, found), '"rules"');
    if (rules_at < 0)
        return "";
    let bracket = index(substr(text, found + rules_at), "[");
    if (bracket < 0)
        return "";
    let pos = found + rules_at + bracket + 1;
    let rest = substr(text, pos);
    let skip = 0;
    while (skip < length(rest)) {
        let ch = substr(rest, skip, 1);
        if (ch != " " && ch != "\n" && ch != "\r" && ch != "\t")
            break;
        skip++;
    }
    if (substr(rest, skip, 1) == "]")
        return substr(text, 0, pos) + rule_text + substr(rest, skip);
    return substr(text, 0, pos) + rule_text + "," + substr(rest, skip);
}

function reload_xray_later() {
    if (getenv("FORKOP_DEVICE_ROUTE_NO_RELOAD") == "1")
        return;
    system("sh -c 'sleep 1; /etc/init.d/xray restart >/dev/null 2>&1' >/dev/null 2>&1 &");
}

function door_items(items) {
    let out = [];
    for (let item in items) {
        if (item.action == "bypass" || item.action == "block")
            continue;
        if (match(pin_port(item.section), /^[0-9]+$/) != null)
            continue;
        push(out, item);
    }
    return out;
}

function sync_xray_rules(items) {
    let text = null;
    try {
        text = fs.readfile(XRAY_CONFIG);
    }
    catch (e) {
        text = null;
    }
    if (text == null || trim(as_string(text)) == "")
        return length(door_items(items)) == 0;
    text = as_string(text);
    let had = index(text, MARKER_V4) >= 0 || index(text, MARKER_V6) >= 0;
    let doors = door_items(items);
    if (!had && length(doors) == 0)
        return true;
    let inbounds = quoted_inbounds(text);
    if (length(doors) > 0 && inbounds == "")
        return false;
    let rules = [];
    for (let item in doors) {
        let outbound = xray_outbound_for(text, item);
        if (outbound == "")
            return false;
        push(rules, xray_rule_text(item, outbound, inbounds));
    }
    text = strip_marker_rules(text);
    let i = length(rules);
    while (i > 0) {
        i--;
        text = insert_rule_after_routing(text, rules[i]);
        if (text == "")
            return false;
    }
    let tmp = XRAY_CONFIG + ".forkop-tmp";
    if (fs.writefile(tmp, text) == null)
        return false;
    if (system("mv " + shell_quote(tmp) + " " + shell_quote(XRAY_CONFIG) + " >/dev/null 2>&1") != 0)
        return false;
    reload_xray_later();
    return true;
}

function routes_ready(items) {
    for (let item in items) {
        if (item.action == "bypass" || item.action == "block")
            continue;
        if (match(pin_port(item.section), /^[0-9]+$/) != null)
            continue;
        if (door_tag(item) == "")
            return false;
    }
    return true;
}

function singbox_pins_ready(items) {
    for (let item in items) {
        if (item.action == "bypass" || item.action == "block")
            continue;
        if (match(pin_port(item.section), /^[0-9]+$/) == null)
            return false;
    }
    return true;
}

function publish(items) {
    let applied = false;
    try {
        apply_nft(items, false);
        if (engine.is_xray_primary())
            applied = routes_ready(items) && sync_xray_rules(items);
        else
            applied = singbox_pins_ready(items);
    }
    catch (e2) {
        applied = false;
    }
    return applied;
}

function stored_items(now) {
    let kept = [];
    let changed = false;
    for (let item in read_state().items) {
        if (!item_alive(item, now)) {
            changed = true;
            continue;
        }
        push(kept, public_item(item));
    }
    if (changed) {
        write_state(kept);
        publish(kept);
    }
    return kept;
}

function list_routes() {
    return { ok: true, items: stored_items(now_time()) };
}

function arm_timer(ip, until, seconds) {
    if (getenv("FORKOP_DEVICE_ROUTE_NO_TIMER") == "1" || seconds <= 0 || until <= 0)
        return;
    system("sh -c 'sleep " + as_string(seconds) + "; /usr/bin/forkop route_device_expire " +
        ip + " " + as_string(until) + " >/dev/null 2>&1' >/dev/null 2>&1 &");
}

function add_route(ip, minutes, section_name, label) {
    ip = normalize_ip(ip);
    if (ip == "")
        return { ok: false, error: "bad-ip" };
    let section = find_section(trim(section_name));
    if (section == null)
        return { ok: false, error: "bad-section" };
    minutes = trim(minutes);
    if (match(minutes, /^[0-9]+$/) == null)
        return { ok: false, error: "bad-time" };
    let count = int(minutes);
    if (count > MAX_MINUTES)
        return { ok: false, error: "bad-time" };
    let now = now_time();
    let until = count == 0 ? 0 : now + count * 60;
    let items = stored_items(now);
    let next = [];
    let replaced = false;
    let fresh = {
        ip: ip,
        until: until,
        label: clean_label(label),
        section: section.name,
        section_label: section.label,
        action: section.action
    };
    for (let item in items) {
        if (item.ip == ip) {
            replaced = true;
            push(next, fresh);
        }
        else
            push(next, item);
    }
    if (!replaced) {
        if (length(next) >= MAX_ROUTES)
            return { ok: false, error: "full" };
        push(next, fresh);
    }
    if (!write_state(next))
        return { ok: false, error: "write" };
    try {
        device_pause.clear_pause(ip);
    }
    catch (e) {
    }
    let applied = publish(next);
    if (until > 0)
        arm_timer(ip, until, count * 60);
    return { ok: true, applied: applied, items: next };
}

function clear_route(ip) {
    ip = normalize_ip(ip);
    if (ip == "")
        return { ok: false, error: "bad-ip" };
    let next = [];
    for (let item in stored_items(now_time()))
        if (item.ip != ip)
            push(next, item);
    if (!write_state(next))
        return { ok: false, error: "write" };
    let applied = publish(next);
    return { ok: true, applied: applied, items: next };
}

function expire_if(ip, expected_until) {
    ip = normalize_ip(ip);
    expected_until = int(expected_until || 0);
    if (ip == "" || expected_until <= 0)
        return list_routes();
    let now = now_time();
    for (let item in stored_items(now)) {
        if (item.ip == ip && int(item.until || 0) == expected_until && now >= expected_until)
            return clear_route(ip);
    }
    return list_routes();
}

function active_for(ip) {
    ip = normalize_ip(ip);
    if (ip == "")
        return null;
    for (let item in stored_items(now_time()))
        if (item.ip == ip)
            return item;
    return null;
}

function ips_for(section_name) {
    let out = [];
    section_name = trim(section_name);
    if (section_name == "")
        return out;
    for (let item in stored_items(now_time()))
        if (item.section == section_name)
            push(out, item.ip);
    return out;
}

function install_from_file() {
    apply_nft(stored_items(now_time()), true);
}

function module_exports() {
    return { list_routes, add_route, clear_route, active_for, ips_for, install_from_file, normalize_ip };
}

if ((sourcepath(1) != null && sourcepath(1) != "") || ARGV[0] == null)
    return module_exports();

let mode = ARGV[0] || "";
let result = null;
if (mode == "list")
    result = list_routes();
else if (mode == "add")
    result = add_route(ARGV[1] || "", ARGV[2] || "", ARGV[3] || "", ARGV[4] || "");
else if (mode == "clear")
    result = clear_route(ARGV[1] || "");
else if (mode == "expire-if")
    result = expire_if(ARGV[1] || "", ARGV[2] || "");
else if (mode == "install") {
    install_from_file();
    result = list_routes();
}
else {
    warn("Usage: service/device_route.uc <list|add|clear> ...\n");
    exit(1);
}

print(sprintf("%J\n", result));
exit(result.ok ? 0 : 1);
