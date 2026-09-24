#!/usr/bin/env ucode

let xray_constants = require("xray.constants");

function as_string(value) {
    return value == null ? "" : "" + value;
}

function object_or_empty(value) {
    return type(value) == "object" ? value : {};
}

function array_or_empty(value) {
    return type(value) == "array" ? value : [];
}

function trim(value) {
    return replace(as_string(value), /^[ \t\r\n]+|[ \t\r\n]+$/g, "");
}

function int_port(value) {
    if (type(value) == "int" || type(value) == "double") {
        let port = int(value);
        return port != null && port >= 1 && port <= 65535 ? port : 0;
    }
    value = trim(value);
    if (value == "")
        return 0;
    let port = int(value, 10);
    if (port == null || port < 1 || port > 65535)
        return 0;
    return port;
}

function sockopt() {
    return { mark: xray_constants.OUTBOUND_MARK };
}

function first_string(value) {
    if (type(value) == "array") {
        for (let item in value) {
            item = trim(item);
            if (item != "")
                return item;
        }
        return "";
    }
    return trim(value);
}

function string_list(value) {
    if (type(value) == "array") {
        let result = [];
        for (let item in value) {
            item = trim(item);
            if (item != "")
                push(result, item);
        }
        return result;
    }
    value = trim(value);
    return value != "" ? [ value ] : [];
}

function first_object(value) {
    if (type(value) == "object")
        return value;
    if (type(value) == "array" && length(value) > 0 && type(value[0]) == "object")
        return value[0];
    return {};
}

function tls_security(tls) {
    tls = object_or_empty(tls);
    if (type(tls.reality) == "object" && tls.reality.enabled)
        return "reality";
    if (tls.enabled)
        return "tls";
    return "none";
}

function tls_settings(tls) {
    tls = object_or_empty(tls);
    let result = {};
    let server_name = as_string(tls.server_name || tls.serverName || "");
    if (server_name != "")
        result.serverName = server_name;
    if (tls.insecure)
        result.allowInsecure = true;
    let alpn = string_list(tls.alpn);
    if (length(alpn) > 0)
        result.alpn = alpn;
    let fingerprint = as_string(object_or_empty(tls.utls).fingerprint || tls.fingerprint || "");
    if (fingerprint != "")
        result.fingerprint = fingerprint;
    let ech = as_string(tls.ech_config || tls.echConfigList || "");
    if (ech == "" && type(tls.ech) == "object")
        ech = first_string(object_or_empty(tls.ech).config || object_or_empty(tls.ech).config_list);
    if (ech != "")
        result.echConfigList = ech;
    return result;
}

function reality_settings(tls) {
    tls = object_or_empty(tls);
    let reality = object_or_empty(tls.reality);
    let spider = as_string(reality.spider_x || reality.spiderX || "/");
    if (spider == "")
        spider = "/";
    let result = {
        publicKey: as_string(reality.public_key || reality.publicKey || ""),
        shortId: as_string(reality.short_id || reality.shortId || ""),
        spiderX: spider
    };
    let server_name = as_string(tls.server_name || tls.serverName || reality.server_name || reality.serverName || "");
    if (server_name != "")
        result.serverName = server_name;
    let fingerprint = as_string(object_or_empty(tls.utls).fingerprint || reality.fingerprint || tls.fingerprint || "");
    if (fingerprint != "")
        result.fingerprint = fingerprint;
    else
        result.fingerprint = "chrome";
    return result;
}

function apply_tls(stream, tls) {
    let security = tls_security(tls);
    if (security == "none")
        return stream;
    stream.security = security;
    if (security == "reality")
        stream.realitySettings = reality_settings(tls);
    else
        stream.tlsSettings = tls_settings(tls);
    return stream;
}

function transport_names(kind) {
    kind = lc(trim(kind));
    if (kind == "" || kind == "tcp" || kind == "raw")
        return { network: "tcp", method: "raw" };
    if (kind == "ws" || kind == "websocket")
        return { network: "ws", method: "websocket" };
    if (kind == "grpc")
        return { network: "grpc", method: "grpc" };
    if (kind == "httpupgrade")
        return { network: "httpupgrade", method: "httpupgrade" };
    if (kind == "xhttp" || kind == "splithttp")
        return { network: "xhttp", method: "xhttp" };
    if (kind == "http" || kind == "h2" || kind == "h3")
        return { network: "xhttp", method: "xhttp" };
    if (kind == "kcp" || kind == "mkcp")
        return { network: "kcp", method: "mkcp" };
    if (kind == "hysteria" || kind == "hysteria2" || kind == "hy2")
        return { network: "hysteria", method: "hysteria" };
    return { network: "tcp", method: "raw" };
}

