#!/usr/bin/env ucode

// Strategy check follows ByeByeDPI (GPL-3, https://github.com/romanvht/ByeByeDPI):
// start ciadpi as a local SOCKS proxy, request each site through it, and count a
// hit only when the response body is received in full. The built-in command list
// and domain lists live in strategy-data/ and come from that project.

let fs = require("fs");

const LIB_DIR = getenv("FORKOP_LIB") || "/usr/lib/forkop";
const DATA_DIR = getenv("BYEDPI_STRATEGY_DATA") || (LIB_DIR + "/providers/byedpi/strategy-data");
const BYEDPI_BIN = getenv("BYEDPI_BIN") || "/usr/bin/ciadpi";
const STATE_DIR = getenv("BYEDPI_STRATEGY_STATE_DIR") || "/var/run/forkop/byedpi-strategy";
const LISTEN_ADDRESS = "127.0.0.1";
const PORT_BASE = int(getenv("BYEDPI_STRATEGY_PORT_BASE") || "39281");
const STATE_FILE = STATE_DIR + "/state.json";
const REQUEST_FILE = STATE_DIR + "/request.json";
const STOP_FILE = STATE_DIR + "/stop";
const WORKER_LOG = STATE_DIR + "/worker.log";

let LIST_ORDER = [
    "youtube", "googlevideo", "discord", "telegram", "social", "general", "cloudflare", "türkiye"
];

function as_string(value) {
    return value == null ? "" : "" + value;
}

function write_json(value) {
    print(sprintf("%J", value), "\n");
}

