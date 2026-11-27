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

function reserve_id(value) {
    value = trim_string(value);
    if (value == "r1" || value == "r2" || value == "r3")
        return value;
    return "";
}

function stored_slot(value) {
    let name = slot_name(value);
    if (name != "")
        return name;
    return reserve_id(value);
}

function slot_path(name) {
    name = stored_slot(name);
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
    name = stored_slot(name);
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

function start_is_busy() {
    return file_size(START_BUSY_FILE) > 0;
}

function stop_is_busy() {
    return file_size(STOP_BUSY_FILE) > 0;
}

function queue_slot_restart() {
    if (!ensure_dir(RUNTIME_STATE_DIR))
        return false;
    let lock = shell_quote(RUNTIME_STATE_DIR + "/slot-restart.lock");
    let start_busy = shell_quote(START_BUSY_FILE);
    let stop_busy = shell_quote(STOP_BUSY_FILE);
    let restart = "FORKOP_SLOT_RESTART=1 " + command_from_args([ SERVICE_INIT, "restart" ]);
    // One waiter. The config file is already the new slot; restart once the
    // current start/stop drops both busy flags, so that run is what stays up.
    let script =
        "if command -v flock >/dev/null 2>&1; then exec 9>" + lock + "; flock -n 9 || exit 0; fi; " +
        "while [ -s " + start_busy + " ] || [ -s " + stop_busy + " ]; do sleep 1; done; " +
        "exec 9>&- 2>/dev/null || true; " +
        restart + " >/dev/null 2>&1";
    log_message("slot restart queued until the current start or stop finishes", "info");
    return system(script + " 1000>&- &") == 0;
}

function restart_after_apply(mode) {
    mode = trim_string(mode);
    if (mode == "none")
        return true;
    if (stop_is_busy() || start_is_busy())
        return queue_slot_restart();
    log_message("requesting Forkop restart in background after slot change", "info");
    return system("FORKOP_SLOT_RESTART=1 " + command_from_args([ SERVICE_INIT, "restart" ]) + " >/dev/null 2>&1 1000>&- &") == 0;
}

function current_active_slot() {
    let settings = settings_section();
    let active = slot_name(option(settings, "slots_active", ""));
    if (active != "")
        return active;
    return slot_name(as_string(read_state().active));
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

function apply_slot(name, reason, restart_mode) {
    name = stored_slot(name);
    if (name == "")
        return false;
    let path = slot_path(name);
    if (file_size(path) <= 0) {
        log_message("slot " + name + " is empty", "error");
        return false;
    }

    let reserve = reserve_id(name) != "";
    let snapshot = settings_section();
    if (reserve) {
        stop_worker();
        sync_cron(false);
    }
    if (!copy_file(path, CONFIG_FILE)) {
        log_message("failed to apply slot " + name, "error");
        return false;
    }
    if (!uci_core.reload_package(CONFIG_NAME))
        log_message("failed to reread the config after applying slot " + name, "warn");

    restore_control_options({
        slots_auto_switch: reserve ? "0" : option(snapshot, "slots_auto_switch", "0"),
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

    if (reserve) {
        log_message("auto-switch turned off because reserve " + name + " was applied", "info");
        sync_scheduler();
    }

    log_message("applied slot " + name + (reason != "" ? " (" + as_string(reason) + ")" : ""), "info");
    restart_after_apply(restart_mode);
    return true;
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

function reserve_labels_path() {
    return SLOTS_DIR + "/reserve-labels.json";
}

function read_reserve_labels() {
    let data = read_json_file(reserve_labels_path());
    return type(data) == "object" ? data : {};
}

function clean_reserve_label(value) {
    value = trim_string(value);
    let out = "";
    let i = 0;
    while (i < length(value) && length(out) < 40) {
        let ch = substr(value, i, 1);
        if (ch != "\n" && ch != "\r" && ch != "\t")
            out += ch;
        i++;
    }
    return trim_string(out);
}

function set_reserve_label(id, label) {
    id = reserve_id(id);
    if (id == "")
        return false;
    if (!ensure_dir(SLOTS_DIR))
        return false;
    let labels = read_reserve_labels();
    labels[id] = clean_reserve_label(label);
    return write_json_file(reserve_labels_path(), labels);
}

function reserve_card(id) {
    let info = slot_info(id);
    let labels = read_reserve_labels();
    info.label = clean_reserve_label(labels[id]);
    return info;
}

function preview_skip_gap(text, i) {
    let n = length(text);
    while (i < n) {
        let ch = substr(text, i, 1);
        if (ch == " " || ch == "\t" || ch == "\n" || ch == "\r") {
            i++;
            continue;
        }
        if (ch == "#") {
            while (i < n && substr(text, i, 1) != "\n")
                i++;
            continue;
        }
        break;
    }
    return i;
}

function preview_read_word(text, i) {
    let n = length(text);
    let out = "";
    while (i < n) {
        let ch = substr(text, i, 1);
        if (ch == " " || ch == "\t" || ch == "\n" || ch == "\r" || ch == "#" || ch == "'" || ch == "\"")
            break;
        out += ch;
        i++;
    }
    return { value: out, next: i };
}

function preview_read_value(text, i) {
    let n = length(text);
    while (i < n) {
        let ch = substr(text, i, 1);
        if (ch == " " || ch == "\t") {
            i++;
            continue;
        }
        break;
    }
    if (i >= n)
        return { value: "", next: i, present: false };
    let ch = substr(text, i, 1);
    if (ch == "\n" || ch == "\r" || ch == "#")
        return { value: "", next: i, present: false };
    if (ch == "'" || ch == "\"") {
        let quote = ch;
        let out = "";
        i++;
        while (i < n) {
            ch = substr(text, i, 1);
            if (ch == quote) {
                if (quote == "'" && i + 3 < n && substr(text, i, 4) == "'\\''") {
                    out += "'";
                    i += 4;
                    continue;
                }
                i++;
                break;
            }
            if (ch == "\\" && i + 1 < n) {
                let nxt = substr(text, i + 1, 1);
                if (nxt == "n") {
                    out += "\n";
                    i += 2;
                    continue;
                }
                if (nxt == "t") {
                    out += "\t";
                    i += 2;
                    continue;
                }
                if (nxt == "\\" || nxt == quote) {
                    out += nxt;
                    i += 2;
                    continue;
                }
            }
            out += ch;
            i++;
        }
        return { value: out, next: i, present: true };
    }
    let out = "";
    while (i < n) {
        ch = substr(text, i, 1);
        if (ch == " " || ch == "\t" || ch == "\n" || ch == "\r" || ch == "#")
            break;
        out += ch;
        i++;
    }
    return { value: out, next: i, present: true };
}

function preview_skip_tail(text, i) {
    let n = length(text);
    while (i < n) {
        let ch = substr(text, i, 1);
        if (ch == "\n")
            return i + 1;
        i++;
    }
    return i;
}

function preview_words(value) {
    let out = [];
    let current = "";
    let text = as_string(value);
    let i = 0;
    while (i < length(text)) {
        let ch = substr(text, i, 1);
        if (ch == " " || ch == "\t" || ch == "," || ch == "\n" || ch == "\r") {
            if (current != "")
                push(out, current);
            current = "";
        }
        else
            current += ch;
        i++;
    }
    if (current != "")
        push(out, current);
    return out;
}

function preview_bucket(key) {
    if (key == "domain" || key == "domains" || key == "domain_suffix" || key == "domain_keyword" || key == "domain_regex" || key == "domain_suffix_text" || key == "domain_keyword_text" || key == "domain_regex_text" || key == "domain_text")
        return "domains";
    if (key == "community_lists" || key == "rule_set" || key == "rule_sets" || key == "local_domain_lists" || key == "domain_ip_lists" || key == "user_lists")
        return "lists";
    if (key == "rule_set_with_subnets" || key == "rule_sets_with_subnets")
        return "subnet_lists";
    if (key == "source_ip_cidr" || key == "source_ip_cidr_text")
        return "devices";
    if (key == "excluded_source_ips" || key == "excluded_source_ips_text")
        return "excluded";
    if (key == "fully_routed_ips" || key == "fully_routed_ips_text")
        return "full";
    if (key == "ip_cidr" || key == "ip_cidr_text")
        return "ips";
    if (key == "ports" || key == "ports_text")
        return "ports";
    return "";
}

function preview_secret_key(key) {
    if (preview_bucket(key) != "")
        return false;
    key = lc(trim_string(key));
    if (key == "")
        return true;
    if (index(key, "pass") >= 0 || index(key, "secret") >= 0 || index(key, "token") >= 0)
        return true;
    if (index(key, "uuid") >= 0 || index(key, "encrypt") >= 0 || index(key, "login") >= 0)
        return true;
    if (index(key, "cookie") >= 0 || index(key, "cert") >= 0 || index(key, "xdrive") >= 0)
        return true;
    if (index(key, "key") >= 0)
        return true;
    return false;
}

function preview_push_unique(list, value) {
    value = trim_string(value);
    if (value == "")
        return;
    for (let item in list)
        if (item == value)
            return;
    push(list, value);
}

function preview_take(values) {
    let shown = [];
    let i = 0;
    while (i < length(values) && i < 6) {
        push(shown, values[i]);
        i++;
    }
    return shown;
}

function blank_preview_section(id) {
    return {
        id: id,
        label: "",
        enabled: true,
        action: "",
        domains: [],
        lists: [],
        devices: [],
        excluded: [],
        full: [],
        ips: [],
        ports: [],
        subnet_lists: [],
        servers: [],
        subscriptions: [],
        interfaces: [],
        openconnect: [],
        openvpn: [],
        warp: [],
        masque: [],
        jsons: [],
        xdrives: [],
        urltest: [],
        priority: [],
        core: "",
        dns_type: "",
        dns_server: "",
        dns_answer: "",
        dns_detour_on: false,
        dns_via: "",
        fallback: "",
        mux: false,
        finalmask: false,
        sort: false,
        mixed: false,
        realip: false,
        cascade_on: false,
        cascade: "",
        dashboard: ""
    };
}

function preview_uses_core(action) {
    action = lc(trim_string(action));
    return action == "connection" || action == "proxy" || action == "outbound" || action == "vpn";
}

function finish_preview_section(section) {
    if (section == null)
        return null;
    return {
        id: section.id,
        label: section.label,
        enabled: section.enabled ? true : false,
        action: section.action,
        domains: preview_take(section.domains),
        domain_count: length(section.domains),
        lists: section.lists,
        list_count: length(section.lists),
        devices: preview_take(section.devices),
        device_count: length(section.devices),
        excluded: preview_take(section.excluded),
        excluded_count: length(section.excluded),
        full: preview_take(section.full),
        full_count: length(section.full),
        ips: preview_take(section.ips),
        ip_count: length(section.ips),
        ports: preview_take(section.ports),
        port_count: length(section.ports),
        subnet_lists: section.subnet_lists,
        subnet_count: length(section.subnet_lists),
        servers: preview_take(section.servers),
        server_count: length(section.servers),
        subscriptions: preview_take(section.subscriptions),
        subscription_count: length(section.subscriptions),
        interfaces: section.interfaces,
        openconnect: section.openconnect,
        openvpn: section.openvpn,
        warp: section.warp,
        masque: section.masque,
        jsons: section.jsons,
        xdrives: section.xdrives,
        urltest: section.urltest,
        priority: section.priority,
        core: section.core != "" ? section.core : (preview_uses_core(section.action) ? "settings" : ""),
        dns_type: section.dns_type,
        dns_server: section.dns_server,
        dns_answer: section.dns_answer,
        dns_via: section.dns_detour_on ? section.dns_via : "",
        fallback: section.fallback,
        mux: section.mux ? true : false,
        finalmask: section.finalmask ? true : false,
        sort: section.sort ? true : false,
        mixed: section.mixed ? true : false,
        realip: section.realip ? true : false,
        cascade: section.cascade_on ? section.cascade : "",
        dashboard: section.dashboard
    };
}

function preview_cut_at(value, mark) {
    let cut = index(value, mark);
    if (cut >= 0)
        return substr(value, 0, cut);
    return value;
}

function preview_public_target(value) {
    value = trim_string(value);
    if (value == "")
        return "";
    let scheme = "";
    let rest = value;
    let sep = index(value, "://");
    if (sep > 0 && sep < 12) {
        scheme = lc(substr(value, 0, sep));
        rest = substr(value, sep + 3);
    }
    let at = index(rest, "@");
    if (at >= 0)
        rest = substr(rest, at + 1);
    rest = preview_cut_at(rest, "?");
    rest = preview_cut_at(rest, "#");
    rest = preview_cut_at(rest, "/");
    rest = trim_string(rest);
    if (rest == "")
        return scheme;
    if (index(rest, ".") < 0 && index(rest, ":") < 0 && index(rest, "[") < 0)
        return scheme;
    if (scheme == "" || scheme == "http" || scheme == "https")
        return rest;
    return scheme + " " + rest;
}

function preview_json_label(value, key, fallback) {
    value = as_string(value);
    let needle = "\"" + key + "\"";
    let at = index(value, needle);
    if (at < 0)
        return fallback;
    let i = at + length(needle);
    let n = length(value);
    while (i < n) {
        let ch = substr(value, i, 1);
        if (ch != " " && ch != "\t" && ch != "\n" && ch != "\r" && ch != ":")
            break;
        i++;
    }
    if (i >= n || substr(value, i, 1) != "\"")
        return fallback;
    i++;
    let out = "";
    while (i < n && length(out) < 60) {
        let ch = substr(value, i, 1);
        if (ch == "\"")
            break;
        if (ch == "\\") {
            i++;
            if (i >= n)
                break;
            ch = substr(value, i, 1);
        }
        out += ch;
        i++;
    }
    out = trim_string(out);
    if (out == "" || index(out, "\n") >= 0)
        return fallback;
    return out;
}

function preview_add_items(section, key, value, kind) {
    if (key == "outbound_jsons" || key == "outbound_json") {
        preview_push_unique(section.jsons, preview_json_label(value, "tag", "JSON"));
        return;
    }
    if (key == "xdrive_outbounds") {
        preview_push_unique(section.xdrives, preview_json_label(value, "name", "XDRIVE"));
        return;
    }
    if (preview_secret_key(key))
        return;
    if (key == "label")
        section.label = value;
    else if (key == "action")
        section.action = value;
    else if (key == "enabled")
        section.enabled = value != "0";
    else if (key == "proxy_core") {
        let core = lc(trim_string(value));
        if (core == "xray" || core == "xray-core")
            section.core = "xray";
        else if (core == "sing-box" || core == "singbox")
            section.core = "sing-box";
    }
    else if (key == "dns_type") {
        let kind_name = lc(trim_string(value));
        if (kind_name != "" && length(kind_name) < 16 && index(kind_name, "/") < 0 && index(kind_name, "@") < 0)
            section.dns_type = kind_name;
    }
    else if (key == "dns_server")
        section.dns_server = preview_public_target(value);
    else if (key == "dns_answer") {
        let answer = lc(trim_string(value));
        if (answer == "real" || answer == "route")
            section.dns_answer = answer;
    }
    else if (key == "dns_detour_enabled")
        section.dns_detour_on = value == "1";
    else if (key == "dns_detour_section" || key == "xray_fallback_target") {
        let target = trim_string(value);
        if (key == "dns_detour_section")
            section.dns_via = target;
        else
            section.fallback = target;
    }
    else if (key == "selector_proxy_links") {
        let target = preview_public_target(value);
        if (target != "")
            preview_push_unique(section.servers, target);
    }
    else if (key == "xray_mux_enabled")
        section.mux = value == "1";
    else if (key == "xray_finalmask")
        section.finalmask = value == "1";
    else if (key == "sort_by_latency")
        section.sort = value == "1";
    else if (key == "mixed_proxy_enabled")
        section.mixed = value == "1";
    else if (key == "resolve_real_ip_for_routing")
        section.realip = value == "1";
    else if (key == "outbound_detour_enabled")
        section.cascade_on = value == "1";
    else if (key == "outbound_detour_section")
        section.cascade = trim_string(value);
    else if (key == "dashboard_filter_mode") {
        let mode = lc(trim_string(value));
        if (mode == "include" || mode == "exclude" || mode == "mixed")
            section.dashboard = mode;
    }
    else {
        let bucket = preview_bucket(key);
        if (bucket == "")
            return;
        let items = kind == "list" ? [ value ] : preview_words(value);
        for (let item in items)
            preview_push_unique(section[bucket], item);
    }
}

function preview_named(sections, id) {
    id = trim_string(id);
    if (id == "")
        return "";
    for (let section in sections) {
        if (section.id != id)
            continue;
        let label = trim_string(section.label);
        if (label != "")
            return label;
        return section.id;
    }
    return id;
}

function preview_fallback_parts(sections, value) {
    value = trim_string(value);
    let tab = index(value, "\t");
    let id = value;
    let tag = "";
    if (tab >= 0) {
        id = trim_string(substr(value, 0, tab));
        tag = trim_string(substr(value, tab + 1));
    }
    return {
        name: preview_named(sections, id),
        tag: tag
    };
}

function preview_child_bucket(kind) {
    if (kind == "subscription_url")
        return "subscriptions";
    if (kind == "section_interface")
        return "interfaces";
    if (kind == "openconnect")
        return "openconnect";
    if (kind == "openvpn")
        return "openvpn";
    if (kind == "warp")
        return "warp";
    if (kind == "masque")
        return "masque";
    if (kind == "urltest")
        return "urltest";
    if (kind == "priority_group")
        return "priority";
    return "";
}

function preview_child_fallback(bucket) {
    if (bucket == "openconnect")
        return "OpenConnect";
    if (bucket == "openvpn")
        return "OpenVPN";
    if (bucket == "warp")
        return "WARP";
    if (bucket == "masque")
        return "MASQUE";
    if (bucket == "urltest")
        return "URLTest";
    if (bucket == "priority")
        return "Priority";
    return "";
}

function preview_slot(id) {
    id = reserve_id(id);
    if (id == "")
        return null;
    let path = slot_path(id);
    let text = "";
    if (file_size(path) > 0)
        text = as_string(fs.readfile(path));
    let raw = [];
    let children = [];
    let current = null;
    let child = null;
    let seen = 0;
    let i = 0;
    let n = length(text);
    while (i < n) {
        i = preview_skip_gap(text, i);
        if (i >= n)
            break;
        let word = preview_read_word(text, i);
        i = word.next;
        if (word.value == "config") {
            if (current != null && seen <= 80)
                push(raw, current);
            if (child != null)
                push(children, child);
            current = null;
            child = null;
            i = preview_skip_gap(text, i);
            let kind = preview_read_word(text, i);
            i = kind.next;
            let name = preview_read_value(text, i);
            i = preview_skip_tail(text, name.next);
            if (kind.value == "section") {
                seen++;
                if (seen > 80)
                    continue;
                let title = name.present ? trim_string(name.value) : "";
                if (title == "")
                    title = "#" + seen;
                current = blank_preview_section(title);
            }
            else if (preview_child_bucket(kind.value) != "")
                child = { bucket: preview_child_bucket(kind.value), owner: "", label: "", url: "" };
            continue;
        }
        if (word.value == "option" || word.value == "list") {
            i = preview_skip_gap(text, i);
            let key = preview_read_word(text, i);
            i = key.next;
            let value = preview_read_value(text, i);
            i = preview_skip_tail(text, value.next);
            if (!value.present)
                continue;
            if (current != null)
                preview_add_items(current, key.value, value.value, word.value);
            else if (child != null) {
                if (key.value == "section")
                    child.owner = trim_string(value.value);
                else if (key.value == "url" && child.bucket == "subscriptions")
                    child.url = value.value;
                else if (key.value == "name")
                    child.label = trim_string(value.value);
            }
            continue;
        }
        i = preview_skip_tail(text, i);
    }
    if (current != null && seen <= 80)
        push(raw, current);
    if (child != null)
        push(children, child);
    for (let item in children) {
        if (item.owner == "")
            continue;
        if (item.bucket == "subscriptions") {
            let host = preview_public_target(item.url);
            if (host == "")
                continue;
            for (let section in raw)
                if (section.id == item.owner)
                    preview_push_unique(section.subscriptions, host);
            continue;
        }
        let label = trim_string(item.label);
        if (label == "")
            label = preview_child_fallback(item.bucket);
        if (label == "")
            continue;
        for (let section in raw)
            if (section.id == item.owner)
                preview_push_unique(section[item.bucket], label);
    }
    let sections = [];
    for (let section in raw)
        push(sections, finish_preview_section(section));
    for (let section in sections) {
        section.dns_via = preview_named(sections, section.dns_via);
        section.cascade = preview_named(sections, section.cascade);
        let fallback = preview_fallback_parts(sections, section.fallback);
        section.fallback = fallback.name;
        section.fallback_tag = fallback.tag;
    }
    return {
        id: id,
        empty: file_size(path) <= 0,
        truncated: seen > 80,
        sections: sections
    };
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
        offline: slot_info("offline"),
        reserves: [
            reserve_card("r1"),
            reserve_card("r2"),
            reserve_card("r3")
        ]
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
        set_reserve_label,
        preview_slot,
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
else if (mode == "label")
    exit(set_reserve_label(ARGV[1], ARGV[2]) ? 0 : 1);
else if (mode == "preview") {
    let preview = preview_slot(ARGV[1]);
    if (preview == null)
        exit(1);
    print(sprintf("%J", preview), "\n");
    exit(0);
}
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