function apply_transport_names(stream, kind) {
    let names = transport_names(kind);
    stream.network = names.network;
    stream.method = names.method;
    return names;
}

function apply_transport(stream, transport) {
    transport = object_or_empty(transport);
    let kind = as_string(transport.type || "");
    if (kind == "" || kind == "tcp" || kind == "raw") {
        apply_transport_names(stream, "tcp");
        return stream;
    }

    let names = apply_transport_names(stream, kind);
    if (kind == "ws" || kind == "websocket") {
        let ws = { path: as_string(transport.path || "/") };
        if (type(transport.headers) == "object")
            ws.headers = transport.headers;
        else if (as_string(transport.host || "") != "")
            ws.headers = { Host: as_string(transport.host) };
        if (as_string(transport.host || "") != "" && ws.host == null)
            ws.host = as_string(transport.host);
        if (transport.max_early_data != null) {
            let early = type(transport.max_early_data) == "int" || type(transport.max_early_data) == "double"
                ? int(transport.max_early_data)
                : int(as_string(transport.max_early_data), 10);
            if (early != null)
                ws.maxEarlyData = early;
        }
        stream.wsSettings = ws;
        return stream;
    }
    if (kind == "grpc") {
        let grpc = {};
        if (as_string(transport.service_name || transport.serviceName || "") != "")
            grpc.serviceName = as_string(transport.service_name || transport.serviceName);
        stream.grpcSettings = grpc;
        return stream;
    }
    if (kind == "httpupgrade") {
        let upgrade = {};
        if (as_string(transport.path || "") != "")
            upgrade.path = as_string(transport.path);
        if (as_string(transport.host || "") != "")
            upgrade.host = as_string(transport.host);
        stream.httpupgradeSettings = upgrade;
        return stream;
    }
    if (kind == "xhttp" || kind == "splithttp" || kind == "http" || kind == "h2" || kind == "h3") {
        let xhttp = {
            path: as_string(transport.path || "/"),
            mode: as_string(transport.mode || "auto")
        };
        if (as_string(transport.host || "") != "")
            xhttp.host = first_string(transport.host);
        stream.xhttpSettings = xhttp;
        if (names.network == "xhttp")
            delete stream.httpSettings;
        return stream;
    }
    if (kind == "hysteria2" || kind == "hysteria" || kind == "hy2") {
        if (type(stream.hysteriaSettings) != "object")
            stream.hysteriaSettings = { version: 2 };
        return stream;
    }
    return stream;
}

function stream_settings(ir) {
    ir = object_or_empty(ir);
    let stream = {
        network: "tcp",
        method: "raw",
        security: "none",
        sockopt: sockopt()
    };
    apply_transport(stream, ir.transport);
    apply_tls(stream, ir.tls);
    let packet = as_string(ir.packet_encoding || ir.packetEncoding || "");
    if (packet == "xudp" || packet == "packetaddr")
        stream.sockopt.xudp = true;
    return stream;
}

function ir_uuid(ir) {
    ir = object_or_empty(ir);
    return as_string(ir.uuid || ir.id || "");
}

function vless_has_transport_security(ir) {
    ir = object_or_empty(ir);
    if (tls_security(object_or_empty(ir.tls)) != "none")
        return true;
    let encryption = lc(as_string(ir.encryption || "none"));
    return encryption != "" && encryption != "none";
}

function convert_vless(ir, tag) {
    ir = object_or_empty(ir);
    let port = int_port(ir.server_port || ir.port);
    let uuid = ir_uuid(ir);
    if (as_string(ir.server || ir.address || "") == "" || port == 0 || uuid == "")
        return null;
    if (!vless_has_transport_security(ir))
        return null;
    let encryption = as_string(ir.encryption || "");
    if (encryption == "")
        encryption = "none";
    let settings = {
        address: as_string(ir.server || ir.address),
        port: port,
        id: uuid,
        encryption: encryption
    };
    let flow = as_string(ir.flow || "");
    if (flow != "")
        settings.flow = flow;
    return {
        tag: as_string(tag),
        protocol: "vless",
        settings: settings,
        streamSettings: stream_settings(ir)
    };
}

