#!/usr/bin/env ucode

let fs = require("fs");

const API = "https://api.cloudflareclient.com/v0a2158";
const LIB_DIR = getenv("FORKOP_LIB") || "/usr/lib/forkop";
const SOCKS_PORT = "39241";

function as_string(value) {
    return value == null ? "" : "" + value;
}

function trim(value) {
    return replace(as_string(value), /^[ \t\r\n]+|[ \t\r\n]+$/g, "");
}

function shell_quote(value) {
    return "'" + replace(as_string(value), /'/g, "'\\''") + "'";
}

function write_json(value) {
    print(sprintf("%J", value), "\n");
}

function fail(message) {
    write_json({ success: false, message: as_string(message) });
    exit(1);
}

function command_output(command) {
    let pipe = fs.popen(command, "r");
    if (!pipe)
        return "";
    let data = pipe.read("all");
    pipe.close();
    return data == null ? "" : as_string(data);
}

function read_json(path) {
    let raw = "";
    try {
        raw = fs.readfile(path);
    }
    catch (e) {
        return null;
    }
    if (raw == null || raw == "")
        return null;
    try {
        return json(raw);
    }
    catch (e) {
        return null;
    }
}

function b64_value(ch) {
    let alpha = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let at = index(alpha, ch);
    return at == null ? -1 : at;
}

function reserved_csv(client_id) {
    client_id = replace(replace(trim(client_id), /-/g, "+"), /_/g, "/");
    while (length(client_id) % 4 != 0)
        client_id += "=";
    if (length(client_id) < 4)
        return "";
    let a = b64_value(substr(client_id, 0, 1));
    let b = b64_value(substr(client_id, 1, 1));
    let c = b64_value(substr(client_id, 2, 1));
    let d = b64_value(substr(client_id, 3, 1));
    if (a < 0 || b < 0 || c < 0 || d < 0)
        return "";
    let n = a * 262144 + b * 4096 + c * 64 + d;
    return (int(n / 65536) % 256) + "," + (int(n / 256) % 256) + "," + (n % 256);
}

function pct_b64(value) {
    return replace(replace(replace(as_string(value), /\+/g, "%2B"), /\//g, "%2F"), /=/g, "%3D");
}

function pct(value) {
    value = as_string(value);
    value = replace(value, /%/g, "%25");
    value = replace(value, /:/g, "%3A");
    value = replace(value, /\//g, "%2F");
    value = replace(value, /,/g, "%2C");
    value = replace(value, / /g, "%20");
    return value;
}

function random_uuid() {
    let value = trim(command_output("cat /proc/sys/kernel/random/uuid 2>/dev/null"));
    return match(value, /^[0-9a-fA-F-]{36}$/) != null ? value : "";
}

function keypair() {
    let private_key = "";
    let public_key = "";
    let text = command_output("sing-box generate wg-keypair 2>/dev/null");
    for (let line in split(text, "\n")) {
        line = trim(line);
        if (index(line, "PrivateKey:") == 0)
            private_key = trim(substr(line, 11));
        else if (index(line, "PublicKey:") == 0)
            public_key = trim(substr(line, 10));
    }
    if (private_key != "" && public_key != "")
        return { private_key, public_key };

    private_key = trim(command_output("wg genkey 2>/dev/null"));
    if (private_key == "")
        return null;
    public_key = trim(command_output("printf %s " + shell_quote(private_key) + " | wg pubkey 2>/dev/null"));
    if (public_key == "")
        return null;
    return { private_key, public_key };
}

function port_listening(port) {
    port = int(port || 0);
    if (port <= 0)
        return false;
    let needle = ":" + sprintf("%04X", port);
    for (let path in [ "/proc/net/tcp", "/proc/net/tcp6" ]) {
        let data = "";
        try {
            data = fs.readfile(path);
        }
        catch (e) {
            data = "";
        }
        for (let line in split(as_string(data), "\n")) {
            if (index(line, needle) >= 0 && match(line, /[ \t]0A[ \t]/) != null)
                return true;
        }
    }
    return false;
}

function mapped_port(path, name) {
    let data = read_json(path);
    if (type(data) != "object")
        return 0;
    let port = int(data[as_string(name)] || 0);
    return port_listening(port) ? port : 0;
}

function stop_socks(pid_path) {
    let pid = trim(as_string(fs.readfile(pid_path)));
    if (match(pid, /^[0-9]+$/) != null)
        system("kill " + pid + " >/dev/null 2>&1");
    system("rm -f " + shell_quote(pid_path) + " /tmp/forkop/warp-socks.json /tmp/forkop/warp-socks.log >/dev/null 2>&1");
}

function start_singbox_socks(section_name) {
    system("mkdir -p /tmp/forkop >/dev/null 2>&1");
    let cfg = "/tmp/forkop/warp-socks.json";
    let log_path = "/tmp/forkop/warp-socks.log";
    let pid_path = "/tmp/forkop/warp-socks.pid";
    stop_socks(pid_path);
    let generator = LIB_DIR + "/singbox/generator.uc";
    if (system("ucode -L " + shell_quote(LIB_DIR) + " " + shell_quote(generator) + " download-socks " + shell_quote(section_name) + " " + shell_quote(cfg) + " " + SOCKS_PORT + " 1 >" + shell_quote(log_path) + " 2>&1") != 0)
        return 0;
    if (system("sing-box check -c " + shell_quote(cfg) + " >>" + shell_quote(log_path) + " 2>&1") != 0)
        return 0;
    if (system("sing-box run -c " + shell_quote(cfg) + " >>" + shell_quote(log_path) + " 2>&1 & echo $! > " + shell_quote(pid_path)) != 0)
        return 0;
    let attempt = 0;
    while (attempt < 8) {
        if (port_listening(SOCKS_PORT))
            return int(SOCKS_PORT);
        system("sleep 1");
        attempt++;
    }
    stop_socks(pid_path);
    return 0;
}

function socks_port_for(section_name) {
    section_name = trim(section_name);
    if (section_name == "")
        return 0;
    let port = mapped_port("/var/run/forkop/xray-ports.json", section_name);
    if (port > 0)
        return port;
    port = mapped_port("/var/run/forkop/openconnect-cascade.json", section_name);
    if (port > 0)
        return port;
    return start_singbox_socks(section_name);
}

function curl_call(method, url, body_path, token, socks_port) {
    let cmd = "curl -fsS --max-time 20 -A " + shell_quote("okhttp/3.12.1") +
        " -H " + shell_quote("CF-Client-Version: a-6.11-2223") +
        " -H " + shell_quote("Content-Type: application/json") +
        " -X " + shell_quote(method) +
        " -o /tmp/forkop/warp-body.json";
    if (trim(token) != "")
        cmd += " -H " + shell_quote("Authorization: Bearer " + token);
    if (int(socks_port || 0) > 0)
        cmd += " --socks5-hostname " + shell_quote("127.0.0.1:" + socks_port);
    if (body_path != "")
        cmd += " --data-binary @" + shell_quote(body_path);
    cmd += " " + shell_quote(url) + " 2>/tmp/forkop/warp-curl.err";
    let status = system(cmd);
    let raw = "";
    try {
        raw = fs.readfile("/tmp/forkop/warp-body.json");
    }
    catch (e) {
        raw = "";
    }
    let body = null;
    if (trim(raw) != "") {
        try {
            body = json(raw);
        }
        catch (e2) {
            body = null;
        }
    }
    return { ok: status == 0, body };
}

function prepare_socks(detour) {
    detour = trim(detour);
    if (detour == "")
        return { socks: 0, started: false };
    let existing = mapped_port("/var/run/forkop/xray-ports.json", detour);
    if (existing <= 0)
        existing = mapped_port("/var/run/forkop/openconnect-cascade.json", detour);
    if (existing > 0)
        return { socks: existing, started: false };
    let socks = start_singbox_socks(detour);
    if (socks <= 0)
        fail("The cascade section is not accepting connections, so WARP was not registered directly");
    return { socks, started: true };
}

function finish_socks(session) {
    if (type(session) == "object" && session.started)
        stop_socks("/tmp/forkop/warp-socks.pid");
}

function account_type_text(account) {
    account = type(account) == "object" ? account : {};
    let kind = lc(trim(as_string(account.account_type || "")));
    if (kind == "free" || kind == "limited" || kind == "unlimited" || kind == "team")
        return kind;
    return "";
}

function account_view(account) {
    account = type(account) == "object" ? account : {};
    let quota = account.quota;
    return {
        warp_plus: account.warp_plus == true,
        quota: quota == null ? "" : as_string(quota),
        account_type: account_type_text(account)
    };
}

function read_account(device, token, socks) {
    device = trim(device);
    token = trim(token);
    if (device == "" || token == "")
        return null;
    let fetched = curl_call("GET", API + "/reg/" + device, "", token, socks);
    if (fetched.ok && type(fetched.body) == "object" && type(fetched.body.account) == "object")
        return fetched.body.account;
    fetched = curl_call("GET", API + "/reg/" + device + "/account", "", token, socks);
    if (fetched.ok && type(fetched.body) == "object")
        return fetched.body;
    return null;
}

function fetch_account(device, token, socks, fallback) {
    fallback = type(fallback) == "object" ? fallback : {};
    let account = read_account(device, token, socks);
    return account != null ? account : fallback;
}

function split_host_port_text(text) {
    text = trim(text);
    let colon = rindex(text, ":");
    if (colon <= 0)
        return [ text, "" ];
    let head = substr(text, 0, colon);
    let tail = substr(text, colon + 1);
    if (index(head, ":") >= 0 || match(tail, /^[0-9]+$/) == null)
        return [ text, "" ];
    return [ head, tail ];
}

function endpoint_port(endpoint, embedded) {
    let port = trim(as_string(endpoint.port || ""));
    if (match(port, /^[0-9]+$/) != null)
        return port;
    if (type(endpoint.ports) == "array") {
        let fallback = "";
        for (let item in endpoint.ports) {
            let text = trim(as_string(item));
            if (text == "2408")
                return text;
            if (fallback == "" && match(text, /^[0-9]+$/) != null)
                fallback = text;
        }
        if (fallback != "")
            return fallback;
    }
    if (embedded != "")
        return embedded;
    return "2408";
}

function endpoint_host(peer) {
    peer = type(peer) == "object" ? peer : {};
    let endpoint = peer.endpoint;
    if (type(endpoint) == "string" && trim(endpoint) != "") {
        let parts = split_host_port_text(trim(endpoint));
        return [ parts[0], parts[1] != "" ? parts[1] : "2408" ];
    }
    endpoint = type(endpoint) == "object" ? endpoint : {};
    let host = trim(as_string(endpoint.host || ""));
    if (host == "")
        host = trim(as_string(endpoint.v4 || ""));
    if (host == "")
        host = "engage.cloudflareclient.com";
    let parts = split_host_port_text(host);
    return [ parts[0], endpoint_port(endpoint, parts[1]) ];
}

function warp_link(private_key, public_key, host, port, addresses, reserved, v4) {
    let query = "privatekey=" + pct_b64(private_key) +
        "&publickey=" + pct_b64(public_key) +
        "&address=" + pct(addresses) +
        "&reserved=" + reserved +
        "&mtu=1280&keepalive=25";
    let label = "WARP " + v4;
    let shown = index(host, ":") >= 0 ? "[" + host + "]" : host;
    return "warp://" + shown + ":" + port + "?" + query + "#" + pct(label);
}

function profile_from(keys, response, account, license) {
    let config = type(response.config) == "object" ? response.config : {};
    let interface = type(config.interface) == "object" ? config.interface : {};
    let addresses = type(interface.addresses) == "object" ? interface.addresses : {};
    let v4 = trim(as_string(addresses.v4 || ""));
    let v6 = trim(as_string(addresses.v6 || ""));
    let peers = type(config.peers) == "array" ? config.peers : [];
    let peer = length(peers) > 0 && type(peers[0]) == "object" ? peers[0] : {};
    let peer_key = trim(as_string(peer.public_key || ""));
    let reserved = reserved_csv(config.client_id);
    let device = trim(as_string(response.id || ""));
    let token = trim(as_string(response.token || ""));
    if (v4 == "" || peer_key == "" || reserved == "" || device == "" || token == "")
        return null;
    let host_port = endpoint_host(peer);
    let address = v4 + "/32";
    if (v6 != "")
        address += "," + v6 + "/128";
    let view = account_view(account);
    return {
        success: true,
        name: "WARP " + v4,
        private_key: keys.private_key,
        public_key: peer_key,
        address_v4: v4,
        address_v6: v6,
        endpoint_host: host_port[0],
        endpoint_port: host_port[1],
        reserved,
        device_id: device,
        access_token: token,
        license: trim(license),
        warp_plus: view.warp_plus,
        quota: view.quota,
        account_type: view.account_type,
        mtu: "1280",
        keepalive: "25",
        link: warp_link(keys.private_key, peer_key, host_port[0], host_port[1], address, reserved, v4),
        label: "WARP " + v4,
        address: v4
    };
}

function register(license, detour) {
    system("mkdir -p /tmp/forkop >/dev/null 2>&1");
    let keys = keypair();
    if (keys == null)
        fail("sing-box or wg is required to create a WireGuard key");

    let session = prepare_socks(detour);
    let body = {
        key: keys.public_key,
        install_id: random_uuid(),
        fcm_token: "",
        tos: trim(command_output("date -u +%Y-%m-%dT%H:%M:%SZ")),
        model: "PC",
        serial_number: random_uuid(),
        locale: "en_US"
    };
    if (fs.writefile("/tmp/forkop/warp-reg.json", sprintf("%J", body)) == null) {
        finish_socks(session);
        fail("Could not write the WARP request");
    }

    let created = curl_call("POST", API + "/reg", "/tmp/forkop/warp-reg.json", "", session.socks);
    let response = created.ok ? created.body : null;
    license = trim(license);
    let license_failed = false;
    let account = response != null && type(response.account) == "object" ? response.account : {};
    if (response != null && license != "") {
        let device = trim(as_string(response.id || ""));
        let token = trim(as_string(response.token || ""));
        if (device == "" || token == "") {
            response = null;
        }
        else {
            fs.writefile("/tmp/forkop/warp-license.json", sprintf("%J", { license }));
            let updated = curl_call("PUT", API + "/reg/" + device + "/account", "/tmp/forkop/warp-license.json", token, session.socks);
            if (!updated.ok || type(updated.body) != "object") {
                response = null;
                license_failed = true;
            }
            else {
                account = updated.body;
            }
        }
    }
    if (response != null)
        account = fetch_account(response.id, response.token, session.socks, account);
    system("rm -f /tmp/forkop/warp-reg.json /tmp/forkop/warp-license.json /tmp/forkop/warp-body.json >/dev/null 2>&1");
    finish_socks(session);
    if (response == null)
        fail(license_failed ? "WARP+ license was rejected" : (trim(detour) != "" ? "Could not reach Cloudflare through the cascade" : "Could not reach Cloudflare"));

    let profile = profile_from(keys, response, account, license);
    if (profile == null)
        fail("Cloudflare returned an incomplete WARP profile");
    write_json(profile);
    return 0;
}

function apply_license(device, token, license, detour) {
    device = trim(device);
    token = trim(token);
    license = trim(license);
    if (device == "" || token == "")
        fail("This WARP profile has no device token. Use New address once.");
    if (license == "")
        fail("Enter a WARP+ license");
    system("mkdir -p /tmp/forkop >/dev/null 2>&1");
    let session = prepare_socks(detour);
    fs.writefile("/tmp/forkop/warp-license.json", sprintf("%J", { license }));
    let updated = curl_call("PUT", API + "/reg/" + device + "/account", "/tmp/forkop/warp-license.json", token, session.socks);
    if (!updated.ok || type(updated.body) != "object") {
        system("rm -f /tmp/forkop/warp-license.json /tmp/forkop/warp-body.json >/dev/null 2>&1");
        finish_socks(session);
        fail(trim(detour) != "" ? "Could not reach Cloudflare through the cascade" : "WARP+ license was rejected");
    }
    let account = fetch_account(device, token, session.socks, updated.body);
    system("rm -f /tmp/forkop/warp-license.json /tmp/forkop/warp-body.json >/dev/null 2>&1");
    finish_socks(session);
    let view = account_view(account);
    write_json({
        success: true,
        license,
        warp_plus: view.warp_plus,
        quota: view.quota,
        account_type: view.account_type
    });
    return 0;
}

function account_status(device, token, detour) {
    device = trim(device);
    token = trim(token);
    if (device == "" || token == "")
        fail("This WARP profile has no device token. Use New address once.");
    system("mkdir -p /tmp/forkop >/dev/null 2>&1");
    let session = prepare_socks(detour);
    let account = read_account(device, token, session.socks);
    system("rm -f /tmp/forkop/warp-body.json >/dev/null 2>&1");
    finish_socks(session);
    if (account == null)
        fail(trim(detour) != "" ? "Could not reach Cloudflare through the cascade" : "Could not check the WARP account");
    let view = account_view(account);
    write_json({
        success: true,
        warp_plus: view.warp_plus,
        quota: view.quota,
        account_type: view.account_type
    });
    return 0;
}

function delete_device(device, token, detour) {
    device = trim(device);
    token = trim(token);
    if (device == "" || token == "")
        fail("This WARP profile has no device token");
    system("mkdir -p /tmp/forkop >/dev/null 2>&1");
    let session = prepare_socks(detour);
    let removed = curl_call("DELETE", API + "/reg/" + device, "", token, session.socks);
    system("rm -f /tmp/forkop/warp-body.json >/dev/null 2>&1");
    finish_socks(session);
    if (!removed.ok)
        fail(trim(detour) != "" ? "Could not reach Cloudflare through the cascade" : "Could not delete the WARP device");
    write_json({ success: true });
    return 0;
}

function warp_account(raw) {
    let request = null;
    try {
        request = json(raw);
    }
    catch (e) {
        request = null;
    }
    if (type(request) != "object")
        fail("WARP request is invalid");
    let action = trim(as_string(request.action || ""));
    if (action == "register")
        return register(request.license || "", request.detour || "");
    if (action == "license")
        return apply_license(request.device_id || "", request.access_token || "", request.license || "", request.detour || "");
    if (action == "status")
        return account_status(request.device_id || "", request.access_token || "", request.detour || "");
    if (action == "delete")
        return delete_device(request.device_id || "", request.access_token || "", request.detour || "");
    fail("unknown warp command");
}

let mode = ARGV[0] || "";
if (mode == "register")
    exit(register(ARGV[1] || "", ARGV[2] || ""));
else if (mode == "account")
    exit(warp_account(ARGV[1] || ""));
else if (mode == "reserved-csv")
    print(reserved_csv(ARGV[1] || ""), "\n");
else
    fail("unknown warp command");
