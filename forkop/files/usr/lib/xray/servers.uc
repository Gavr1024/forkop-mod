#!/usr/bin/env ucode

let common = require("core.common");

let as_string = common.as_string;
let option = common.option;
let list_option = common.list_option;
let bool_option = common.bool_option;
let int_option = common.int_option;

function trim(value) {
    return replace(as_string(value), /^[ \t\r\n]+|[ \t\r\n]+$/g, "");
}

function nonempty_list(section, key) {
    let result = [];
    for (let item in list_option(section, key)) {
        item = trim(item);
        if (item != "")
            push(result, item);
    }
    return result;
}

function supported(protocol) {
    protocol = lc(trim(protocol));
    return protocol == "vless" || protocol == "vmess" || protocol == "trojan" ||
        protocol == "shadowsocks" || protocol == "socks" || protocol == "hysteria2";
}

function effective_security(section, protocol) {
    let security = option(section, "security", "");
    if (security == "") {
        if (protocol == "vless")
            security = "reality";
        else if (protocol == "trojan" || protocol == "hysteria2")
            security = "tls";
        else
            security = "none";
    }
    if (protocol == "shadowsocks" || protocol == "socks")
        return "none";
    if (protocol == "hysteria2")
        return "tls";
    if (protocol == "vmess" && security == "reality")
        return "none";
    if (protocol == "trojan" && security == "reality")
        return "tls";
    return security;
}

function user_name(section) {
    let name = option(section, "label", section[".name"]);
    if (name == "")
        name = as_string(section[".name"]);
    return name;
}

function duration_ms(value) {
    value = lc(trim(value));
    if (value == "")
        return null;
    let mult = 1;
    if (match(value, /ms$/) != null) {
        value = substr(value, 0, length(value) - 2);
    }
    else if (match(value, /h$/) != null) {
        mult = 3600000;
        value = substr(value, 0, length(value) - 1);
    }
    else if (match(value, /m$/) != null) {
        mult = 60000;
        value = substr(value, 0, length(value) - 1);
    }
    else if (match(value, /s$/) != null) {
        mult = 1000;
        value = substr(value, 0, length(value) - 1);
    }
    if (match(value, /^[0-9]+$/) == null)
        return null;
    return int(value, 10) * mult;
}

function transport_spec(kind) {
    kind = lc(trim(kind));
    if (kind == "" || kind == "tcp" || kind == "raw")
        return { network: "tcp", method: "raw", kind: "raw" };
    if (kind == "ws" || kind == "websocket")
        return { network: "ws", method: "websocket", kind: "ws" };
    if (kind == "grpc")
        return { network: "grpc", method: "grpc", kind: "grpc" };
    if (kind == "httpupgrade")
        return { network: "httpupgrade", method: "httpupgrade", kind: "httpupgrade" };
    if (kind == "xhttp" || kind == "splithttp")
        return { network: "xhttp", method: "xhttp", kind: "xhttp" };
    // HTTP/h2/h3 were removed in Xray 26. Emitting network "http" fails xray -test.
    if (kind == "http" || kind == "h2" || kind == "h3")
        return { network: "xhttp", method: "xhttp", kind: "http" };
    if (kind == "hysteria" || kind == "hysteria2" || kind == "hy2")
        return { network: "hysteria", method: "hysteria", kind: "hysteria" };
    return { network: "tcp", method: "raw", kind: "raw" };
}

function apply_transport_names(stream, kind) {
    let spec = transport_spec(kind);
    stream.network = spec.network;
    stream.method = spec.method;
    return spec;
}

function reality_transport_ok(kind) {
    return kind == "raw" || kind == "xhttp" || kind == "grpc";
}