function convert_vmess(ir, tag) {
    ir = object_or_empty(ir);
    let port = int_port(ir.server_port || ir.port);
    let uuid = ir_uuid(ir);
    if (as_string(ir.server || ir.address || "") == "" || port == 0 || uuid == "")
        return null;
    let security = as_string(ir.security || "auto");
    if (security == "" || security == "none" || security == "zero")
        security = "auto";
    return {
        tag: as_string(tag),
        protocol: "vmess",
        settings: {
            address: as_string(ir.server || ir.address),
            port: port,
            id: uuid,
            security: security
        },
        streamSettings: stream_settings(ir)
    };
}

function convert_trojan(ir, tag) {
    ir = object_or_empty(ir);
    let port = int_port(ir.server_port || ir.port);
    let password = as_string(ir.password || "");
    if (as_string(ir.server || ir.address || "") == "" || port == 0 || password == "")
        return null;
    return {
        tag: as_string(tag),
        protocol: "trojan",
        settings: {
            address: as_string(ir.server || ir.address),
            port: port,
            password: password
        },
        streamSettings: stream_settings(ir)
    };
}

function convert_shadowsocks(ir, tag) {
    ir = object_or_empty(ir);
    let port = int_port(ir.server_port || ir.port);
    if (as_string(ir.server || ir.address || "") == "" || port == 0 || as_string(ir.password || "") == "" || as_string(ir.method || "") == "")
        return null;
    let settings = {
        address: as_string(ir.server || ir.address),
        port: port,
        method: as_string(ir.method),
        password: as_string(ir.password)
    };
    if (as_string(ir.plugin || "") != "")
        settings.plugin = as_string(ir.plugin);
    if (as_string(ir.plugin_opts || ir.pluginOpts || "") != "")
        settings.pluginOpts = as_string(ir.plugin_opts || ir.pluginOpts);
    return {
        tag: as_string(tag),
        protocol: "shadowsocks",
        settings: settings,
        streamSettings: {
            network: "tcp",
            method: "raw",
            sockopt: sockopt()
        }
    };
}

function convert_socks(ir, tag) {
    ir = object_or_empty(ir);
    let port = int_port(ir.server_port || ir.port);
    if (as_string(ir.server || ir.address || "") == "" || port == 0)
        return null;
    let settings = {
        address: as_string(ir.server || ir.address),
        port: port
    };
    if (as_string(ir.username || ir.user || "") != "") {
        settings.user = as_string(ir.username || ir.user);
        settings.pass = as_string(ir.password || ir.pass || "");
    }
    return {
        tag: as_string(tag),
        protocol: "socks",
        settings: settings,
        streamSettings: {
            network: "tcp",
            method: "raw",
            sockopt: sockopt()
        }
    };
}

function hysteria_looks_like_hostname(value) {
    value = as_string(value);
    return value != "" && match(value, /[A-Za-z]/) != null;
}

function hysteria_udphop_ports(server_ports) {
    if (type(server_ports) != "array" || length(server_ports) == 0)
        return "";
    let parts = [];
    for (let item in server_ports) {
        item = trim(as_string(item));
        if (item == "")
            continue;
        let colon = index(item, ":");
        if (colon < 0) {
            push(parts, item);
            continue;
        }
        let start = substr(item, 0, colon);
        let stop = substr(item, colon + 1);
        if (start == stop || stop == "")
            push(parts, start);
        else
            push(parts, start + "-" + stop);
    }
    return join(",", parts);
}

function hysteria_obfs_password(ir) {
    ir = object_or_empty(ir);
    let obfs = object_or_empty(ir.obfs);
    let kind = lc(as_string(obfs.type || ir.obfs_type || ""));
    if (kind == "" || kind == "none")
        return "";
    return as_string(obfs.password || obfs.obfs_password || ir["obfs-password"] || ir.obfs_password || "");
}

function apply_hysteria_finalmask(stream, obfs_password, hop_ports) {
    stream = object_or_empty(stream);
    let mask = {};
    if (obfs_password != "")
        mask.udp = [{ type: "salamander", settings: { password: obfs_password } }];
    if (hop_ports != "") {
        if (type(mask.quicParams) != "object")
            mask.quicParams = {};
        mask.quicParams.udpHop = { ports: hop_ports };
    }
    if (length(keys(mask)) > 0)
        stream.finalmask = mask;
    return stream;
}

