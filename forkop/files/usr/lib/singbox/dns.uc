#!/usr/bin/env ucode

let common = require("core.common");
let core_ip = require("core.ip");
let runtime_constants = require("singbox.constants");
let runtime_url = require("core.url");

let as_string = common.as_string;
let bool_option = common.bool_option;
let list_option = common.list_option;
let object_or_empty = common.object_or_empty;
let option = common.option;
let read_json_file = common.read_json_file;

const DNS_FAILOVER_STATE_FILE = getenv("FORKOP_DNS_FAILOVER_STATE_FILE") || "/var/run/forkop/dns-failover.json";
const DNS_HEALTH_ADDRESS = getenv("FORKOP_DNS_HEALTH_ADDRESS") || "127.0.0.42";
const DNS_HEALTH_PORT_BASE = int(getenv("FORKOP_DNS_HEALTH_PORT_BASE") || "10053");

function doq_server_name(value) {
    let host = lc(trim(as_string(value)));
    if (host == "9.9.9.9" || host == "149.112.112.112" || host == "dns.quad9.net")
        return "dns.quad9.net";
    if (host == "9.9.9.11" || host == "149.112.112.11" || host == "dns11.quad9.net")
        return "dns11.quad9.net";
    if (host == "223.5.5.5" || host == "223.6.6.6" || host == "dns.alidns.com")
        return "dns.alidns.com";
    if (host == "94.140.14.14" || host == "94.140.15.15" || host == "dns.adguard-dns.com")
        return "dns.adguard-dns.com";
    if (host == "94.140.14.140" || host == "94.140.15.141" || host == "unfiltered.adguard-dns.com")
        return "unfiltered.adguard-dns.com";
    if (host == "94.140.14.15" || host == "94.140.15.16" || host == "family.adguard-dns.com")
        return "family.adguard-dns.com";
    return "";
}

function doh3_server_name(value) {
    let host = lc(trim(as_string(value)));
    if (host == "8.8.8.8" || host == "8.8.4.4" || host == "dns.google")
        return "dns.google";
    if (host == "1.1.1.1" || host == "1.0.0.1" || host == "cloudflare-dns.com")
        return "cloudflare-dns.com";
    if (host == "9.9.9.9" || host == "149.112.112.112" || host == "dns.quad9.net")
        return "dns.quad9.net";
    if (host == "9.9.9.11" || host == "149.112.112.11" || host == "dns11.quad9.net")
        return "dns11.quad9.net";
    if (host == "223.5.5.5" || host == "223.6.6.6" || host == "dns.alidns.com")
        return "dns.alidns.com";
    if (host == "94.140.14.14" || host == "94.140.15.15" || host == "dns.adguard-dns.com")
        return "dns.adguard-dns.com";
    if (host == "94.140.14.140" || host == "94.140.15.141" || host == "unfiltered.adguard-dns.com")
        return "unfiltered.adguard-dns.com";
    if (host == "94.140.14.15" || host == "94.140.15.16" || host == "family.adguard-dns.com")
        return "family.adguard-dns.com";
    return "";
}

function explicit_certificate_name(value) {
    value = trim(as_string(value));
    let hash = index(value, "#");
    if (hash < 0)
        return "";
    return lc(trim(substr(value, hash + 1)));
}

function preset_tls_name(dns_type, host) {
    dns_type = lc(trim(as_string(dns_type)));
    if (dns_type == "doq")
        return doq_server_name(host);
    if (dns_type == "doh3")
        return doh3_server_name(host);
    return "";
}

function with_certificate_name(value, dns_type, extra_name) {
    value = trim(as_string(value));
    extra_name = lc(trim(as_string(extra_name)));
    if (value == "" || extra_name == "" || explicit_certificate_name(value) != "")
        return value;
    let host = runtime_url.host(value);
    if (host == "")
        host = value;
    if (!core_ip.valid_ip(host) || preset_tls_name(dns_type, host) != "")
        return value;
    return value + "#" + extra_name;
}

function server_list(settings, key, fallback) {
    let result = [];
    let cert = key == "dns_server" ? option(settings, "dns_certificate_name", "") : "";
    let dns_type = option(settings, "dns_type", "udp");
    for (let value in list_option(settings, key)) {
        value = trim(as_string(value));
        if (value == "")
            continue;
        push(result, with_certificate_name(value, dns_type, cert));
    }
    if (length(result) == 0)
        push(result, fallback);
    return result;
}

function arrays_equal(left, right) {
    if (length(left || []) != length(right || []))
        return false;
    for (let i = 0; i < length(left); i++)
        if (as_string(left[i]) != as_string(right[i]))
            return false;
    return true;
}

function detour_tag(settings) {
    if (!bool_option(settings, "dns_detour_enabled", false))
        return "";
    let section_name = option(settings, "dns_detour_section", "");
    return section_name == "" ? "" : runtime_constants.outbound_tag(section_name);
}

function state_template(settings) {
    return {
        version: 1,
        dns_type: option(settings, "dns_type", "udp"),
        dns_detour: detour_tag(settings),
        main_servers: server_list(settings, "dns_server", "77.88.8.8"),
        bootstrap_servers: server_list(settings, "bootstrap_dns_server", "77.88.8.8"),
        main_index: 0,
        bootstrap_index: 0
    };
}

