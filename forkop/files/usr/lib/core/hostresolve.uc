#!/usr/bin/env ucode
// Resolve many hostnames for nft/Xray without blocking startup on serial DNS.

let fs = require("fs");

function as_string(value) {
    return value == null ? "" : "" + value;
}

function trim(value) {
    return replace(as_string(value), /^[ \t\r\n]+|[ \t\r\n]+$/g, "");
}

function shell_quote(value) {
    return "'" + replace(as_string(value), /'/g, "'\\''") + "'";
}

function cache_path() {
    return "/tmp/forkop/host-ip.cache";
}

function push_unique(list, value) {
    for (let item in list) {
        if (item == value)
            return;
    }
    push(list, value);
}

function is_skipped_address(addr, dns_server) {
    addr = lc(trim(addr));
    if (addr == "" || addr == lc(trim(dns_server)))
        return true;
    if (index(addr, "198.18.") == 0 || index(addr, "198.19.") == 0)
        return true;
    if (index(addr, "fc00:") == 0 || index(addr, "fd") == 0)
        return true;
    return false;
}

function parse_nslookup(raw, dns_server) {
    let ips = [];
    for (let line in split(as_string(raw), /\n/)) {
        line = trim(replace(line, /\r/g, ""));
        let matched = match(line, /^Address[ \t]*[0-9]*:[ \t]*([^ \t]+)/);
        let addr = matched ? trim(as_string(matched[1])) : "";
        if (addr == "")
            continue;
        let v4port = match(addr, /^([0-9]+(\.[0-9]+){3}):[0-9]+$/);
        if (v4port)
            addr = as_string(v4port[1]);
        let v6port = match(addr, /^\[([0-9A-Fa-f:]+)\]:[0-9]+$/);
        if (v6port)
            addr = as_string(v6port[1]);
        let ipv4 = match(addr, /^[0-9]+(\.[0-9]+){3}$/) != null;
        let ipv6 = index(addr, ":") >= 0 && match(addr, /^[0-9A-Fa-f:]+$/) != null;
        if (!ipv4 && !ipv6)
            continue;
        if (is_skipped_address(addr, dns_server))
            continue;
        push_unique(ips, addr);
    }
    return ips;
}

function load_cache() {
    let map = {};
    let raw = null;
    try {
        raw = fs.readfile(cache_path());
    }
    catch (e) {
        raw = null;
    }
    if (raw == null)
        return map;
    for (let line in split(as_string(raw), /\n/)) {
        line = trim(line);
        let space = index(line, " ");
        if (space <= 0)
            continue;
        let host = substr(line, 0, space);
        let ips = [];
        for (let ip in split(substr(line, space + 1), /,/)) {
            ip = trim(ip);
            if (ip != "")
                push(ips, ip);
        }
        if (length(ips) > 0)
            map[host] = ips;
    }
    return map;
}

function read_cache_text() {
    try {
        return as_string(fs.readfile(cache_path()));
    }
    catch (e) {
        return "";
    }
}

function save_cache(map, hosts) {
    system("mkdir -p /tmp/forkop");
    let lines = [];
    let seen = {};
    for (let host in hosts) {
        let ips = map[host];
        if (type(ips) != "array" || length(ips) == 0 || seen[host])
            continue;
        seen[host] = true;
        push(lines, host + " " + join(",", ips));
    }
    for (let line in split(read_cache_text(), /\n/)) {
        line = trim(line);
        let space = index(line, " ");
        if (space <= 0)
            continue;
        let host = substr(line, 0, space);
        if (seen[host])
            continue;
        seen[host] = true;
        push(lines, line);
    }
    fs.writefile(cache_path(), length(lines) > 0 ? join("\n", lines) + "\n" : "");
}

function resolve_wave(hosts, dns_server) {
    let found = {};
    if (length(hosts) == 0)
        return found;
    let dir = "/tmp/forkop/hostres-" + replace(dns_server, /\./g, "_");
    system("rm -rf " + shell_quote(dir) + " && mkdir -p " + shell_quote(dir));
    let list_path = dir + "/hosts";
    if (fs.writefile(list_path, join("\n", hosts) + "\n") == null)
        return found;
    // One public resolver, 32 at a time, 1s each. Serial timeout-3 lookups
    // of 8.8.8.8 made Xray wait many minutes before it could start.
    system(
        "n=0; while IFS= read -r host; do " +
        "[ -n \"$host\" ] || continue; " +
        "timeout 1 nslookup \"$host\" " + shell_quote(dns_server) + " >" + shell_quote(dir) + "/\"$host\" 2>/dev/null & " +
        "n=$((n+1)); " +
        "if [ \"$n\" -ge 32 ]; then wait; n=0; fi; " +
        "done < " + shell_quote(list_path) + "; wait"
    );
    for (let host in hosts) {
        let raw = null;
        try {
            raw = fs.readfile(dir + "/" + host);
        }
        catch (e) {
            raw = null;
        }
        if (raw == null)
            continue;
        let ips = parse_nslookup(raw, dns_server);
        if (length(ips) > 0)
            found[host] = ips;
    }
    system("rm -rf " + shell_quote(dir));
    return found;
}

function resolve_hosts(hosts) {
    let unique = [];
    let seen = {};
    for (let host in hosts) {
        host = lc(trim(host));
        if (host == "" || match(host, /^[a-z0-9._-]+$/) == null || seen[host])
            continue;
        seen[host] = true;
        push(unique, host);
    }
    let cache = load_cache();
    let result = {};
    let pending = [];
    for (let host in unique) {
        if (type(cache[host]) == "array" && length(cache[host]) > 0)
            result[host] = cache[host];
        else
            push(pending, host);
    }
    if (length(pending) == 0)
        return result;
    let changed = false;
    for (let dns_server in [ "77.88.8.8", "1.1.1.1", "8.8.8.8" ]) {
        if (length(pending) == 0)
            break;
        let found = resolve_wave(pending, dns_server);
        let still = [];
        for (let host in pending) {
            if (type(found[host]) == "array" && length(found[host]) > 0) {
                result[host] = found[host];
                cache[host] = found[host];
                changed = true;
            }
            else {
                push(still, host);
            }
        }
        pending = still;
    }
    if (changed)
        save_cache(cache, unique);
    return result;
}

return {
    parse_nslookup,
    resolve_hosts,
    resolve_wave
};
