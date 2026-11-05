#!/usr/bin/env ucode

// sing-box has no idle timeout for TCP. This loop watches the connection list
// and closes a flow whose byte counters stay unchanged for five minutes.

let fs = require("fs");
let uci_core = require("core.uci");
let common = require("core.common");

const CONFIG_NAME = getenv("FORKOP_CONFIG_NAME") || "forkop";
const LIB_DIR = getenv("FORKOP_LIB") || "/usr/lib/forkop";
const RUNTIME_STATE_DIR = getenv("FORKOP_RUNTIME_STATE_DIR") || "/var/run/forkop";
const PID_FILE = getenv("FORKOP_SINGBOX_IDLE_PID_FILE") || RUNTIME_STATE_DIR + "/singbox-idle.pid";
const IDLE_UC = getenv("FORKOP_SINGBOX_IDLE_UC") || LIB_DIR + "/singbox/idle.uc";
const RUNTIME_UC = LIB_DIR + "/singbox/runtime.uc";
const IDLE_LIMIT = 300;
const POLL_SECONDS = 60;

function as_string(value) {
    return value == null ? "" : "" + value;
}

function shell_quote(value) {
    return "'" + replace(as_string(value), /'/g, "'\\''") + "'";
}

function command_from_args(args) {
    let result = [];
    for (let arg in args)
        push(result, shell_quote(arg));
    return join(" ", result);
}

function command_status(command) {
    let status = int(system(command));
    return status > 255 ? int(status / 256) : status;
}

function command_success_from_args(args) {
    return command_status(command_from_args(args) + " >/dev/null 2>&1") == 0;
}

function command_output_from_args(args) {
    let pipe = fs.popen(command_from_args(args), "r");
    if (!pipe)
        return "";
    let data = pipe.read("all");
    let status = pipe.close();
    return status == 0 && data != null ? as_string(data) : "";
}

function now_seconds() {
    return int(clock()[0]);
}

function log_message(message, level) {
    level = as_string(level || "info");
    system("logger -t " + shell_quote("forkop") + " " + shell_quote("[" + level + "] " + as_string(message)) + " >/dev/null 2>&1");
}

function ensure_dir(path) {
    return command_success_from_args([ "mkdir", "-p", path ]);
}

function remove_file(path) {
    try { fs.unlink(as_string(path)); } catch (e) {}
}

function file_first_line(path) {
    let data = fs.readfile(path);
    if (data == null)
        return "";
    return trim(split(as_string(data), "\n")[0]);
}

function process_running(pid) {
    return match(as_string(pid), /^[0-9]+$/) != null && command_success_from_args([ "kill", "-0", pid ]);
}

function settings() {
    return common.object_or_empty(uci_core.get_all(CONFIG_NAME, "settings"));
}

function clash_base_url() {
    let address = trim(command_output_from_args([ "ucode", "-L", LIB_DIR, RUNTIME_UC, "service-listen-address" ]));
    if (address == "" || address == "0.0.0.0")
        address = "127.0.0.1";
    return "http://" + address + ":9090";
}

function curl_args(method, url, extra) {
    let args = [ "curl", "-sS", "--max-time", "3", "-X", method ];
    for (let item in (type(extra) == "array" ? extra : []))
        push(args, item);
    let cfg = settings();
    let secret = trim(as_string(cfg.yacd_secret_key || ""));
    if (secret != "" && (cfg.enable_yacd == "1" || cfg.enable_yacd === true)) {
        push(args, "--header");
        push(args, "Authorization: Bearer " + secret);
    }
    push(args, url);
    return args;
}

function connection_bytes(conn) {
    let upload = int(conn.upload || conn.Upload || 0);
    let download = int(conn.download || conn.Download || 0);
    if (upload < 0)
        upload = 0;
    if (download < 0)
        download = 0;
    return upload + download;
}

function command_output_always(args) {
    let pipe = fs.popen(command_from_args(args), "r");
    if (!pipe)
        return "";
    let data = pipe.read("all");
    pipe.close();
    return data == null ? "" : as_string(data);
}

function close_connection(base, id) {
    let args = curl_args("DELETE", base + "/connections/" + id, [ "-o", "/dev/null", "-w", "%{http_code}" ]);
    let code = trim(command_output_always(args));
    return code == "200" || code == "204" || code == "404";
}

function sweep(seen, base) {
    let raw = command_output_from_args(curl_args("GET", base + "/connections"));
    let parsed = null;
    try { parsed = json(raw); } catch (e) { parsed = null; }
    if (type(parsed) != "object")
        return 0;
    let rows = parsed.connections || parsed.Connections;
    if (type(rows) != "array")
        return 0;

    let now = now_seconds();
    let live = {};
    let closed = 0;
    for (let conn in rows) {
        if (type(conn) != "object")
            continue;
        let id = trim(as_string(conn.id || conn.ID || ""));
        if (id == "" || match(id, /^[A-Za-z0-9_.:-]+$/) == null)
            continue;
        live[id] = true;
        let bytes = connection_bytes(conn);
        let previous = seen[id];
        if (type(previous) != "object" || int(previous.bytes) != bytes) {
            seen[id] = { bytes: bytes, since: now };
            continue;
        }
        if (now - int(previous.since) < IDLE_LIMIT)
            continue;
        if (!close_connection(base, id))
            continue;
        delete seen[id];
        closed++;
    }
    let stale = [];
    for (let id in seen)
        if (live[id] !== true)
            push(stale, id);
    for (let id in stale)
        delete seen[id];
    return closed;
}

function worker() {
    let seen = {};
    let base = clash_base_url();
    while (true) {
        let closed = 0;
        try {
            closed = sweep(seen, base);
        }
        catch (e) {
            closed = 0;
        }
        if (closed > 0)
            log_message("Closed " + closed + " silent sing-box connections", "info");
        command_success_from_args([ "sleep", as_string(POLL_SECONDS) ]);
    }
}

function stop_runtime() {
    let pid = file_first_line(PID_FILE);
    if (process_running(pid))
        command_success_from_args([ "kill", pid ]);
    remove_file(PID_FILE);
    return 0;
}

function start_runtime() {
    stop_runtime();
    if (!ensure_dir(RUNTIME_STATE_DIR))
        return 1;
    let command = command_from_args([ "ucode", "-L", LIB_DIR, IDLE_UC, "worker" ]) +
        " >/dev/null 2>&1 1000>&- & echo $! >" + shell_quote(PID_FILE);
    return command_status(command);
}

let mode = ARGV[0] || "";
if (mode == "start-runtime")
    exit(start_runtime());
else if (mode == "stop-runtime")
    exit(stop_runtime());
else if (mode == "worker")
    exit(worker());
warn("Usage: singbox/idle.uc <start-runtime|stop-runtime|worker>\n");
exit(1);