function convert_hysteria2(ir, tag) {
    ir = object_or_empty(ir);
    let port = int_port(ir.server_port || ir.port);
    if (port == 0 && type(ir.server_ports) == "array" && length(ir.server_ports) > 0) {
        let first = as_string(ir.server_ports[0]);
        let colon = index(first, ":");
        port = int_port(colon >= 0 ? substr(first, 0, colon) : first);
    }
    let password = as_string(ir.password || ir.auth || "");
    if (as_string(ir.server || ir.address || "") == "" || port == 0 || password == "")
        return null;

    let tls = object_or_empty(ir.tls);
    if (!tls.enabled)
        tls.enabled = true;
    let tls_cfg = tls_settings(tls);
    if (object_or_empty(tls_cfg).alpn == null)
        tls_cfg.alpn = [ "h3" ];
    if (as_string(tls_cfg.serverName || "") == "" && hysteria_looks_like_hostname(ir.server || ir.address))
        tls_cfg.serverName = as_string(ir.server || ir.address);

    let hy = { version: 2, auth: password };
    if (ir.up_mbps != null && as_string(ir.up_mbps) != "")
        hy.up = as_string(ir.up_mbps) + "mbps";
    if (ir.down_mbps != null && as_string(ir.down_mbps) != "")
        hy.down = as_string(ir.down_mbps) + "mbps";
    let hop_ports = hysteria_udphop_ports(ir.server_ports);
    if (hop_ports != "")
        hy.udphop = { ports: hop_ports };

    let stream = {
        network: "hysteria",
        method: "hysteria",
        security: "tls",
        tlsSettings: tls_cfg,
        hysteriaSettings: hy,
        sockopt: sockopt()
    };
    apply_hysteria_finalmask(stream, hysteria_obfs_password(ir), hop_ports);

    return {
        tag: as_string(tag),
        protocol: "hysteria",
        settings: {
            version: 2,
            address: as_string(ir.server || ir.address),
            port: port
        },
        streamSettings: stream
    };
}

function normalize_stream_protocol(stream) {
    stream = object_or_empty(stream);
    let kind = as_string(stream.method || stream.network || "");
    if (kind == "") {
        stream.network = "tcp";
        stream.method = "raw";
        return stream;
    }
    let names = transport_names(kind);
    stream.network = names.network;
    stream.method = names.method;
    if (names.network == "hysteria") {
        if (type(stream.hysteriaSettings) != "object")
            stream.hysteriaSettings = {};
        if (stream.hysteriaSettings.version == null)
            stream.hysteriaSettings.version = 2;
    }
    if (names.network == "xhttp" && type(stream.httpSettings) == "object" && type(stream.xhttpSettings) != "object") {
        stream.xhttpSettings = stream.httpSettings;
        delete stream.httpSettings;
    }
    return stream;
}

function flatten_vnext(settings, extra_user_fields) {
    settings = object_or_empty(settings);
    if (as_string(settings.address || "") != "" && int_port(settings.port) > 0)
        return settings;
    let server = first_object(settings.vnext);
    if (as_string(server.address || "") == "")
        return settings;
    let user = first_object(server.users);
    settings.address = as_string(server.address);
    settings.port = int_port(server.port);
    if (as_string(user.id || user.uuid || settings.id || "") != "")
        settings.id = as_string(user.id || user.uuid || settings.id);
    for (let field in extra_user_fields) {
        if (as_string(settings[field] || "") == "" && as_string(user[field] || "") != "")
            settings[field] = user[field];
    }
    delete settings.vnext;
    return settings;
}

function flatten_servers(settings, extra_fields) {
    settings = object_or_empty(settings);
    if (as_string(settings.address || "") != "" && int_port(settings.port) > 0)
        return settings;
    let server = first_object(settings.servers);
    if (as_string(server.address || "") == "")
        return settings;
    settings.address = as_string(server.address);
    settings.port = int_port(server.port);
    for (let field in extra_fields) {
        if (as_string(settings[field] || "") == "" && as_string(server[field] || "") != "")
            settings[field] = server[field];
    }
    if (type(server.users) == "array" && length(server.users) > 0 && type(server.users[0]) == "object") {
        let user = server.users[0];
        if (as_string(settings.user || "") == "")
            settings.user = as_string(user.user || user.username || "");
        if (as_string(settings.pass || "") == "")
            settings.pass = as_string(user.pass || user.password || "");
    }
    delete settings.servers;
    return settings;
}