function state_matches(template, state) {
    state = object_or_empty(state);
    return int(state.version || 0) == 1 &&
        as_string(state.dns_type) == template.dns_type &&
        as_string(state.dns_detour) == template.dns_detour &&
        arrays_equal(state.main_servers, template.main_servers) &&
        arrays_equal(state.bootstrap_servers, template.bootstrap_servers);
}

function bounded_index(value, values) {
    let index_value = int(value || 0);
    return index_value >= 0 && index_value < length(values) ? index_value : 0;
}

function normalize_state(settings, state) {
    let result = state_template(settings);
    if (!state_matches(result, state))
        return result;

    result.main_index = bounded_index(object_or_empty(state).main_index, result.main_servers);
    result.bootstrap_index = bounded_index(object_or_empty(state).bootstrap_index, result.bootstrap_servers);
    return result;
}

function runtime_state(settings, override_state) {
    let state = override_state;
    if (state == null)
        state = read_json_file(DNS_FAILOVER_STATE_FILE);
    return normalize_state(settings, state);
}

function active_values(settings, override_state) {
    let state = runtime_state(settings, override_state);
    return {
        state,
        main: state.main_servers[state.main_index],
        bootstrap: state.bootstrap_servers[state.bootstrap_index]
    };
}

function dns_pinned_ip(name) {
    name = lc(trim(as_string(name)));
    if (name == "dns.quad9.net")
        return "9.9.9.9";
    if (name == "dns11.quad9.net")
        return "9.9.9.11";
    if (name == "dns.google")
        return "8.8.8.8";
    if (name == "cloudflare-dns.com" || name == "one.one.one.one")
        return "1.1.1.1";
    if (name == "dns.alidns.com")
        return "223.5.5.5";
    if (name == "dns.adguard-dns.com")
        return "94.140.14.14";
    if (name == "unfiltered.adguard-dns.com")
        return "94.140.14.140";
    if (name == "family.adguard-dns.com")
        return "94.140.14.15";
    if (name == "doh.opendns.com" || name == "dns.opendns.com")
        return "208.67.222.222";
    if (name == "common.dot.dns.yandex.net")
        return "77.88.8.8";
    return "";
}

function server_from_options(tag_name, dns_type, dns_server, detour) {
    let server = runtime_url.host(dns_server);
    let port = runtime_url.port(dns_server);
    let result = {
        type: "udp",
        tag: tag_name,
        server,
        server_port: 53
    };

    if (dns_type == "udp") {
        if (port != "")
            result.server_port = int(port, 10);
    }
    else if (dns_type == "dot") {
        result.type = "tls";
        result.server_port = port != "" ? int(port, 10) : 853;
    }
    else if (dns_type == "doh") {
        result.type = "https";
        result.server_port = port != "" ? int(port, 10) : 443;
        let path = runtime_url.path(dns_server);
        if (path != "")
            result.path = path;
    }
    else if (dns_type == "doq") {
        result.type = "quic";
        result.server_port = port != "" ? int(port, 10) : 853;
        let explicit = explicit_certificate_name(dns_server);
        let name = doq_server_name(server);
        if (name == "" && explicit != "")
            name = explicit;
        if (name == "")
            name = server;
        let pin = core_ip.valid_ip(server) ? server : dns_pinned_ip(name);
        if (pin != "")
            result.server = pin;
        else if (name != "")
            result.server = name;
        if (name != "" && !core_ip.valid_ip(name))
            result.tls = { enabled: true, server_name: name };
    }
    else if (dns_type == "doh3") {
        result.type = "h3";
        result.server_port = port != "" ? int(port, 10) : 443;
        let path = runtime_url.path(dns_server);
        result.path = path != "" && path != "/" ? path : "/dns-query";
        let explicit = explicit_certificate_name(dns_server);
        let name = doh3_server_name(server);
        if (name == "" && explicit != "")
            name = explicit;
        if (name == "")
            name = server;
        let pin = core_ip.valid_ip(server) ? server : dns_pinned_ip(name);
        if (pin != "")
            result.server = pin;
        else if (name != "")
            result.server = name;
        if (name != "" && !core_ip.valid_ip(name))
            result.tls = { enabled: true, server_name: name };
    }
    else {
        return { unsupported: "unsupported dns_type " + dns_type };
    }

    if (!core_ip.valid_ip(result.server))
        result.domain_resolver = runtime_constants.BOOTSTRAP_DNS_SERVER_TAG;
    if (as_string(detour) != "")
        result.detour = as_string(detour);

    return result;
}

function bootstrap_server(tag_name, value) {
    let server = runtime_url.host(value);
    let port = runtime_url.port(value);
    return {
        type: "udp",
        tag: tag_name,
        server: server != "" ? server : value,
        server_port: port != "" ? int(port, 10) : 53
    };
}

function server_config(settings, override_state) {
    let active = active_values(settings, override_state);
    return server_from_options(
        runtime_constants.DNS_SERVER_TAG,
        active.state.dns_type,
        active.main,
        active.state.dns_detour
    );
}