function json_text(value) {
    return sprintf("%J", value) + "\n";
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

function command_output(command) {
    let pipe = fs.popen(command, "r");
    if (!pipe)
        return "";
    let data = pipe.read("all");
    let status = pipe.close();
    if (status != 0 || data == null)
        return "";
    return as_string(data);
}

function command_status(command) {
    let status = int(system(command));
    return status > 255 ? int(status / 256) : status;
}

function command_success_from_args(args) {
    return command_status(command_from_args(args) + " >/dev/null 2>&1") == 0;
}

function now_seconds() {
    return int(clock()[0]);
}

function read_text(path) {
    let data = fs.readfile(as_string(path));
    return data == null ? "" : as_string(data);
}

function read_json(path) {
    let data = read_text(path);
    if (data == "")
        return null;
    try {
        return json(data);
    }
    catch (e) {
        return null;
    }
}

function write_file(path, value) {
    return fs.writefile(as_string(path), as_string(value)) != null;
}

function write_json_file(path, value) {
    path = as_string(path);
    let stamp = clock();
    let tmp_path = sprintf("%s.%d.%d.tmp", path, stamp[0], stamp[1]);
    if (!write_file(tmp_path, json_text(value))) {
        try { fs.unlink(tmp_path); } catch (e) {}
        return false;
    }
    if (!fs.rename(tmp_path, path)) {
        try { fs.unlink(tmp_path); } catch (e) {}
        return false;
    }
    return true;
}

function ensure_state_dir() {
    return command_success_from_args([ "mkdir", "-p", STATE_DIR, STATE_DIR + "/probe" ]);
}

function provider_available() {
    let stat = fs.stat(BYEDPI_BIN);
    return stat != null && stat.mode != null && (int(stat.mode) & 73) != 0;
}

function contains(values, needle) {
    for (let value in values)
        if (value == needle)
            return true;
    return false;
}

function clamp_int(value, min_value, max_value, fallback) {
    let text = trim(as_string(value));
    if (match(text, /^-?[0-9]+$/) == null)
        return fallback;
    let number = int(text);
    if (number < min_value)
        return min_value;
    if (number > max_value)
        return max_value;
    return number;
}

function empty_state() {
    return {
        success: true,
        running: false,
        stopping: false,
        failed: false,
        interrupted: false,
        message: "",
        current: 0,
        total: 0,
        pid: "",
        ciadpi_pid: "",
        child_pids: [],
        started_at: 0,
        updated_at: 0,
        finished_at: 0,
        settings: {},
        strategies: []
    };
}

function read_state() {
    let value = read_json(STATE_FILE);
    if (type(value) != "object")
        return empty_state();
    if (type(value.strategies) != "array")
        value.strategies = [];
    if (type(value.child_pids) != "array")
        value.child_pids = [];
    if (type(value.settings) != "object")
        value.settings = {};
    return value;
}

function save_state(state) {
    state.updated_at = now_seconds();
    return write_json_file(STATE_FILE, state);
}

function pid_running(pid) {
    pid = as_string(pid);
    if (match(pid, /^[0-9]+$/) == null)
        return false;
    return command_success_from_args([ "kill", "-0", pid ]);
}

function kill_pid(pid, signal) {
    pid = as_string(pid);
    if (!pid_running(pid))
        return;
    let args = [ "kill" ];
    if (as_string(signal) != "")
        push(args, "-" + as_string(signal));
    push(args, pid);
    command_success_from_args(args);
}

function sleep_for(seconds) {
    seconds = int(seconds);
    if (seconds < 1)
        command_success_from_args([ "sleep", "0.4" ]);
    else
        command_success_from_args([ "sleep", as_string(seconds) ]);
}

function stop_requested() {
    return fs.stat(STOP_FILE) != null;
}

function shell_split(value) {
    let tokens = [];
    let current = "";
    let quote = "";
    let size = length(as_string(value));
    value = as_string(value);

    for (let i = 0; i < size; i++) {
        let ch = substr(value, i, 1);
        if (quote == "" && (ch == " " || ch == "\t" || ch == "\n" || ch == "\r")) {
            if (current != "") {
                push(tokens, current);
                current = "";
            }
            continue;
        }
        if (quote == "" && (ch == "'" || ch == "\"")) {
            quote = ch;
            continue;
        }
        if (quote != "" && ch == quote) {
            quote = "";
            continue;
        }
        if (ch == "\\" && quote != "'") {
            let next = substr(value, i + 1, 1);
            if (next != "") {
                current = current + next;
                i++;
                continue;
            }
        }
        current = current + ch;
    }

    if (current != "")
        push(tokens, current);
    return tokens;
}

function token_looks_like_option(token) {
    token = as_string(token);
    return match(token, /^--.+/) != null || match(token, /^-[A-Za-z].*/) != null;
}

function controlled_token(token) {
    token = as_string(token);
    if (token == "--ip" || token == "--port" || token == "-i" || token == "-p" || token == "--pidfile" || token == "-w")
        return "value";
    if (index(token, "--ip=") == 0 || index(token, "--port=") == 0 || index(token, "--pidfile=") == 0)
        return "skip";
    if (match(token, /^-i.+/) != null || match(token, /^-p.+/) != null || match(token, /^-w.+/) != null)
        return "skip";
    if (token == "--transparent" || token == "-E" || token == "--daemon" || token == "-D" ||
        token == "--help" || token == "-h" || token == "--version" || token == "-v")
        return "skip";
    if (match(token, /^-E.+/) != null || match(token, /^-D.+/) != null || match(token, /^-h.+/) != null || match(token, /^-v.+/) != null)
        return "skip";
    return "";
}

function strip_controlled(tokens) {
    let result = [];
    for (let i = 0; i < length(tokens); i++) {
        let kind = controlled_token(tokens[i]);
        if (kind == "") {
            push(result, tokens[i]);
            continue;
        }
        if (kind == "value") {
            let next = as_string(tokens[i + 1]);
            if (next != "" && !token_looks_like_option(next))
                i++;
        }
    }
    return result;
}

function valid_sni(value) {
    value = trim(as_string(value));
    return match(value, /^[A-Za-z0-9.-]+$/) != null && index(value, "..") < 0;
}

function list_title(id) {
    id = as_string(id);
    if (id == "türkiye")
        return "Türkiye";
    if (id == "")
        return id;
    return uc(substr(id, 0, 1)) + substr(id, 1);
}

function list_id_from_filename(name) {
    name = as_string(name);
    if (index(name, "proxytest_") != 0)
        return "";
    if (substr(name, length(name) - 6) != ".sites")
        return "";
    return substr(name, 10, length(name) - 16);
}

function read_domain_file(path) {
    let domains = [];
    for (let line in split(read_text(path), "\n")) {
        line = trim(line);
        if (line == "" || substr(line, 0, 1) == "#")
            continue;
        push(domains, line);
    }
    return domains;
}

function load_domain_lists() {
    let by_id = {};
    let names = fs.lsdir(DATA_DIR);
    if (type(names) != "array")
        names = [];
    for (let name in names) {
        let id = list_id_from_filename(name);
        if (id == "")
            continue;
        by_id[id] = {
            id: id,
            name: list_title(id),
            domains: read_domain_file(DATA_DIR + "/" + name)
        };
    }

    let ordered = [];
    for (let id in LIST_ORDER) {
        if (by_id[id] != null) {
            push(ordered, by_id[id]);
            by_id[id] = null;
        }
    }
    for (let name in names) {
        let id = list_id_from_filename(name);
        if (id != "" && by_id[id] != null)
            push(ordered, by_id[id]);
    }
    return ordered;
}

function load_builtin_strategies() {
    let lines = [];
    for (let line in split(read_text(DATA_DIR + "/proxytest_strategies.list"), "\n")) {
        line = trim(line);
        if (line != "" && substr(line, 0, 1) != "#")
            push(lines, line);
    }
    return lines;
}

function find_list(lists, name) {
    name = lc(trim(as_string(name)));
    for (let item in lists) {
        if (lc(item.id) == name || lc(item.name) == name)
            return item;
    }
    return null;
}

function expand_lists(command, lists) {
    let result = "";
    let rest = as_string(command);
    while (true) {
        let at = index(rest, "{list:");
        if (at < 0) {
            result = result + rest;
            break;
        }
        result = result + substr(rest, 0, at);
        rest = substr(rest, at + 6);
        let end = index(rest, "}");
        if (end < 0) {
            result = result + "{list:" + rest;
            break;
        }
        let list_name = trim(substr(rest, 0, end));
        rest = substr(rest, end + 1);
        let item = find_list(lists, list_name);
        if (item != null)
            result = result + join(" ", item.domains);
    }
    return result;
}

function prepare_strategy(command, sni, lists) {
    command = expand_lists(command, lists);
    let quoted = "\"" + as_string(sni) + "\"";
    command = replace(command, /\{sni\}/g, quoted);
    let tokens = strip_controlled(shell_split(command));
    return {
        command: join(" ", tokens),
        tokens: tokens
    };
}

function normalize_site(raw) {
    raw = trim(as_string(raw));
    if (raw == "" || substr(raw, 0, 1) == "#")
        return "";
    if (match(raw, /[ \t\r\n"'<>]/) != null || index(raw, "`") >= 0)
        return "";
    if (index(raw, "://") < 0)
        raw = "https://" + raw;
    if (index(raw, "https://") != 0 && index(raw, "http://") != 0)
        return "";
    return raw;
}

function site_label(url) {
    url = as_string(url);
    let scheme = index(url, "://");
    if (scheme >= 0)
        url = substr(url, scheme + 3);
    let slash = index(url, "/");
    if (slash >= 0)
        url = substr(url, 0, slash);
    return url;
}

function split_sites(value) {
    let sites = [];
    let seen = {};
    for (let line in split(as_string(value), "\n")) {
        let url = normalize_site(line);
        if (url == "" || seen[url])
            continue;
        seen[url] = true;
        push(sites, url);
    }
    return sites;
}

function selected_sites(request, lists) {
    let sites = [];
    let seen = {};
    let wanted = type(request.lists) == "array" ? request.lists : [];
    for (let id in wanted) {
        let item = find_list(lists, id);
        if (item == null)
            continue;
        for (let domain in item.domains) {
            let url = normalize_site(domain);
            if (url == "" || seen[url])
                continue;
            seen[url] = true;
            push(sites, url);
        }
    }
    for (let url in split_sites(request.domains)) {
        if (seen[url])
            continue;
        seen[url] = true;
        push(sites, url);
    }
    return sites;
}

function normalize_site_list(value) {
    let sites = [];
    let seen = {};
    if (type(value) != "array")
        return sites;
    for (let raw in value) {
        let url = normalize_site(raw);
        if (url == "" || seen[url])
            continue;
        seen[url] = true;
        push(sites, url);
    }
    return sites;
}

function resolve_sites(request, lists) {
    let chosen = type(request.sites) == "array" ? request.sites : [];
    if (length(chosen) > 0)
        return chosen;
    return selected_sites(request, lists);
}

function selected_commands(request) {
    if (request.use_custom == true) {
        let lines = [];
        for (let line in split(as_string(request.commands), "\n")) {
            line = trim(line);
            if (line != "" && substr(line, 0, 1) != "#")
                push(lines, line);
        }
        return lines;
    }
    return load_builtin_strategies();
}

function catalog_payload() {
    let lists = load_domain_lists();
    let public_lists = [];
    for (let item in lists) {
        push(public_lists, {
            id: item.id,
            name: item.name,
            count: length(item.domains),
            domains: item.domains
        });
    }
    let strategies = load_builtin_strategies();
    return {
        success: true,
        installed: provider_available(),
        provider_path: BYEDPI_BIN,
        strategy_count: length(strategies),
        defaults: {
            sni: "google.com",
            requests: 1,
            timeout: 5,
            delay: 1,
            limit: 8,
            active: [ "youtube", "googlevideo" ]
        },
        lists: public_lists,
        source: "https://github.com/romanvht/ByeByeDPI"
    };
}

function probe_succeeded(exit_code, content_length, body_size) {
    if (int(exit_code) != 0)
        return false;
    if (int(content_length) <= 0)
        return true;
    return int(body_size) >= int(content_length);
}

function last_content_length(header_text) {
    header_text = replace(as_string(header_text), /\r/g, "");
    let value = -1;
    let current = -1;
    for (let line in split(header_text, "\n")) {
        if (trim(line) == "") {
            if (current >= 0)
                value = current;
            current = -1;
            continue;
        }
        let lower = lc(line);
        if (index(lower, "content-length:") == 0) {
            let num = trim(substr(line, 15));
            if (match(num, /^[0-9]+$/) != null)
                current = int(num);
        }
    }
    if (current >= 0)
        value = current;
    return value;
}

function file_size(path) {
    let stat = fs.stat(as_string(path));
    if (stat == null || stat.size == null)
        return 0;
    return int(stat.size);
}

function spawn_detached(args, log_path) {
    log_path = as_string(log_path);
    let pid_path = log_path + ".pid";
    try { fs.unlink(pid_path); } catch (e) {}
    let daemon = trim(command_output("command -v start-stop-daemon"));
    if (daemon != "") {
        // Detach and close the file descriptors inherited from LuCI.
        // Otherwise file.exec waits until this process exits, the page
        // reports a failed start, and the check keeps running anyway.
        let script = "exec " + command_from_args(args) + " >>" + shell_quote(log_path) + " 2>&1";
        if (!command_success_from_args([
            daemon, "-S", "-b", "-m", "-p", pid_path,
            "-x", "/bin/sh", "--", "-c", script
        ]))
            return "";
        return trim(read_text(pid_path));
    }
    let command = command_from_args(args) + " </dev/null >>" + shell_quote(log_path) + " 2>&1 1000>&- & echo $!";
    return trim(command_output("sh -c " + shell_quote(command)));
}

function port_free_enough(port) {
    let output = command_output("netstat -ltn 2>/dev/null; ss -ltn 2>/dev/null");
    let needle = ":" + as_string(port);
    for (let line in split(output, "\n")) {
        let at = index(line, needle);
        while (at >= 0) {
            let next = substr(line, at + length(needle), 1);
            if (next == "" || match(next, /[0-9]/) == null)
                return false;
            let rest = substr(line, at + 1);
            let next_at = index(rest, needle);
            if (next_at < 0)
                break;
            at = at + 1 + next_at;
        }
    }
    return true;
}

function stop_ciadpi(state) {
    kill_pid(state.ciadpi_pid, "TERM");
    for (let pid in state.child_pids)
        kill_pid(pid, "TERM");
    sleep_for(0);
    if (pid_running(state.ciadpi_pid))
        kill_pid(state.ciadpi_pid, "KILL");
    for (let pid in state.child_pids) {
        if (pid_running(pid))
            kill_pid(pid, "KILL");
    }
    state.ciadpi_pid = "";
    state.child_pids = [];
}

function start_ciadpi(tokens) {
    for (let port = PORT_BASE; port < PORT_BASE + 20; port++) {
        if (!port_free_enough(port))
            continue;
        let log_path = STATE_DIR + "/ciadpi.log";
        write_file(log_path, "");
        let args = [ BYEDPI_BIN, "--ip", LISTEN_ADDRESS, "--port", as_string(port) ];
        for (let token in tokens)
            push(args, token);
        let pid = spawn_detached(args, log_path);
        sleep_for(0);
        if (pid_running(pid))
            return { pid: pid, port: port, proxy: LISTEN_ADDRESS + ":" + as_string(port) };
    }
    return null;
}

function curl_command(url, body_path, header_path, timeout, proxy, code_path) {
    let curl = command_from_args([
        "curl", "-sS",
        "-o", body_path,
        "-D", header_path,
        "--socks5-hostname", proxy,
        "--connect-timeout", as_string(timeout),
        "--max-time", as_string(timeout),
        "--http1.1",
        "-A", "Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36",
        "-L", "--max-redirs", "2",
        "--path-as-is",
        url
    ]);
    return curl + " >/dev/null 2>" + shell_quote(body_path + ".err") + "; echo $? > " + shell_quote(code_path);
}

function launch_curl(url, slot, timeout, proxy) {
    let body_path = STATE_DIR + "/probe/" + slot + ".body";
    let header_path = STATE_DIR + "/probe/" + slot + ".hdr";
    let code_path = STATE_DIR + "/probe/" + slot + ".code";
    try { fs.unlink(code_path); } catch (e) {}
    let script = "( " + curl_command(url, body_path, header_path, timeout, proxy, code_path) + " ) & echo $!";
    let pid = trim(command_output("sh -c " + shell_quote(script)));
    return {
        pid: pid,
        url: url,
        body_path: body_path,
        header_path: header_path,
        code_path: code_path
    };
}

function job_finished(job) {
    if (fs.stat(job.code_path) != null)
        return true;
    return !pid_running(job.pid);
}

function job_success(job) {
    let code_text = trim(read_text(job.code_path));
    if (match(code_text, /^-?[0-9]+$/) == null)
        return false;
    return probe_succeeded(code_text, last_content_length(read_text(job.header_path)), file_size(job.body_path));
}

function blank_site_rows(sites, requests) {
    let rows = [];
    for (let url in sites)
        push(rows, { site: site_label(url), url: url, success: 0, total: requests });
    return rows;
}

function publish(state) {
    save_state(state);
}

function check_sites(state, strategy, sites, requests, timeout, limit, proxy) {
    command_success_from_args([ "rm", "-rf", STATE_DIR + "/probe" ]);
    command_success_from_args([ "mkdir", "-p", STATE_DIR + "/probe" ]);
    strategy.sites = [];
    strategy.success = 0;
    strategy.total = length(sites) * requests;
    strategy.progress = 0;
    publish(state);

    let next_site = 0;
    let running = [];
    let slot = 0;

    while (next_site < length(sites) || length(running) > 0) {
        if (stop_requested() || !pid_running(state.ciadpi_pid))
            return false;

        while (next_site < length(sites) && length(running) < limit) {
            let url = sites[next_site];
            let job = launch_curl(url, as_string(slot), timeout, proxy);
            slot++;
            push(running, {
                url: url,
                success: 0,
                done: 0,
                job: job
            });
            next_site++;
        }
        state.child_pids = [];
        for (let item in running)
            if (item.job != null && item.job.pid != "")
                push(state.child_pids, item.job.pid);
        publish(state);

        sleep_for(0);
        let still = [];
        for (let item in running) {
            if (item.job != null && !job_finished(item.job)) {
                push(still, item);
                continue;
            }
            if (item.job != null && job_success(item.job))
                item.success = item.success + 1;
            item.done = item.done + 1;
            item.job = null;
            if (item.done < requests) {
                if (stop_requested() || !pid_running(state.ciadpi_pid))
                    return false;
                item.job = launch_curl(item.url, as_string(slot), timeout, proxy);
                slot++;
                push(still, item);
                continue;
            }
            push(strategy.sites, {
                site: site_label(item.url),
                url: item.url,
                success: item.success,
                total: requests
            });
            strategy.success = strategy.success + item.success;
            strategy.progress = strategy.progress + requests;
        }
        running = still;
        publish(state);
    }
    state.child_pids = [];
    return true;
}

function reconcile_state(state) {
    if (state.running != true)
        return state;
    if (as_string(state.pid) == "") {
        if (now_seconds() - int(state.started_at) < 5)
            return state;
    }
    else if (pid_running(state.pid)) {
        return state;
    }
    state.running = false;
    state.stopping = false;
    state.interrupted = true;
    state.failed = false;
    if (as_string(state.message) == "")
        state.message = "interrupted";
    state.finished_at = now_seconds();
    state.ciadpi_pid = "";
    state.child_pids = [];
    save_state(state);
    return state;
}

function worker() {
    if (!ensure_state_dir())
        exit(1);
    let request = read_json(REQUEST_FILE);
    if (type(request) != "object")
        exit(1);

    let state = read_state();
    state.pid = trim(read_text("/proc/self/stat"));
    let space = index(state.pid, " ");
    if (space > 0)
        state.pid = substr(state.pid, 0, space);
    publish(state);

    let lists = load_domain_lists();
    let sites = resolve_sites(request, lists);
    let commands = selected_commands(request);
    let sni = as_string(request.sni);
    let requests = clamp_int(request.requests, 1, 10, 1);
    let timeout = clamp_int(request.timeout, 1, 30, 5);
    let delay = clamp_int(request.delay, 0, 15, 1);
    let limit = clamp_int(request.limit, 1, 20, 8);
    let strategies = [];

    for (let command in commands) {
        let prepared = prepare_strategy(command, sni, lists);
        push(strategies, {
            command: prepared.command,
            tokens: prepared.tokens,
            success: 0,
            total: length(sites) * requests,
            progress: 0,
            completed: false,
            error: "",
            sites: []
        });
    }

    state.total = length(strategies);
    state.current = 0;
    state.strategies = strategies;
    publish(state);

    for (let index_value = 0; index_value < length(strategies); index_value++) {
        if (stop_requested()) {
            state.running = false;
            state.stopping = false;
            state.interrupted = true;
            state.message = "interrupted";
            state.finished_at = now_seconds();
            stop_ciadpi(state);
            publish(state);
            exit(0);
        }

        let strategy = strategies[index_value];
        state.current = index_value + 1;
        publish(state);

        if (length(strategy.tokens) == 0) {
            strategy.error = "empty";
            strategy.sites = blank_site_rows(sites, requests);
            strategy.completed = true;
            strategy.tokens = [];
            publish(state);
            continue;
        }

        let engine = start_ciadpi(strategy.tokens);
        if (engine == null) {
            strategy.error = "ciadpi";
            strategy.sites = blank_site_rows(sites, requests);
            strategy.completed = true;
            strategy.tokens = [];
            publish(state);
            continue;
        }

        state.ciadpi_pid = engine.pid;
        publish(state);
        if (delay > 0)
            sleep_for(delay);
        else
            sleep_for(0);

        let alive = pid_running(engine.pid) && !stop_requested();
        let checked = false;
        if (alive)
            checked = check_sites(state, strategy, sites, requests, timeout, limit, engine.proxy);

        stop_ciadpi(state);
        if (stop_requested()) {
            strategy.completed = true;
            state.running = false;
            state.stopping = false;
            state.interrupted = true;
            state.message = "interrupted";
            state.finished_at = now_seconds();
            publish(state);
            exit(0);
        }
        if (!checked) {
            strategy.success = 0;
            strategy.progress = 0;
            strategy.sites = blank_site_rows(sites, requests);
            strategy.error = "ciadpi";
        }
        strategy.completed = true;
        strategy.tokens = [];
        publish(state);
        if (delay > 0)
            sleep_for(delay);
    }

    state.running = false;
    state.stopping = false;
    state.failed = false;
    state.interrupted = false;
    state.message = "complete";
    state.finished_at = now_seconds();
    state.current = length(strategies);
    publish(state);
    exit(0);
}

function normalize_request(raw) {
    if (type(raw) != "object")
        return null;
    let sni = trim(as_string(raw.sni));
    if (sni == "")
        sni = "google.com";
    if (!valid_sni(sni))
        return null;
    let list_ids = [];
    if (type(raw.lists) == "array") {
        for (let id in raw.lists) {
            id = trim(as_string(id));
            if (id != "")
                push(list_ids, id);
        }
    }
    let expected = -1;
    if (match(trim(as_string(raw.expected)), /^[0-9]+$/) != null)
        expected = int(raw.expected);
    return {
        lists: list_ids,
        sites: normalize_site_list(raw.sites),
        expected: expected,
        domains: as_string(raw.domains),
        sni: sni,
        requests: clamp_int(raw.requests, 1, 10, 1),
        timeout: clamp_int(raw.timeout, 1, 30, 5),
        delay: clamp_int(raw.delay, 0, 15, 1),
        limit: clamp_int(raw.limit, 1, 20, 8),
        use_custom: raw.use_custom == true || as_string(raw.use_custom) == "1" || as_string(raw.use_custom) == "true",
        commands: as_string(raw.commands)
    };
}

function start_test(raw_json) {
    if (!provider_available()) {
        write_json({ success: false, message: "not_installed", provider_path: BYEDPI_BIN });
        exit(1);
    }
    let request = null;
    try {
        request = normalize_request(json(as_string(raw_json)));
    }
    catch (e) {
        request = null;
    }
    if (request == null) {
        write_json({ success: false, message: "bad_request" });
        exit(1);
    }

    if (!ensure_state_dir()) {
        write_json({ success: false, message: "state_dir" });
        exit(1);
    }

    let existing = reconcile_state(read_state());
    if (existing.running == true) {
        write_json({ success: false, message: "already_running", state: status_view(existing) });
        exit(1);
    }

    let lists = load_domain_lists();
    let sites = resolve_sites(request, lists);
    let commands = selected_commands(request);
    if (length(sites) == 0) {
        write_json({ success: false, message: "no_sites" });
        exit(1);
    }
    if (request.expected >= 0 && request.expected != length(sites)) {
        write_json({
            success: false,
            message: "sites_mismatch",
            sites: length(sites),
            expected: request.expected
        });
        exit(1);
    }
    if (length(commands) == 0) {
        write_json({ success: false, message: "no_commands" });
        exit(1);
    }
    if (length(sites) > 300 || length(commands) > 300) {
        write_json({ success: false, message: "too_many" });
        exit(1);
    }

    try { fs.unlink(STOP_FILE); } catch (e) {}
    if (!write_json_file(REQUEST_FILE, request)) {
        write_json({ success: false, message: "state_dir" });
        exit(1);
    }

    let state = empty_state();
    state.running = true;
    state.started_at = now_seconds();
    state.total = length(commands);
    state.settings = {
        sni: request.sni,
        requests: request.requests,
        timeout: request.timeout,
        delay: request.delay,
        limit: request.limit,
        sites: length(sites),
        lists: request.lists,
        commands: length(commands),
        use_custom: request.use_custom
    };
    if (!save_state(state)) {
        write_json({ success: false, message: "state_dir" });
        exit(1);
    }

    write_file(WORKER_LOG, "");
    let module_path = LIB_DIR + "/providers/byedpi/strategy_test.uc";
    if (getenv("BYEDPI_STRATEGY_TEST_UC") != null && getenv("BYEDPI_STRATEGY_TEST_UC") != "")
        module_path = getenv("BYEDPI_STRATEGY_TEST_UC");
    let pid = spawn_detached([
        "ucode", "-L", LIB_DIR, module_path, "worker"
    ], WORKER_LOG);
    if (!pid_running(pid)) {
        state.running = false;
        state.failed = true;
        state.message = "worker";
        state.finished_at = now_seconds();
        save_state(state);
        write_json({ success: false, message: "worker", state: status_view(read_state()) });
        exit(1);
    }
    write_json({ success: true, message: "started", state: status_view(read_state()) });
}

function json_int(value) {
    let text = trim(as_string(value));
    if (match(text, /^-?[0-9]+$/) == null)
        return 0;
    return int(text);
}

function status_view(state) {
    let strategies = [];
    let items = type(state.strategies) == "array" ? state.strategies : [];
    let index_value = 0;
    for (let item in items) {
        push(strategies, {
            index: index_value,
            command: as_string(item.command),
            success: json_int(item.success),
            total: json_int(item.total),
            progress: json_int(item.progress),
            completed: item.completed == true,
            error: as_string(item.error)
        });
        index_value++;
    }
    return {
        success: state.success != false,
        running: state.running == true,
        stopping: state.stopping == true,
        failed: state.failed == true,
        interrupted: state.interrupted == true,
        message: as_string(state.message),
        current: json_int(state.current),
        total: json_int(state.total),
        started_at: json_int(state.started_at),
        updated_at: json_int(state.updated_at),
        finished_at: json_int(state.finished_at),
        settings: type(state.settings) == "object" ? state.settings : {},
        strategies: strategies
    };
}

function status_test() {
    if (!ensure_state_dir()) {
        write_json(status_view(empty_state()));
        exit(0);
    }
    write_json(status_view(reconcile_state(read_state())));
}

function sites_test(index_text) {
    if (!ensure_state_dir()) {
        write_json({ success: false, message: "bad_index", sites: [] });
        exit(1);
    }
    let state = read_state();
    let items = type(state.strategies) == "array" ? state.strategies : [];
    if (match(trim(as_string(index_text)), /^[0-9]+$/) == null) {
        write_json({ success: false, message: "bad_index", sites: [] });
        exit(1);
    }
    let index_value = int(index_text);
    if (index_value < 0 || index_value >= length(items)) {
        write_json({ success: false, message: "bad_index", sites: [] });
        exit(1);
    }
    let item = items[index_value];
    let sites = type(item.sites) == "array" ? item.sites : [];
    write_json({
        success: true,
        index: index_value,
        total: int(item.total),
        success_count: int(item.success),
        sites: sites
    });
}

function stop_test() {
    if (!ensure_state_dir()) {
        write_json({ success: true, message: "idle", state: status_view(empty_state()) });
        exit(0);
    }
    let state = read_state();
    if (state.running != true) {
        write_json({ success: true, message: "idle", state: status_view(state) });
        exit(0);
    }
    write_file(STOP_FILE, "1\n");
    state = read_state();
    if (state.running == true) {
        state.stopping = true;
        save_state(state);
        stop_ciadpi(state);
        save_state(read_state());
    }

    for (let i = 0; i < 8; i++) {
        sleep_for(0);
        state = read_state();
        if (state.running != true) {
            write_json({ success: true, message: "stopped", state: status_view(state) });
            exit(0);
        }
    }

    kill_pid(state.pid, "TERM");
    sleep_for(0);
    if (pid_running(state.pid))
        kill_pid(state.pid, "KILL");
    state = read_state();
    state.running = false;
    state.stopping = false;
    state.interrupted = true;
    state.message = "interrupted";
    state.finished_at = now_seconds();
    state.pid = "";
    state.ciadpi_pid = "";
    state.child_pids = [];
    save_state(state);
    write_json({ success: true, message: "stopped", state: status_view(state) });
}

function self_check() {
    let strategies = load_builtin_strategies();
    if (length(strategies) < 50)
        exit(1);
    let lists = load_domain_lists();
    if (length(lists) < 8)
        exit(1);
    let youtube = find_list(lists, "youtube");
    if (youtube == null || length(youtube.domains) < 5)
        exit(1);
    let prepared = prepare_strategy("-n {sni} --ip 1.2.3.4 --port 9 -d1", "google.com", lists);
    if (prepared.command != "-n google.com -d1")
        exit(1);
    if (index(join(" ", prepared.tokens), "--ip") >= 0 || index(join(" ", prepared.tokens), "--port") >= 0)
        exit(1);
    let quoted = shell_split("-n \"google.com\" -d1");
    if (length(quoted) != 3 || quoted[1] != "google.com")
        exit(1);
    if (!probe_succeeded(0, -1, 0))
        exit(1);
    if (!probe_succeeded(0, 0, 0))
        exit(1);
    if (!probe_succeeded(0, 20, 20))
        exit(1);
    if (probe_succeeded(0, 20, 4))
        exit(1);
    if (probe_succeeded(18, 20, 4))
        exit(1);
    if (probe_succeeded(7, -1, 0))
        exit(1);
    let expanded = prepare_strategy("-H {list:Youtube} -d1", "google.com", lists);
    if (index(expanded.command, "youtube.com") < 0)
        exit(1);
    for (let line in strategies) {
        let item = prepare_strategy(line, "google.com", lists);
        if (length(item.tokens) == 0)
            exit(1);
        if (index(item.command, "{sni}") >= 0)
            exit(1);
    }
    if (normalize_site("googleapis.com") != "https://googleapis.com")
        exit(1);
    if (normalize_site("rr1---sn-4axm-n8vs.googlevideo.com") != "https://rr1---sn-4axm-n8vs.googlevideo.com")
        exit(1);
    if (normalize_site("discord.com") != "https://discord.com")
        exit(1);
    if (normalize_site("bad domain.com") != "")
        exit(1);
    let explicit = normalize_site_list([ "youtu.be", "https://youtube.com", "youtu.be" ]);
    if (length(explicit) != 2 || explicit[0] != "https://youtu.be" || explicit[1] != "https://youtube.com")
        exit(1);
    let view = status_view({
        strategies: [ {
            command: "-d1",
            success: 1,
            total: 2,
            sites: [ { site: "youtu.be" } ]
        } ],
        settings: { sites: 2, lists: [ "youtube" ] }
    });
    if (length(view.strategies) != 1 || view.strategies[0].index != 0 || view.strategies[0].total != 2)
        exit(1);
    if (view.strategies[0].sites != null)
        exit(1);
    print("ok\n");
}

let mode = ARGV[0] || "";

if (mode == "catalog")
    write_json(catalog_payload());
else if (mode == "start")
    start_test(ARGV[1] || "");
else if (mode == "status")
    status_test();
else if (mode == "sites")
    sites_test(ARGV[1] || "");
else if (mode == "stop")
    stop_test();
else if (mode == "worker")
    worker();
else if (mode == "self-check")
    self_check();
else if (mode == "prepare") {
    let lists = load_domain_lists();
    write_json(prepare_strategy(ARGV[1] || "", ARGV[2] || "google.com", lists));
}
else if (mode == "probe-ok")
    print(probe_succeeded(ARGV[1], ARGV[2], ARGV[3]) ? "1\n" : "0\n");
else {
    warn("Usage: providers/byedpi/strategy_test.uc <catalog|start|status|sites|stop|worker|self-check> ...\n");
    exit(1);
}