function normalize_hysteria_native(outbound) {
    outbound = object_or_empty(outbound);
    let proto = lc(as_string(outbound.protocol || ""));
    if (proto != "hysteria" && proto != "hysteria2")
        return outbound;

    outbound.protocol = "hysteria";
    if (type(outbound.settings) != "object")
        outbound.settings = {};
    let settings = outbound.settings;
    settings = flatten_servers(settings, [ "password", "auth" ]);
    let password = as_string(settings.password || settings.auth || "");
    if (settings.password != null)
        delete settings.password;
    if (settings.auth != null)
        delete settings.auth;
    if (settings.version == null)
        settings.version = 2;
    outbound.settings = settings;

    if (type(outbound.streamSettings) != "object")
        outbound.streamSettings = {};
    let stream = outbound.streamSettings;
    normalize_stream_protocol(stream);
    stream.network = "hysteria";
    stream.method = "hysteria";
    if (type(stream.hysteriaSettings) != "object")
        stream.hysteriaSettings = {};
    if (stream.hysteriaSettings.version == null)
        stream.hysteriaSettings.version = 2;
    if (as_string(stream.hysteriaSettings.auth || "") == "" && password != "")
        stream.hysteriaSettings.auth = password;
    let hop_ports = as_string(stream.hysteriaSettings.hopPorts || "");
    if (hop_ports != "") {
        delete stream.hysteriaSettings.hopPorts;
        if (type(stream.hysteriaSettings.udphop) != "object")
            stream.hysteriaSettings.udphop = { ports: hop_ports };
    }
    if (as_string(stream.security || "") == "")
        stream.security = "tls";
    if (type(stream.tlsSettings) != "object")
        stream.tlsSettings = {};
    if (object_or_empty(stream.tlsSettings).alpn == null)
        stream.tlsSettings.alpn = [ "h3" ];
    if (as_string(stream.tlsSettings.serverName || "") == "" && hysteria_looks_like_hostname(settings.address))
        stream.tlsSettings.serverName = as_string(settings.address);
    apply_hysteria_finalmask(
        stream,
        hysteria_obfs_password(outbound),
        as_string(object_or_empty(stream.hysteriaSettings.udphop).ports || hop_ports)
    );
    outbound.streamSettings = stream;
    return outbound;
}

function normalize_native_settings(outbound) {
    outbound = object_or_empty(outbound);
    let proto = lc(as_string(outbound.protocol || ""));
    if (type(outbound.settings) != "object")
        outbound.settings = {};
    if (proto == "vless") {
        outbound.settings = flatten_vnext(outbound.settings, [ "flow", "encryption" ]);
        if (as_string(outbound.settings.encryption || "") == "")
            outbound.settings.encryption = "none";
    }
    else if (proto == "vmess") {
        outbound.settings = flatten_vnext(outbound.settings, [ "security", "email" ]);
        if (outbound.settings.alterId != null)
            delete outbound.settings.alterId;
        if (as_string(outbound.settings.security || "") == "" || outbound.settings.security == "none" || outbound.settings.security == "zero")
            outbound.settings.security = "auto";
    }
    else if (proto == "trojan")
        outbound.settings = flatten_servers(outbound.settings, [ "password", "email" ]);
    else if (proto == "shadowsocks")
        outbound.settings = flatten_servers(outbound.settings, [ "method", "password", "email", "plugin", "pluginOpts" ]);
    else if (proto == "socks")
        outbound.settings = flatten_servers(outbound.settings, [ "user", "pass", "email" ]);
    return outbound;
}

function ensure_sockopt(outbound) {
    outbound = object_or_empty(outbound);
    if (type(outbound.streamSettings) != "object")
        outbound.streamSettings = {};
    let stream = outbound.streamSettings;
    normalize_stream_protocol(stream);
    if (type(stream.sockopt) != "object")
        stream.sockopt = {};
    stream.sockopt.mark = xray_constants.OUTBOUND_MARK;
    outbound.streamSettings = stream;
    return outbound;
}

function native_vless_is_plaintext(outbound) {
    outbound = object_or_empty(outbound);
    if (lc(as_string(outbound.protocol || "")) != "vless")
        return false;
    let security = lc(as_string(object_or_empty(outbound.streamSettings).security || "none"));
    if (security != "" && security != "none")
        return false;
    let encryption = lc(as_string(object_or_empty(outbound.settings).encryption || "none"));
    return encryption == "" || encryption == "none";
}

function convert_xray_native(outbound, tag) {
    outbound = object_or_empty(outbound);
    if (as_string(outbound.protocol || "") == "")
        return null;
    let result = {};
    for (let key in outbound)
        result[key] = outbound[key];
    result.tag = as_string(tag || outbound.tag || "");
    result = normalize_native_settings(result);
    result = normalize_hysteria_native(result);
    if (native_vless_is_plaintext(result))
        return null;
    return ensure_sockopt(result);
}

