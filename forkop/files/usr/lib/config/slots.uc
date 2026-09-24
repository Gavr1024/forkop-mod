#!/usr/bin/env ucode

let fs = require("fs");
let uci_core = require("core.uci");

const CONFIG_NAME = getenv("FORKOP_CONFIG_NAME") || "forkop";
const CONFIG_FILE = getenv("FORKOP_CONFIG") || "/etc/config/" + CONFIG_NAME;
const SLOTS_DIR = getenv("FORKOP_SLOTS_DIR") || "/etc/forkop/slots";
const STATE_FILE = getenv("FORKOP_SLOTS_STATE") || SLOTS_DIR + "/state.json";
const SERVICE_INIT = getenv("FORKOP_SERVICE_INIT") || "/etc/init.d/forkop";
const BIN_PATH = getenv("FORKOP_BIN") || "/usr/bin/forkop";
const CRON_MARKER = "# forkop-slot-probe";
const WORKER_PID_FILE = getenv("FORKOP_SLOT_PROBE_PID") || "/var/run/forkop/slot-probe.pid";
const RUNTIME_STATE_DIR = getenv("FORKOP_RUNTIME_STATE_DIR") || "/var/run/forkop";
const START_BUSY_FILE = getenv("FORKOP_START_BUSY") || (RUNTIME_STATE_DIR + "/start.busy");
const STOP_BUSY_FILE = getenv("FORKOP_STOP_BUSY") || (RUNTIME_STATE_DIR + "/stop.busy");
const CONTROL_KEYS = [
    "slots_auto_switch",
    "slots_ping_host",
    "slots_ping_host_backup",
    "slots_check_interval",
    "slots_fail_count",
    "slots_probe_backend",
    "slots_active"
];

function as_string(value) {
    return value == null ? "" : "" + value;
}

function trim_string(value) {
    let text = as_string(value);
    let start_match = match(text, /^[ \t\r\n]*/);
    let start = start_match ? length(start_match[0]) : 0;
    let end = length(text);
    while (end > start && match(substr(text, end - 1, 1), /[ \t\r\n]/))
        end--;
    return substr(text, start, end - start);
}

function object_or_empty(value) {
    return type(value) == "object" ? value : {};
}

function bool_option(section, name, fallback) {
    let value = object_or_empty(section)[name];
    if (value == null)
        return fallback ? true : false;
    return value === true || value == 1 || value == "1" || value == "true" || value == "yes" || value == "on";
}

function option(section, name, fallback) {
    let value = object_or_empty(section)[name];
    if (value == null)
        return fallback;
    return as_string(value);
}

function int_option(section, name, fallback) {
    let value = int(option(section, name, fallback));
    return value > 0 ? value : int(fallback);
}

