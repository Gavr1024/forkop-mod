#!/usr/bin/env ucode

let fs = require("fs");
let core_ip = require("core.ip");

const PAUSE_FILE = getenv("FORKOP_DEVICE_PAUSE_FILE") || "/var/run/forkop/device-pauses.json";
const NFT_TABLE = getenv("NFT_TABLE_NAME") || "ForkopTable";
const MAX_PAUSES = 32;
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

function pause_now() {
    let value = time();
    return value == null ? 0 : int(value);
}

function parent_dir(path) {
    let slash = rindex(path, "/");
    return slash > 0 ? substr(path, 0, slash) : "";
}

function read_items() {
    let data = fs.readfile(PAUSE_FILE);
    if (data == null || trim(data) == "")
        return [];
    let parsed = null;
    try {
        parsed = json(as_string(data));
    }
    catch (e) {
        return [];
    }
    if (type(parsed) != "object" || type(parsed.items) != "array")
        return [];
    return parsed.items;
}

function write_items(items) {
    let dir = parent_dir(PAUSE_FILE);
    if (dir != "")
        system("mkdir -p " + shell_quote(dir) + " >/dev/null 2>&1");
    return fs.writefile(PAUSE_FILE, sprintf("%J\n", { items: items })) != null;
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

function item_alive(item, now) {
    if (type(item) != "object")
        return false;
    let ip = normalize_ip(item.ip);
    if (ip == "")
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
        label: clean_label(item.label)
    };
}

function nft_element(ip, present) {
    if (match(NFT_TABLE, /^[A-Za-z0-9_]+$/) == null)
        return;
    let set_name = index(ip, ":") >= 0 ? "forkop_paused6" : "forkop_paused";
    let verb = present ? "add" : "delete";
    system("nft " + verb + " element inet " + NFT_TABLE + " " + set_name + " { " + ip + " } >/dev/null 2>&1");
}

function stored_items(now) {
    let kept = [];
    let changed = false;
    for (let item in read_items()) {
        if (!item_alive(item, now)) {
            let ip = normalize_ip(type(item) == "object" ? item.ip : "");
            if (ip != "")
                nft_element(ip, false);
            changed = true;
            continue;
        }
        push(kept, public_item(item));
    }
    if (changed)
        write_items(kept);
    return kept;
}

function list_pauses() {
    return { ok: true, items: stored_items(pause_now()) };
}

function arm_timer(ip, until, seconds) {
    if (getenv("FORKOP_DEVICE_PAUSE_NO_TIMER") == "1" || seconds <= 0 || until <= 0)
        return;
    system("sh -c 'sleep " + as_string(seconds) + "; /usr/bin/forkop pause_device_expire " +
        ip + " " + as_string(until) + " >/dev/null 2>&1' >/dev/null 2>&1 &");
}

function add_pause(ip, minutes, label) {
    ip = normalize_ip(ip);
    if (ip == "")
        return { ok: false, error: "bad-ip" };
    minutes = trim(minutes);
    if (match(minutes, /^[0-9]+$/) == null)
        return { ok: false, error: "bad-time" };
    let count = int(minutes);
    if (count > MAX_MINUTES)
        return { ok: false, error: "bad-time" };
    let now = pause_now();
    let until = count == 0 ? 0 : now + count * 60;
    let items = stored_items(now);
    let next = [];
    let replaced = false;
    for (let item in items) {
        if (item.ip == ip) {
            replaced = true;
            push(next, { ip: ip, until: until, label: clean_label(label) });
        }
        else
            push(next, item);
    }
    if (!replaced) {
        if (length(next) >= MAX_PAUSES)
            return { ok: false, error: "full" };
        push(next, { ip: ip, until: until, label: clean_label(label) });
    }
    if (!write_items(next))
        return { ok: false, error: "write" };
    nft_element(ip, true);
    if (until > 0)
        arm_timer(ip, until, count * 60);
    return { ok: true, items: next };
}

function clear_pause(ip) {
    ip = normalize_ip(ip);
    if (ip == "")
        return { ok: false, error: "bad-ip" };
    let next = [];
    for (let item in stored_items(pause_now()))
        if (item.ip != ip)
            push(next, item);
    if (!write_items(next))
        return { ok: false, error: "write" };
    nft_element(ip, false);
    return { ok: true, items: next };
}

function expire_if(ip, expected_until) {
    ip = normalize_ip(ip);
    expected_until = int(expected_until || 0);
    if (ip == "" || expected_until <= 0)
        return list_pauses();
    let now = pause_now();
    for (let item in stored_items(now)) {
        if (item.ip == ip && int(item.until || 0) == expected_until && now >= expected_until)
            return clear_pause(ip);
    }
    return list_pauses();
}

function active_families() {
    let v4 = [];
    let v6 = [];
    for (let item in stored_items(pause_now())) {
        if (index(item.ip, ":") >= 0)
            push(v6, item.ip);
        else
            push(v4, item.ip);
    }
    return { v4: v4, v6: v6 };
}

function module_exports() {
    return { list_pauses, add_pause, clear_pause, active_families, normalize_ip };
}

if ((sourcepath(1) != null && sourcepath(1) != "") || ARGV[0] == null)
    return module_exports();

let mode = ARGV[0] || "";
let result = null;
if (mode == "list")
    result = list_pauses();
else if (mode == "add")
    result = add_pause(ARGV[1] || "", ARGV[2] || "", ARGV[3] || "");
else if (mode == "clear")
    result = clear_pause(ARGV[1] || "");
else if (mode == "expire-if")
    result = expire_if(ARGV[1] || "", ARGV[2] || "");
else {
    warn("Usage: service/device_pause.uc <list|add|clear> ...\n");
    exit(1);
}

print(sprintf("%J\n", result));
exit(result.ok ? 0 : 1);