function client_settings(section, protocol) {
    let name = user_name(section);
    if (protocol == "vless") {
        let uuid = option(section, "server_uuid", "");
        if (uuid == "")
            return null;
        let client = { id: uuid, email: name };
        let flow = option(section, "vless_flow", "");
        let transport = option(section, "transport", "tcp");
        let security = effective_security(section, protocol);
        // Vision is only valid on RAW with TLS or REALITY. Other combos fail xray -test.
        if (flow != "" && flow != "none" &&
            (transport == "" || transport == "tcp" || transport == "raw") &&
            (security == "tls" || security == "reality"))
            client.flow = flow;
        return { clients: [ client ], decryption: "none" };
    }
    if (protocol == "vmess") {
        let uuid = option(section, "server_uuid", "");
        if (uuid == "")
            return null;
        return {
            clients: [{
                id: uuid,
                alterId: int_option(section, "vmess_alter_id", "0"),
                email: name
            }]
        };
    }
    if (protocol == "trojan") {
        let password = option(section, "server_password", "");
        if (password == "")
            return null;
        return { clients: [{ password: password, email: name }] };
    }
    if (protocol == "shadowsocks") {
        let password = option(section, "server_password", "");
        if (password == "")
            return null;
        return {
            method: option(section, "shadowsocks_method", "aes-128-gcm"),
            password: password,
            network: "tcp,udp"
        };
    }
    if (protocol == "socks") {
        let settings = { udp: true };
        if (bool_option(section, "socks_auth_enabled", true)) {
            let username = option(section, "server_username", "");
            if (username == "")
                username = name != "" ? name : "user";
            let password = option(section, "server_password", "");
            if (password == "")
                return null;
            settings.auth = "password";
            settings.accounts = [{ user: username, pass: password }];
        }
        else {
            settings.auth = "noauth";
        }
        return settings;
    }
    if (protocol == "hysteria2") {
        let password = option(section, "server_password", "");
        if (password == "")
            return null;
        return { version: 2, users: [{ auth: password }] };
    }
    return null;
}

function apply_reality(stream, section) {
    let handshake = option(section, "reality_handshake_server", "www.microsoft.com");
    if (handshake == "")
        handshake = "www.microsoft.com";
    let handshake_port = int_option(section, "reality_handshake_server_port", "443");
    if (handshake_port <= 0)
        handshake_port = 443;
    let private_key = option(section, "reality_private_key", "");
    if (private_key == "")
        return false;
    let names = nonempty_list(section, "tls_server_name");
    if (length(names) == 0)
        push(names, handshake);
    let short_ids = nonempty_list(section, "reality_short_id");
    if (length(short_ids) == 0)
        push(short_ids, "");
    let reality = {
        show: false,
        dest: handshake + ":" + as_string(handshake_port),
        xver: 0,
        serverNames: names,
        privateKey: private_key,
        shortIds: short_ids
    };
    let diff = duration_ms(option(section, "reality_max_time_difference", "1m"));
    if (diff != null && diff > 0)
        reality.maxTimeDiff = diff;
    stream.security = "reality";
    stream.realitySettings = reality;
    return true;
}

function apply_tls(stream, section, protocol) {
    let cert = option(section, "tls_certificate_path", "");
    let key = option(section, "tls_key_path", "");
    if (cert == "" || key == "")
        return false;
    let tls = {
        certificates: [{
            certificateFile: cert,
            keyFile: key
        }]
    };
    let alpn = nonempty_list(section, "tls_alpn");
    if (length(alpn) == 0 && protocol == "hysteria2")
        push(alpn, "h3");
    if (length(alpn) > 0)
        tls.alpn = alpn;
    let server_name = option(section, "tls_server_name", "");
    if (server_name != "")
        tls.serverName = server_name;
    stream.security = "tls";
    stream.tlsSettings = tls;
    return true;
}

