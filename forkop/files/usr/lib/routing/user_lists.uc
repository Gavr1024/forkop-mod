#!/usr/bin/env ucode

let fs = require("fs");
let uci_core = require("core.uci");

const CONFIG_NAME = getenv("FORKOP_CONFIG_NAME") || "forkop";
const USER_LIST_DIR = getenv("FORKOP_USER_LIST_DIR") || "/etc/forkop/user-lists";
const USER_LIST_INDEX = USER_LIST_DIR + "/index.json";
const MAX_TEXT = 200000;
const MAX_LINES = 20000;
const LIST_KEYS = [
    "rule_set",
    "rule_set_with_subnets",
    "domain_ip_lists",
    "remote_domain_lists",
    "remote_subnet_lists",
    "local_domain_lists",
    "local_subnet_lists"
];

function as_string(value) {
    return value == null ? "" : "" + value;
}

function trim_string(value) {
    return trim(as_string(value));
}

function shell_quote(value) {
    return "'" + replace(as_string(value), /'/g, "'\\''") + "'";
}

function ensure_dir(path) {
    path = as_string(path);
    if (path == "")
        return false;
    if (fs.stat(path) != null)
        return true;
    return system("mkdir -p " + shell_quote(path) + " >/dev/null 2>&1") == 0;
}

function read_index() {
    let data = fs.readfile(USER_LIST_INDEX);
    if (data == null || data == "")
        return [];
    try {
        let parsed = json(data);
        if (type(parsed) == "object" && type(parsed.items) == "array")
            return parsed.items;
    }
    catch (e) {
        return [];
    }
    return [];
}

function write_index(items) {
    if (!ensure_dir(USER_LIST_DIR))
        return false;
    let result = fs.writefile(USER_LIST_INDEX, sprintf("%J\n", { items: items }));
    if (result == null)
        return false;
    if (type(result) == "boolean" && !result)
        return false;
    return true;
}

function valid_id(value) {
    return match(as_string(value), /^[a-z0-9]{6,32}$/) != null;
}

function path_for(id) {
    if (!valid_id(id))
        return "";
    return USER_LIST_DIR + "/" + id + ".lst";
}

function entry_by_id(id) {
    if (!valid_id(id))
        return null;
    for (let entry in read_index()) {
        entry = type(entry) == "object" ? entry : {};
        if (as_string(entry.id) == id)
            return entry;
    }
    return null;
}

function entry_by_path(path) {
    path = as_string(path);
    if (path == "")
        return null;
    for (let entry in read_index()) {
        entry = type(entry) == "object" ? entry : {};
        if (path_for(as_string(entry.id)) == path)
            return entry;
    }
    return null;
}

function valid_name(value) {
    value = trim_string(value);
    if (value == "" || length(value) > 80)
        return "";
    if (index(value, "\n") >= 0 || index(value, "\r") >= 0)
        return "";
    return value;
}

function normalize_text(text) {
    text = replace(as_string(text), /\r/g, "");
    if (length(text) > MAX_TEXT)
        return { ok: false, error: "too-large" };
    let lines = [];
    let seen = {};
    for (let line in split(text, "\n")) {
        line = trim_string(line);
        if (line == "" || substr(line, 0, 1) == "#")
            continue;
        if (index(line, " ") >= 0 || index(line, "\t") >= 0 || length(line) > 300)
            return { ok: false, error: "bad-line" };
        if (seen[line])
            continue;
        seen[line] = true;
        push(lines, line);
        if (length(lines) > MAX_LINES)
            return { ok: false, error: "too-large" };
    }
    return { ok: true, text: length(lines) > 0 ? join("\n", lines) + "\n" : "" };
}

function write_text(path, text) {
    let result = fs.writefile(path, text);
    if (result == null)
        return false;
    if (type(result) == "boolean" && !result)
        return false;
    let prev = int(trim_string(fs.readfile(path + ".rev") || "0"));
    fs.writefile(path + ".rev", sprintf("%d\n", prev + 1));
    return true;
}

function new_id(items) {
    let stamp = sprintf("%08x%04x", int(clock()[0]) % 4294967296, int(clock()[1] || 0) % 65536);
    let used = {};
    for (let entry in items) {
        entry = type(entry) == "object" ? entry : {};
        used[as_string(entry.id)] = true;
    }
    let n = 0;
    let id = stamp;
    while (used[id] && n < 200) {
        n++;
        id = stamp + sprintf("%02x", n % 256);
    }
    return id;
}

function file_extension(path) {
    let i = length(path) - 1;
    while (i >= 0) {
        let char = substr(path, i, 1);
        if (char == "/")
            return "";
        if (char == ".")
            return substr(path, i + 1);
        i--;
    }
    return "";
}

function safe_list_path(path) {
    path = as_string(path);
    if (substr(path, 0, 1) != "/" || index(path, "..") >= 0 || index(path, "\n") >= 0)
        return false;
    if (path == USER_LIST_INDEX)
        return false;
    let blocked = [
        "/bin/", "/sbin/", "/usr/", "/lib/", "/proc/", "/sys/", "/dev/",
        "/etc/init.d/", "/etc/config/", "/etc/rc.d/", "/etc/passwd", "/etc/shadow"
    ];
    for (let prefix in blocked) {
        if (path == prefix || substr(path, 0, length(prefix)) == prefix)
            return false;
    }
    let ext = file_extension(path);
    return ext == "lst" || ext == "txt" || ext == "list" || ext == "conf";
}

function editable_file(path) {
    if (!safe_list_path(path))
        return false;
    let stat = fs.stat(path);
    if (stat == null)
        return true;
    return stat.type == "file";
}

function valid_remote(value) {
    value = trim_string(value);
    if (value == "" || length(value) > 2000)
        return "";
    if (index(value, " ") >= 0 || index(value, "\n") >= 0 || index(value, "\t") >= 0)
        return "";
    if (substr(value, 0, 7) != "http://" && substr(value, 0, 8) != "https://")
        return "";
    return value;
}

function list_tokens(value) {
    if (type(value) == "array") {
        let tokens = [];
        for (let item in value) {
            item = trim_string(item);
            if (item != "")
                push(tokens, item);
        }
        return tokens;
    }
    value = trim_string(value);
    if (value == "")
        return [];
    let tokens = [];
    for (let item in split(value, /[ \t\r\n]+/))
        if (item != "")
            push(tokens, item);
    return tokens;
}

function reference_used(token) {
    token = trim_string(token);
    if (token == "")
        return false;
    for (let section in uci_core.section_objects(CONFIG_NAME, "section")) {
        section = type(section) == "object" ? section : {};
        for (let key in LIST_KEYS) {
            for (let value in list_tokens(section[key])) {
                if (value == token)
                    return true;
            }
        }
    }
    return false;
}

function store_list_values(section_name, key, values) {
    let path = CONFIG_NAME + "." + section_name + "." + key;
    if (length(values) == 0)
        return uci_core.delete_path(path);
    return uci_core.set(path, values);
}

function read_file_text(path) {
    if (!editable_file(path))
        return null;
    let data = fs.readfile(path);
    if (data == null)
        return "";
    if (length(data) > MAX_TEXT)
        return null;
    return data;
}

function catalog() {
    let items = [];
    for (let entry in read_index()) {
        entry = type(entry) == "object" ? entry : {};
        let id = as_string(entry.id);
        let path = path_for(id);
        if (path == "")
            continue;
        push(items, {
            id: id,
            name: as_string(entry.name),
            path: path
        });
    }
    return items;
}

function meta(item) {
    item = type(item) == "object" ? item : {};
    let path = as_string(item.path);
    let entry = entry_by_path(path);
    if (entry != null)
        return {
            edit: "user",
            user_id: as_string(entry.id),
            name: as_string(entry.name),
            kind: "user"
        };
    if (item.builtin == true || as_string(item.kind) == "community")
        return { edit: "", user_id: "", name: "", kind: "" };
    if (item.local == true && editable_file(path))
        return { edit: "file", user_id: "", name: "", kind: "" };
    if (item.local != true && valid_remote(as_string(item.url)) != "")
        return { edit: "url", user_id: "", name: "", kind: "" };
    return { edit: "", user_id: "", name: "", kind: "" };
}

function item_object(entry) {
    let id = as_string(entry.id);
    let path = path_for(id);
    return {
        id: "user-" + id,
        name: as_string(entry.name),
        kind: "user",
        builtin: false,
        local: true,
        url: path,
        path: path
    };
}

function selected_item(id) {
    id = trim_string(id);
    if (substr(id, 0, 5) == "user-")
        id = substr(id, 5);
    let entry = entry_by_id(id);
    if (entry == null)
        return null;
    return item_object(entry);
}

function unattached(seen_paths) {
    seen_paths = type(seen_paths) == "object" ? seen_paths : {};
    let items = [];
    for (let entry in catalog()) {
        if (seen_paths[as_string(entry.path)] == true)
            continue;
        push(items, item_object(entry));
    }
    return items;
}

function save(id, name, text) {
    name = valid_name(name);
    if (name == "")
        return { ok: false, error: "bad-name" };
    let body = normalize_text(text);
    if (body.ok != true)
        return { ok: false, error: as_string(body.error) };
    if (!ensure_dir(USER_LIST_DIR))
        return { ok: false, error: "missing" };
    let items = read_index();
    let created = false;
    if (trim_string(id) == "") {
        id = new_id(items);
        created = true;
    }
    else if (!valid_id(id) || entry_by_id(id) == null)
        return { ok: false, error: "missing" };
    let path = path_for(id);
    if (path == "" || !write_text(path, body.text))
        return { ok: false, error: "missing" };
    let next = [];
    let found = false;
    for (let entry in items) {
        entry = type(entry) == "object" ? entry : {};
        if (as_string(entry.id) != id) {
            push(next, entry);
            continue;
        }
        found = true;
        push(next, { id: id, name: name });
    }
    if (!found)
        push(next, { id: id, name: name });
    if (!write_index(next))
        return { ok: false, error: "missing" };
    return {
        ok: true,
        id: id,
        name: name,
        path: path,
        created: created,
        used: reference_used(path)
    };
}

function read(id) {
    let entry = entry_by_id(id);
    if (entry == null)
        return { ok: false, error: "missing" };
    let path = path_for(as_string(entry.id));
    let data = fs.readfile(path);
    if (data == null)
        data = "";
    if (length(data) > MAX_TEXT)
        return { ok: false, error: "too-large" };
    return {
        ok: true,
        id: as_string(entry.id),
        kind: "user",
        name: as_string(entry.name),
        text: data,
        path: path
    };
}

function remove_reference(old) {
    old = trim_string(old);
    if (old == "")
        return false;
    let changed = false;
    for (let section in uci_core.section_objects(CONFIG_NAME, "section")) {
        section = type(section) == "object" ? section : {};
        let name = as_string(section[".name"]);
        if (name == "")
            continue;
        for (let key in LIST_KEYS) {
            let values = list_tokens(section[key]);
            let found = false;
            let updated = [];
            for (let value in values) {
                if (value == old)
                    found = true;
                else
                    push(updated, value);
            }
            if (!found)
                continue;
            changed = true;
            store_list_values(name, key, updated);
        }
    }
    if (changed)
        uci_core.commit(CONFIG_NAME);
    return changed;
}

function remove(id) {
    let entry = entry_by_id(id);
    if (entry == null)
        return { ok: false, error: "missing" };
    let path = path_for(as_string(entry.id));
    let next = [];
    for (let item in read_index()) {
        item = type(item) == "object" ? item : {};
        if (as_string(item.id) != as_string(entry.id))
            push(next, item);
    }
    if (!write_index(next))
        return { ok: false, error: "missing" };
    if (path != "") {
        try { fs.unlink(path); } catch (e) { }
        try { fs.unlink(path + ".rev"); } catch (e2) { }
    }
    return { ok: true, id: as_string(entry.id), used: remove_reference(path) };
}

function replace_reference(old, next) {
    old = trim_string(old);
    next = valid_remote(next);
    if (old == "" || next == "" || old == next)
        return { ok: false, error: "bad-url" };
    let changed = false;
    for (let section in uci_core.section_objects(CONFIG_NAME, "section")) {
        section = type(section) == "object" ? section : {};
        let name = as_string(section[".name"]);
        if (name == "")
            continue;
        for (let key in LIST_KEYS) {
            let values = list_tokens(section[key]);
            let found = false;
            let updated = [];
            for (let value in values) {
                if (value == old) {
                    found = true;
                    push(updated, next);
                }
                else
                    push(updated, value);
            }
            if (!found)
                continue;
            changed = true;
            store_list_values(name, key, updated);
        }
    }
    if (!changed)
        return { ok: false, error: "missing" };
    if (!uci_core.commit(CONFIG_NAME))
        return { ok: false, error: "missing" };
    return { ok: true, used: true };
}

function read_custom(item) {
    if (type(item) != "object")
        return { ok: false, error: "missing" };
    let info = meta(item);
    if (info.edit == "user")
        return read(info.user_id);
    if (info.edit == "url")
        return {
            ok: true,
            kind: "url",
            name: as_string(item.name),
            text: as_string(item.url)
        };
    if (info.edit == "file") {
        let path = as_string(item.path);
        if (!safe_list_path(path))
            return { ok: false, error: "missing" };
        let data = fs.readfile(path);
        if (data == null)
            data = "";
        if (length(data) > MAX_TEXT)
            return { ok: false, error: "too-large" };
        return {
            ok: true,
            kind: "file",
            name: as_string(item.name),
            text: data
        };
    }
    return { ok: false, error: "missing" };
}

function save_custom(item, text) {
    if (type(item) != "object")
        return { ok: false, error: "missing" };
    let info = meta(item);
    if (info.edit == "user")
        return save(info.user_id, info.name, text);
    if (info.edit == "url")
        return replace_reference(as_string(item.url), text);
    if (info.edit != "file" || !editable_file(as_string(item.path)))
        return { ok: false, error: "missing" };
    let body = normalize_text(text);
    if (body.ok != true)
        return { ok: false, error: as_string(body.error) };
    if (!write_text(as_string(item.path), body.text))
        return { ok: false, error: "missing" };
    return { ok: true, kind: "file", used: reference_used(as_string(item.path)) };
}

return {
    catalog: catalog,
    meta: meta,
    selected_item: selected_item,
    unattached: unattached,
    save: save,
    read: read,
    remove: remove,
    replace_reference: replace_reference,
    read_custom: read_custom,
    save_custom: save_custom
};
