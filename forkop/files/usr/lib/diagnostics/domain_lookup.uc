#!/usr/bin/env ucode

let fs = require("fs");
let uci_core = require("core.uci");
let connections = require("config.connections");
let geodata = require("xray.geodata");
let rulesets = require("singbox.rulesets");
let list_cache = require("routing.list_cache");
let device_route = require("service.device_route");

let dat_bytes_cache = {};

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
    let st = fs.stat(path);
    let safe = replace(path, /[^A-Za-z0-9]/g, "_");
    if (length(safe) > 80)
        safe = substr(safe, length(safe) - 80);
    let out = "/tmp/forkop-stage/lookup-srs-" + safe + "-" + as_string(st != null ? st.size || 0 : 0) + "-" + as_string(st != null ? st.mtime || 0 : 0) + ".json";
    if (fs.stat(out) != null && int(fs.stat(out).size || 0) > 0) {
        push(decompiled_files, out);
        return out;
    }
    let command = shell_quote(bin) + " rule-set decompile " + shell_quote(path) + " -o " + shell_quote(out) + " >/dev/null 2>&1";
    if (system(command) != 0 || fs.stat(out) == null)
        return "";
    push(decompiled_files, out);
    return out;
}

function singbox_primary() {
    try {
        let engine = require("core.engine");
        return engine.is_singbox_primary() == true;
    }
    catch (e) {
        return true;
    }
}

function matcher_covers(value, host) {
    value = trim(value);
    if (value == "")
        return false;
    if (index(value, "full:") == 0)
        return lc(trim(substr(value, 5))) == host;
    if (index(value, "keyword:") == 0) {
        let body = lc(trim(substr(value, 8)));
        return length(body) >= 2 && index(host, body) >= 0;
    }
    if (index(value, "regexp:") == 0 || index(value, "regex:") == 0) {
        let body = index(value, "regexp:") == 0 ? substr(value, 7) : substr(value, 6);
        let matched = false;
        try {
            matched = match(host, regexp(body)) != null;
        }
        catch (e) {
            matched = false;
        }
        return matched;
    }
    if (index(value, "geosite:") == 0 || index(value, "ext:") == 0)
        return false;
    if (index(value, "domain:") == 0)
        value = substr(value, 7);
    value = lc(trim(value));
    for (let name in suffix_names(host))
        if (value == name)
            return true;
    return false;
}

function xray_ruleset_hit(path, host) {
    let matchers = null;
    try {
        matchers = geodata.decompile_srs(path);
    }
    catch (e) {
        matchers = null;
    }
    if (type(matchers) != "object" || matchers.ok != true) {
        let limit = 524288;
        try {
            if (geodata.MAX_DECOMPILE_BYTES != null)
                limit = int(geodata.MAX_DECOMPILE_BYTES);
        }
        catch (e2) {
        }
        let st = fs.stat(path);
        let size = st == null ? 0 : int(st.size || 0);
        if (size > limit)
            return "large";
        // The file is in the reserve, but Xray did not apply it.
        return "";
    }
    let domains = type(matchers.domains) == "array" ? matchers.domains : [];
    for (let value in domains) {
        if (matcher_covers(as_string(value), host))
            return as_string(value);
    }
    return "";
}