function apply_transport(stream, section, protocol) {
    if (protocol == "hysteria2") {
        apply_transport_names(stream, "hysteria");
        let hy = { version: 2 };
        let up = option(section, "hysteria2_up_mbps", "");
        let down = option(section, "hysteria2_down_mbps", "");
        if (match(trim(up), /^[0-9]+$/) != null && int(up, 10) > 0)
            hy.up = trim(up) + "mbps";
        if (match(trim(down), /^[0-9]+$/) != null && int(down, 10) > 0)
            hy.down = trim(down) + "mbps";
        stream.hysteriaSettings = hy;
        let obfs = option(section, "hysteria2_obfs_type", "");
        let obfs_password = option(section, "hysteria2_obfs_password", "");
        if (obfs == "salamander" && obfs_password != "")
            stream.finalmask = { udp: [{ type: "salamander", settings: { password: obfs_password } }] };
        return "hysteria";
    }
    if (protocol != "vless" && protocol != "vmess" && protocol != "trojan") {
        apply_transport_names(stream, "tcp");
        return "raw";
    }
    let transport = option(section, "transport", "tcp");
    let spec = apply_transport_names(stream, transport);
    if (spec.kind == "raw")
        return "raw";
    let path = option(section, "transport_path", "");
    let host = option(section, "transport_host", "");
    if (spec.kind == "ws") {
        let ws = {};
        if (path != "")
            ws.path = path;
        if (host != "") {
            ws.host = host;
            ws.headers = { Host: host };
        }
        stream.wsSettings = ws;
        return spec.kind;
    }
    if (spec.kind == "grpc") {
        let grpc = {};
        let service = option(section, "transport_service_name", "");
        if (service != "")
            grpc.serviceName = service;
        stream.grpcSettings = grpc;
        return spec.kind;
    }
    if (spec.kind == "httpupgrade") {
        let upgrade = {};
        if (path != "")
            upgrade.path = path;
        if (host != "")
            upgrade.host = host;
        stream.httpupgradeSettings = upgrade;
        return spec.kind;
    }
    if (spec.kind == "xhttp" || spec.kind == "http") {
        let mode = spec.kind == "http" ? "stream-one" : option(section, "transport_xhttp_mode", "auto");
        if (mode == "")
            mode = "auto";
        if (host == "" && spec.kind == "http") {
            let hosts = nonempty_list(section, "transport_hosts");
            if (length(hosts) > 0)
                host = hosts[0];
        }
        let xhttp = {
            path: path != "" ? path : "/",
            mode: mode
        };
        if (host != "")
            xhttp.host = host;
        stream.xhttpSettings = xhttp;
        return "xhttp";
    }
    return spec.kind;
}

function build_inbound(section, tag) {
    let protocol = lc(option(section, "protocol", "vless"));
    if (!supported(protocol))
        return null;
    let port = int_option(section, "listen_port", "443");
    if (port <= 0 || port > 65535)
        return null;
    let settings = client_settings(section, protocol);
    if (settings == null)
        return null;
    let xray_protocol = protocol == "hysteria2" ? "hysteria" : protocol;
    let stream = { security: "none" };
    let transport_kind = apply_transport(stream, section, protocol);
    let security = effective_security(section, protocol);
    if (security == "reality" && !reality_transport_ok(transport_kind)) {
        warn("Xray server '" + option(section, ".name", "") +
            "' REALITY only supports TCP, XHTTP and gRPC; skipped\n");
        return null;
    }
    if (security == "reality") {
        if (!apply_reality(stream, section))
            return null;
    }
    else if (security == "tls") {
        if (!apply_tls(stream, section, protocol))
            return null;
    }
    let listen = option(section, "listen", "0.0.0.0");
    if (listen == "")
        listen = "0.0.0.0";
    return {
        tag: as_string(tag),
        listen: listen,
        port: port,
        protocol: xray_protocol,
        settings: settings,
        streamSettings: stream,
        sniffing: {
            enabled: true,
            destOverride: [ "http", "tls", "quic" ],
            metadataOnly: false,
            routeOnly: true
        }
    };
}

return {
    supported,
    build_inbound
};