function fragment_range(value, fallback) {
    value = trim(as_string(value));
    if (match(value, /^[0-9]+$/) == null && match(value, /^[0-9]+-[0-9]+$/) == null)
        return fallback;
    return value;
}

function apply_freedom_fragment(outbound, spec) {
    outbound = object_or_empty(outbound);
    spec = object_or_empty(spec);
    if (lc(as_string(outbound.protocol || "")) != "freedom")
        return outbound;
    if (spec.enabled != true)
        return outbound;
    if (type(outbound.settings) != "object")
        outbound.settings = {};
    outbound.settings.fragment = {
        packets: "tlshello",
        length: fragment_range(spec.length, "100-200"),
        interval: fragment_range(spec.interval, "10-20")
    };
    return outbound;
}

function apply_tcp_finalmask(outbound, spec) {
    outbound = object_or_empty(outbound);
    spec = object_or_empty(spec);
    if (spec.enabled != true)
        return outbound;
    let proto = lc(as_string(outbound.protocol || ""));
    if (proto == "" || proto == "freedom" || proto == "blackhole" || proto == "dns" || proto == "hysteria")
        return outbound;
    if (type(outbound.streamSettings) != "object")
        outbound.streamSettings = {};
    let stream = outbound.streamSettings;
    if (type(stream.finalmask) != "object")
        stream.finalmask = {};
    if (type(stream.finalmask.tcp) != "array")
        stream.finalmask.tcp = [];
    for (let item in stream.finalmask.tcp) {
        if (type(item) == "object" && lc(as_string(item.type || "")) == "fragment")
            return outbound;
    }
    push(stream.finalmask.tcp, {
        type: "fragment",
        settings: {
            packets: "tlshello",
            lengths: [ fragment_range(spec.length, "100-200") ],
            delays: [ fragment_range(spec.interval, "10-20") ]
        }
    });
    outbound.streamSettings = stream;
    return outbound;
}

function convert_interface(iface, tag) {
    iface = trim(iface);
    if (iface == "")
        return null;
    return {
        tag: as_string(tag),
        protocol: "freedom",
        settings: {
            domainStrategy: "UseIP"
        },
        streamSettings: {
            sockopt: {
                mark: xray_constants.OUTBOUND_MARK,
                interface: iface
            }
        }
    };
}

function socks_chain_outbound(tag, port) {
    port = int_port(port);
    if (port == 0)
        return null;
    return {
        tag: as_string(tag),
        protocol: "socks",
        settings: {
            address: xray_constants.XRAY_SOCKS_LISTEN,
            port: port
        },
        streamSettings: {
            sockopt: sockopt()
        }
    };
}

function apply_dialer_proxy(outbound, via_tag) {
    outbound = object_or_empty(outbound);
    via_tag = as_string(via_tag);
    if (via_tag == "")
        return outbound;
    if (type(outbound.streamSettings) != "object")
        outbound.streamSettings = {};
    if (type(outbound.streamSettings.sockopt) != "object")
        outbound.streamSettings.sockopt = sockopt();
    outbound.streamSettings.sockopt.dialerProxy = via_tag;
    return outbound;
}

function convert_ir(ir, tag) {
    ir = object_or_empty(ir);
    tag = as_string(tag || ir.tag || "");
    if (tag == "")
        return null;

    if (as_string(ir.protocol || "") != "")
        return convert_xray_native(ir, tag);

    let kind = lc(as_string(ir.type || ""));
    if (kind == "vless")
        return convert_vless(ir, tag);
    if (kind == "vmess")
        return convert_vmess(ir, tag);
    if (kind == "trojan")
        return convert_trojan(ir, tag);
    if (kind == "shadowsocks")
        return convert_shadowsocks(ir, tag);
    if (kind == "socks")
        return convert_socks(ir, tag);
    if (kind == "hysteria2" || kind == "hysteria" || kind == "hy2")
        return convert_hysteria2(ir, tag);
    if (kind == "direct")
        return convert_interface(ir.bind_interface || ir.interface || "", tag);
    return null;
}

function supported_ir(ir) {
    return convert_ir(ir, "probe") != null;
}

return {
    convert_ir,
    convert_xray_native,
    convert_interface,
    socks_chain_outbound,
    apply_dialer_proxy,
    apply_freedom_fragment,
    apply_tcp_finalmask,
    supported_ir,
    ensure_sockopt,
    sockopt
};