function searchable_hit(path, host) {
    try {
        if (binary_blob(path) && !compressed_ruleset(path))
            return "opaque";
        if (!compressed_ruleset(path))
            return file_hit(path, host);
        if (!singbox_primary())
            return xray_ruleset_hit(path, host);
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

function one_path(path) {
    let paths = [];
    let seen = {};
    remember_path(paths, seen, path);
    return paths;
}

function singbox_community_paths(name) {
    let url = "";
    try {
        url = rulesets.community_url(name);
    }
    catch (e) {
        url = "";
    }
    return one_path(cached_url_file(url));
}

function ads_paths() {
    let paths = [];
    let seen = {};
    let extra = trim(getenv("FORKOP_ADLIST_DAT") || "");
    if (extra != "")
        remember_path(paths, seen, extra);
    remember_path(paths, seen, "/usr/share/xray/adlist.dat");
    remember_path(paths, seen, "/etc/xray/adlist.dat");
    remember_path(paths, seen, "/etc/forkop/list-cache/xray/adlist.dat");
    return paths;
}

function finish_scanned(scanned, dat, name, missing, large) {
    if (scanned != null && scanned.hit != null)
        return { hit: name, missing: missing, large: large };
    let text_miss = scanned != null && scanned.miss;
    if (dat == "hit")
        return { hit: name, missing: missing, large: large };
    if (dat == "miss" || text_miss)
        return { hit: "", missing: missing, large: large };
    if (dat == "large" || (scanned != null && scanned.uncertain == "large")) {
        if (large == "")
            large = name;
        return { hit: "", missing: missing, large: large };
    }
    if (missing == "")
        missing = name;
    return { hit: "", missing: missing, large: large };
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
    if (saw_text)
        return { miss: true };
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
        let kind = "suffix";
        let body = value;
        if (index(value, "full:") == 0) {
            kind = "domain";
            body = substr(value, 5);
        }
        else if (index(value, "keyword:") == 0) {
            kind = "keyword";
            body = substr(value, 8);
        }
        else if (index(value, "regex:") == 0 || index(value, "regexp:") == 0) {
            kind = "regex";
            body = index(value, "regex:") == 0 ? substr(value, 6) : substr(value, 7);
        }
        else if (index(value, "domain:") == 0)
            body = substr(value, 7);
        body = trim(body);
        if (body == "")
            continue;
        if (kind == "domain") {
            if (body == host)
                return { reason_kind: "domain", reason_value: body };
            continue;
        }
        if (kind == "suffix") {
            for (let name in suffix_names(host))
                if (body == name)
                    return { reason_kind: "suffix", reason_value: body };
            continue;
        }
        if (kind == "keyword") {
            if (length(body) >= 2 && index(host, body) >= 0)
                return { reason_kind: "keyword", reason_value: body };
            continue;
        }
        let matched = false;
        try {
            matched = match(host, regexp(body)) != null;
        }
        catch (e) {
            matched = false;
        }
        if (matched)
            return { reason_kind: "regex", reason_value: body };
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

function read_varint(data, i, end) {
    let value = 0;
    let mul = 1;
    let guard = 0;
    while (i < end && guard < 5) {
        let byte = ord(substr(data, i, 1));
        i++;
        value += (byte & 127) * mul;
        if (byte < 128)
            return [ value, i ];
        mul *= 128;
        guard++;
    }
    return null;
}

function domain_value_hits(kind, value, host) {
    value = lower(value);
    if (value == "" || host == "")
        return false;
    if (kind == 3)
        return value == host;
    if (kind == 2)
        return host == value ||
            (length(host) > length(value) + 1 &&
                substr(host, length(host) - length(value) - 1, 1) == "." &&
                substr(host, length(host) - length(value)) == value);
    if (kind == 1) {
        let ok = false;
        try {
            ok = match(host, regexp(value)) != null;
        }
        catch (e) {
            ok = false;
        }
        return ok;
    }
    return length(value) >= 2 && index(host, value) >= 0;
}

function domain_message_hits(data, start, end, host) {
    let kind = 0;
    let value = "";
    let i = start;
    while (i < end) {
        let tag = ord(substr(data, i, 1));
        i++;
        let field = tag >> 3;
        let wire = tag & 7;
        if (wire == 0) {
            let parsed = read_varint(data, i, end);
            if (parsed == null)
                return null;
            if (field == 1)
                kind = parsed[0];
            i = parsed[1];
            continue;
        }
        if (wire != 2)
            return null;
        let parsed = read_varint(data, i, end);
        if (parsed == null)
            return null;
        let size = parsed[0];
        i = parsed[1];
        if (size < 0 || i + size > end)
            return null;
        if (field == 2)
            value = substr(data, i, size);
        i += size;
    }
    return domain_value_hits(kind, value, host);
}

function dat_code_hits(data, start, end, code, host) {
    let i = start;
    let wanted = lower(code);
    let matched = false;
    let saw_code = false;
    while (i < end) {
        let tag = ord(substr(data, i, 1));
        i++;
        let field = tag >> 3;
        let wire = tag & 7;
        if (wire == 0) {
            let parsed = read_varint(data, i, end);
            if (parsed == null)
                return null;
            i = parsed[1];
            continue;
        }
        if (wire != 2)
            return null;
        let parsed = read_varint(data, i, end);
        if (parsed == null)
            return null;
        let size = parsed[0];
        i = parsed[1];
        if (size < 0 || i + size > end)
            return null;
        if (field == 1) {
            saw_code = true;
            matched = lower(substr(data, i, size)) == wanted;
        }
        else if (field == 2 && matched) {
            let hit = domain_message_hits(data, i, i + size, host);
            if (hit == null)
                return null;
            if (hit)
                return true;
        }
        i += size;
    }
    if (!saw_code)
        return null;
    return false;
}

function dat_bytes(path) {
    let cached = dat_bytes_cache[path];
    if (cached != null)
        return cached;
    let data = "";
    try {
        data = as_string(fs.readfile(path));
    }
    catch (e) {
        data = "";
    }
    dat_bytes_cache[path] = data;
    return data;
}

function code_marker(code) {
    let n = length(code);
    if (n <= 0 || n >= 16384)
        return "";
    if (n < 128)
        return sprintf("%c%c", 10, n) + code;
    return sprintf("%c%c%c", 10, (n & 127) | 128, n >> 7) + code;
}

// The code field is the start of one geosite entry. The bytes in front of it
// are that entry's length, so the other lists in the file are not walked.
function message_span(data, code_at, n) {
    if (code_at < 2 || code_at >= n)
        return null;
    let last = code_at - 1;
    if (ord(substr(data, last, 1)) >= 128)
        return null;
    let first = last;
    let guard = 0;
    while (first > 0 && guard < 4 && ord(substr(data, first - 1, 1)) >= 128) {
        first--;
        guard++;
    }
    if (first < 1 || ord(substr(data, first - 1, 1)) != 10)
        return null;
    let parsed = read_varint(data, first, code_at);
    if (parsed == null || parsed[1] != code_at)
        return null;
    let size = parsed[0];
    if (size < 2 || code_at + size > n)
        return null;
    let after = code_at + size;
    if (after < n) {
        let next = ord(substr(data, after, 1));
        if (next != 10 && next != 0)
            return null;
    }
    return [ code_at, after ];
}

function dat_locate(data, code) {
    let marker = code_marker(lower(code));
    if (marker == "")
        return null;
    let from = 0;
    let n = length(data);
    let guard = 0;
    while (from < n && guard < 6) {
        let hay = from == 0 ? data : substr(data, from);
        let at = index(hay, marker);
        if (at < 0)
            return null;
        let pos = from + at;
        let span = message_span(data, pos, n);
        if (span != null)
            return span;
        from = pos + 1;
        guard++;
    }
    return null;
}

function dat_walk_status(data, code, host) {
    let n = length(data);
    let i = 0;
    let entries = 0;
    while (i < n && entries < 20000) {
        if (ord(substr(data, i, 1)) != 10)
            break;
        i++;
        let parsed = read_varint(data, i, n);
        if (parsed == null)
            return "opaque";
        let size = parsed[0];
        i = parsed[1];
        if (size < 2 || i + size > n)
            return "opaque";
        let hit = dat_code_hits(data, i, i + size, code, host);
        if (hit == null)
            return "opaque";
        if (hit)
            return "hit";
        i += size;
        entries++;
    }
    return i >= n || entries > 0 ? "miss" : "opaque";
}

function dat_file_status(path, code, host) {
    let st = fs.stat(path);
    if (st == null || int(st.size || 0) <= 0)
        return "opaque";
    let data = dat_bytes(path);
    if (data == "")
        return "opaque";
    let n = length(data);
    if (n < 2 || ord(substr(data, 0, 1)) != 10)
        return "opaque";
    let located = dat_locate(data, code);
    if (located != null) {
        let hit = dat_code_hits(data, located[0], located[1], code, host);
        if (hit == null)
            return "opaque";
        return hit ? "hit" : "miss";
    }
    // The code is not in the file. Walking every other list is what made the
    // check run until the page gave up.
    if (n > 262144)
        return "miss";
    return dat_walk_status(data, code, host);
}

function dat_list_status(name, host) {
    let refs = [];
    try {
        refs = geodata.community_dat_refs(name);
    }
    catch (e) {
        refs = [];
    }
    if (type(refs) != "array" || length(refs) == 0)
        return "none";
    let opened = false;
    let opaque = false;
    let large = false;
    for (let ref in refs) {
        ref = type(ref) == "object" ? ref : {};
        let status = dat_file_status(as_string(ref.path), as_string(ref.code), host);
        if (status == "hit")
            return "hit";
        if (status == "miss")
            opened = true;
        else if (status == "large")
            large = true;
        else
            opaque = true;
    }
    if (opened)
        return "miss";
    if (large)
        return "large";
    if (opaque)
        return "opaque";
    return "none";
}

function list_hit(section, host) {
    let missing = "";
    let large = "";
    for (let name in connections.community_lists(section)) {
        if (singbox_primary()) {
            let paths = singbox_community_paths(name);
            let scanned = length(paths) > 0 ? scan_paths(paths, host, name) : null;
            let step = finish_scanned(scanned, "none", name, missing, large);
            if (step.hit != "")
                return { reason_kind: "community", reason_value: name };
            missing = step.missing;
            large = step.large;
            continue;
        }
        let source = { kind: "none", path: "" };
        try {
            source = geodata.community_xray_source(name);
        }
        catch (e_src) {
            source = { kind: "none", path: "" };
        }
        if (type(source) != "object")
            source = { kind: "none", path: "" };
        let kind = as_string(source.kind);
        let paths = [];
        let dat = "none";
        if (kind == "file")
            paths = one_path(as_string(source.path));
        else if (kind == "ads")
            paths = ads_paths();
        if (kind == "dat" || kind == "ads")
            dat = dat_list_status(name, host);
        let scanned = length(paths) > 0 ? scan_paths(paths, host, name) : null;
        let step = finish_scanned(scanned, dat, name, missing, large);
        if (step.hit != "")
            return { reason_kind: "community", reason_value: name };
        missing = step.missing;
        large = step.large;
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
        if (scanned == null || scanned.miss)
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
        dns_reason_value: "",
        ports: ""
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
function section_ports(section) {
    let values = [];
    let seen = {};
    for (let key in [ "ports", "ports_text" ]) {
        for (let item in raw_items(section, key)) {
            if (seen[item])
                continue;
            seen[item] = true;
            push(values, item);
        }
    }
    let text = "";
    for (let item in values) {
        if (text != "")
            text += ", ";
        text += item;
    }
    return text;
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
        if (via == "domain" || via == "dns")
            result.ports = section_ports(section);
    }
    let route_locked = false;
    if (device != "") {
        let settings_items = [];
        for (let settings in uci_core.section_objects("forkop", "settings")) {
            settings = type(settings) == "object" ? settings : {};
            for (let item in section_addresses(settings, [ "routing_excluded_ips", "routing_excluded_ips_text" ]))
                push(settings_items, item);
        }
        if (address_in_any(device, settings_items)) {
            result.status = "excluded";
            result.via = "settings";
            result.reason_kind = "excluded";
            return with_forced(result);
        }
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
            route_locked = true;
        }
    }
    for (let section in uci_core.section_objects("forkop", "section")) {
        section = type(section) == "object" ? section : {};
        if (as_string(section.enabled) == "0")
            continue;
        if (device != "" && address_in_any(device, section_addresses(section, [ "excluded_source_ips", "excluded_source_ips_text" ])))
            continue;
        let action = connections.action(section);
        if (route_locked && action != "dns")
            continue;
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
                if (route_locked)
                    continue;
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
            if (!route_locked && result.dns_mode == "real" && dns_hit.reason_kind != "full") {
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

    if (route_locked)
        return with_forced(result);
    if (device != "" && result.status == "none" && result.dns_mode == "real") {
        result.status = "dns";
        result.via = "dns";
        result.label = result.dns_label;
        result.action = "dns";
    }
    return with_forced(result);
}

function positive_speed(section, key) {
    let raw = trim(as_string(section[key]));
    if (match(raw, /^[0-9]+$/) == null)
        return 0;
    let value = int(raw);
    if (value < 1 || value > 10000)
        return 0;
    return value;
}

function speeds_of(section) {
    let down = positive_speed(section, "speed_limit_down_mbit");
    let up = positive_speed(section, "speed_limit_up_mbit");
    if (down > 0)
        return { down: down, up: up };
    if (up > 0)
        return { down: 0, up: up };
    let shared = positive_speed(section, "speed_limit_mbit");
    return { down: shared, up: shared };
}

function limit_on(section) {
    if (type(section) != "object")
        return false;
    if (as_string(section.enabled) == "0")
        return false;
    if (as_string(section.speed_limit_enabled) == "0")
        return false;
    let speeds = speeds_of(section);
    return speeds.down > 0 || speeds.up > 0;
}

function decorate_limit(result) {
    if (type(result) != "object")
        return result;
    result.limit = "none";
    let id = as_string(result.section_id);
    if (id == "" || result.status == "none" || result.status == "bad" || result.status == "unknown")
        return result;
    let map = {};
    for (let section in uci_core.section_objects("forkop", "section")) {
        section = type(section) == "object" ? section : {};
        let name = as_string(section[".name"]);
        if (name != "")
            map[name] = section;
    }
    let section = map[id];
    if (!limit_on(section))
        return result;
    let speeds = speeds_of(section);
    result.limit_down = speeds.down;
    result.limit_up = speeds.up;
    let place = as_string(section.speed_limit_place) == "egress" ? "egress" : "ingress";
    result.limit_place = place;
    if (place == "ingress") {
        result.limit = (result.via == "full" || result.reason_kind == "temporary" || result.reason_kind == "full") ? "holds" : "domains";
        return result;
    }
    let hop = id;
    let seen = {};
    let guard = 0;
    while (guard < 8) {
        guard++;
        if (seen[hop])
            break;
        seen[hop] = true;
        let current = map[hop];
        if (type(current) != "object" || as_string(current.outbound_detour_enabled) != "1")
            break;
        let next = trim(as_string(current.outbound_detour_section));
        if (next == "" || type(map[next]) != "object")
            break;
        hop = next;
    }
    if (hop == id) {
        result.limit = "holds";
        return result;
    }
    let target = map[hop];
    result.limit = "cascade";
    let label = trim(as_string(target.label));
    result.limit_via = label != "" ? label : hop;
    result.limit_via_holds = limit_on(target) && as_string(target.speed_limit_place) == "egress";
    return result;
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
    dat_bytes_cache = {};
    return decorate_limit(result);
}

function lookup_job_dir() {
    let dir = trim(getenv("FORKOP_LOOKUP_JOB_DIR") || "");
    if (dir == "")
        dir = "/tmp/forkop-stage/lookup-jobs";
    return dir;
}

function lookup_self_path() {
    let path = sourcepath(0);
    if (path == null || trim(as_string(path)) == "")
        path = "/usr/lib/forkop/diagnostics/domain_lookup.uc";
    return as_string(path);
}

function lookup_lib_dir() {
    let env = trim(getenv("FORKOP_LIB") || "");
    if (env != "")
        return env;
    let self = lookup_self_path();
    let slash = rindex(self, "/");
    if (slash > 0)
        self = substr(self, 0, slash);
    slash = rindex(self, "/");
    if (slash > 0)
        return substr(self, 0, slash);
    return "/usr/lib/forkop";
}

function lookup_job_id() {
    let raw = "";
    try {
        raw = trim(as_string(fs.readfile("/proc/sys/kernel/random/uuid")));
    }
    catch (e) {
        raw = "";
    }
    raw = replace(raw, /[^0-9a-f]/g, "");
    if (raw == "")
        raw = as_string(time());
    return raw;
}

function lookup_pid_alive(pid) {
    pid = trim(as_string(pid));
    if (match(pid, /^[0-9]+$/) == null)
        return false;
    return fs.stat("/proc/" + pid) != null;
}

function lookup_pid_ours(pid) {
    if (!lookup_pid_alive(pid))
        return false;
    let cmd = "";
    try {
        cmd = as_string(fs.readfile("/proc/" + pid + "/cmdline"));
    }
    catch (e) {
        cmd = "";
    }
    return index(cmd, "domain_lookup.uc") >= 0;
}

function lookup_stop_pid(pid) {
    pid = trim(as_string(pid));
    if (!lookup_pid_ours(pid))
        return;
    system("kill -TERM -" + pid + " >/dev/null 2>&1");
    system("kill -TERM " + pid + " >/dev/null 2>&1");
}

function lookup_forget_job(dir, id) {
    if (match(id, /^[0-9a-f]+$/) == null)
        return;
    for (let suffix in [ ".json", ".part", ".pid", ".started" ]) {
        try {
            fs.unlink(dir + "/" + id + suffix);
        }
        catch (e) {
        }
    }
}

function lookup_job_id_from_name(name) {
    name = as_string(name);
    let at = index(name, ".");
    if (at <= 0)
        return "";
    return substr(name, 0, at);
}

function lookup_reap(dir) {
    let names = [];
    try {
        names = fs.lsdir(dir);
    }
    catch (e) {
        names = [];
    }
    if (type(names) != "array")
        return;
    let seen = {};
    for (let name in names) {
        let id = lookup_job_id_from_name(name);
        if (id == "" || seen[id])
            continue;
        seen[id] = true;
        let pid = "";
        try {
            pid = trim(as_string(fs.readfile(dir + "/" + id + ".pid")));
        }
        catch (e2) {
            pid = "";
        }
        lookup_stop_pid(pid);
        lookup_forget_job(dir, id);
    }
}

function lookup_start(raw, device_raw) {
    let dir = lookup_job_dir();
    system("mkdir -p " + shell_quote(dir) + " >/dev/null 2>&1");
    lookup_reap(dir);
    let id = lookup_job_id();
    let out = dir + "/" + id + ".json";
    let part = dir + "/" + id + ".part";
    let pidfile = dir + "/" + id + ".pid";
    let started = dir + "/" + id + ".started";
    try {
        fs.writefile(started, as_string(time()) + "\n");
    }
    catch (e) {
        return { ok: false, failed: true };
    }
    let lib = lookup_lib_dir();
    let inner = "echo $$ > " + shell_quote(pidfile) + "; ucode -L " + shell_quote(lib) + " " +
        shell_quote(lookup_self_path()) + " lookup " + shell_quote(raw) + " " + shell_quote(device_raw) +
        " > " + shell_quote(part) + " && mv " + shell_quote(part) + " " + shell_quote(out);
    let setsid = "/usr/bin/setsid";
    if (fs.stat(setsid) == null)
        setsid = "/bin/setsid";
    let launch = "sh -c " + shell_quote(inner);
    if (fs.stat(setsid) != null)
        launch = shell_quote(setsid) + " " + launch;
    let command = "( " + launch + " >/dev/null 2>&1 & )";
    if (system(command) != 0)
        return { ok: false, failed: true, id: id };
    return { ok: true, running: true, id: id };
}

function lookup_status(id) {
    id = trim(as_string(id));
    if (match(id, /^[0-9a-f]+$/) == null)
        return { failed: true, running: false };
    let dir = lookup_job_dir();
    let out = dir + "/" + id + ".json";
    if (fs.stat(out) != null) {
        let text = "";
        try {
            text = trim(as_string(fs.readfile(out)));
        }
        catch (e) {
            text = "";
        }
        if (text != "") {
            let parsed = null;
            try {
                parsed = json(text);
            }
            catch (e2) {
                parsed = null;
            }
            if (type(parsed) == "object") {
                parsed.running = false;
                lookup_forget_job(dir, id);
                return parsed;
            }
        }
    }
    let pid = "";
    try {
        pid = trim(as_string(fs.readfile(dir + "/" + id + ".pid")));
    }
    catch (e3) {
        pid = "";
    }
    if (lookup_pid_ours(pid))
        return { running: true, id: id };
    let started = 0;
    try {
        started = int(trim(as_string(fs.readfile(dir + "/" + id + ".started"))));
    }
    catch (e4) {
        started = 0;
    }
    if (pid == "" && started > 0 && time() - started < 3)
        return { running: true, id: id };
    lookup_forget_job(dir, id);
    return { failed: true, running: false, id: id };
}

function module_exports() {
    return { lookup_domain, normalize_domain, token_found };
}

if ((sourcepath(1) != null && sourcepath(1) != "") || ARGV[0] == null)
    return module_exports();

let mode = ARGV[0] || "";
if (mode == "lookup")
    print(sprintf("%J", lookup_domain(ARGV[1] || "", ARGV[2] || "")), "\n");
else if (mode == "start")
    print(sprintf("%J", lookup_start(ARGV[1] || "", ARGV[2] || "")), "\n");
else if (mode == "status")
    print(sprintf("%J", lookup_status(ARGV[1] || "")), "\n");
else {
    warn("Usage: diagnostics/domain_lookup.uc lookup <domain> [device-ip]\n");
    exit(1);
}