function bootstrap_config(settings, override_state) {
    let active = active_values(settings, override_state);
    return bootstrap_server(runtime_constants.BOOTSTRAP_DNS_SERVER_TAG, active.bootstrap);
}

function excluded_bootstrap_host(settings, override_state) {
    let active = active_values(settings, override_state);
    let server = runtime_url.host(active.bootstrap);
    if (server == "")
        server = as_string(active.bootstrap);
    if (server == "")
        server = "1.1.1.1";
    return server;
}

function excluded_tls_config(settings, override_state) {
    let server = excluded_bootstrap_host(settings, override_state);
    let result = {
        type: "tls",
        tag: runtime_constants.EXCLUDED_DNS_SERVER_TAG,
        server,
        server_port: 853,
        detour: runtime_constants.BYPASS_OUTBOUND_TAG
    };
    if (!core_ip.valid_ip(server))
        result.domain_resolver = runtime_constants.BOOTSTRAP_DNS_SERVER_TAG;
    return result;
}

function excluded_https_config(settings, override_state) {
    let server = excluded_bootstrap_host(settings, override_state);
    let result = {
        type: "https",
        tag: runtime_constants.EXCLUDED_DNS_HTTPS_TAG,
        server,
        server_port: 443,
        path: "/dns-query",
        detour: runtime_constants.BYPASS_OUTBOUND_TAG
    };
    if (!core_ip.valid_ip(server))
        result.domain_resolver = runtime_constants.BOOTSTRAP_DNS_SERVER_TAG;
    return result;
}

function failover_enabled(settings) {
    let state = state_template(settings);
    return length(state.main_servers) > 1 || length(state.bootstrap_servers) > 1;
}

function health_tag(kind, index_value, suffix) {
    return "dns-health-" + as_string(kind) + "-" + as_string(index_value + 1) + "-" + as_string(suffix);
}

function health_port(kind, index_value) {
    if (kind == "active")
        return DNS_HEALTH_PORT_BASE + 2000;
    return DNS_HEALTH_PORT_BASE + int(index_value) * 2 + (kind == "bootstrap" ? 1 : 0);
}

function add_active_health_inbound(result) {
    let inbound_tag = "dns-health-active-main-in";
    push(result.inbounds, {
        type: "direct",
        tag: inbound_tag,
        listen: DNS_HEALTH_ADDRESS,
        listen_port: health_port("active", 0)
    });
    push(result.rules, {
        action: "route",
        inbound: inbound_tag,
        server: runtime_constants.DNS_SERVER_TAG,
        disable_cache: true
    });
    push(result.sniff_inbounds, inbound_tag);
}

function add_health_candidate(result, kind, index_value, server) {
    let server_tag = health_tag(kind, index_value, "server");
    let inbound_tag = health_tag(kind, index_value, "in");
    let dns_server = kind == "main"
        ? server_from_options(server_tag, result.state.dns_type, server, result.state.dns_detour)
        : bootstrap_server(server_tag, server);

    if (dns_server.unsupported) {
        result.unsupported = dns_server.unsupported;
        return;
    }

    push(result.servers, dns_server);
    push(result.inbounds, {
        type: "direct",
        tag: inbound_tag,
        listen: DNS_HEALTH_ADDRESS,
        listen_port: health_port(kind, index_value)
    });
    push(result.rules, {
        action: "route",
        inbound: inbound_tag,
        server: server_tag,
        disable_cache: true
    });
    push(result.sniff_inbounds, inbound_tag);
}

function config(settings, override_state) {
    let state = runtime_state(settings, override_state);
    let main = server_config(settings, state);
    if (main.unsupported)
        return { unsupported: main.unsupported };

    let result = {
        state,
        servers: [ bootstrap_config(settings, state), main ],
        inbounds: [],
        rules: [],
        sniff_inbounds: []
    };

    if (length(state.main_servers) > 1 || length(state.bootstrap_servers) > 1)
        add_active_health_inbound(result);

    if (length(state.main_servers) > 1)
        for (let i = 0; i < length(state.main_servers); i++)
            add_health_candidate(result, "main", i, state.main_servers[i]);

    if (length(state.bootstrap_servers) > 1)
        for (let i = 0; i < length(state.bootstrap_servers); i++)
            add_health_candidate(result, "bootstrap", i, state.bootstrap_servers[i]);

    return result;
}

function default_domain_resolver(settings) {
    return bool_option(settings, "dns_detour_enabled", false)
        ? runtime_constants.BOOTSTRAP_DNS_SERVER_TAG
        : runtime_constants.DNS_SERVER_TAG;
}

return {
    DNS_FAILOVER_STATE_FILE,
    DNS_HEALTH_ADDRESS,
    active_values,
    arrays_equal,
    bootstrap_config,
    config,
    default_domain_resolver,
    detour_tag,
    excluded_https_config,
    excluded_tls_config,
    failover_enabled,
    health_port,
    normalize_state,
    runtime_state,
    server_config,
    server_from_options,
    with_certificate_name,
    server_list,
    state_matches,
    state_template
};
