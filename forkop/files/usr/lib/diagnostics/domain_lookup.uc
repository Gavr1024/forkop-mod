#!/usr/bin/env ucode

let fs = require("fs");
let uci_core = require("core.uci");
let connections = require("config.connections");
let geodata = require("xray.geodata");
let rulesets = require("singbox.rulesets");
let list_cache = require("routing.list_cache");
let device_route = require("service.device_route");

const MAX_LIST_BYTES = 64 * 1024 * 1024;

function as_string(value) {
    return value == null ? "" : "" + value;
}

function trim(value) {
    return replace(as_string(value), /^[ \t\r\n]+|[ \t\r\n]+$/g, "");
}

function lower(value) {
    return lc(trim(value));
}

function routing_action(action) {
    action = as_string(action);
    return action == "connection" || action == "proxy" || action == "outbound" ||
        action == "vpn" || action == "bypass" || action == "block" ||
        action == "zapret" || action == "zapret2" || action == "byedpi";
}

function normalize_domain(value) {
    value = lower(value);
    value = replace(value, /^[a-z][a-z0-9+.-]*:\/\//, "");
    value = replace(value, /[/?#].*$/, "");
    value = replace(value, /:\d+$/, "");
    value = replace(value, /^\*\./, "");
    value = replace(value, /\.$/, "");
    if (value == "" || index(value, "..") >= 0 || index(value, ".") < 1)
        return "";
    if (match(value, /^[a-z0-9._-]+$/) == null)
        return "";
    return value;
}

function raw_items(section, key) {
    let value = section[key];
    let result = [];
    if (type(value) == "array") {
        for (let item in value) {
            item = trim(item);
            if (item != "")
                push(result, item);
        }
        return result;
    }
    for (let item in split(replace(as_string(value), /[, \t\r\n]+/g, "\n"), "\n")) {
        item = trim(item);
        if (item != "")
            push(result, item);
    }
    return result;
}

function option_items(section, key) {
    let result = [];
    for (let item in raw_items(section, key))
        push(result, lower(item));
    return result;
}

function name_char(ch) {
    return ch != "" && match(ch, /^[a-z0-9-]$/) != null;
}

function token_found(text, needle) {
    let from = 0;
    let size = length(needle);
    while (from < length(text)) {
        let at = index(substr(text, from), needle);
        if (at < 0)
            return false;
        let pos = from + at;
        let before = pos == 0 ? "" : substr(text, pos - 1, 1);
        let before2 = pos < 2 ? "" : substr(text, pos - 2, 1);
        let after = pos + size >= length(text) ? "" : substr(text, pos + size, 1);
        let left_ok = !name_char(before) && before != ".";
        if (!left_ok && before == "." && before2 == "*")
            left_ok = true;
        if (left_ok && !name_char(after) && after != ".")
            return true;
        from = pos + 1;
    }
    return false;
}

function suffix_names(host) {
    let names = [];
    let cursor = host;
    while (cursor != "" && index(cursor, ".") > 0) {
        push(names, cursor);
        let dot = index(cursor, ".");
        cursor = substr(cursor, dot + 1);
    }
    return names;
}

function file_prefix(path, count) {
    let fh = null;
    try {
        fh = fs.open(as_string(path), "r");
    }
    catch (e) {
        fh = null;
    }
    if (fh == null)
        return "";
    let data = "";
    try {
        data = as_string(fh.read(count));
    }
    catch (e2) {
        data = "";
    }
    try {
        fh.close();
    }
    catch (e3) {
    }
    return data;
}

function file_head(path) {
    return file_prefix(path, 4);
}

function binary_blob(path) {
    let st = fs.stat(path);
    if (st == null)
        return false;
    let size = int(st.size || 0);
    if (size <= 0)
        return false;
    let want = size > 4096 ? 4096 : size;
    let data = file_prefix(path, want);
    if (index(data, "\0") >= 0)
        return true;
    return length(data) < want;
}

function file_hit(path, host) {
    path = trim(path);
    if (path == "")
        return null;
    let st = fs.stat(path);
    if (st == null || int(st.size || 0) <= 0)
        return null;
    if (int(st.size || 0) > MAX_LIST_BYTES)
        return "large";
    if (binary_blob(path))
        return null;
    let names = suffix_names(host);
    let fh = null;
    try {
        fh = fs.open(path, "r");
    }
    catch (e) {
        fh = null;
    }
    if (fh == null)
        return null;
    let carry = "";
    let overlap = length(host) + 2;
    let saw = false;
    while (true) {
        let chunk = "";
        try {
            chunk = as_string(fh.read(65536));
        }
        catch (e2) {
            chunk = "";
        }
        if (chunk == "")
            break;
        saw = true;
        let text = lc(carry + chunk);
        for (let name in names) {
            if (token_found(text, name)) {
                try {
                    fh.close();
                }
                catch (e3) {
                }
                return name;
            }
        }
        carry = length(text) > overlap ? substr(text, length(text) - overlap) : text;
    }
    try {
        fh.close();
    }
    catch (e4) {
    }
    return saw ? "" : null;
}

function compressed_ruleset(path) {
    let head = file_head(path);
    if (length(head) < 2)
        return false;
    if (ord(substr(head, 0, 1)) == 31 && ord(substr(head, 1, 1)) == 139)
        return true;
    if (length(head) < 4 || substr(head, 0, 3) != "SRS")
        return false;
    return ord(substr(head, 3, 1)) >= 2;
}

function shell_quote(value) {
    return "'" + replace(as_string(value), /'/g, "'\\''") + "'";
}

let decompiled_cache = {};
let decompiled_files = [];
let decompile_seq = 0;

function cleanup_decompiled() {
    for (let path in decompiled_files) {
        try {
            fs.unlink(path);
        }
        catch (e) {
        }
    }
    decompiled_files = [];
    decompiled_cache = {};
}

function decompile_ruleset(path) {
    let bin = trim(getenv("SING_BOX_BIN") || "/usr/bin/sing-box");
    if (bin == "" || fs.stat(bin) == null)
        return "";
    system("mkdir -p /tmp/forkop-stage >/dev/null 2>&1");
    decompile_seq++;
    let out = "/tmp/forkop-stage/lookup-" + as_string(time()) + "-" + as_string(decompile_seq) + ".json";
    try {
        fs.unlink(out);
    }
    catch (e) {
    }
    let command = shell_quote(bin) + " rule-set decompile " + shell_quote(path) + " -o " + shell_quote(out) + " >/dev/null 2>&1";
    if (fs.stat("/usr/bin/timeout") != null)
        command = shell_quote("/usr/bin/timeout") + " 20 " + command;
    else if (fs.stat("/bin/timeout") != null)
        command = shell_quote("/bin/timeout") + " 20 " + command;
    if (system(command) != 0 || fs.stat(out) == null)
        return "";
    push(decompiled_files, out);
    return out;
}

function searchable_hit(path, host) {
    try {
        if (!compressed_ruleset(path))
            return file_hit(path, host);
        let cached = decompiled_cache[path];
        if (cached == null) {
            cached = decompile_ruleset(path);
            decompiled_cache[path] = cached;
        }
        if (cached == "")
            return "opaque";
        return file_hit(cached, host);
    }
    catch (e) {
        return "opaque";
    }
}

function existing_file(path) {
    path = trim(path);
    if (path == "")
        return "";
    let st = fs.stat(path);
    if (st == null || int(st.size || 0) <= 0)
        return "";
    return path;
}

function cached_url_file(url) {
    url = trim(url);
    if (url == "")
        return "";
    let path = "";
    try {
        path = existing_file(list_cache.usable_local_path(url));
    }
    catch (e) {
        path = "";
    }
    if (path != "")
        return path;
    try {
        path = list_cache.cache_path_for_url(url);
    }
    catch (e2) {
        path = "";
    }
    return existing_file(path);
}

function remember_path(paths, seen, path) {
    path = existing_file(path);
    if (path == "" || seen[path])
        return;
    seen[path] = true;
    push(paths, path);
}

function community_paths(name) {
    let paths = [];
    let seen = {};
    try {
        remember_path(paths, seen, geodata.community_lst_path(name));
    }
    catch (e) {
    }
    if (name == "ads_hagezi_pro") {
        let extra = trim(getenv("FORKOP_ADLIST_DAT") || "");
        if (extra != "")
            remember_path(paths, seen, extra);
        remember_path(paths, seen, "/usr/share/xray/adlist.dat");
        remember_path(paths, seen, "/etc/xray/adlist.dat");
        remember_path(paths, seen, "/etc/forkop/list-cache/xray/adlist.dat");
    }
    let url = "";
    try {
        url = rulesets.community_url(name);
    }
    catch (e2) {
        url = "";
    }
    remember_path(paths, seen, cached_url_file(url));
    let text_ready = false;
    let kept = [];
    for (let path in paths) {
        if (compressed_ruleset(path) || binary_blob(path))
            continue;
        text_ready = true;
        push(kept, path);
    }
    if (text_ready)
        return kept;
    return paths;
}

function scan_paths(paths, host, label) {
    let saw_text = false;
    let opaque = false;
    let large = false;
    for (let path in paths) {
        let found = searchable_hit(path, host);
        if (found == "opaque") {
            opaque = true;
            continue;
        }
        if (found == "large") {
            large = true;
            continue;
        }
        if (found == null)
            continue;
        saw_text = true;
        if (found != "")
            return { hit: found };
    }
    if (!saw_text && large)
        return { uncertain: "large", label: label };
    if (!saw_text && opaque)
        return { uncertain: "missing", label: label };
    return null;
}

function reference_file(reference) {
    reference = trim(reference);
    if (reference == "")
        return "";
    if (substr(reference, 0, 1) == "/")
        return existing_file(reference);
    return cached_url_file(reference);
}

function inline_hit(section, host) {
    for (let value in option_items(section, "domain")) {
        value = replace(value, /^full:/, "");
        if (value == host)
            return { reason_kind: "domain", reason_value: value };
    }
    for (let key in [ "domain_suffix", "domain_suffix_text" ]) {
        for (let value in option_items(section, key)) {
            value = replace(value, /^domain:/, "");
            for (let name in suffix_names(host))
                if (value == name)
                    return { reason_kind: "suffix", reason_value: value };
        }
    }
    for (let key in [ "domain_keyword", "domain_keyword_text" ]) {
        for (let value in option_items(section, key)) {
            value = replace(value, /^keyword:/, "");
            if (length(value) >= 2 && index(host, value) >= 0)
                return { reason_kind: "keyword", reason_value: value };
        }
    }
    for (let key in [ "domain_regex", "domain_regex_text" ]) {
        for (let value in option_items(section, key)) {
            value = replace(value, /^regexp:/, "");
            value = replace(value, /^regex:/, "");
            let ok = false;
            try {
                ok = match(host, regexp(value)) != null;
            }
            catch (e) {
                ok = false;
            }
            if (ok)
                return { reason_kind: "regex", reason_value: value };
        }
    }
    return null;
}

function list_hit(section, host) {
    let missing = "";
    let large = "";
    for (let name in connections.community_lists(section)) {
        let paths = community_paths(name);
        if (length(paths) == 0) {
            if (missing == "")
                missing = name;
            continue;
        }
        let scanned = scan_paths(paths, host, name);
        if (scanned == null)
            continue;
        if (scanned.hit != null)
            return { reason_kind: "community", reason_value: name };
        if (scanned.uncertain == "large" && large == "")
            large = name;
        else if (scanned.uncertain == "missing" && missing == "")
            missing = name;
    }
    let refs = [];
    for (let reference in connections.rule_sets(section))
        push(refs, reference);
    for (let reference in connections.rule_sets_with_subnets(section))
        push(refs, reference);
    for (let reference in raw_items(section, "domain_ip_lists"))
        push(refs, reference);
    for (let reference in refs) {
        let path = reference_file(reference);
        if (path == "") {
            if (missing == "")
                missing = reference;
            continue;
        }
        let scanned = scan_paths([ path ], host, reference);
        if (scanned == null)
            continue;
        if (scanned.hit != null)
            return { reason_kind: "list", reason_value: reference };
        if (scanned.uncertain == "large" && large == "")
            large = reference;
        else if (scanned.uncertain == "missing" && missing == "")
            missing = reference;
    }
    if (large != "")
        return { reason_kind: "large", reason_value: large, uncertain: true };
    if (missing != "")
        return { reason_kind: "missing", reason_value: missing, uncertain: true };
    return null;
}

function section_hit(section, host) {
    let inline = inline_hit(section, host);
    if (inline != null)
        return inline;
    return list_hit(section, host);
}

function source_limited(section) {
    return length(option_items(section, "source_ip_cidr")) > 0;
}

function flag_on(value) {
    value = lc(trim(as_string(value)));
    return value == "1" || value == "true" || value == "yes" || value == "on";
}

function dns_mode_of(section) {
    return lc(trim(as_string(section.dns_answer))) == "route" ? "route" : "real";
}

function section_label_of(section) {
    let label = trim(section.label);
    if (label == "")
        label = as_string(section[".name"]);
    return label;
}

function detour_label(section) {
    if (!flag_on(section.dns_detour_enabled))
        return "";
    let name = trim(as_string(section.dns_detour_section));
    if (name == "")
        return "";
    for (let item in uci_core.section_objects("forkop", "section")) {
        item = type(item) == "object" ? item : {};
        if (as_string(item[".name"]) != name)
            continue;
        return section_label_of(item);
    }
    return name;
}

function remember_dns(result, section, hit) {
    result.dns_mode = dns_mode_of(section);
    result.dns_label = section_label_of(section);
    result.dns_server = trim(as_string(section.dns_server));
    result.dns_type = lc(trim(as_string(section.dns_type)));
    if (result.dns_type == "")
        result.dns_type = "udp";
    result.dns_detour = detour_label(section);
    result.dns_source_limited = source_limited(section);
    result.dns_reason_kind = hit.reason_kind;
    result.dns_reason_value = hit.reason_value;
}

function forced_devices(section) {
    let devices = [];
    let seen = {};
    for (let key in [ "fully_routed_ips", "fully_routed_ips_text" ]) {
        for (let item in raw_items(section, key)) {
            item = trim(item);
            if (item == "" || seen[item])
                continue;
            seen[item] = true;
            push(devices, item);
        }
    }
    return devices;
}

function hex_value(text) {
    text = lc(trim(text));
    if (text == "" || length(text) > 4)
        return -1;
    let digits = "0123456789abcdef";
    let value = 0;
    let i = 0;
    while (i < length(text)) {
        let pos = index(digits, substr(text, i, 1));
        if (pos < 0)
            return -1;
        value = value * 16 + pos;
        i++;
    }
    return value;
}

function ipv4_number(text) {
    let parts = split(trim(text), ".");
    if (length(parts) != 4)
        return -1;
    let value = 0;
    for (let part in parts) {
        if (match(part, /^[0-9]+$/) == null)
            return -1;
        let n = int(part);
        if (n < 0 || n > 255)
            return -1;
        value = value * 256 + n;
    }
    return value;
}

function ipv6_hextets(text) {
    text = lc(trim(text));
    let zone = index(text, "%");
    if (zone >= 0)
        text = substr(text, 0, zone);
    if (text == "" || index(text, ".") >= 0)
        return [];
    let dbl = index(text, "::");
    let head = [];
    let tail = [];
    if (dbl >= 0) {
        if (index(substr(text, dbl + 2), "::") >= 0)
            return [];
        let left = dbl == 0 ? "" : substr(text, 0, dbl);
        let right = substr(text, dbl + 2);
        if (left != "")
            head = split(left, ":");
        if (right != "")
            tail = split(right, ":");
    }
    else
        head = split(text, ":");
    let missing = dbl >= 0 ? 8 - length(head) - length(tail) : 0;
    if (missing < 0 || (dbl < 0 && length(head) != 8))
        return [];
    let out = [];
    for (let part in head) {
        let n = hex_value(part);
        if (n < 0)
            return [];
        push(out, n);
    }
    let i = 0;
    while (i < missing) {
        push(out, 0);
        i++;
    }
    for (let part in tail) {
        let n = hex_value(part);
        if (n < 0)
            return [];
        push(out, n);
    }
    if (length(out) != 8)
        return [];
    return out;
}

function ipv4_in_cidr(ip, rule) {
    let slash = index(rule, "/");
    let base = slash >= 0 ? trim(substr(rule, 0, slash)) : trim(rule);
    let bits = 32;
    if (slash >= 0) {
        let raw = trim(substr(rule, slash + 1));
        if (match(raw, /^[0-9]+$/) == null)
            return false;
        bits = int(raw);
    }
    let host = ipv4_number(ip);
    let network = ipv4_number(base);
    if (host < 0 || network < 0 || bits < 0 || bits > 32)
        return false;
    if (bits == 0)
        return true;
    let shift = 32 - bits;
    return (host >> shift) == (network >> shift);
}

function ipv6_in_cidr(ip, rule) {
    let slash = index(rule, "/");
    let base = slash >= 0 ? trim(substr(rule, 0, slash)) : trim(rule);
    let bits = 128;
    if (slash >= 0) {
        let raw = trim(substr(rule, slash + 1));
        if (match(raw, /^[0-9]+$/) == null)
            return false;
        bits = int(raw);
    }
    let host = ipv6_hextets(ip);
    let network = ipv6_hextets(base);
    if (length(host) != 8 || length(network) != 8 || bits < 0 || bits > 128)
        return false;
    let i = 0;
    while (i < 8) {
        let take = bits - i * 16;
        if (take >= 16) {
            if (host[i] != network[i])
                return false;
        }
        else if (take > 0) {
            let shift = 16 - take;
            return (host[i] >> shift) == (network[i] >> shift);
        }
        else
            return true;
        i++;
    }
    return true;
}

function normalize_device(value) {
    value = trim(value);
    if (value == "")
        return "";
    let slash = index(value, "/");
    if (slash >= 0) {
        let bits = trim(substr(value, slash + 1));
        if (bits != "32" && bits != "128")
            return "";
        value = trim(substr(value, 0, slash));
    }
    if (ipv4_number(value) >= 0)
        return value;
    if (length(ipv6_hextets(value)) == 8)
        return lc(value);
    return "";
}

function address_in_any(ip, items) {
    if (ip == "")
        return false;
    let v6 = index(ip, ":") >= 0;
    for (let item in items) {
        item = trim(item);
        if (item == "")
            continue;
        if ((index(item, ":") >= 0) != v6)
            continue;
        if (v6) {
            if (ipv6_in_cidr(ip, item))
                return true;
        }
        else if (ipv4_in_cidr(ip, item))
            return true;
    }
    return false;
}

function section_addresses(section, keys) {
    let items = [];
    for (let key in keys)
        for (let item in raw_items(section, key))
            push(items, item);
    return items;
}

function lookup_domain_work(raw, device_raw) {
    let host = normalize_domain(raw);
    if (host == "")
        return { status: "bad", domain: trim(raw) };
    let device = normalize_device(device_raw);

    let result = {
        status: "none",
        domain: host,
        device: device,
        via: "",
        section_id: "",
        label: "",
        action: "",
        reason_kind: "",
        reason_value: "",
        source_limited: false,
        fallback_status: "",
        fallback_label: "",
        fallback_action: "",
        fallback_reason_kind: "",
        fallback_reason_value: "",
        dns_mode: "",
        dns_label: "",
        dns_server: "",
        dns_type: "",
        dns_detour: "",
        dns_source_limited: false,
        dns_via: "",
        dns_reason_kind: "",
        dns_reason_value: ""
    };

    let dns_seen = false;
    let forced = [];
    let domain_closed = false;
    function with_forced(value) {
        value.forced = device == "" ? forced : [];
        return value;
    }
    function take_forced(section) {
        if (device != "")
            return;
        if (!routing_action(connections.action(section)))
            return;
        let devices = forced_devices(section);
        if (length(devices) == 0)
            return;
        push(forced, {
            label: section_label_of(section),
            action: connections.action(section),
            devices: devices
        });
    }
    function fill_match(section, action, kind, value, via) {
        result.status = "match";
        result.via = via;
        result.section_id = as_string(section[".name"]);
        result.label = section_label_of(section);
        result.action = action;
        result.reason_kind = kind;
        result.reason_value = value;
        result.source_limited = device == "" && source_limited(section);
    }
    if (device != "") {
        let temporary = null;
        try {
            temporary = device_route.active_for(device);
        }
        catch (e_temp) {
            temporary = null;
        }
        if (temporary != null) {
            result.status = "match";
            result.via = "full";
            result.section_id = temporary.section;
            result.label = temporary.section_label != "" ? temporary.section_label : temporary.section;
            result.action = temporary.action;
            result.reason_kind = "temporary";
            return with_forced(result);
        }
    }
    for (let section in uci_core.section_objects("forkop", "section")) {
        section = type(section) == "object" ? section : {};
        if (as_string(section.enabled) == "0")
            continue;
        if (device != "" && address_in_any(device, section_addresses(section, [ "excluded_source_ips", "excluded_source_ips_text" ])))
            continue;
        let action = connections.action(section);
        let fully = device != "" && address_in_any(device, section_addresses(section, [ "fully_routed_ips", "fully_routed_ips_text" ]));
        let source_ok = device == "" || !source_limited(section) ||
            address_in_any(device, section_addresses(section, [ "source_ip_cidr", "source_ip_cidr_text" ]));
        if (routing_action(action) && fully) {
            fill_match(section, action, "full", "", "full");
            return with_forced(result);
        }
        if (action == "dns") {
            if (device != "" && !source_ok && !fully)
                continue;
            let dns_hit = null;
            try {
                dns_hit = section_hit(section, host);
            }
            catch (e) {
                dns_hit = null;
            }
            if (dns_hit == null && !fully)
                continue;
            if (dns_hit != null && dns_hit.uncertain && source_ok) {
                if (result.status == "none") {
                    result.status = "unknown";
                    result.via = "dns";
                    result.section_id = as_string(section[".name"]);
                    result.label = section_label_of(section);
                    result.action = "dns";
                    result.reason_kind = dns_hit.reason_kind;
                    result.reason_value = dns_hit.reason_value;
                }
                return with_forced(result);
            }
            if (dns_hit != null && dns_hit.uncertain)
                continue;
            if (dns_seen)
                continue;
            if (dns_hit == null)
                dns_hit = { reason_kind: "full", reason_value: "", uncertain: false };
            dns_seen = true;
            remember_dns(result, section, dns_hit);
            result.dns_via = fully ? "full" : "domain";
            if (result.section_id == "")
                result.section_id = as_string(section[".name"]);
            if (result.dns_mode == "real" && dns_hit.reason_kind != "full") {
                result.status = "dns";
                result.via = "dns";
                result.section_id = as_string(section[".name"]);
                result.label = result.dns_label;
                result.action = "dns";
                result.reason_kind = dns_hit.reason_kind;
                result.reason_value = dns_hit.reason_value;
                result.source_limited = device == "" && result.dns_source_limited;
                if (device != "" || !result.dns_source_limited)
                    domain_closed = true;
            }
            continue;
        }
        if (!routing_action(action))
            continue;
        if (domain_closed) {
            take_forced(section);
            continue;
        }
        let hit = null;
        try {
            hit = section_hit(section, host);
        }
        catch (e2) {
            hit = null;
        }
        if (hit == null) {
            take_forced(section);
            continue;
        }
        if (device != "" && !source_ok)
            continue;
        let label = section_label_of(section);
        if (hit.uncertain) {
            if (result.status == "none") {
                result.status = "unknown";
                result.via = "domain";
                result.section_id = as_string(section[".name"]);
                result.label = label;
                result.action = action;
                result.reason_kind = hit.reason_kind;
                result.reason_value = hit.reason_value;
            }
            return with_forced(result);
        }
        if (device != "" && (result.status == "none" || result.status == "dns")) {
            fill_match(section, action, hit.reason_kind, hit.reason_value, "domain");
            return with_forced(result);
        }
        if (result.status == "dns") {
            result.fallback_status = "match";
            result.fallback_label = label;
            result.fallback_action = action;
            result.fallback_reason_kind = hit.reason_kind;
            result.fallback_reason_value = hit.reason_value;
            return with_forced(result);
        }
        if (result.status == "none") {
            fill_match(section, action, hit.reason_kind, hit.reason_value, "domain");
            if (!result.source_limited)
                return with_forced(result);
            take_forced(section);
            continue;
        }
        result.fallback_status = "match";
        result.fallback_label = label;
        result.fallback_action = action;
        result.fallback_reason_kind = hit.reason_kind;
        result.fallback_reason_value = hit.reason_value;
        return with_forced(result);
    }

    if (device != "" && result.status == "none" && result.dns_mode == "real") {
        result.status = "dns";
        result.via = "dns";
        result.label = result.dns_label;
        result.action = "dns";
    }
    return with_forced(result);
}

function lookup_domain(raw, device_raw) {
    let result = null;
    try {
        result = lookup_domain_work(raw, device_raw);
    }
    catch (e) {
        let host = normalize_domain(raw);
        result = host == "" ? { status: "bad", domain: trim(raw) } : {
            status: "none",
            domain: host
        };
    }
    cleanup_decompiled();
    return result;
}

function module_exports() {
    return { lookup_domain, normalize_domain, token_found };
}

if ((sourcepath(1) != null && sourcepath(1) != "") || ARGV[0] == null)
    return module_exports();

let mode = ARGV[0] || "";
if (mode == "lookup")
    print(sprintf("%J", lookup_domain(ARGV[1] || "", ARGV[2] || "")), "\n");
else {
    warn("Usage: diagnostics/domain_lookup.uc lookup <domain> [device-ip]\n");
    exit(1);
}
