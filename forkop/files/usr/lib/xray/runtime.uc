#!/usr/bin/env ucode

let fs = require("fs");
let uci_core = require("core.uci");
let connections = require("config.connections");
let xray_constants = require("xray.constants");
let engine = require("core.engine");
let urltest_step = "init";
let urltest_chosen = {};

function as_string(value) {
    return value == null ? "" : "" + value;
}

function trim(value) {
    return replace(as_string(value), /^[ \t\r\n]+|[ \t\r\n]+$/g, "");
}

function object_or_empty(value) {
    return type(value) == "object" ? value : {};
}

function array_or_empty(value) {
    return type(value) == "array" ? value : [];
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

function command_status(command) {
    let status = int(system(command));
    return status > 255 ? int(status / 256) : status;
}

function command_success(command) {
    return command_status("(" + command + ") >/dev/null 2>&1") == 0;
}

function command_success_from_args(args) {
    return command_success(command_from_args(args));
}

function command_output(command) {
    let pipe = fs.popen(command, "r");
    if (!pipe)
        return "";
    let data = pipe.read("all");
    pipe.close();
    return data == null ? "" : as_string(data);
}

function command_output_from_args(args) {
    return command_output(command_from_args(args));
}

function file_exists(path) {
    return fs.stat(path) != null;
}

function file_executable(path) {
    let st = fs.stat(path);
    return st != null && st.type == "file";
}

function write_file(path, value) {
    return fs.writefile(path, as_string(value));
}

function read_file(path) {
    let data = fs.readfile(path);
    return data == null ? "" : as_string(data);
}

function remove_file(path) {
    fs.unlink(path);
}

function ensure_dir(path) {
    path = as_string(path);
    if (path == "" || path == "/" || path == ".")
        return true;
    if (fs.stat(path) != null)
        return true;
    system("mkdir -p " + shell_quote(path) + " >/dev/null 2>&1");
    return fs.stat(path) != null;
}

function copy_file(src, dest) {
    src = as_string(src);
    dest = as_string(dest);
    if (src == "" || dest == "" || src == dest || !file_exists(src))
        return false;
    let slash = rindex(dest, "/");
    if (slash > 0 && !ensure_dir(substr(dest, 0, slash)))
        return false;
    return command_success("cp -f " + shell_quote(src) + " " + shell_quote(dest));
}

function file_md5(path) {
    if (!file_exists(path))
        return "";
    let fields = split(trim(command_output("md5sum " + shell_quote(path) + " 2>/dev/null")), /[ \t\r\n]+/);
    return length(fields) > 0 ? as_string(fields[0]) : "";
}

function file_stamp(path) {
    let st = fs.stat(as_string(path));
    if (st == null)
        return as_string(path) + ":0:0";
    return as_string(path) + ":" + as_string(st.size || 0) + ":" + as_string(st.mtime || 0);
}

function config_input_fingerprint() {
    let body = join("\n", [
        file_stamp("/etc/config/forkop"),
        file_stamp(xray_constants.XRAY_SELECTED_FILE),
        file_stamp(xray_constants.ALLOW_DOMAINS_DAT),
        file_stamp(xray_constants.ALLOW_DOMAINS_DAT_ETC),
        file_stamp(xray_constants.XRAY_LOCATION_ASSET + "/geosite.dat"),
        file_stamp(xray_constants.XRAY_LOCATION_ASSET + "/adlist.dat"),
        "balancer-live-switch-2"
    ]);
    let tmp = "/tmp/forkop-xray-fp." + as_string(clock()[0]);
    write_file(tmp, body + "\n");
    let sum = file_md5(tmp);
    remove_file(tmp);
    return sum;
}

function read_config_stamp() {
    let result = { fingerprint: "", config_md5: "", validated: false };
    for (let line in split(read_file(xray_constants.XRAY_CONFIG_STAMP), "\n")) {
        let sep = index(line, "=");
        if (sep <= 0)
            continue;
        let key = substr(line, 0, sep);
        let value = substr(line, sep + 1);
        if (key == "fingerprint")
            result.fingerprint = value;
        else if (key == "config_md5")
            result.config_md5 = value;
        else if (key == "validated")
            result.validated = value == "1";
    }
    return result;
}

function write_config_stamp(stamp) {
    stamp = object_or_empty(stamp);
    ensure_dir("/etc/forkop");
    write_file(xray_constants.XRAY_CONFIG_STAMP,
        "fingerprint=" + as_string(stamp.fingerprint) + "\n" +
        "config_md5=" + as_string(stamp.config_md5) + "\n" +
        "validated=" + (stamp.validated ? "1" : "0") + "\n");
}

function persist_runtime_sidecars() {
    let dir = xray_constants.XRAY_LAST_DIR;
    ensure_dir(dir);
    copy_file(xray_constants.XRAY_PORTS_FILE, dir + "/ports.json");
    copy_file(xray_constants.XRAY_CASCADE_FILE, dir + "/cascade.json");
    copy_file(xray_constants.XRAY_NODES_FILE, dir + "/nodes.json");
}

function restore_runtime_sidecars() {
    let dir = xray_constants.XRAY_LAST_DIR;
    ensure_dir("/var/run/forkop");
    copy_file(dir + "/ports.json", xray_constants.XRAY_PORTS_FILE);
    copy_file(dir + "/cascade.json", xray_constants.XRAY_CASCADE_FILE);
    copy_file(dir + "/nodes.json", xray_constants.XRAY_NODES_FILE);
}

function persist_lists_locally() {
    let settings = object_or_empty(uci_core.get_all("forkop", "settings"));
    let value = settings.persist_lists_locally;
    if (value == null)
        return true;
    return value === true || value == 1 || value == "1" || value == "true" || value == "yes" || value == "on";
}

function can_reuse_generated_config() {
    if (!persist_lists_locally())
        return false;
    if (!file_exists(xray_constants.XRAY_CONFIG))
        return false;
    let stamp = read_config_stamp();
    if (stamp.fingerprint == "")
        return false;
    return stamp.fingerprint == config_input_fingerprint();
}

function write_json(value) {
    print(sprintf("%J", value), "\n");
}

function log_message(message, level) {
    level = as_string(level || "info");
    message = as_string(message);
    command_success_from_args([ "logger", "-t", "forkop", "[" + level + "] " + message ]);
    if (level == "fatal" || level == "error")
        warn(message, "\n");
}

function parse_xray_version(text) {
    let newline = index(as_string(text), "\n");
    let line = trim(newline >= 0 ? substr(text, 0, newline) : text);
    let fields = split(line, /[ \t]+/);
    if (length(fields) >= 2 && lc(fields[0]) == "xray")
        return as_string(fields[1]);
    return length(fields) > 0 ? as_string(fields[length(fields) - 1]) : "";
}

function strip_leading_v(value) {
    value = as_string(value);
    return substr(value, 0, 1) == "v" || substr(value, 0, 1) == "V" ? substr(value, 1) : value;
}

function xray_installed() {
    return file_executable(xray_constants.XRAY_BIN);
}

function xray_version_output() {
    if (!xray_installed())
        return "";
    return command_output_from_args([ xray_constants.XRAY_BIN, "version" ]);
}

function xray_version() {
    let stored = trim(read_file(xray_constants.XRAY_VERSION_STATE_FILE));
    if (stored != "")
        return stored;
    return parse_xray_version(xray_version_output());
}

function write_version_state(version) {
    version = trim(version);
    if (version == "")
        return false;
    let parent = "/etc/forkop";
    if (fs.stat(parent) == null)
        system("mkdir -p " + shell_quote(parent) + " >/dev/null 2>&1");
    return write_file(xray_constants.XRAY_VERSION_STATE_FILE, version + "\n");
}

function read_json_object(path) {
    let data = read_file(path);
    if (data == "")
        return {};
    try {
        let value = json(data);
        return type(value) == "object" ? value : {};
    }
    catch (e) {
        return {};
    }
}

function read_ports() {
    return read_json_object(xray_constants.XRAY_PORTS_FILE);
}

function read_nodes() {
    return read_json_object(xray_constants.XRAY_NODES_FILE);
}

function write_empty_ports() {
    let path = xray_constants.XRAY_PORTS_FILE;
    let slash = rindex(path, "/");
    let parent = slash > 0 ? substr(path, 0, slash) : "";
    if (parent != "" && parent != "." && !ensure_dir(parent))
        return false;
    write_file(xray_constants.XRAY_CASCADE_FILE, "{}\n");
    write_file(xray_constants.XRAY_NODES_FILE, "{}\n");
    return write_file(path, "{}\n");
}

function xray_section_count() {
    return length(keys(read_ports()));
}

function uci_xray_section_count() {
    if (!uci_core.available())
        return 0;
    let count = 0;
    for (let section in uci_core.section_objects("forkop", "section")) {
        section = object_or_empty(section);
        let enabled = section.enabled == null ? "1" : as_string(section.enabled);
        if (enabled == "0")
            continue;
        if (!connections.is_connections_action(as_string(section.action || "")))
            continue;
        if (connections.proxy_core(section) == "xray")
            count++;
    }
    return count;
}

function xray_needed() {
    return engine.is_xray_primary() || xray_section_count() > 0 || uci_xray_section_count() > 0;
}

function as_port(value) {
    if (type(value) == "int" || type(value) == "double") {
        let port = int(value);
        return port > 0 ? port : 0;
    }
    let text = trim(as_string(value));
    if (match(text, /^[0-9]+$/) == null)
        return 0;
    let port = int(text);
    return port > 0 ? port : 0;
}

function collect_listen_ports() {
    let seen = {};
    let result = [];

    function remember(port) {
        port = as_port(port);
        if (port <= 0)
            return;
        let key = as_string(port);
        if (seen[key])
            return;
        seen[key] = true;
        push(result, port);
    }

    if (engine.is_xray_primary()) {
        remember(xray_constants.XRAY_TPROXY_PORT);
        remember(xray_constants.XRAY_TPROXY_FAKEIP_PORT);
        remember(xray_constants.XRAY_DNS_PORT);
        remember(xray_constants.XRAY_DNS_REDIR_PORT);
        if (uci_core.available()) {
            let settings = object_or_empty(uci_core.get_all("forkop", "settings"));
            if (as_string(settings.route_router_traffic || "") == "1" &&
                trim(as_string(settings.route_router_traffic_section || "")) != "")
                remember(xray_constants.XRAY_REDIRECT_PORT);
        }
    }

    let ports = read_ports();
    for (let name in keys(ports))
        remember(ports[name]);

    let nodes = read_nodes();
    for (let name in keys(nodes)) {
        for (let node in array_or_empty(nodes[name]))
            remember(object_or_empty(node).port);
    }

    return result;
}

function listen_table() {
    let data = command_output_from_args([ "netstat", "-ln" ]);
    if (trim(data) == "")
        data = command_output("ss -lntu 2>/dev/null");
    return as_string(data);
}

function port_is_listening(table, port) {
    port = as_string(port);
    if (port == "" || table == "")
        return false;
    return index(table, ":" + port + " ") >= 0 ||
        index(table, ":" + port + "\n") >= 0 ||
        index(table, ":" + port) >= 0;
}

function configured_ports_listening() {
    let ports = collect_listen_ports();
    if (length(ports) == 0)
        return false;
    let table = listen_table();
    if (trim(table) == "")
        return false;
    for (let port in ports) {
        if (!port_is_listening(table, port))
            return false;
    }
    return true;
}

function plane_listen_ready() {
    if (!engine.is_xray_primary())
        return configured_ports_listening();
    let table = listen_table();
    if (trim(table) == "")
        return false;
    let dns = as_string(xray_constants.XRAY_DNS_LISTEN) + ":" + as_string(xray_constants.XRAY_DNS_PORT);
    return index(table, dns) >= 0 && port_is_listening(table, xray_constants.XRAY_TPROXY_PORT);
}

function service_exists() {
    return file_exists(xray_constants.XRAY_SERVICE_INIT);
}

function service_enabled() {
    return service_exists() && command_success_from_args([ xray_constants.XRAY_SERVICE_INIT, "enabled" ]);
}

function procd_instance_running() {
    if (service_exists() && command_success_from_args([ xray_constants.XRAY_SERVICE_INIT, "running" ]))
        return true;
    let ubus = command_output("ubus call service list '{\"name\":\"xray\"}' 2>/dev/null");
    if (match(ubus, /"running"\s*:\s*true/) != null)
        return true;
    if (match(ubus, /"pid"\s*:\s*[1-9]/) != null)
        return true;
    return false;
}

function process_detected() {
    if (!xray_installed())
        return false;

    if (command_success_from_args([ "pidof", "xray" ]) ||
        command_success_from_args([ "pidof", "Xray" ]))
        return true;

    if (command_success_from_args([ "pgrep", "-x", "xray" ]) ||
        command_success_from_args([ "pgrep", "-x", "Xray" ]) ||
        command_success_from_args([ "pgrep", "-f", "^/usr/bin/xray[[:space:]]" ]))
        return true;

    let exes = command_output("ls -l /proc/[0-9]*/exe 2>/dev/null");
    if (index(exes, xray_constants.XRAY_BIN) >= 0)
        return true;

    return procd_instance_running();
}

function process_running() {
    if (!xray_installed())
        return false;
    return process_detected() || configured_ports_listening();
}

function urltest_pid_running(pid) {
    pid = trim(as_string(pid));
    return match(pid, /^[0-9]+$/) != null && command_success_from_args([ "kill", "-0", pid ]);
}

function stop_urltest_worker() {
    let pid = trim(read_file(xray_constants.XRAY_URLTEST_PID_FILE));
    let newline = index(pid, "\n");
    if (newline >= 0)
        pid = trim(substr(pid, 0, newline));
    if (urltest_pid_running(pid))
        command_success_from_args([ "kill", pid ]);
    remove_file(xray_constants.XRAY_URLTEST_PID_FILE);
}

function start_urltest_worker() {
    stop_urltest_worker();
    if (!engine.is_xray_primary())
        return 0;
    let parent = "/var/run/forkop";
    if (!ensure_dir(parent))
        return 1;
    let lib_dir = getenv("FORKOP_LIB") || "/usr/lib/forkop";
    let command = command_from_args([
        "ucode", "-L", lib_dir, lib_dir + "/xray/runtime.uc", "urltest-worker"
    ]) + " >/dev/null 2>&1 1000>&- & echo $! >" + shell_quote(xray_constants.XRAY_URLTEST_PID_FILE);
    return command_status(command);
}

function ports_listening() {
    if (!xray_installed())
        return false;
    if (!xray_needed())
        return false;
    return configured_ports_listening();
}

function check_config(path) {
    path = as_string(path || xray_constants.XRAY_CONFIG);
    if (!xray_installed())
        return { status: 1, reason: "xray is not installed" };
    if (!file_exists(path))
        return { status: 1, reason: "xray config is missing" };
    let output = "/tmp/xray-check." + as_string(clock()[0]);
    let test_cmd = command_from_args([ xray_constants.XRAY_BIN, "run", "-test", "-c", path ]);
    if (file_exists("/usr/bin/timeout"))
        test_cmd = command_from_args([ "/usr/bin/timeout", "20" ]) + " " + test_cmd;
    else if (file_exists("/bin/timeout"))
        test_cmd = command_from_args([ "/bin/timeout", "20" ]) + " " + test_cmd;
    test_cmd = "XRAY_LOCATION_ASSET=" + shell_quote(xray_constants.XRAY_LOCATION_ASSET) + " " + test_cmd;
    let status = command_status(test_cmd + " >" + shell_quote(output) + " 2>&1");
    let reason = trim(read_file(output));
    remove_file(output);
    if (status != 0 && reason == "")
        reason = "exit status " + status;
    return { status, reason };
}

function ensure_asset_env() {
    if (!file_exists(xray_constants.XRAY_SERVICE_INIT))
        return false;
    let text = read_file(xray_constants.XRAY_SERVICE_INIT);
    if (index(text, "XRAY_LOCATION_ASSET") >= 0)
        return true;
    let needle = "    procd_set_param command";
    if (index(text, needle) < 0)
        needle = "procd_set_param command";
    if (index(text, needle) < 0)
        return false;
    text = replace(text, needle,
        "    procd_set_param env XRAY_LOCATION_ASSET=\"" + xray_constants.XRAY_LOCATION_ASSET + "\"\n" + needle);
    return write_file(xray_constants.XRAY_SERVICE_INIT, text) != null;
}

function init_config() {
    if (uci_xray_section_count() == 0 && !engine.is_xray_primary()) {
        write_empty_ports();
        return;
    }

    if (engine.is_xray_primary()) {
        log_message("Xray plane: staging community lists from cache", "debug");
        ensure_asset_env();
        try {
            let xray_geodata = require("xray.geodata");
            xray_geodata.stage_geosite_dat();
            xray_geodata.ensure_from_uci();
        }
        catch (e) {
            log_message("Xray list conversion failed; continuing without converted lists: " + e, "warn");
        }
    }

    let LIB_DIR = getenv("FORKOP_LIB") || "/usr/lib/forkop";
    let generator = LIB_DIR + "/xray/generator.uc";
    if (!file_exists(generator)) {
        log_message("Xray generator is missing. Aborted.", "fatal");
        exit(1);
    }

    let fingerprint = engine.is_xray_primary() ? config_input_fingerprint() : "";
    if (engine.is_xray_primary() && can_reuse_generated_config()) {
        restore_runtime_sidecars();
        log_message("Xray plane: reusing existing configuration", "info");
    }
    else {
        log_message("Xray plane: generating configuration", "debug");
        let log_path = "/tmp/forkop-xray-generate." + as_string(clock()[0]);
        let status = command_status(
            command_from_args([
                "ucode", "-L", LIB_DIR, generator,
                "generate-config",
                xray_constants.XRAY_CONFIG,
                xray_constants.XRAY_PORTS_FILE
            ]) + " >" + shell_quote(log_path) + " 2>&1"
        );
        let output = trim(read_file(log_path));
        remove_file(log_path);
        if (status != 0) {
            log_message(
                "Failed to generate xray configuration" + (output != "" ? ": " + output : "") + ". Aborted.",
                "fatal"
            );
            exit(1);
        }
        persist_runtime_sidecars();
    }

    if (!xray_needed())
        return;

    if (!xray_installed()) {
        log_message("Xray is the routing plane or sections are enabled, but /usr/bin/xray is not installed. Install Xray from Components. Aborted.", "fatal");
        exit(1);
    }

    let stamp = read_config_stamp();
    let md5 = file_md5(xray_constants.XRAY_CONFIG);
    if (persist_lists_locally() && stamp.validated && stamp.config_md5 == md5) {
        log_message("Xray plane: skipping validation, config unchanged", "info");
        if (fingerprint != "" && stamp.fingerprint != fingerprint) {
            stamp.fingerprint = fingerprint;
            write_config_stamp(stamp);
        }
        return;
    }

    log_message("Xray plane: validating configuration", "debug");
    let check = check_config(xray_constants.XRAY_CONFIG);
    if (check.status != 0) {
        log_message("Generated xray configuration is invalid: " + check.reason + ". Aborted.", "fatal");
        exit(1);
    }
    write_config_stamp({
        fingerprint: fingerprint,
        config_md5: md5,
        validated: true
    });
}

function override_balancer_tag(balancer_tag, target, remove) {
    let args = [
        xray_constants.XRAY_BIN, "api", "bo",
        "-s", "127.0.0.1:" + as_string(xray_constants.XRAY_API_PORT),
        "-b", as_string(balancer_tag)
    ];
    if (remove)
        push(args, "-r");
    else
        push(args, as_string(target));
    return command_success_from_args(args);
}

function node_tags_of(section_name) {
    let result = [];
    for (let node in array_or_empty(read_nodes()[section_name])) {
        let tag = as_string(object_or_empty(node).tag || "");
        if (tag != "")
            push(result, tag);
    }
    return result;
}

function retarget_section_rules(config, section_name, tag) {
    section_name = as_string(section_name);
    let inbound = "socks-in-" + section_name;
    let balancer = "balancer-" + section_name;
    let probe_prefix = inbound + "-";
    let nodes = node_tags_of(section_name);
    for (let rule in array_or_empty(object_or_empty(config.routing).rules)) {
        rule = object_or_empty(rule);
        let probe_rule = false;
        for (let item in array_or_empty(rule.inboundTag)) {
            if (index(as_string(item), probe_prefix) == 0)
                probe_rule = true;
        }
        if (probe_rule)
            continue;
        let current = as_string(rule.outboundTag || "");
        let current_balancer = as_string(rule.balancerTag || "");
        let match = current_balancer == balancer;
        if (!match) {
            for (let item in array_or_empty(rule.inboundTag))
                if (as_string(item) == inbound)
                    match = true;
        }
        if (!match) {
            for (let node_tag in nodes)
                if (current == node_tag)
                    match = true;
        }
        if (!match)
            continue;
        delete rule.balancerTag;
        rule.outboundTag = tag;
    }
    return config;
}

function replace_routing_live(config) {
    if (type(object_or_empty(config).routing) != "object")
        return false;
    let path = "/tmp/forkop-xray-routing.json";
    if (write_file(path, sprintf("%J\n", { routing: config.routing })) == null)
        return false;
    let ok = command_success_from_args([
        xray_constants.XRAY_BIN, "api", "adrules",
        "-s", "127.0.0.1:" + as_string(xray_constants.XRAY_API_PORT),
        path
    ]);
    remove_file(path);
    return ok;
}

function apply_saved_balancer_overrides() {
    let selected = read_json_object(xray_constants.XRAY_SELECTED_FILE);
    let config = read_json_object(xray_constants.XRAY_CONFIG);
    let dirty = false;
    let seen = {};
    for (let balancer in array_or_empty(object_or_empty(config.routing).balancers)) {
        balancer = object_or_empty(balancer);
        let btag = as_string(balancer.tag || "");
        if (index(btag, "balancer-") != 0)
            continue;
        let section_name = substr(btag, length("balancer-"));
        seen[section_name] = true;
        let pin = as_string(selected[section_name] || "");
        if (pin == "" || pin == xray_constants.XRAY_URLTEST_TAG)
            continue;
        if (override_balancer_tag(btag, pin, false))
            continue;
        log_message("Xray balancer override failed for " + section_name + "; updating rules", "warn");
        retarget_section_rules(config, section_name, pin);
        dirty = true;
    }
    for (let section_name in selected) {
        if (seen[section_name])
            continue;
        let pin = as_string(selected[section_name] || "");
        if (pin == "" || pin == xray_constants.XRAY_URLTEST_TAG)
            continue;
        retarget_section_rules(config, section_name, pin);
        dirty = true;
    }
    if (!dirty)
        return;
    if (write_file(xray_constants.XRAY_CONFIG, sprintf("%J\n", config)) == null)
        log_message("failed to store the pinned Xray outbound", "warn");
    if (process_running() && !replace_routing_live(config))
        log_message("Xray routing API switch failed while restoring the selected servers", "warn");
}

function start_runtime() {
    if (!xray_needed())
        return 0;
    if (!xray_installed()) {
        log_message("Xray is required by enabled sections but is not installed", "fatal");
        return 1;
    }
    if (!service_exists()) {
        log_message("Xray service script is missing; install Xray from Components", "fatal");
        return 1;
    }
    ensure_asset_env();
    let log_path = "/tmp/forkop-xray-start." + as_string(clock()[0]);
    let status = command_status(
        command_from_args([ xray_constants.XRAY_SERVICE_INIT, "start" ]) +
        " >" + shell_quote(log_path) + " 2>&1"
    );
    let output = trim(read_file(log_path));
    remove_file(log_path);
    if (status != 0) {
        log_message(
            "Failed to start xray" + (output != "" ? ": " + output : "") + ". Aborted.",
            "fatal"
        );
        return 1;
    }

    let limit = engine.is_xray_primary() ? int(getenv("FORKOP_XRAY_START_VERIFY_TIMEOUT") || "60") : 8;
    let tries = 0;
    if (engine.is_xray_primary())
        log_message(
            "Starting Xray; waiting up to " + as_string(limit) +
            "s for DNS " + as_string(xray_constants.XRAY_DNS_LISTEN) +
            ":" + as_string(xray_constants.XRAY_DNS_PORT) +
            " and TPROXY :" + as_string(xray_constants.XRAY_TPROXY_PORT),
            "info"
        );
    while (tries < limit) {
        if (engine.is_xray_primary()) {
            if (process_detected() && plane_listen_ready()) {
                apply_saved_balancer_overrides();
                start_urltest_worker();
                return 0;
            }
        }
        else if (process_detected() || configured_ports_listening()) {
            apply_saved_balancer_overrides();
            start_urltest_worker();
            return 0;
        }
        command_status("sleep 1");
        tries++;
    }

    if (engine.is_xray_primary() && process_detected()) {
        log_message(
            "Xray started but DNS " + as_string(xray_constants.XRAY_DNS_LISTEN) +
            ":" + as_string(xray_constants.XRAY_DNS_PORT) +
            " / TPROXY :" + as_string(xray_constants.XRAY_TPROXY_PORT) +
            " are not listening. Check /etc/xray/config.json and logread -e xray.",
            "fatal"
        );
        return 1;
    }

    log_message(
        "Xray start returned success but the process is not running. Check /etc/xray/config.json and logread -e xray.",
        "fatal"
    );
    return 1;
}

function stop_runtime() {
    stop_urltest_worker();
    if (service_exists()) {
        let stop_cmd = command_from_args([ xray_constants.XRAY_SERVICE_INIT, "stop" ]);
        // procd can wait forever for Xray TPROXY sockets to drain.
        command_status(
            stop_cmd + " >/dev/null 2>&1 & child=$!; " +
            "(sleep 15; kill -KILL $child >/dev/null 2>&1) & watchdog=$!; " +
            "wait $child >/dev/null 2>&1; kill -KILL $watchdog >/dev/null 2>&1"
        );
    }
    command_success("killall xray >/dev/null 2>&1");
    command_success("killall -9 xray >/dev/null 2>&1");
    return 0;
}

function reload_runtime() {
    if (!xray_needed()) {
        stop_runtime();
        return 0;
    }
    if (process_running()) {
        if (command_success_from_args([ xray_constants.XRAY_SERVICE_INIT, "reload" ])) {
            apply_saved_balancer_overrides();
            return 0;
        }
        command_success_from_args([ xray_constants.XRAY_SERVICE_INIT, "restart" ]);
        apply_saved_balancer_overrides();
        return 0;
    }
    return start_runtime();
}

function status_json() {
    let installed = xray_installed() ? 1 : 0;
    let version = installed ? (xray_version() || "unknown") : "not installed";
    write_json({
        installed,
        version,
        configured: xray_needed() ? 1 : 0,
        section_count: xray_section_count(),
        service_exist: service_exists() ? 1 : 0,
        autostart_disabled: service_enabled() ? 0 : 1,
        process_running: process_running() ? 1 : 0,
        ports_listening: ports_listening() ? 1 : 0,
        config_path: xray_constants.XRAY_CONFIG,
        ready: installed && (!xray_needed() || (process_running() && ports_listening())) ? 1 : 0,
        status_message: installed ? version : "not installed"
    });
    return 0;
}

function check_json() {
    let installed = xray_installed() ? 1 : 0;
    let version = installed ? strip_leading_v(xray_version()) : "";
    let version_ok = 0;
    if (installed && version != "") {
        let LIB_DIR = getenv("FORKOP_LIB") || "/usr/lib/forkop";
        version_ok = command_success(command_from_args([
            "ucode", "-L", LIB_DIR, LIB_DIR + "/core/helpers.uc",
            "version-at-least", version, xray_constants.XRAY_REQUIRED_VERSION
        ])) ? 1 : 0;
    }
    write_json({
        xray_installed: installed,
        xray_version_ok: version_ok,
        xray_service_exist: service_exists() ? 1 : 0,
        xray_autostart_disabled: service_enabled() ? 0 : 1,
        xray_process_running: process_running() ? 1 : 0,
        xray_ports_listening: ports_listening() ? 1 : 0,
        xray_sections_configured: xray_needed() ? 1 : 0
    });
    return 0;
}

function show_config() {
    print(read_file(xray_constants.XRAY_CONFIG));
    return 0;
}

function parse_json_object(text) {
    text = trim(as_string(text));
    if (text == "")
        return null;
    let start = index(text, "{");
    if (start < 0)
        return null;
    try {
        let value = json(substr(text, start));
        return type(value) == "object" ? value : null;
    }
    catch (e) {
        return null;
    }
}

function stat_value(stat) {
    if (type(stat) != "object")
        return 0;
    let value = stat.value;
    if (value == null)
        value = stat.Value;
    if (type(value) == "object")
        value = value.value || value.Value || 0;
    return int(value || 0);
}

function stats_entries(parsed) {
    if (parsed == null)
        return [];
    if (type(parsed.stat) == "array")
        return parsed.stat;
    if (type(parsed.Stat) == "array")
        return parsed.Stat;
    if (type(parsed.stats) == "array")
        return parsed.stats;
    if (type(parsed.stat) == "object")
        return [ parsed.stat ];
    return [];
}

function xray_api_server() {
    return "127.0.0.1:" + as_string(xray_constants.XRAY_API_PORT);
}

function xray_api_output(subcommand) {
    return command_output(command_from_args([
        xray_constants.XRAY_BIN, "api", as_string(subcommand),
        "-s", xray_api_server()
    ]) + " 2>/dev/null");
}

function xray_inbound_stats() {
    let parsed = parse_json_object(xray_api_output("statsquery"));
    let uplink = 0;
    let downlink = 0;
    for (let stat in stats_entries(parsed)) {
        let name = as_string(object_or_empty(stat).name || object_or_empty(stat).Name || "");
        if (index(name, ">>>traffic>>>") < 0)
            continue;
        if (index(name, "inbound>>>api>>>") >= 0 || index(name, "outbound>>>api>>>") >= 0)
            continue;
        if (index(name, "inbound>>>") != 0)
            continue;
        if (index(name, ">>>uplink") >= 0)
            uplink += stat_value(stat);
        else if (index(name, ">>>downlink") >= 0)
            downlink += stat_value(stat);
    }
    return { uplink, downlink };
}

function nft_table_name() {
    let value = trim(getenv("NFT_TABLE_NAME") || "");
    return value != "" ? value : "ForkopTable";
}

function nft_chain_bytes(chain) {
    let parsed = parse_json_object(command_output_from_args([
        "nft", "-j", "list", "chain", "inet", nft_table_name(), as_string(chain)
    ]));
    if (parsed == null || type(parsed.nftables) != "array")
        return 0;
    let bytes = 0;
    for (let item in parsed.nftables) {
        let rule = object_or_empty(object_or_empty(item).rule);
        for (let expr in array_or_empty(rule.expr)) {
            let counter = object_or_empty(expr).counter;
            if (type(counter) == "object")
                bytes += int(counter.bytes || 0);
        }
    }
    return bytes;
}

function xray_sys_alloc() {
    let parsed = parse_json_object(xray_api_output("statssys"));
    if (parsed != null) {
        let alloc = int(parsed.Alloc || parsed.alloc || 0);
        if (alloc > 0)
            return alloc;
    }
    let pids = trim(command_output_from_args([ "pidof", "xray" ]));
    if (pids == "")
        pids = trim(command_output_from_args([ "pidof", "Xray" ]));
    if (pids == "")
        return 0;
    let pid = split(pids, " ")[0];
    let status = read_file("/proc/" + as_string(pid) + "/status");
    for (let line in split(status, "\n")) {
        if (index(line, "VmRSS:") != 0)
            continue;
        let parts = split(replace(line, /[\t ]+/g, " "), " ");
        return int(parts[1] || 0) * 1024;
    }
    return 0;
}

function xray_established_count() {
    let table = command_output("ss -Htn state established 2>/dev/null");
    if (trim(table) == "")
        table = command_output_from_args([ "netstat", "-tn" ]);
    let count = 0;
    let needle = ":" + as_string(xray_constants.XRAY_TPROXY_PORT);
    let fakeip_needle = ":" + as_string(xray_constants.XRAY_TPROXY_FAKEIP_PORT);
    for (let line in split(as_string(table), "\n")) {
        if (index(line, needle) >= 0 || index(line, fakeip_needle) >= 0)
            count++;
    }
    return count;
}

function stats_json() {
    if (!engine.is_xray_primary() || !process_running()) {
        write_json({
            success: false,
            uplink: 0,
            downlink: 0,
            connections: 0,
            memory: 0
        });
        return 0;
    }
    let traffic = xray_inbound_stats();
    let uplink = traffic.uplink;
    let downlink = traffic.downlink;
    if (uplink <= 0 && downlink <= 0) {
        let nft_bytes = nft_chain_bytes("proxy");
        if (nft_bytes <= 0)
            nft_bytes = nft_chain_bytes("mangle");
        uplink = nft_bytes;
    }
    write_json({
        success: true,
        uplink,
        downlink,
        connections: xray_established_count(),
        memory: xray_sys_alloc()
    });
    return 0;
}

function fakeip_mark_bit() {
    return 67108864;
}

function is_local_or_dns_dest(ip, port) {
    ip = as_string(ip);
    port = as_string(port);
    if (port == as_string(xray_constants.XRAY_TPROXY_PORT) ||
        port == as_string(xray_constants.XRAY_TPROXY_FAKEIP_PORT) ||
        port == as_string(xray_constants.XRAY_DNS_REDIR_PORT))
        return false;
    if (ip == "" || ip == "127.0.0.1" || ip == "::1" || ip == "0.0.0.0")
        return true;
    if (index(ip, "127.") == 0)
        return true;
    if (port == "53" && (ip == xray_constants.XRAY_DNS_LISTEN || ip == "127.0.0.42"))
        return true;
    return false;
}

function is_fakeip_dest(ip) {
    ip = as_string(ip);
    return index(ip, "198.18.") == 0 || index(ip, "198.19.") == 0 ||
        index(ip, "fc00:") == 0 || index(ip, "fc0") == 0;
}

function line_mark_value(line) {
    let m = match(as_string(line), /mark=([0-9]+)/);
    if (m != null)
        return int(m[1]);
    return 0;
}

function conntrack_is_forkop(line) {
    line = as_string(line);
    if ((int(line_mark_value(line)) & fakeip_mark_bit()) == fakeip_mark_bit())
        return true;
    if (index(line, "dst=198.18.") >= 0 || index(line, "dst=198.19.") >= 0)
        return true;
    if (index(line, "dport=" + as_string(xray_constants.XRAY_TPROXY_PORT)) >= 0)
        return true;
    if (index(line, "dport=" + as_string(xray_constants.XRAY_TPROXY_FAKEIP_PORT)) >= 0)
        return true;
    if (index(line, "dport=" + as_string(xray_constants.XRAY_DNS_REDIR_PORT)) >= 0)
        return true;
    return false;
}

function kv_values(line, key) {
    let result = [];
    let prefix = as_string(key) + "=";
    let rest = as_string(line);
    while (true) {
        let pos = index(rest, prefix);
        if (pos < 0)
            break;
        rest = substr(rest, pos + length(prefix));
        let end = index(rest, " ");
        push(result, end < 0 ? rest : substr(rest, 0, end));
        if (end < 0)
            break;
        rest = substr(rest, end + 1);
    }
    return result;
}

function access_time_iso(line) {
    let m = match(as_string(line), /^([0-9]{4})\/([0-9]{2})\/([0-9]{2})[ T]([0-9]{2}):([0-9]{2}):([0-9]{2})/);
    if (m == null)
        return "";
    return m[1] + "-" + m[2] + "-" + m[3] + "T" + m[4] + ":" + m[5] + ":" + m[6];
}

function split_hostport(value) {
    value = trim(as_string(value));
    if (value == "")
        return { host: "", port: "" };
    if (substr(value, 0, 1) == "[") {
        let close = index(value, "]");
        if (close > 0) {
            let host = substr(value, 1, close - 1);
            let rest = substr(value, close + 1);
            let port = substr(rest, 0, 1) == ":" ? substr(rest, 1) : "";
            return { host, port };
        }
    }
    let colon = rindex(value, ":");
    if (colon < 0)
        return { host: value, port: "" };
    return { host: substr(value, 0, colon), port: substr(value, colon + 1) };
}

function outbound_section_name(tag) {
    tag = as_string(tag);
    if (tag == "" || tag == xray_constants.FREEDOM_TAG || tag == xray_constants.BLACKHOLE_TAG ||
        tag == xray_constants.SINGBOX_SIDECAR_TAG)
        return "";
    let nodes = read_nodes();
    for (let name in keys(nodes)) {
        if (tag == xray_constants.outbound_tag(name) ||
            tag == xray_constants.balancer_tag(name))
            return name;
        for (let node in array_or_empty(nodes[name])) {
            if (as_string(object_or_empty(node).tag || "") == tag)
                return name;
        }
        if (index(tag, name + "-") == 0)
            return name;
    }
    if (!uci_core.available())
        return "";
    for (let section in uci_core.section_objects("forkop", "section")) {
        section = object_or_empty(section);
        let name = as_string(section[".name"] || "");
        if (name == "")
            continue;
        if (tag == xray_constants.outbound_tag(name) ||
            tag == xray_constants.balancer_tag(name) ||
            index(tag, xray_constants.outbound_tag(name) + "-") == 0)
            return name;
    }
    return "";
}

function clash_section_tag(section_name) {
    section_name = as_string(section_name);
    return section_name != "" ? section_name + "-out" : "";
}

function section_inbound_tag(section_name) {
    return "socks-in-" + as_string(section_name);
}

function section_balancer_tag(section_name) {
    return "balancer-" + as_string(section_name);
}

function parse_access_log_map() {
    let map = {};
    let data = command_output("tail -n 2500 " + shell_quote(xray_constants.XRAY_ACCESS_LOG) + " 2>/dev/null");
    for (let line in split(as_string(data), "\n")) {
        if (index(line, "accepted") < 0)
            continue;
        let from_pos = index(line, "from ");
        let acc_pos = index(line, " accepted ");
        if (from_pos < 0 || acc_pos < 0 || acc_pos <= from_pos)
            continue;
        let src_raw = trim(substr(line, from_pos + 5, acc_pos - from_pos - 5));
        let src = split_hostport(src_raw);
        let dest_start = acc_pos + 10;
        let dest_raw = trim(substr(line, dest_start));
        let proto = "tcp";
        if (index(dest_raw, "tcp:") == 0) {
            proto = "tcp";
            dest_raw = substr(dest_raw, 4);
        } else if (index(dest_raw, "udp:") == 0) {
            proto = "udp";
            dest_raw = substr(dest_raw, 4);
        }
        let space = index(dest_raw, " ");
        if (space >= 0)
            dest_raw = substr(dest_raw, 0, space);
        let dest = split_hostport(dest_raw);
        let detour = "";
        let detour_pos = index(line, "detour: ");
        if (detour_pos >= 0) {
            detour = trim(substr(line, detour_pos + 8));
            space = index(detour, " ");
            if (space >= 0)
                detour = substr(detour, 0, space);
        } else {
            let bracket = index(line, "[");
            let close = rindex(line, "]");
            if (bracket >= 0 && close > bracket) {
                let inside = substr(line, bracket + 1, close - bracket - 1);
                let arrow = index(inside, "->");
                if (arrow < 0)
                    arrow = index(inside, ">>");
                if (arrow >= 0)
                    detour = trim(substr(inside, arrow + 2));
            }
        }
        let key = proto + "|" + src.host + "|" + src.port;
        map[key] = {
            host: dest.host,
            port: dest.port,
            detour,
            start: access_time_iso(line)
        };
    }
    return map;
}

function conntrack_filter_script() {
    return join("\n", [
        "FNR == NR { srcport[$1 \" \" $2] = 1; next }",
        "{",
        "  gsub(/\\t/, \" \")",
        "  keep = 0",
        "  if (index($0, \"dport=1602\") > 0 || index($0, \"dport=1605\") > 0 || index($0, \"dport=1603\") > 0)",
        "    keep = 1",
        "  if (index($0, \"dst=198.18.\") > 0 || index($0, \"dst=198.19.\") > 0)",
        "    keep = 1",
        "  n = split($0, f, \" \")",
        "  src = \"\"",
        "  sport = \"\"",
        "  for (i = 1; i <= n; i++) {",
        "    if (index(f[i], \"mark=\") == 1) {",
        "      m = substr(f[i], 6) + 0",
        "      if (int(m / 67108864) % 2 == 1)",
        "        keep = 1",
        "    }",
        "    if (src == \"\" && index(f[i], \"src=\") == 1)",
        "      src = substr(f[i], 5)",
        "    if (sport == \"\" && index(f[i], \"sport=\") == 1)",
        "      sport = substr(f[i], 7)",
        "  }",
        "  if (src != \"\" && ((src \" \" sport) in srcport))",
        "    keep = 1",
        "  if (keep)",
        "    print",
        "}"
    ]);
}

function filter_conntrack(path, access) {
    path = as_string(path);
    if (!command_success("command -v awk >/dev/null 2>&1")) {
        if (file_exists(path))
            return read_file(path);
        return command_output("conntrack -L 2>/dev/null");
    }
    let pairs_path = "/tmp/forkop-xray-ct-src.txt";
    let script_path = "/tmp/forkop-xray-ct.awk";
    let body = "0 0\n";
    let count = 0;
    for (let key in access) {
        let parts = split(as_string(key), "|");
        if (length(parts) < 3)
            continue;
        let ip = as_string(parts[1] || "");
        let port = as_string(parts[2] || "");
        if (ip == "" || port == "")
            continue;
        body = body + ip + " " + port + "\n";
        count++;
        if (count >= 2500)
            break;
    }
    if (write_file(script_path, conntrack_filter_script() + "\n") == null) {
        if (file_exists(path))
            return read_file(path);
        return command_output("conntrack -L 2>/dev/null");
    }
    write_file(pairs_path, body);
    let raw = "";
    if (file_exists(path))
        raw = command_output("awk -f " + shell_quote(script_path) + " " + shell_quote(pairs_path) + " " + shell_quote(path) + " 2>/dev/null");
    else
        raw = command_output("conntrack -L 2>/dev/null | awk -f " + shell_quote(script_path) + " " + shell_quote(pairs_path) + " -");
    remove_file(pairs_path);
    remove_file(script_path);
    return raw;
}

function connections_json() {
    let access = parse_access_log_map();
    let raw = filter_conntrack("/proc/net/nf_conntrack", access);
    if (trim(raw) == "" && !file_exists("/proc/net/nf_conntrack"))
        raw = command_output("conntrack -L 2>/dev/null");
    let connections = [];
    let seen = {};
    let seen_src = {};
    for (let line in split(as_string(raw), "\n")) {
        let proto = index(line, " tcp ") >= 0 || index(line, "\ttcp\t") >= 0 ? "tcp" :
            (index(line, " udp ") >= 0 || index(line, "\tudp\t") >= 0 ? "udp" : "");
        if (proto == "")
            continue;
        let srcs = kv_values(line, "src");
        let dsts = kv_values(line, "dst");
        let sports = kv_values(line, "sport");
        let dports = kv_values(line, "dport");
        let packets = kv_values(line, "packets");
        let bytes = kv_values(line, "bytes");
        if (length(srcs) < 1 || length(dsts) < 1 || length(sports) < 1 || length(dports) < 1)
            continue;
        let src = srcs[0];
        let dst = dsts[0];
        let sport = sports[0];
        let dport = dports[0];
        let access_key = proto + "|" + src + "|" + sport;
        if (!conntrack_is_forkop(line) && object_or_empty(access[access_key]).host == null)
            continue;
        if (is_local_or_dns_dest(dst, dport) || is_local_or_dns_dest(src, sport))
            continue;
        if (src == xray_constants.XRAY_DNS_LISTEN)
            continue;
        let id = proto + "|" + src + "|" + sport + "|" + dst + "|" + dport;
        if (seen[id])
            continue;
        seen[id] = true;
        seen_src[access_key] = true;
        let access_hit = object_or_empty(access[access_key]);
        let host = as_string(access_hit.host || "");
        if (host == "" || is_fakeip_dest(host))
            host = is_fakeip_dest(dst) ? "" : dst;
        if (dst == "127.0.0.1" || dst == "::1") {
            if (as_string(access_hit.host || "") != "") {
                host = as_string(access_hit.host);
                dst = host;
            }
            if (as_string(access_hit.port || "") != "")
                dport = as_string(access_hit.port);
        }
        let section = outbound_section_name(access_hit.detour || "");
        let route = clash_section_tag(section);
        let chains = [];
        if (route != "")
            push(chains, route);
        else if (as_string(access_hit.detour || "") != "")
            push(chains, as_string(access_hit.detour));
        else
            push(chains, "tproxy-in");
        let upload = length(bytes) > 0 ? int(bytes[0]) : 0;
        let download = length(bytes) > 1 ? int(bytes[1]) : 0;
        push(connections, {
            id,
            upload,
            download,
            start: as_string(access_hit.start || ""),
            chains,
            rule: route != "" ? "=> route(" + route + ")" : "=> route(" + as_string(chains[0]) + ")",
            metadata: {
                network: proto,
                type: "TProxy",
                sourceIP: src,
                sourcePort: sport,
                destinationIP: is_fakeip_dest(dst) && host != "" ? host : dst,
                destinationPort: as_string(access_hit.port || dport),
                host
            }
        });
        if (length(connections) >= 300)
            break;
    }
    write_json({ connections });
    return 0;
}

function close_tracked_connection(id) {
    let parts = split(as_string(id), "|");
    if (length(parts) < 5)
        return false;
    let proto = parts[0];
    let src = parts[1];
    let sport = parts[2];
    let dst = parts[3];
    let dport = parts[4];
    command_success("conntrack -D -p " + proto +
        " -s " + shell_quote(src) + " --sport " + sport +
        " -d " + shell_quote(dst) + " --dport " + dport +
        " >/dev/null 2>&1");
    command_success("ss -K src " + shell_quote(src) + " sport = :" + sport +
        " dst " + shell_quote(dst) + " dport = :" + dport +
        " >/dev/null 2>&1");
    return true;
}

function close_connection_json(id) {
    write_json({ success: close_tracked_connection(id) ? true : false });
    return 0;
}

function close_all_connections_json() {
    command_success("conntrack -D --mark " + as_string(fakeip_mark_bit()) +
        "/" + as_string(fakeip_mark_bit()) + " >/dev/null 2>&1");
    write_json({ success: true });
    return 0;
}

function read_selected_outbounds() {
    return read_json_object(xray_constants.XRAY_SELECTED_FILE);
}

function write_selected_outbounds(value) {
    let parent = "/etc/forkop";
    if (fs.stat(parent) == null)
        system("mkdir -p " + shell_quote(parent) + " >/dev/null 2>&1");
    return write_file(xray_constants.XRAY_SELECTED_FILE, sprintf("%J\n", value));
}

function uci_section_by_name(section_name) {
    section_name = as_string(section_name);
    if (!uci_core.available() || section_name == "")
        return {};
    for (let section in uci_core.section_objects("forkop", "section")) {
        section = object_or_empty(section);
        if (as_string(section[".name"] || "") == section_name)
            return section;
    }
    return {};
}

function uci_section_uses_urltest(section_name) {
    let section = uci_section_by_name(section_name);
    return length(connections.urltests(section)) > 0;
}

function section_node_tags(section_name) {
    let result = [];
    for (let node in array_or_empty(read_nodes()[section_name])) {
        let tag = as_string(object_or_empty(node).tag || "");
        if (tag != "")
            push(result, tag);
    }
    return result;
}

function rule_has_inbound(rule, tag) {
    for (let inbound in array_or_empty(object_or_empty(rule).inboundTag))
        if (as_string(inbound) == tag)
            return true;
    return false;
}

function apply_selected_tag_to_config(config, section_name, tag) {
    return retarget_section_rules(config, section_name, tag);
}

function write_latency_delays(updates) {
    let delays = read_json_object(xray_constants.XRAY_LATENCY_FILE);
    if (type(delays) != "object")
        delays = {};
    updates = object_or_empty(updates);
    for (let tag in updates)
        delays[as_string(tag)] = int(updates[tag] || 0);
    let path = xray_constants.XRAY_LATENCY_FILE;
    let slash = rindex(path, "/");
    let parent = slash > 0 ? substr(path, 0, slash) : "";
    if (parent != "" && parent != "." && !ensure_dir(parent))
        return false;
    return write_file(path, sprintf("%J\n", delays)) != null;
}

function nodes_with_latency() {
    let nodes = read_nodes();
    let delays = read_json_object(xray_constants.XRAY_LATENCY_FILE);
    for (let section_name in nodes) {
        let list = array_or_empty(nodes[section_name]);
        if (uci_section_uses_urltest(section_name)) {
            let auto_node = {
                tag: xray_constants.XRAY_URLTEST_TAG,
                name: "Fastest",
                kind: "urltest",
                delay: 0
            };
            let prefixed = [ auto_node ];
            for (let node in list)
                push(prefixed, node);
            list = prefixed;
        }
        for (let node in list) {
            if (type(node) != "object")
                continue;
            let tag = as_string(node.tag || "");
            let delay = int(delays[tag] || 0);
            if (delay > 0)
                node.delay = delay;
        }
        nodes[section_name] = list;
    }
    return nodes;
}

function nodes_json() {
    let selected = read_selected_outbounds();
    let nodes = nodes_with_latency();
    for (let section_name in nodes) {
        if (!uci_section_uses_urltest(section_name))
            continue;
        let current = as_string(selected[section_name] || "");
        if (current == "")
            selected[section_name] = xray_constants.XRAY_URLTEST_TAG;
    }
    write_json({
        success: true,
        nodes,
        selected
    });
    return 0;
}

function select_outbound_json(section_name, tag) {
    section_name = trim(as_string(section_name));
    tag = trim(as_string(tag));
    let auto = tag == xray_constants.XRAY_URLTEST_TAG;
    let nodes = section_node_tags(section_name);
    let found = auto;
    for (let node_tag in nodes)
        if (node_tag == tag)
            found = true;
    if (section_name == "" || tag == "" || !found) {
        write_json({ success: false, error: "unknown xray outbound" });
        return 1;
    }

    let selected = read_selected_outbounds();
    if (auto) {
        delete selected[section_name];
    }
    else
        selected[section_name] = tag;
    if (!write_selected_outbounds(selected)) {
        write_json({ success: false, error: "failed to persist xray selection" });
        return 1;
    }

    let balancer_tag = section_balancer_tag(section_name);
    let config = read_json_object(xray_constants.XRAY_CONFIG);
    let has_balancer = false;
    for (let balancer in array_or_empty(object_or_empty(config.routing).balancers)) {
        if (as_string(object_or_empty(balancer).tag || "") == balancer_tag)
            has_balancer = true;
    }
    if (auto) {
        if (has_balancer && process_running())
            override_balancer_tag(balancer_tag, "", true);
        init_config();
        if (reload_runtime() != 0) {
            write_json({ success: false, error: "xray reload failed" });
            return 1;
        }
        start_urltest_worker();
        write_json({ success: true, section: section_name, tag: tag });
        return 0;
    }

    if (type(config.routing) != "object") {
        write_json({ success: false, error: "xray config is missing" });
        return 1;
    }
    apply_selected_tag_to_config(config, section_name, tag);
    if (write_file(xray_constants.XRAY_CONFIG, sprintf("%J\n", config)) == null) {
        write_json({ success: false, error: "failed to write xray config" });
        return 1;
    }
    if (process_running() && replace_routing_live(config)) {
        delete urltest_chosen[section_name];
        write_json({ success: true, section: section_name, tag: tag });
        return 0;
    }
    let check = check_config(xray_constants.XRAY_CONFIG);
    if (check.status != 0) {
        write_json({ success: false, error: check.reason });
        return 1;
    }
    if (reload_runtime() != 0) {
        write_json({ success: false, error: "xray reload failed" });
        return 1;
    }
    delete urltest_chosen[section_name];
    write_json({ success: true, section: section_name, tag: tag });
    return 0;
}

function latency_test_url() {
    if (!uci_core.available())
        return "https://www.gstatic.com/generate_204";
    let settings = object_or_empty(uci_core.get_all("forkop", "settings"));
    let value = trim(as_string(settings.latency_test_url || ""));
    return value != "" ? value : "https://www.gstatic.com/generate_204";
}

function latency_tags(latency_type, tag) {
    tag = trim(as_string(tag));
    if (as_string(latency_type) == "proxy_list") {
        try {
            let parsed = json(tag);
            if (type(parsed) == "array") {
                let tags = [];
                for (let item in parsed) {
                    item = trim(as_string(item));
                    if (item != "")
                        push(tags, item);
                }
                return tags;
            }
        }
        catch (e) {
        }
    }
    return tag != "" ? [ tag ] : [];
}

function node_port_by_tag(tag) {
    tag = as_string(tag);
    let nodes = read_nodes();
    for (let section_name in nodes) {
        for (let node in array_or_empty(nodes[section_name])) {
            if (type(node) == "object" && as_string(node.tag || "") == tag)
                return int(node.port || 0);
        }
    }
    return 0;
}

function seconds_to_ms(value) {
    value = trim(as_string(value));
    let parts = split(value, ".");
    let sec = int(parts[0] || 0);
    let frac = as_string(parts[1] || "0");
    while (length(frac) < 3)
        frac += "0";
    return sec * 1000 + int(substr(frac, 0, 3));
}

function probe_socks_delay(port, url, timeout_ms) {
    port = int(port || 0);
    timeout_ms = int(timeout_ms || 5000);
    if (port <= 0)
        return 0;
    let seconds = int(timeout_ms / 1000);
    if (seconds < 1)
        seconds = 1;
    let cmd = "curl -sS -o /dev/null -w '%{http_code} %{time_total}' --connect-timeout " +
        as_string(seconds) + " --max-time " + as_string(seconds) +
        " -x socks5h://127.0.0.1:" + as_string(port) + " " + shell_quote(url);
    let out = trim(command_output(cmd + " 2>/dev/null"));
    let parts = split(replace(out, /[ \t]+/g, " "), " ");
    if (length(parts) < 2)
        return 0;
    let code = as_string(parts[0]);
    if (code == "" || code == "000")
        return 0;
    let delay = seconds_to_ms(parts[1]);
    return delay > 0 ? delay : 1;
}

function latency_test_json(latency_type, tag, timeout) {
    let tags = latency_tags(latency_type, tag);
    let url = latency_test_url();
    let timeout_ms = int(timeout || 5000);
    let delays = read_json_object(xray_constants.XRAY_LATENCY_FILE);
    if (type(delays) != "object")
        delays = {};
    for (let item in tags) {
        let port = node_port_by_tag(item);
        delays[item] = probe_socks_delay(port, url, timeout_ms);
    }
    if (!write_latency_delays(delays))
        return 1;
    return 0;
}

function resolve_probe_port(tag) {
    tag = trim(as_string(tag));
    if (tag == "")
        return 0;
    let ports = read_ports();
    let port = int(ports[tag] || 0);
    if (port > 0)
        return port;
    return node_port_by_tag(tag);
}

function proxy_latency_json(tag, timeout) {
    tag = trim(as_string(tag));
    let delay = probe_socks_delay(resolve_probe_port(tag), latency_test_url(), int(timeout || 5000));
    let updates = {};
    updates[tag] = delay;
    write_latency_delays(updates);
    if (delay > 0) {
        write_json({ delay });
        return 0;
    }
    write_json({ message: "timeout" });
    return 0;
}

function group_latency_json(section_name, timeout) {
    section_name = trim(as_string(section_name));
    let timeout_ms = int(timeout || 5000);
    let url = latency_test_url();
    let result = {};
    let nodes = array_or_empty(read_nodes()[section_name]);
    for (let node in nodes) {
        if (type(node) != "object")
            continue;
        let tag = as_string(node.tag || "");
        if (tag == "")
            continue;
        let port = int(node.port || 0);
        if (port <= 0)
            port = node_port_by_tag(tag);
        let delay = probe_socks_delay(port, url, timeout_ms);
        result[tag] = delay;
    }
    let section_delay = probe_socks_delay(int(read_ports()[section_name] || 0), url, timeout_ms);
    if (section_delay > 0)
        result[section_name] = section_delay;
    write_latency_delays(result);
    write_json(result);
    return 0;
}

function duration_to_seconds(value, fallback_seconds) {
    value = trim(as_string(value));
    if (value == "")
        return fallback_seconds;
    let matched = match(value, /^([0-9]+)(ms|s|m|h)?$/);
    if (matched == null)
        return fallback_seconds;
    let amount = int(matched[1] || 0);
    let unit = as_string(matched[2] || "s");
    if (unit == "ms")
        amount = int((amount + 999) / 1000);
    else if (unit == "m")
        amount *= 60;
    else if (unit == "h")
        amount *= 3600;
    return amount > 0 ? amount : fallback_seconds;
}

function urltest_first_id(section) {
    let parent = as_string(section[".name"] || "");
    if (parent == "" || !uci_core.available())
        return as_string(section.urltest_enabled || "") == "1" ? "urltest" : "";
    try {
        for (let child in uci_core.section_objects("forkop", "urltest")) {
            child = object_or_empty(child);
            if (as_string(child.section || "") != parent)
                continue;
            let id = as_string(child[".name"] || child.id || "");
            if (id != "")
                return id;
        }
    }
    catch (e) {
    }
    return as_string(section.urltest_enabled || "") == "1" ? "urltest" : "";
}

function current_rule_outbound(config, section_name) {
    let inbound = section_inbound_tag(section_name);
    for (let rule in array_or_empty(object_or_empty(config.routing).rules)) {
        rule = object_or_empty(rule);
        if (!rule_has_inbound(rule, inbound))
            continue;
        let tag = as_string(rule.outboundTag || "");
        if (tag != "")
            return tag;
        return as_string(rule.balancerTag || "");
    }
    return "";
}

function section_is_connection(section) {
    let action = as_string(section.action || "");
    return action == "" || action == "connection" || action == "proxy" ||
        action == "outbound" || action == "vpn";
}

function section_core_name(section) {
    let raw = lc(as_string(section.proxy_core || ""));
    if (raw == "xray" || raw == "xray-core")
        return "xray";
    if (raw == "sing-box" || raw == "singbox")
        return "sing-box";
    return engine.is_xray_primary() ? "xray" : "sing-box";
}

function urltest_tick() {
    urltest_step = "plane";
    if (!engine.is_xray_primary() || !process_running())
        return 0;
    urltest_step = "selected";
    let selected = read_selected_outbounds();
    urltest_step = "config";
    let config = read_json_object(xray_constants.XRAY_CONFIG);
    if (type(config.routing) != "object")
        return 0;
    urltest_step = "latency";
    let delays = read_json_object(xray_constants.XRAY_LATENCY_FILE);
    if (type(delays) != "object")
        delays = {};
    let changed = false;
    urltest_step = "sections";
    for (let section in uci_core.section_objects("forkop", "section")) {
        section = object_or_empty(section);
        let name = as_string(section[".name"] || "");
        if (name == "" || as_string(section.enabled || "1") == "0")
            continue;
        if (!section_is_connection(section))
            continue;
        urltest_step = "core:" + name;
        if (section_core_name(section) != "xray")
            continue;
        urltest_step = "urltests:" + name;
        let urltest_id = urltest_first_id(section);
        if (urltest_id == "")
            continue;
        let pin = as_string(selected[name] || "");
        if (pin != "" && pin != xray_constants.XRAY_URLTEST_TAG)
            continue;
        urltest_step = "nodes:" + name;
        let tags = section_node_tags(name);
        if (length(tags) < 2)
            continue;
        urltest_step = "url:" + name;
        let url = as_string(section.urltest_testing_url || "") || "https://www.gstatic.com/generate_204";
        let tolerance = int(section.urltest_tolerance || 50);
        if (uci_core.available() && urltest_id != "" && urltest_id != "urltest") {
            try {
                let child = object_or_empty(uci_core.get_all("forkop", urltest_id));
                let child_url = as_string(child.testing_url || child.urltest_testing_url || "");
                if (child_url != "")
                    url = child_url;
                let child_tol = int(child.tolerance || child.urltest_tolerance || 0);
                if (child_tol > 0)
                    tolerance = child_tol;
            }
            catch (e) {
            }
        }
        if (tolerance <= 0)
            tolerance = 50;
        let best_tag = "";
        let best_delay = 0;
        for (let tag in tags) {
            urltest_step = "probe:" + name + ":" + as_string(tag);
            let delay = probe_socks_delay(node_port_by_tag(tag), url, 5000);
            delays[tag] = delay;
            if (delay <= 0)
                continue;
            if (best_tag == "" || delay < best_delay) {
                best_tag = as_string(tag);
                best_delay = delay;
            }
        }
        if (best_tag == "")
            continue;
        urltest_step = "current:" + name;
        let current = as_string(urltest_chosen[name] || "");
        if (current == "")
            current = current_rule_outbound(config, name);
        if (index(current, "balancer-") == 0)
            current = "";
        let current_delay = int(delays[current] || 0);
        if (current == best_tag)
            continue;
        if (current_delay > 0 && current_delay <= best_delay + tolerance)
            continue;
        urltest_step = "apply:" + name;
        let balancer_tag = section_balancer_tag(name);
        let has_balancer = false;
        for (let balancer in array_or_empty(object_or_empty(config.routing).balancers)) {
            if (as_string(object_or_empty(balancer).tag || "") == balancer_tag)
                has_balancer = true;
        }
        if (has_balancer) {
            if (override_balancer_tag(balancer_tag, best_tag, false)) {
                urltest_chosen[name] = best_tag;
                log_message("Xray URLTest: " + name + " -> " + best_tag + " (" + as_string(best_delay) + "ms)", "info");
                continue;
            }
            log_message("Xray URLTest balancer switch failed for " + name + "; updating rules", "warn");
            apply_selected_tag_to_config(config, name, best_tag);
            if (replace_routing_live(config)) {
                urltest_chosen[name] = best_tag;
                log_message("Xray URLTest: " + name + " -> " + best_tag + " (" + as_string(best_delay) + "ms)", "info");
                continue;
            }
            log_message("Xray URLTest routing API failed for " + name + "; reloading", "warn");
            changed = true;
            continue;
        }
        apply_selected_tag_to_config(config, name, best_tag);
        changed = true;
        log_message("Xray URLTest: " + name + " -> " + best_tag + " (" + as_string(best_delay) + "ms)", "info");
    }
    urltest_step = "write";
    write_file(xray_constants.XRAY_LATENCY_FILE, sprintf("%J\n", delays));
    if (!changed)
        return 0;
    if (!write_file(xray_constants.XRAY_CONFIG, sprintf("%J\n", config)))
        return 1;
    urltest_step = "validate";
    let check = check_config(xray_constants.XRAY_CONFIG);
    if (check.status != 0) {
        log_message("Xray URLTest skipped invalid config: " + check.reason, "warn");
        return 1;
    }
    urltest_step = "reload";
    return reload_runtime();
}

function urltest_worker() {
    if (!engine.is_xray_primary())
        return 0;
    command_status("sleep 8");
    while (engine.is_xray_primary() && process_running()) {
        urltest_step = "tick";
        try {
            urltest_tick();
        }
        catch (e) {
            log_message("Xray URLTest worker at " + urltest_step + ": " + e, "warn");
        }
        let wait_seconds = 180;
        for (let section in uci_core.section_objects("forkop", "section")) {
            section = object_or_empty(section);
            if (as_string(section.enabled || "1") == "0")
                continue;
            if (!section_is_connection(section))
                continue;
            let urltest_id = urltest_first_id(section);
            if (urltest_id == "")
                continue;
            let interval = 180;
            let raw_interval = as_string(section.urltest_check_interval || "");
            if (uci_core.available() && urltest_id != "" && urltest_id != "urltest") {
                try {
                    let child = object_or_empty(uci_core.get_all("forkop", urltest_id));
                    let child_interval = as_string(child.check_interval || child.urltest_check_interval || "");
                    if (child_interval != "")
                        raw_interval = child_interval;
                }
                catch (e) {
                }
            }
            if (raw_interval != "")
                interval = duration_to_seconds(raw_interval, 180);
            if (interval < wait_seconds)
                wait_seconds = interval;
        }
        if (wait_seconds < 15)
            wait_seconds = 15;
        command_status("sleep " + as_string(wait_seconds));
    }
    return 0;
}

function show_version() {
    print(xray_version(), "\n");
    return 0;
}

let mode = ARGV[0] || "";

if (mode == "init-config")
    init_config();
else if (mode == "start-runtime")
    exit(start_runtime());
else if (mode == "stop-runtime")
    exit(stop_runtime());
else if (mode == "reload-runtime")
    exit(reload_runtime());
else if (mode == "status")
    exit(status_json());
else if (mode == "running")
    exit(process_running() ? 0 : 1);
else if (mode == "check")
    exit(check_json());
else if (mode == "installed")
    exit(xray_installed() ? 0 : 1);
else if (mode == "version")
    exit(show_version());
else if (mode == "version-from-output") {
    print(parse_xray_version(fs.readfile("/dev/stdin") || ""), "\n");
}
else if (mode == "write-version-state")
    exit(write_version_state(ARGV[1] || "") ? 0 : 1);
else if (mode == "read-version-state")
    print(trim(read_file(xray_constants.XRAY_VERSION_STATE_FILE)), "\n");
else if (mode == "show-config")
    exit(show_config());
else if (mode == "ports")
    write_json(read_ports());
else if (mode == "stats")
    exit(stats_json());
else if (mode == "connections")
    exit(connections_json());
else if (mode == "nodes")
    exit(nodes_json());
else if (mode == "latency-test")
    exit(latency_test_json(ARGV[1] || "", ARGV[2] || "", ARGV[3] || ""));
else if (mode == "proxy-latency")
    exit(proxy_latency_json(ARGV[1] || "", ARGV[2] || ""));
else if (mode == "group-latency")
    exit(group_latency_json(ARGV[1] || "", ARGV[2] || ""));
else if (mode == "urltest-worker")
    exit(urltest_worker());
else if (mode == "select-outbound")
    exit(select_outbound_json(ARGV[1] || "", ARGV[2] || ""));
else if (mode == "close-connection")
    exit(close_connection_json(ARGV[1] || ""));
else if (mode == "close-all-connections")
    exit(close_all_connections_json());
else if (mode == "needed")
    exit(xray_needed() ? 0 : 1);
else {
    warn("Usage: xray/runtime.uc <init-config|start-runtime|stop-runtime|status|running|check|...> ...\n");
    exit(1);
}