function shell_quote(value) {
    return "'" + replace(as_string(value), /'/g, "'\\''") + "'";
}

function command_from_args(args) {
    let parts = [];
    for (let arg in args)
        push(parts, shell_quote(arg));
    return join(" ", parts);
}

function command_success(command) {
    return system(command + " >/dev/null 2>&1") == 0;
}

function command_success_from_args(args) {
    return command_success(command_from_args(args));
}

function command_status(command) {
    return int(system(as_string(command)));
}

function log_message(message, level) {
    command_success_from_args([
        "logger", "-t", "forkop",
        "[" + (level || "info") + "] slots: " + as_string(message)
    ]);
}

function now_seconds() {
    let value = time();
    return type(value) == "int" || type(value) == "double" ? int(value) : 0;
}

function file_size(path) {
    let stat = fs.stat(path);
    if (stat == null || stat.type != "file")
        return 0;
    return int(stat.size || 0);
}

function file_mtime(path) {
    let stat = fs.stat(path);
    if (stat == null)
        return 0;
    return int(stat.mtime || 0);
}

function ensure_dir(path) {
    if (fs.stat(path) != null)
        return true;
    return command_success_from_args([ "mkdir", "-p", path ]);
}

function settings_section() {
    return object_or_empty(uci_core.get_all(CONFIG_NAME, "settings"));
}

function slot_name(value) {
    value = trim_string(value);
    if (value == "online" || value == "offline")
        return value;
    return "";
}

function slot_path(name) {
    name = slot_name(name);
    if (name == "")
        return "";
    return SLOTS_DIR + "/" + name;
}

function normalize_host(value, fallback) {
    value = trim_string(value);
    if (value == "")
        return trim_string(fallback);
    value = replace(value, /^https?:\/\//, "");
    let cut = index(value, "/");
    if (cut >= 0)
        value = substr(value, 0, cut);
    return value;
}

function collect_hosts(settings) {
    let hosts = [];
    let seen = {};
    for (let host in [
        normalize_host(option(settings, "slots_ping_host", ""), "1.1.1.1"),
        normalize_host(option(settings, "slots_ping_host_backup", ""), "")
    ]) {
        if (host == "" || seen[host])
            continue;
        seen[host] = true;
        push(hosts, host);
    }
    return hosts;
}

function parse_ping_ms(text) {
    let matched = match(as_string(text), /time[=<]([0-9]+(\.[0-9]+)?)/);
    if (matched == null)
        return "";
    return as_string(matched[1]);
}

function owner_token(value) {
    return replace(as_string(value), /[^A-Za-z0-9._-]/, "_");
}

function ping_one(host) {
    host = trim_string(host);
    if (host == "")
        return { host, ok: false, ms: "" };

    let tmp = "/tmp/forkop-slot-ping." + owner_token(host);
    let code = system(command_from_args([ "ping", "-c", "1", "-W", "2", host ]) + " >" + shell_quote(tmp) + " 2>&1");
    let text = as_string(fs.readfile(tmp));
    try { fs.unlink(tmp); } catch (e) { }
    let ms = parse_ping_ms(text);
    let ok = code == 0 || ms != "";
    return { host, ok: ok ? true : false, ms };
}

function ping_hosts(hosts) {
    let results = [];
    let any_ok = false;
    for (let host in hosts) {
        let item = ping_one(host);
        if (item.ok)
            any_ok = true;
        push(results, item);
    }
    return { ok: any_ok, results };
}

function hosts_from_values(values, settings) {
    values = object_or_empty(values);
    if (values.host != null || values.backup_host != null) {
        let hosts = [];
        let seen = {};
        for (let host in [
            normalize_host(values.host, ""),
            normalize_host(values.backup_host, "")
        ]) {
            if (host == "" || seen[host])
                continue;
            seen[host] = true;
            push(hosts, host);
        }
        if (length(hosts) > 0)
            return hosts;
    }
    return collect_hosts(settings);
}

function empty_state() {
    return {
        active: "",
        last_ok: false,
        last_check: 0,
        last_rtt_ms: 0,
        host: "",
        backup_host: "",
        hosts: [],
        streak_ok: 0,
        streak_fail: 0
    };
}

function read_json_file(path) {
    let data = fs.readfile(path);
    if (data == null)
        return null;
    try {
        return json(as_string(data));
    }
    catch (e) {
        return null;
    }
}

function write_json_file(path, value) {
    return fs.writefile(path, sprintf("%J", value) + "\n") != null;
}

function read_state() {
    let data = object_or_empty(read_json_file(STATE_FILE));
    let state = empty_state();
    for (let key in state)
        if (data[key] != null)
            state[key] = data[key];
    return state;
}

function write_state(state) {
    if (!ensure_dir(SLOTS_DIR))
        return false;
    return write_json_file(STATE_FILE, state);
}

function copy_file(source_path, target_path) {
    if (!command_success_from_args([ "cp", "-f", source_path, target_path ]))
        return false;
    return file_size(target_path) > 0;
}

function slot_info(name) {
    let path = slot_path(name);
    let size = file_size(path);
    return {
        name,
        path,
        saved: size > 0,
        size,
        mtime: size > 0 ? file_mtime(path) : 0
    };
}

function save_slot(name) {
    name = slot_name(name);
    if (name == "")
        return false;
    if (file_size(CONFIG_FILE) <= 0) {
        log_message("current config is empty, cannot save slot " + name, "error");
        return false;
    }
    if (!ensure_dir(SLOTS_DIR))
        return false;
    if (!copy_file(CONFIG_FILE, slot_path(name))) {
        log_message("failed to save slot " + name, "error");
        return false;
    }
    log_message("saved current config to slot " + name, "info");
    return true;
}

function restore_control_options(snapshot) {
    snapshot = object_or_empty(snapshot);
    for (let key in CONTROL_KEYS) {
        if (snapshot[key] == null)
            continue;
        uci_core.set(CONFIG_NAME + ".settings." + key, snapshot[key]);
    }
    uci_core.commit(CONFIG_NAME);
}

function forkop_service_running() {
    return command_success_from_args([ SERVICE_INIT, "running" ]);
}

function start_is_busy() {
    return file_size(START_BUSY_FILE) > 0;
}

function stop_is_busy() {
    return file_size(STOP_BUSY_FILE) > 0;
}

function restart_after_apply(mode) {
    mode = trim_string(mode);
    if (mode == "none")
        return true;
    if (stop_is_busy()) {
        log_message("slot restart skipped because Forkop is stopping", "info");
        return true;
    }
    if (start_is_busy()) {
        log_message("slot change saved; Forkop restart waits until the current start finishes", "info");
        return true;
    }
    let action = "reload";
    if (mode == "start" || !forkop_service_running())
        action = "start";
    log_message("requesting Forkop " + action + " in background after slot change", "info");
    // Do not block LuCI / slot_apply: Xray reload can take over a minute.
    // FORKOP_SLOT_RESTART lets a stop already in progress ignore this start.
    return system("FORKOP_SLOT_RESTART=1 " + command_from_args([ SERVICE_INIT, action ]) + " >/dev/null 2>&1 1000>&- &") == 0;
}

function apply_slot(name, reason, restart_mode) {
    name = slot_name(name);
    if (name == "")
        return false;
    let path = slot_path(name);
    if (file_size(path) <= 0) {
        log_message("slot " + name + " is empty", "error");
        return false;
    }

    let snapshot = settings_section();
    if (!copy_file(path, CONFIG_FILE)) {
        log_message("failed to apply slot " + name, "error");
        return false;
    }

    restore_control_options({
        slots_auto_switch: option(snapshot, "slots_auto_switch", "0"),
        slots_ping_host: option(snapshot, "slots_ping_host", "1.1.1.1"),
        slots_ping_host_backup: option(snapshot, "slots_ping_host_backup", ""),
        slots_check_interval: option(snapshot, "slots_check_interval", "30"),
        slots_fail_count: option(snapshot, "slots_fail_count", "2"),
        slots_probe_backend: option(snapshot, "slots_probe_backend", "worker"),
        slots_active: name
    });

    let state = read_state();
    state.active = name;
    write_state(state);

    log_message("applied slot " + name + (reason != "" ? " (" + as_string(reason) + ")" : ""), "info");
    restart_after_apply(restart_mode);
    return true;
}

function current_active_slot() {
    let settings = settings_section();
    let active = slot_name(option(settings, "slots_active", ""));
    if (active != "")
        return active;
    return slot_name(as_string(read_state().active));
}

function try_fallback_slot() {
    let settings = settings_section();
    if (!bool_option(settings, "slots_auto_switch", false))
        return false;

    let active = current_active_slot();
    let fallback = active == "offline" ? "online" : "offline";
    if (file_size(slot_path(fallback)) <= 0) {
        log_message("start failed and fallback slot " + fallback + " is empty", "warn");
        return false;
    }
    return apply_slot(fallback, "start failed, switching slot", "none");
}

function cron_line() {
    return "* * * * * " + BIN_PATH + " slot_probe_if_due " + CRON_MARKER;
}

function read_crontab() {
    let tmp = "/tmp/forkop-slots.cron";
    system("crontab -l >" + shell_quote(tmp) + " 2>/dev/null");
    let data = fs.readfile(tmp);
    try { fs.unlink(tmp); } catch (e) { }
    return as_string(data);
}

function write_crontab(text) {
    let tmp = "/tmp/forkop-slots.cron";
    fs.writefile(tmp, as_string(text));
    let ok = command_success_from_args([ "crontab", tmp ]);
    try { fs.unlink(tmp); } catch (e) { }
    return ok;
}

function probe_backend() {
    let value = trim_string(option(settings_section(), "slots_probe_backend", "worker"));
    if (value == "cron")
        return "cron";
    return "worker";
}

function worker_pid() {
    let data = null;
    try { data = fs.readfile(WORKER_PID_FILE); } catch (e) { data = null; }
    let pid = trim_string(as_string(data));
    let newline = index(pid, "\n");
    if (newline >= 0)
        pid = trim_string(substr(pid, 0, newline));
    return pid;
}

function worker_pid_running(pid) {
    pid = trim_string(pid);
    return match(pid, /^[0-9]+$/) != null && command_success_from_args([ "kill", "-0", pid ]);
}

function stop_worker() {
    let pid = worker_pid();
    if (worker_pid_running(pid)) {
        command_success_from_args([ "kill", pid ]);
        command_success_from_args([ "kill", "-9", pid ]);
    }
    try { fs.unlink(WORKER_PID_FILE); } catch (e) { }
    return true;
}

function start_worker() {
    stop_worker();
    let settings = settings_section();
    if (!bool_option(settings, "slots_auto_switch", false))
        return true;
    if (probe_backend() != "worker")
        return true;
    if (!ensure_dir(RUNTIME_STATE_DIR)) {
        log_message("failed to create runtime dir for slot worker", "warn");
        return false;
    }
    let lib_dir = getenv("FORKOP_LIB") || "/usr/lib/forkop";
    let inner = command_from_args([
        "ucode", "-L", lib_dir, lib_dir + "/config/slots.uc", "probe-worker"
    ]);
    log_message("Starting slot probe worker", "info");
    // setsid and close procd lock fd 1000. A worker that inherits that fd
    // holds the service lock, so /etc/init.d/forkop stop waits forever.
    return command_success(
        "setsid " + inner + " </dev/null >/dev/null 2>&1 1000>&- & echo $! > " + shell_quote(WORKER_PID_FILE)
    );
}

function sync_cron(enabled) {
    let lines = [];
    for (let line in split(read_crontab(), "\n")) {
        if (trim_string(line) == "")
            continue;
        if (index(line, CRON_MARKER) >= 0)
            continue;
        push(lines, line);
    }
    if (enabled)
        push(lines, cron_line());
    return write_crontab(join("\n", lines) + "\n");
}

function sync_scheduler() {
    let enabled = bool_option(settings_section(), "slots_auto_switch", false);
    let backend = probe_backend();
    let cron_ok = true;
    if (!enabled || backend != "cron")
        cron_ok = sync_cron(false);
    else
        cron_ok = sync_cron(true);
    if (!cron_ok)
        log_message("failed to update the slot probe cron job", "warn");
    if (enabled && backend == "worker")
        start_worker();
    else
        stop_worker();
    return true;
}

function sync_cron_only() {
    let enabled = bool_option(settings_section(), "slots_auto_switch", false);
    let backend = probe_backend();
    let cron_ok = sync_cron(enabled && backend == "cron");
    if (!cron_ok)
        log_message("failed to update the slot probe cron job", "warn");
    return true;
}

function prepare_boot_slot() {
    let settings = settings_section();
    let enabled = bool_option(settings, "slots_auto_switch", false);
    if (!enabled)
        return true;

    let hosts = collect_hosts(settings);
    let ping = ping_hosts(hosts);
    let wanted = ping.ok ? "online" : "offline";
    let state = read_state();
    state.last_check = now_seconds();
    state.last_ok = ping.ok ? true : false;
    state.hosts = ping.results;
    state.host = length(hosts) > 0 ? hosts[0] : "";
    state.backup_host = length(hosts) > 1 ? hosts[1] : "";
    if (ping.ok) {
        state.streak_ok = int_option(settings, "slots_fail_count", 2);
        state.streak_fail = 0;
    }
    else {
        state.streak_fail = int_option(settings, "slots_fail_count", 2);
        state.streak_ok = 0;
    }
    write_state(state);

    if (file_size(slot_path(wanted)) <= 0) {
        log_message("boot ping wants slot " + wanted + ", but it is empty", "warn");
        return true;
    }
    if (wanted == current_active_slot())
        return true;
    return apply_slot(wanted, ping.ok ? "boot: host reachable" : "boot: all hosts unreachable", "none");
}

function self_pid() {
    let stat = "";
    try { stat = trim_string(as_string(fs.readfile("/proc/self/stat"))); } catch (e) { stat = ""; }
    let fields = split(stat, " ");
    if (length(fields) > 0 && match(fields[0], /^[0-9]+$/) != null)
        return fields[0];
    return "";
}

function probe(force, values) {
    if (start_is_busy() || stop_is_busy()) {
        log_message("slot probe skipped because Forkop is still starting or stopping", "info");
        return true;
    }
    let settings = settings_section();
    if (!bool_option(settings, "slots_auto_switch", false) && !force)
        return true;

    let hosts = hosts_from_values(values, settings);
    let need = int_option(settings, "slots_fail_count", 2);
    let ping = ping_hosts(hosts);
    let ok = ping.ok ? true : false;
    let state = read_state();
    state.last_check = now_seconds();
    state.host = length(hosts) > 0 ? hosts[0] : "";
    state.backup_host = length(hosts) > 1 ? hosts[1] : "";
    state.hosts = ping.results;
    state.last_ok = ok;

    if (ok) {
        state.streak_ok = int(state.streak_ok) + 1;
        state.streak_fail = 0;
    }
    else {
        state.streak_fail = int(state.streak_fail) + 1;
        state.streak_ok = 0;
    }
    write_state(state);

    let wanted = ok ? "online" : "offline";
    let ready = ok ? int(state.streak_ok) >= need : int(state.streak_fail) >= need;
    let active = option(settings, "slots_active", as_string(state.active));
    if (!ready || wanted == active)
        return true;
    if (file_size(slot_path(wanted)) <= 0) {
        log_message("ping wants slot " + wanted + ", but it is empty", "warn");
        return true;
    }
    return apply_slot(wanted, ok ? "at least one host reachable" : "all hosts unreachable", "");
}

function probe_if_due() {
    let settings = settings_section();
    if (!bool_option(settings, "slots_auto_switch", false)) {
        stop_worker();
        sync_cron(false);
        return true;
    }
    if (probe_backend() == "cron")
        sync_cron(true);
    else
        sync_cron(false);
    let interval = int_option(settings, "slots_check_interval", 30);
    let state = read_state();
    if (int(state.last_check) > 0 && now_seconds() - int(state.last_check) < interval)
        return true;
    return probe(false);
}

function worker_wait(seconds) {
    let left = int(seconds);
    if (left < 1)
        left = 1;
    while (left > 0) {
        if (stop_is_busy() || start_is_busy())
            return false;
        let settings = settings_section();
        if (!bool_option(settings, "slots_auto_switch", false) || probe_backend() != "worker")
            return false;
        system("sleep 1");
        left--;
    }
    return true;
}

function probe_worker() {
    let pid = self_pid();
    if (pid != "") {
        try { fs.writefile(WORKER_PID_FILE, pid + "\n"); } catch (e) { }
    }
    log_message("Slot probe worker is running", "info");
    let first = true;
    while (1) {
        let settings = settings_section();
        if (!bool_option(settings, "slots_auto_switch", false) || probe_backend() != "worker")
            return 0;
        let wait_seconds = int_option(settings, "slots_check_interval", 30);
        if (wait_seconds < 10)
            wait_seconds = 10;
        if (!worker_wait(wait_seconds))
            return 0;
        if (first) {
            first = false;
            continue;
        }
        if (stop_is_busy() || start_is_busy())
            return 0;
        try {
            probe_if_due();
        }
        catch (e) {
            log_message("worker: " + e, "warn");
        }
    }
}

function option_line(key, value) {
    return "        option " + as_string(key) + " '" + replace(as_string(value), /'/, "") + "'";
}

function is_uci_section_start(line) {
    return match(trim_string(line), /^config[ \t]/) != null;
}

function is_settings_section_start(line) {
    return match(trim_string(line), /^config[ \t]+settings([ \t]|$)/) != null;
}

function option_key_from_line(line) {
    let matched = match(trim_string(line), /^option[ \t]+([A-Za-z0-9_]+)([ \t]|$)/);
    if (matched == null)
        return "";
    return as_string(matched[1]);
}

function upsert_settings_options(text, options) {
    options = object_or_empty(options);
    let lines = split(as_string(text), "\n");
    let out = [];
    let in_settings = false;
    let seen = {};
    let wrote_settings = false;

    function flush_missing() {
        for (let key in options) {
            if (seen[key])
                continue;
            push(out, option_line(key, options[key]));
            seen[key] = true;
        }
    }

    for (let line in lines) {
        if (is_uci_section_start(line)) {
            if (in_settings)
                flush_missing();
            in_settings = is_settings_section_start(line);
            if (in_settings)
                wrote_settings = true;
        }
        if (in_settings) {
            let key = option_key_from_line(line);
            if (key != "" && options[key] != null) {
                push(out, option_line(key, options[key]));
                seen[key] = true;
                continue;
            }
        }
        push(out, line);
    }
    if (in_settings)
        flush_missing();
    if (!wrote_settings && length(out) > 0) {
        push(out, "config settings 'settings'");
        flush_missing();
    }
    return join("\n", out);
}

function write_text_file(path, text) {
    return fs.writefile(path, as_string(text)) != null;
}

function patch_config_file(path, options) {
    if (file_size(path) <= 0)
        return false;
    let text = fs.readfile(path);
    if (text == null)
        return false;
    return write_text_file(path, upsert_settings_options(text, options));
}

function switch_options_from_values(enabled, host, backup_host, interval, fail_count, scheduler) {
    return {
        slots_auto_switch: enabled ? "1" : "0",
        slots_ping_host: host,
        slots_ping_host_backup: backup_host,
        slots_check_interval: "" + interval,
        slots_fail_count: "" + fail_count,
        slots_probe_backend: scheduler == "cron" ? "cron" : "worker"
    };
}

function sync_switch_settings_to_slots(options) {
    let ok = true;
    if (!patch_config_file(CONFIG_FILE, options))
        ok = false;
    for (let name in [ "online", "offline" ]) {
        let path = slot_path(name);
        if (file_size(path) <= 0)
            continue;
        if (!patch_config_file(path, options)) {
            log_message("failed to write switch settings into slot " + name, "warn");
            ok = false;
        }
    }
    return ok;
}

function configure(values) {
    values = object_or_empty(values);
    let host = normalize_host(values.host != null ? values.host : values.slots_ping_host, "1.1.1.1");
    let backup_host = normalize_host(values.backup_host != null ? values.backup_host : values.slots_ping_host_backup, "");
    let interval = int(values.interval != null ? values.interval : values.slots_check_interval);
    let fail_count = int(values.fail_count != null ? values.fail_count : values.slots_fail_count);
    let enabled = bool_option(values, "enabled", bool_option(values, "slots_auto_switch", false));
    let scheduler = trim_string(values.scheduler != null ? values.scheduler : values.slots_probe_backend);
    if (scheduler == "")
        scheduler = probe_backend();
    if (scheduler != "cron")
        scheduler = "worker";

    if (interval < 10)
        interval = 10;
    if (fail_count < 1)
        fail_count = 1;

    uci_core.set(CONFIG_NAME + ".settings.slots_auto_switch", enabled ? "1" : "0");
    uci_core.set(CONFIG_NAME + ".settings.slots_ping_host", host);
    uci_core.set(CONFIG_NAME + ".settings.slots_ping_host_backup", backup_host);
    uci_core.set(CONFIG_NAME + ".settings.slots_check_interval", "" + interval);
    uci_core.set(CONFIG_NAME + ".settings.slots_fail_count", "" + fail_count);
    uci_core.set(CONFIG_NAME + ".settings.slots_probe_backend", scheduler);
    uci_core.commit(CONFIG_NAME);
    let options = switch_options_from_values(enabled, host, backup_host, interval, fail_count, scheduler);
    if (!sync_switch_settings_to_slots(options))
        log_message("live config saved, but some slot files were not updated", "warn");
    try {
        sync_scheduler();
    }
    catch (e) {
        log_message("scheduler: " + e, "warn");
    }
    return true;
}

function status_object() {
    let settings = settings_section();
    let state = read_state();
    return {
        enabled: bool_option(settings, "slots_auto_switch", false),
        host: normalize_host(option(settings, "slots_ping_host", ""), "1.1.1.1"),
        backup_host: normalize_host(option(settings, "slots_ping_host_backup", ""), ""),
        hosts: type(state.hosts) == "array" ? state.hosts : [],
        interval: int_option(settings, "slots_check_interval", 30),
        fail_count: int_option(settings, "slots_fail_count", 2),
        scheduler: probe_backend(),
        active: option(settings, "slots_active", as_string(state.active)),
        last_ok: state.last_ok ? true : false,
        last_check: int(state.last_check || 0),
        streak_ok: int(state.streak_ok || 0),
        streak_fail: int(state.streak_fail || 0),
        online: slot_info("online"),
        offline: slot_info("offline")
    };
}

function print_status_json() {
    print(sprintf("%J", status_object()), "\n");
}

function parse_configure_args() {
    let values = {};
    for (let arg in ARGV) {
        let sep = index(as_string(arg), "=");
        if (sep <= 0)
            continue;
        values[substr(arg, 0, sep)] = substr(arg, sep + 1);
    }
    return values;
}

function sync_cron_from_uci() {
    return sync_scheduler();
}

function module_exports() {
    return {
        save_slot,
        apply_slot,
        probe,
        probe_if_due,
        probe_worker,
        configure,
        status_object,
        print_status_json,
        sync_cron,
        sync_cron_from_uci,
        sync_scheduler,
        start_worker,
        stop_worker,
        prepare_boot_slot,
        try_fallback_slot
    };
}

if ((sourcepath(1) != null && sourcepath(1) != "") || ARGV[0] == null)
    return module_exports();

let mode = ARGV[0] || "";
if (mode == "status-json")
    print_status_json();
else if (mode == "save")
    exit(save_slot(ARGV[1]) ? 0 : 1);
else if (mode == "apply")
    exit(apply_slot(ARGV[1], "manual") ? 0 : 1);
else if (mode == "probe")
    exit(probe(true, parse_configure_args()) ? 0 : 1);
else if (mode == "probe-if-due")
    exit(probe_if_due() ? 0 : 1);
else if (mode == "configure")
    exit(configure(parse_configure_args()) ? 0 : 1);
else if (mode == "sync-cron-from-uci" || mode == "sync-scheduler")
    exit(sync_scheduler() ? 0 : 1);
else if (mode == "sync-cron-only")
    exit(sync_cron_only() ? 0 : 1);
else if (mode == "stop-worker")
    exit(stop_worker() ? 0 : 1);
else if (mode == "probe-worker")
    exit(probe_worker());
else if (mode == "prepare-boot-slot")
    exit(prepare_boot_slot() ? 0 : 1);
else if (mode == "try-fallback-slot")
    exit(try_fallback_slot() ? 0 : 1);
else
    exit(1);
