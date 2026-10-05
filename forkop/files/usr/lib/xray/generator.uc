#!/usr/bin/env ucode

let fs = require("fs");
let uci_core = require("core.uci");
let connections = require("config.connections");
let parser = require("subscription.parser");
let runtime_subscription = require("singbox.subscription");
let runtime_url = require("core.url");
let xray_constants = require("xray.constants");
let xray_outbound = require("xray.outbound");
let xray_servers = require("xray.servers");
let xray_geodata = require("xray.geodata");
let engine = require("core.engine");
let hostresolve = require("core.hostresolve");
let sb_constants = require("singbox.constants");
let converted_lists_cache = {};

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

function option(section, key, fallback) {
    let value = section[key];
    if (value == null || value == "")
        return fallback;
    return as_string(value);
}

function bool_option(section, key, fallback) {
    let value = section[key];
    if (value == null)
        return fallback ? true : false;
    value = as_string(value);
    return value == "1" || value == "true" || value == "yes" || value == "on";
}

function generate_fail(reason) {
    warn(as_string(reason), "\n");
    exit(1);
}

function ensure_dir(path) {
    path = as_string(path);
    if (path == "" || path == "/" || path == ".")
        return true;
    if (fs.stat(path) != null)
        return true;
    system("mkdir -p '" + replace(path, /'/g, "'\\''") + "' >/dev/null 2>&1");
    return fs.stat(path) != null;
}

function write_json_file(path, value) {
    let tmp = as_string(path) + ".tmp";
    if (!fs.writefile(tmp, sprintf("%J\n", value)))
        return false;
    return fs.rename(tmp, path);
}

function parse_json_text(value) {
    try {
        return json(as_string(value));
    }
    catch (e) {
        return null;
    }
}

function unique_tag(base, taken) {
    base = as_string(base);
    if (base == "")
        base = "proxy";
    if (!taken[base])
        return base;
    for (let i = 1; i < 100000; i++) {
        let candidate = base + "-" + i;
        if (!taken[candidate])
            return candidate;
    }
    return base + "-overflow";
}

function is_leaf_ir(outbound) {
    outbound = object_or_empty(outbound);
    let kind = as_string(outbound.type || "");
    if (kind == "selector" || kind == "urltest" || kind == "dns" || kind == "block" || kind == "direct")
        return false;
    return xray_outbound.supported_ir(outbound);
}

function settings_section() {
    if (!uci_core.available())
        return {};
    return object_or_empty(uci_core.get_all("forkop", "settings"));
}

function xray_log_level() {
    let level = lc(option(settings_section(), "log_level", "warn"));
    if (level == "debug" || level == "trace")
        return "debug";
    if (level == "info")
        return "info";
    if (level == "error" || level == "fatal" || level == "panic")
        return "error";
    if (level == "none")
        return "none";
    return "warning";
}

function output_network_interface() {
    let settings = settings_section();
    if (!bool_option(settings, "enable_output_network_interface", false))
        return "";
    return trim(option(settings, "output_network_interface", ""));
}

function global_freedom_fragment_spec() {
    let settings = settings_section();
    if (!bool_option(settings, "xray_freedom_fragment", false))
        return null;
    return {
        enabled: true,
        packets: option(settings, "xray_freedom_fragment_packets", "tlshello"),
        length: option(settings, "xray_freedom_fragment_length", "100-200"),
        interval: option(settings, "xray_freedom_fragment_interval", "10-20"),
        max_split: option(settings, "xray_freedom_fragment_max_split", "100-200"),
        noise: bool_option(settings, "xray_freedom_fragment_noise", false),
        noise_type: option(settings, "xray_freedom_fragment_noise_type", "rand"),
        noise_rand: option(settings, "xray_freedom_fragment_noise_rand", "10-20"),
        noise_packet: option(settings, "xray_freedom_fragment_noise_packet", ""),
        noise_delay: option(settings, "xray_freedom_fragment_noise_delay", "10-16")
    };
}

function section_finalmask_spec(section) {
    if (!bool_option(section, "xray_finalmask", false))
        return null;
    return {
        enabled: true,
        packets: option(section, "xray_finalmask_packets", "tlshello"),
        length: option(section, "xray_finalmask_length", "100-200"),
        interval: option(section, "xray_finalmask_interval", "10-20"),
        max_split: option(section, "xray_finalmask_max_split", "100-200"),
        noise: bool_option(section, "xray_finalmask_noise", false),
        noise_type: option(section, "xray_finalmask_noise_type", "rand"),
        noise_rand: option(section, "xray_finalmask_noise_rand", "10-20"),
        noise_rand_range: option(section, "xray_finalmask_noise_rand_range", "0-255"),
        noise_packet: option(section, "xray_finalmask_noise_packet", ""),
        noise_delay: option(section, "xray_finalmask_noise_delay", "10-16")
    };
}

function freedom_outbound() {
    let outbound = {
        protocol: "freedom",
        tag: xray_constants.FREEDOM_TAG,
        streamSettings: { sockopt: xray_outbound.sockopt() }
    };
    return xray_outbound.apply_freedom_fragment(outbound, global_freedom_fragment_spec());
}

function blackhole_outbound() {
    return {
        protocol: "blackhole",
        tag: xray_constants.BLACKHOLE_TAG
    };
}

function socks_inbound(tag, port) {
    return {
        tag: as_string(tag),
        listen: xray_constants.XRAY_SOCKS_LISTEN,
        port: int(port, 10),
        protocol: "socks",
        settings: {
            udp: true,
            auth: "noauth",
            ip: xray_constants.XRAY_SOCKS_LISTEN
        },
        sniffing: {
            enabled: true,
            destOverride: [ "http", "tls", "quic" ],
            routeOnly: true
        }
    };
}

function prepare_share_link(link) {
    link = trim(link);
    if (link == "")
        return "";
    if (lc(substr(link, 0, 8)) == "vmess://")
        return link;
    let decoded = trim(runtime_url.decode(link));
    return decoded != "" ? decoded : link;
}

function share_link_scheme(link) {
    let marker = index(as_string(link), "://");
    return marker > 0 ? lc(substr(link, 0, marker)) : "unknown";
}

function section_mux_spec(section) {
    if (!bool_option(section, "xray_mux_enabled", false))
        return { enabled: false };
    let concurrency = int(option(section, "xray_mux_concurrency", "8"), 10);
    if (concurrency == null || concurrency < 1)
        concurrency = 8;
    if (concurrency > 128)
        concurrency = 128;
    let udp443 = lc(trim(option(section, "xray_mux_udp443", "reject")));
    if (udp443 != "allow" && udp443 != "skip")
        udp443 = "reject";
    return {
        enabled: true,
        concurrency: concurrency,
        xudp: bool_option(section, "xray_mux_xudp", true),
        udp443: udp443
    };
}

function add_converted(config, taken, ir, tag_base, display_names, display_name, mux_spec) {
    let tag = unique_tag(tag_base, taken);
    let converted = xray_outbound.convert_ir(ir, tag);
    if (converted == null)
        return "";
    xray_outbound.apply_mux(converted, mux_spec);
    taken[tag] = true;
    push(config.outbounds, converted);
    if (type(display_names) == "object") {
        let name = trim(as_string(display_name || ""));
        if (name == "")
            name = trim(as_string(ir.tag || ir.remark || ""));
        display_names[tag] = name != "" ? name : tag;
    }
    return tag;
}

function add_manual_links(config, taken, section, tags, display_names) {
    let section_name = as_string(section[".name"]);
    let links = connections.connection_urls(section);
    for (let i = 0; i < length(links); i++) {
        let raw = prepare_share_link(links[i]);
        let ir = parser.parse_share_link(raw);
        if (type(ir) != "object")
            ir = parser.parse_share_link(trim(as_string(links[i])));
        if (type(ir) != "object") {
            warn("xray: skipped invalid share-link (", share_link_scheme(raw), ") in section '", section_name, "'\n");
            continue;
        }
        if (lc(as_string(ir.type || "")) == "hysteria2" && type(ir.obfs) == "object" && as_string(object_or_empty(ir.obfs).type || "") != "" && as_string(ir.obfs.type) != "none")
            warn("xray: Hysteria2 '" + as_string(ir.tag || "") + "' in section '" + section_name + "' uses " + as_string(ir.obfs.type) + " via FinalMask\n");
        let tag_base = as_string(ir.tag || (section_name + "-" + (i + 1)));
        let tag = add_converted(config, taken, ir, tag_base, display_names, ir.tag || ir.remark, section_mux_spec(section));
        if (tag != "")
            push(tags, tag);
        else
            warn("xray: share-link (", as_string(ir.type || share_link_scheme(raw)), ") in section '", section_name, "' could not be converted to Xray 26 outbound\n");
    }
}

function add_json_outbounds(config, taken, section, tags, display_names) {
    let section_name = as_string(section[".name"]);
    let items = connections.outbound_jsons(section);
    for (let i = 0; i < length(items); i++) {
        let parsed = parse_json_text(items[i]);
        if (type(parsed) != "object") {
            generate_fail("xray JSON outbound is invalid in section " + section_name);
        }
        let tag_base = as_string(parsed.tag || (section_name + "-json-" + (i + 1)));
        let tag = add_converted(config, taken, parsed, tag_base, display_names, parsed.tag, section_mux_spec(section));
        if (tag != "")
            push(tags, tag);
        else
            warn("xray: JSON outbound in section '", section_name, "' is not supported\n");
    }
}

function add_subscriptions(config, taken, section, tags, display_names) {
    let section_name = as_string(section[".name"]);
    let urls = connections.subscription_urls(section);
    for (let i = 0; i < length(urls); i++) {
        let source_section = runtime_subscription.source_id(section_name, i + 1);
        if (!runtime_subscription.source_cache_is_current(
            source_section,
            urls[i],
            connections.subscription_user_agent(section, urls[i]),
            connections.subscription_hwid(section, urls[i])
        ))
            continue;

        let outbounds = runtime_subscription.read_source_outbounds(source_section);
        let node_prefix = trim(as_string(connections.subscription_node_prefix(section, urls[i])));
        for (let outbound in outbounds) {
            if (!is_leaf_ir(outbound))
                continue;
            let display = as_string(outbound.remark || outbound.tag || "server");
            if (node_prefix != "")
                display = node_prefix + " " + display;
            let tag = add_converted(config, taken, outbound, display, display_names, display, section_mux_spec(section));
            if (tag != "")
                push(tags, tag);
        }
    }
}

function section_uses_urltest(section) {
    return length(connections.urltests(section)) > 0;
}

function urltest_probe_url(section) {
    for (let urltest_id in connections.urltests(section))
        return connections.urltest_testing_url(section, urltest_id);
    return "https://www.gstatic.com/generate_204";
}

function urltest_interval(section) {
    for (let urltest_id in connections.urltests(section))
        return connections.urltest_check_interval(section, urltest_id);
    return "3m";
}

function add_interfaces(config, taken, section, tags, display_names) {
    let section_name = as_string(section[".name"]);
    let items = connections.interfaces(section);
    for (let i = 0; i < length(items); i++) {
        let iface = trim(as_string(items[i]));
        if (iface == "")
            continue;
        let tag_base = section_name + "-iface-" + (i + 1);
        let tag = unique_tag(tag_base, taken);
        let converted = xray_outbound.convert_interface(iface, tag);
        if (converted == null)
            continue;
        xray_outbound.apply_freedom_fragment(converted, global_freedom_fragment_spec());
        taken[tag] = true;
        push(config.outbounds, converted);
        push(tags, tag);
        if (type(display_names) == "object")
            display_names[tag] = iface;
    }
}

function detour_target_name(section) {
    if (!bool_option(section, "outbound_detour_enabled", false))
        return "";
    return trim(option(section, "outbound_detour_section", ""));
}

function section_index_by_name(sections, name) {
    name = as_string(name);
    for (let i = 0; i < length(sections); i++) {
        if (as_string(sections[i][".name"]) == name)
            return i;
    }
    return -1;
}

function outbound_by_tag(config, tag) {
    tag = as_string(tag);
    for (let outbound in array_or_empty(config.outbounds)) {
        if (type(outbound) == "object" && as_string(outbound.tag || "") == tag)
            return outbound;
    }
    return null;
}

function is_chainable_leaf(outbound) {
    outbound = object_or_empty(outbound);
    let proto = lc(as_string(outbound.protocol || ""));
    if (proto == "" || proto == "freedom" || proto == "blackhole" || proto == "dns")
        return false;
    return true;
}

function detour_leaf_tags(config, tags) {
    let result = [];
    for (let tag in array_or_empty(tags)) {
        if (is_chainable_leaf(outbound_by_tag(config, tag)))
            push(result, as_string(tag));
    }
    return result;
}

function apply_detour_to_leaf_tags(config, tags, via_tag) {
    via_tag = as_string(via_tag);
    if (via_tag == "")
        return;
    for (let outbound in array_or_empty(config.outbounds)) {
        if (!is_chainable_leaf(outbound))
            continue;
        let tag = as_string(outbound.tag || "");
        for (let leaf in tags) {
            if (as_string(leaf) == tag) {
                xray_outbound.apply_dialer_proxy(outbound, via_tag);
                break;
            }
        }
    }
}

function add_via_socks(config, taken, target, port) {
    let via_tag = unique_tag("via-" + as_string(target), taken);
    let via = xray_outbound.socks_chain_outbound(via_tag, port);
    if (via == null)
        return "";
    taken[via_tag] = true;
    push(config.outbounds, via);
    return via_tag;
}

function apply_section_detour(config, taken, section, tags, xray_sections, connection_sections, cascade, deferred) {
    let target = detour_target_name(section);
    if (target == "")
        return;
    if (target == as_string(section[".name"]))
        generate_fail("xray cascade for '" + target + "' cannot point to itself");

    let leaf_tags = detour_leaf_tags(config, tags);
    if (length(leaf_tags) == 0)
        return;

    let xray_index = section_index_by_name(xray_sections, target);
    if (xray_index >= 0) {
        push(deferred, {
            tags: leaf_tags,
            target: target,
            xray_index: xray_index
        });
        return;
    }

    let conn_index = section_index_by_name(connection_sections, target);
    if (conn_index < 0)
        generate_fail("xray cascade target '" + target + "' was not found");
    let port = xray_constants.XRAY_CASCADE_PORT_BASE + conn_index;
    cascade[target] = port;
    let via_tag = add_via_socks(config, taken, target, port);
    if (via_tag == "")
        generate_fail("xray cascade target '" + target + "' has no listen port");
    apply_detour_to_leaf_tags(config, leaf_tags, via_tag);
}

function target_inbound_rule(config, inbound) {
    inbound = as_string(inbound);
    for (let rule in array_or_empty(object_or_empty(config.routing).rules)) {
        if (type(rule) != "object")
            continue;
        for (let tag in array_or_empty(rule.inboundTag)) {
            if (as_string(tag) == inbound)
                return rule;
        }
    }
    return null;
}

function resolve_deferred_xray_detours(config, taken, deferred) {
    for (let item in array_or_empty(deferred)) {
        item = object_or_empty(item);
        let target = as_string(item.target || "");
        let rule = target_inbound_rule(config, xray_constants.inbound_tag(target));
        let via_tag = "";
        if (type(rule) == "object" && as_string(rule.outboundTag || "") != "")
            via_tag = as_string(rule.outboundTag);
        else {
            let port = xray_constants.XRAY_SOCKS_PORT_BASE + int(item.xray_index || 0);
            via_tag = add_via_socks(config, taken, target, port);
        }
        if (via_tag == "")
            generate_fail("xray cascade target '" + target + "' has no usable outbound");
        apply_detour_to_leaf_tags(config, array_or_empty(item.tags), via_tag);
    }
}

function read_selected_outbounds() {
    let data = parse_json_text(fs.readfile(xray_constants.XRAY_SELECTED_FILE) || "{}");
    return type(data) == "object" ? data : {};
}

function chosen_section_outbound(section_name, tags) {
    let chosen = as_string(object_or_empty(read_selected_outbounds())[section_name] || "");
    if (chosen == "" || chosen == xray_constants.XRAY_URLTEST_TAG)
        return "";
    for (let tag in tags)
        if (tag == chosen)
            return chosen;
    return "";
}

function xray_balancer_strategy(section) {
    let raw = lc(trim(option(section, "xray_balancer_strategy", "")));
    if (raw == "off" || raw == "disabled" || raw == "none")
        return "off";
    if (raw == "roundrobin" || raw == "round_robin")
        return "roundRobin";
    if (raw == "leastping" || raw == "least_ping")
        return "leastPing";
    if (raw == "leastload" || raw == "least_load")
        return "leastLoad";
    if (raw == "random" || raw == "auto" || raw == "")
        return "random";
    return "random";
}

function xray_probe_url(section) {
    let url = trim(option(section, "xray_probe_url", ""));
    if (url != "")
        return url;
    if (section_uses_urltest(section))
        return urltest_probe_url(section);
    return "https://www.gstatic.com/generate_204";
}

function xray_probe_interval(section) {
    let interval = trim(option(section, "xray_probe_interval", ""));
    if (match(interval, /^[0-9]+(ms|s|m|h)$/) != null)
        return interval;
    if (section_uses_urltest(section))
        return urltest_interval(section);
    return "3m";
}

function xray_probe_concurrency(section) {
    if (option(section, "xray_probe_concurrency", "") == "")
        return true;
    return bool_option(section, "xray_probe_concurrency", true);
}

function parse_unit_fraction(value, fallback) {
    value = trim(as_string(value));
    if (match(value, /^[0-9]+(\.[0-9]+)?$/) == null)
        return fallback;
    let parsed = null;
    try {
        parsed = json(value);
    }
    catch (e) {
        return fallback;
    }
    if (type(parsed) != "int" && type(parsed) != "double")
        return fallback;
    if (parsed < 0)
        return 0;
    if (parsed > 1)
        return 1;
    return parsed;
}

function least_load_settings(section) {
    let expected = int(option(section, "xray_leastload_expected", "1"));
    if (expected == null || expected < 1)
        expected = 1;
    if (expected > 16)
        expected = 16;
    let max_rtt = trim(option(section, "xray_leastload_max_rtt", "1s"));
    if (match(max_rtt, /^[0-9]+(ms|s|m|h)$/) == null)
        max_rtt = "1s";
    return {
        expected: expected,
        maxRTT: max_rtt,
        tolerance: parse_unit_fraction(option(section, "xray_leastload_tolerance", "0.5"), 0.5),
        baselines: [ max_rtt ]
    };
}

function section_fallback_request(section) {
    let raw = trim(option(section, "xray_fallback_target", ""));
    let tab = index(raw, "\t");
    if (tab <= 0)
        return null;
    let other = trim(substr(raw, 0, tab));
    let server = trim(substr(raw, tab + 1));
    if (other == "" || server == "" || other == as_string(section[".name"]))
        return null;
    return { section: other, server: server };
}

function strategy_needs_observatory(strategy, fallback) {
    return strategy == "leastPing" || strategy == "leastLoad" || fallback != null;
}

function ensure_observatory(config, section, tags) {
    if (type(config.observatory) != "object")
        config.observatory = {
            subjectSelector: [],
            probeUrl: xray_probe_url(section),
            probeInterval: xray_probe_interval(section),
            enableConcurrency: xray_probe_concurrency(section)
        };
    let seen = {};
    for (let existing in array_or_empty(config.observatory.subjectSelector))
        seen[as_string(existing)] = true;
    for (let tag in tags) {
        tag = as_string(tag);
        if (tag == "" || seen[tag])
            continue;
        seen[tag] = true;
        push(config.observatory.subjectSelector, tag);
    }
}

function resolve_fallback_tag(nodes_map, request) {
    request = object_or_empty(request);
    let nodes = array_or_empty(nodes_map[as_string(request.section)]);
    let wanted = as_string(request.server);
    for (let node in nodes) {
        node = object_or_empty(node);
        if (as_string(node.tag) == wanted || as_string(node.name) == wanted)
            return as_string(node.tag);
    }
    return "";
}

function apply_balancer_fallbacks(config, nodes_map, requests) {
    for (let item in array_or_empty(requests)) {
        item = object_or_empty(item);
        let tag = resolve_fallback_tag(nodes_map, item);
        if (tag == "") {
            warn("Xray fallback server for section '" + as_string(item.owner) + "' was not found\n");
            continue;
        }
        for (let balancer in array_or_empty(object_or_empty(config.routing).balancers)) {
            if (type(balancer) != "object")
                continue;
            if (as_string(balancer.tag) != as_string(item.balancer))
                continue;
            let inside = false;
            for (let selected in array_or_empty(balancer.selector))
                if (as_string(selected) == tag)
                    inside = true;
            if (inside)
                continue;
            balancer.fallbackTag = tag;
        }
    }
}

function node_stream_security(stream) {
    let security = lc(as_string(object_or_empty(stream).security || ""));
    if (security == "none" || security == "zero" || security == "auto")
        return "";
    return security;
}

function node_stream_mask(stream) {
    let mask = object_or_empty(object_or_empty(stream).finalmask);
    for (let item in array_or_empty(mask.udp)) {
        let kind = lc(as_string(object_or_empty(item).type || ""));
        if (kind != "" && kind != "none")
            return kind;
    }
    for (let item in array_or_empty(mask.tcp)) {
        let kind = lc(as_string(object_or_empty(item).type || ""));
        if (kind != "" && kind != "none")
            return kind;
    }
    return "";
}

function add_section(config, taken, section, ports, index, xray_sections, connection_sections, cascade, deferred, nodes_map, node_seq, fallback_requests) {
    let section_name = as_string(section[".name"]);
    let tags = [];
    let display_names = {};

    add_manual_links(config, taken, section, tags, display_names);
    add_subscriptions(config, taken, section, tags, display_names);
    add_json_outbounds(config, taken, section, tags, display_names);
    add_interfaces(config, taken, section, tags, display_names);
    apply_section_detour(config, taken, section, tags, xray_sections, connection_sections, cascade, deferred);
    let mask = section_finalmask_spec(section);
    if (mask != null) {
        for (let tag in tags)
            xray_outbound.apply_tcp_finalmask(outbound_by_tag(config, tag), mask);
    }

    if (length(tags) == 0)
        generate_fail("xray section '" + section_name + "' has no usable outbounds");

    let port = xray_constants.XRAY_SOCKS_PORT_BASE + index;
    push(config.inbounds, socks_inbound(xray_constants.inbound_tag(section_name), port));
    ports[section_name] = port;

    let inbound = xray_constants.inbound_tag(section_name);
    let pinned = chosen_section_outbound(section_name, tags);
    let strategy = xray_balancer_strategy(section);
    let fallback_req = strategy == "off" ? null : section_fallback_request(section);
    let use_balancer = strategy != "off" && pinned == "" && (length(tags) > 1 || fallback_req != null);
    if (use_balancer) {
        let balancer = xray_constants.balancer_tag(section_name);
        let selector = [];
        for (let tag in tags)
            push(selector, tag);
        let balancer_cfg = {
            tag: balancer,
            selector: selector,
            strategy: { type: strategy }
        };
        if (strategy == "leastLoad")
            balancer_cfg.strategy.settings = least_load_settings(section);
        if (strategy == "leastPing" || strategy == "leastLoad")
            balancer_cfg.fallbackTag = tags[0];
        push(config.routing.balancers, balancer_cfg);
        push(config.routing.rules, {
            type: "field",
            inboundTag: [ inbound ],
            balancerTag: balancer
        });
        if (strategy_needs_observatory(strategy, fallback_req))
            ensure_observatory(config, section, tags);
        if (fallback_req != null && type(fallback_requests) == "array")
            push(fallback_requests, {
                owner: section_name,
                balancer: balancer,
                section: fallback_req.section,
                server: fallback_req.server
            });
    }
    else {
        push(config.routing.rules, {
            type: "field",
            inboundTag: [ inbound ],
            outboundTag: pinned != "" ? pinned : tags[0]
        });
    }

    let section_nodes = [];
    if (type(node_seq) != "object")
        node_seq = { next: xray_constants.XRAY_NODE_PORT_BASE };
    for (let i = 0; i < length(tags); i++) {
        let tag = as_string(tags[i]);
        let node_port = int(node_seq.next || xray_constants.XRAY_NODE_PORT_BASE);
        if (node_port < xray_constants.XRAY_NODE_PORT_BASE)
            node_port = xray_constants.XRAY_NODE_PORT_BASE;
        node_seq.next = node_port + 1;
        let node_inbound = xray_constants.node_inbound_tag(section_name, i + 1);
        push(config.inbounds, socks_inbound(node_inbound, node_port));
        push(config.routing.rules, {
            type: "field",
            inboundTag: [ node_inbound ],
            outboundTag: tag
        });
        let kind = "proxy";
        let outbound = outbound_by_tag(config, tag);
        let iface_name = "";
        if (lc(as_string(object_or_empty(outbound).protocol || "")) == "freedom") {
            kind = "iface";
            iface_name = trim(as_string(object_or_empty(object_or_empty(outbound.streamSettings).sockopt).interface || ""));
        }
        let stream = object_or_empty(object_or_empty(outbound).streamSettings);
        let network = lc(as_string(stream.network || ""));
        if (network == "raw")
            network = "tcp";
        if (network == "hysteria")
            network = "quic";
        let node_name = trim(as_string(display_names[tag] || ""));
        if (node_name == "")
            node_name = iface_name != "" ? iface_name : tag;
        push(section_nodes, {
            tag: tag,
            port: node_port,
            name: node_name,
            kind: kind,
            protocol: as_string(object_or_empty(outbound).protocol || ""),
            network: network,
            security: node_stream_security(stream),
            mask: node_stream_mask(stream)
        });
    }
    nodes_map[section_name] = section_nodes;
}

function enabled_xray_sections() {
    let result = [];
    if (!uci_core.available())
        return result;
    for (let section in uci_core.section_objects("forkop", "section")) {
        section = object_or_empty(section);
        let enabled = section.enabled == null ? "1" : as_string(section.enabled);
        if (enabled == "0")
            continue;
        if (!connections.is_connections_action(option(section, "action", "")))
            continue;
        if (connections.proxy_core(section) != "xray")
            continue;
        push(result, section);
    }
    return result;
}

function enabled_connection_sections() {
    let result = [];
    if (!uci_core.available())
        return result;
    for (let section in uci_core.section_objects("forkop", "section")) {
        section = object_or_empty(section);
        let enabled = section.enabled == null ? "1" : as_string(section.enabled);
        if (enabled == "0")
            continue;
        if (!connections.is_connections_action(option(section, "action", "")))
            continue;
        push(result, section);
    }
    return result;
}

function enabled_sections_any() {
    let result = [];
    if (!uci_core.available())
        return result;
    for (let section in uci_core.section_objects("forkop", "section")) {
        section = object_or_empty(section);
        let enabled = section.enabled == null ? "1" : as_string(section.enabled);
        if (enabled == "0")
            continue;
        push(result, section);
    }
    return result;
}

function enabled_action_index(action_name, target_section) {
    let index = 0;
    let target = option(target_section, ".name", "");
    for (let section in enabled_sections_any()) {
        if (option(section, "action", "") != action_name)
            continue;
        index++;
        if (option(section, ".name", "") == target)
            return index;
    }
    return 0;
}

function list_values(section, key) {
    let value = object_or_empty(section)[key];
    if (type(value) == "array")
        return value;
    value = trim(as_string(value));
    if (value == "")
        return [];
    let result = [];
    for (let item in split(value, /[ \t\r\n,]+/)) {
        item = trim(as_string(item));
        if (item != "")
            push(result, item);
    }
    return result;
}

function csv_values(section, key, kind) {
    let raw = "";
    try {
        raw = connections.rule_condition_csv(section, key, kind);
    }
    catch (e) {
        raw = "";
    }
    let result = [];
    for (let item in split(as_string(raw), /[, \t\r\n]+/)) {
        item = trim(as_string(item));
        if (item != "")
            push(result, item);
    }
    return result;
}

function push_unique(result, value) {
    value = trim(as_string(value));
    if (value == "")
        return;
    for (let existing in result) {
        if (as_string(existing) == value)
            return;
    }
    push(result, value);
}

function geosite_dat_present() {
    return xray_geodata.v2fly_geosite_present() || xray_geodata.allow_domains_dat_present();
}

function community_geosite(name) {
    return xray_geodata.community_ext_tag(name);
}

function section_converted_lists(section) {
    let cache_key = as_string(object_or_empty(section)[".name"] || "");
    if (cache_key != "" && type(converted_lists_cache[cache_key]) == "object")
        return converted_lists_cache[cache_key];

    let domains = [];
    let ips = [];
    let unmapped = false;
    for (let community in connections.community_lists(section)) {
        let converted = { ok: false, domains: [], ips: [] };
        try {
            converted = xray_geodata.community_matchers(community);
        }
        catch (e) {
            converted = { ok: false, domains: [], ips: [] };
        }
        if (!converted.ok)
            unmapped = true;
        else {
            for (let value in array_or_empty(converted.domains))
                push_unique(domains, value);
            for (let value in array_or_empty(converted.ips))
                push_unique(ips, value);
        }
    }
    for (let reference in connections.rule_sets(section)) {
        let converted = { ok: false, domains: [], ips: [] };
        try {
            converted = xray_geodata.ruleset_matchers(reference);
        }
        catch (e) {
            converted = { ok: false, domains: [], ips: [] };
        }
        if (!converted.ok)
            unmapped = true;
        else {
            for (let value in array_or_empty(converted.domains))
                push_unique(domains, value);
            for (let value in array_or_empty(converted.ips))
                push_unique(ips, value);
        }
    }
    for (let reference in list_values(section, "domain_ip_lists")) {
        let converted = { ok: false, domains: [], ips: [] };
        try {
            converted = xray_geodata.list_file_matchers(reference);
        }
        catch (e) {
            converted = { ok: false, domains: [], ips: [] };
        }
        if (!converted.ok)
            unmapped = true;
        else {
            for (let value in array_or_empty(converted.domains))
                push_unique(domains, value);
            for (let value in array_or_empty(converted.ips))
                push_unique(ips, value);
        }
    }
    let result = { domains, ips, unmapped };
    if (cache_key != "")
        converted_lists_cache[cache_key] = result;
    return result;
}

function section_has_unmapped_domain_list(section) {
    return section_converted_lists(section).unmapped;
}

function usable_xray_matchers(values) {
    let result = [];
    for (let value in array_or_empty(values))
        if (xray_geodata.dat_matcher_usable(value))
            push_unique(result, value);
    return result;
}

function as_xray_domain_matcher(kind, value) {
    value = trim(as_string(value));
    if (value == "")
        return "";
    if (index(value, "geosite:") == 0 || index(value, "ext:") == 0 ||
        index(value, "full:") == 0 || index(value, "domain:") == 0 ||
        index(value, "keyword:") == 0 || index(value, "regexp:") == 0)
        return value;
    if (kind == "domain")
        return "full:" + value;
    if (kind == "domain_keyword")
        return "keyword:" + value;
    if (kind == "domain_regex")
        return "regexp:" + value;
    return "domain:" + value;
}

function section_domain_matchers(section) {
    let result = [];
    for (let value in csv_values(section, "domain", "domains"))
        push_unique(result, as_xray_domain_matcher("domain", value));
    for (let value in csv_values(section, "domain_suffix", "domains"))
        push_unique(result, as_xray_domain_matcher("domain_suffix", value));
    for (let value in csv_values(section, "domain_keyword", "generic"))
        push_unique(result, as_xray_domain_matcher("domain_keyword", value));
    for (let value in csv_values(section, "domain_regex", "generic"))
        push_unique(result, as_xray_domain_matcher("domain_regex", value));

    for (let value in list_values(section, "domain"))
        push_unique(result, as_xray_domain_matcher("domain_suffix", value));
    for (let value in list_values(section, "domain_suffix_text"))
        push_unique(result, as_xray_domain_matcher("domain_suffix", value));
    for (let value in list_values(section, "domain_list"))
        push_unique(result, as_xray_domain_matcher("domain_suffix", value));
    for (let value in section_converted_lists(section).domains)
        push_unique(result, as_xray_domain_matcher("domain_suffix", value));
    return usable_xray_matchers(result);
}

function section_user_domain_hosts(section) {
    let result = [];
    for (let key in [ "domain", "domain_suffix_text", "domain_list" ]) {
        for (let blob in list_values(section, key)) {
            for (let item in split(as_string(blob), /[,; \t\r\n]+/)) {
                item = trim(replace(as_string(item), /^https?:\/\//, ""));
                let slash = index(item, "/");
                if (slash >= 0)
                    item = substr(item, 0, slash);
                if (index(item, "full:") == 0)
                    item = substr(item, 5);
                if (index(item, "domain:") == 0)
                    item = substr(item, 7);
                item = trim(item);
                if (item != "" && match(item, /^[A-Za-z0-9._-]+$/) != null)
                    push_unique(result, lc(item));
            }
        }
    }
    return result;
}

function section_ip_matchers(section) {
    let result = [];
    for (let value in csv_values(section, "ip_cidr", "subnets"))
        push_unique(result, value);
    for (let value in csv_values(section, "subnet", "subnets"))
        push_unique(result, value);
    for (let key in [ "subnet", "ip_cidr", "user_subnet" ]) {
        for (let value in list_values(section, key))
            push_unique(result, value);
        for (let value in list_values(section, key + "_text"))
            push_unique(result, value);
    }
    for (let value in section_converted_lists(section).ips)
        push_unique(result, value);
    if (engine.is_xray_primary()) {
        let hosts = section_user_domain_hosts(section);
        let resolved = hostresolve.resolve_hosts(hosts);
        for (let host in hosts) {
            let ips = resolved[host];
            if (type(ips) != "array")
                continue;
            for (let ip in ips) {
                if (match(ip, /^[0-9]+(\.[0-9]+){3}$/) != null)
                    push_unique(result, ip);
            }
        }
    }
    return usable_xray_matchers(result);
}

function tproxy_inbound_tags() {
    return [
        xray_constants.XRAY_TPROXY_TAG,
        xray_constants.XRAY_TPROXY6_TAG,
        xray_constants.XRAY_TPROXY_FAKEIP_TAG,
        xray_constants.XRAY_TPROXY_FAKEIP6_TAG
    ];
}

function tproxy_inbound(tag, listen) {
    return {
        tag: as_string(tag),
        listen: as_string(listen),
        port: xray_constants.XRAY_TPROXY_PORT,
        protocol: "dokodemo-door",
        settings: {
            network: "tcp,udp",
            followRedirect: true
        },
        streamSettings: {
            sockopt: {
                tproxy: "tproxy"
            }
        },
        sniffing: {
            enabled: true,
            destOverride: [ "fakedns", "http", "tls", "quic" ],
            metadataOnly: false,
            routeOnly: true
        }
    };
}

function tproxy_fakeip_inbound(tag, listen) {
    return {
        tag: as_string(tag),
        listen: as_string(listen),
        port: xray_constants.XRAY_TPROXY_FAKEIP_PORT,
        protocol: "dokodemo-door",
        settings: {
            network: "tcp,udp",
            followRedirect: true
        },
        streamSettings: {
            sockopt: {
                tproxy: "tproxy"
            }
        },
        sniffing: {
            enabled: true,
            destOverride: [ "fakedns", "http", "tls", "quic" ],
            metadataOnly: false,
            routeOnly: false
        }
    };
}

function dns_inbound_at(tag, listen, port) {
    return {
        tag: as_string(tag),
        listen: as_string(listen),
        port: int(port),
        protocol: "dokodemo-door",
        settings: {
            address: "1.1.1.1",
            port: 53,
            network: "tcp,udp"
        }
    };
}

function dns_inbound() {
    return dns_inbound_at(
        xray_constants.XRAY_DNS_INBOUND_TAG,
        xray_constants.XRAY_DNS_LISTEN,
        xray_constants.XRAY_DNS_PORT
    );
}

function redirect_inbound() {
    return {
        tag: xray_constants.XRAY_REDIRECT_TAG,
        listen: xray_constants.XRAY_REDIRECT_LISTEN,
        port: xray_constants.XRAY_REDIRECT_PORT,
        protocol: "dokodemo-door",
        settings: {
            network: "tcp",
            followRedirect: true
        },
        sniffing: {
            enabled: true,
            destOverride: [ "fakedns", "http", "tls", "quic" ],
            metadataOnly: false,
            routeOnly: false
        }
    };
}

function dns_outbound() {
    return {
        protocol: "dns",
        tag: xray_constants.XRAY_DNS_OUTBOUND_TAG,
        settings: {
            nonIPQuery: "drop",
            blockTypes: [64, 65]
        },
        streamSettings: { sockopt: xray_outbound.sockopt() }
    };
}

function singbox_sidecar_outbound() {
    return {
        protocol: "socks",
        tag: xray_constants.SINGBOX_SIDECAR_TAG,
        settings: {
            servers: [{
                address: xray_constants.SINGBOX_SIDECAR_LISTEN,
                port: xray_constants.SINGBOX_SIDECAR_PORT
            }]
        },
        streamSettings: {
            sockopt: xray_outbound.sockopt()
        }
    };
}

function router_traffic_section_name() {
    let settings = settings_section();
    if (!bool_option(settings, "route_router_traffic", false))
        return "";
    return option(settings, "route_router_traffic_section", "");
}

function settings_list(key, fallback) {
    let result = [];
    let value = object_or_empty(settings_section())[key];
    if (type(value) == "array") {
        for (let item in value) {
            item = trim(as_string(item));
            if (item != "")
                push(result, item);
        }
    }
    else {
        value = trim(as_string(value));
        if (value != "") {
            for (let item in split(value, /[ \t\r\n]+/)) {
                item = trim(as_string(item));
                if (item != "")
                    push(result, item);
            }
        }
    }
    if (length(result) == 0 && fallback != "")
        push(result, as_string(fallback));
    return result;
}

function xray_query_strategy() {
    let strategy = lc(option(settings_section(), "dns_strategy", "prefer_ipv4"));
    if (strategy == "ipv6_only" || strategy == "prefer_ipv6")
        return "UseIPv6";
    if (strategy == "ipv4_only" || strategy == "prefer_ipv4")
        return "UseIPv4";
    return "UseIP";
}

function xray_dial_strategy() {
    let strategy = lc(option(settings_section(), "dns_strategy", "prefer_ipv4"));
    if (strategy == "ipv6_only")
        return "UseIPv6";
    if (strategy == "ipv4_only")
        return "UseIPv4";
    if (strategy == "prefer_ipv6")
        return "UseIPv6v4";
    return "UseIPv4v6";
}

function apply_dial_strategy(config) {
    let strategy = xray_dial_strategy();
    let primary = false;
    try {
        primary = engine.is_xray_primary();
    }
    catch (e) {
        primary = false;
    }
    for (let outbound in array_or_empty(config.outbounds)) {
        let tag = as_string(outbound.tag || "");
        if (tag == xray_constants.SINGBOX_SIDECAR_TAG ||
            tag == xray_constants.XRAY_DNS_OUTBOUND_TAG ||
            tag == xray_constants.BLACKHOLE_TAG)
            continue;
        let protocol = lc(as_string(outbound.protocol || ""));
        if (protocol == "hysteria")
            continue;
        if (type(outbound.streamSettings) != "object")
            outbound.streamSettings = {};
        if (type(outbound.streamSettings.sockopt) != "object")
            outbound.streamSettings.sockopt = xray_outbound.sockopt();
        if (primary && protocol != "freedom" && protocol != "blackhole" && protocol != "dns") {
            outbound.streamSettings.sockopt.domainStrategy = "AsIs";
            continue;
        }
        if (protocol == "freedom" &&
            type(outbound.settings) == "object" &&
            as_string(outbound.settings.domainStrategy || "") != "") {
            // settings.domainStrategy is not what DialSystem reads. Without sockopt.domainStrategy
            // the router resolver answers FakeIP and the interface dials 198.18.
            let explicit = as_string(outbound.settings.domainStrategy);
            if (explicit == "UseIP")
                explicit = strategy;
            outbound.streamSettings.sockopt.domainStrategy = explicit;
            continue;
        }
        outbound.streamSettings.sockopt.domainStrategy = strategy;
        if (protocol == "freedom") {
            if (type(outbound.settings) != "object")
                outbound.settings = {};
            if (as_string(outbound.settings.domainStrategy || "") == "")
                outbound.settings.domainStrategy = strategy;
        }
    }
}

function dns_server_token(value) {
    value = trim(as_string(value));
    let hash = index(value, "#");
    if (hash > 0)
        value = trim(substr(value, 0, hash));
    let space = index(value, " ");
    if (space > 0)
        value = trim(substr(value, 0, space));
    return value;
}

function dns_certificate_token(value) {
    value = trim(as_string(value));
    let hash = index(value, "#");
    if (hash < 0)
        return "";
    return lc(trim(substr(value, hash + 1)));
}

function doh_hostname_for(value) {
    let host = lc(dns_server_token(value));
    if (host == "8.8.8.8" || host == "8.8.4.4")
        return "dns.google";
    if (host == "1.1.1.1" || host == "1.0.0.1" || host == "1.1.1.2")
        return "cloudflare-dns.com";
    if (host == "9.9.9.9" || host == "149.112.112.112")
        return "dns.quad9.net";
    if (host == "208.67.222.222" || host == "208.67.220.220")
        return "doh.opendns.com";
    if (host == "223.5.5.5" || host == "223.6.6.6")
        return "dns.alidns.com";
    if (host == "77.88.8.8" || host == "77.88.8.1")
        return "common.dot.dns.yandex.net";
    return "";
}

function dot_hostname_for(value) {
    let host = lc(dns_server_token(value));
    if (host == "8.8.8.8" || host == "8.8.4.4")
        return "dns.google";
    if (host == "1.1.1.1" || host == "1.0.0.1" || host == "1.1.1.2")
        return "one.one.one.one";
    if (host == "9.9.9.9" || host == "149.112.112.112")
        return "dns.quad9.net";
    if (host == "208.67.222.222" || host == "208.67.220.220")
        return "dns.opendns.com";
    if (host == "223.5.5.5" || host == "223.6.6.6")
        return "dns.alidns.com";
    if (host == "77.88.8.8" || host == "77.88.8.1")
        return "common.dot.dns.yandex.net";
    return "";
}

function doq_hostname_for(value) {
    let host = lc(dns_server_token(value));
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

function doh3_hostname_for(value) {
    let host = lc(dns_server_token(value));
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

// DoQ/DoH3 settings are IPs, same as DoH/DoT. Xray still needs the certificate
// name: quic+local uses that name as SNI, and dns.hosts pins it to this IP so
// the system lookup inside quic.DialAddr cannot come back as 198.18.
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

function add_dns_host(hosts, name, ip) {
    name = trim(as_string(name));
    ip = dns_server_token(ip);
    if (name == "" || ip == "" || match(ip, /^[0-9.]+$/) == null)
        return;
    let existing = hosts[name];
    if (existing == null) {
        hosts[name] = ip;
        return;
    }
    if (type(existing) == "array") {
        push_unique(existing, ip);
        return;
    }
    if (as_string(existing) != ip)
        hosts[name] = [ existing, ip ];
}

function decorate_certificate_name(value, dns_type, extra_name) {
    extra_name = lc(trim(as_string(extra_name)));
    if (extra_name == "" || dns_certificate_token(value) != "")
        return as_string(value);
    let host = dns_server_token(value);
    if (match(host, /^[0-9]+(\.[0-9]+){3}$/) == null)
        return as_string(value);
    dns_type = lc(as_string(dns_type || ""));
    let known = "";
    if (dns_type == "doq")
        known = doq_hostname_for(host);
    else if (dns_type == "doh3")
        known = doh3_hostname_for(host);
    else if (dns_type == "dot")
        known = dot_hostname_for(host);
    else if (dns_type == "doh")
        known = doh_hostname_for(host);
    else
        return as_string(value);
    if (known != "")
        return as_string(value);
    return trim(as_string(value)) + "#" + extra_name;
}

function tls_dns_name(dns_type, value) {
    let host = dns_server_token(value);
    let mapped = "";
    dns_type = lc(as_string(dns_type || ""));
    if (dns_type == "doh")
        mapped = doh_hostname_for(host);
    else if (dns_type == "dot")
        mapped = dot_hostname_for(host);
    else if (dns_type == "doq")
        mapped = doq_hostname_for(host);
    else if (dns_type == "doh3")
        mapped = doh3_hostname_for(host);
    if (mapped == "")
        mapped = dns_certificate_token(value);
    return mapped != "" ? mapped : host;
}

function xray_dns_server_address(dns_type, value) {
    let named = tls_dns_name(dns_type, value);
    value = dns_server_token(value);
    if (value == "")
        return "";
    let existing = lc(runtime_url.scheme(value));
    if (existing == "https" || existing == "https+local" || existing == "h3" ||
        existing == "quic" || existing == "quic+local" ||
        existing == "tls" || existing == "tcp" || existing == "udp")
        return value;

    let host = trim(as_string(runtime_url.host(value)));
    if (host == "")
        host = value;
    let path = as_string(runtime_url.path(value));
    let port = as_string(runtime_url.port(value));
    dns_type = lc(as_string(dns_type || "udp"));
    if (dns_type == "doh" || dns_type == "doh3") {
        if (named != "")
            host = named;
        if (path == "" || path == "/")
            path = "/dns-query";
        return "https://" + host + path;
    }
    if (dns_type == "dot") {
        if (named != "")
            host = named;
        if (port == "")
            port = "853";
        return "tls://" + host + ":" + port;
    }
    if (dns_type == "doq") {
        if (named == "")
            named = host;
        if (port == "")
            port = "853";
        // Plain quic:// is not a DNS client. Xray only dials DoQ for quic+local://
        // and uses the URL host as SNI, so the certificate name has to stay here.
        return "quic+local://" + named + ":" + port;
    }
    return host;
}

function dns_action_tag(section_name) {
    return "dns-action-" + as_string(section_name);
}

function section_first_dns_server(section) {
    let values = list_values(section, "dns_server");
    if (length(values) > 0)
        return trim(as_string(values[0]));
    return option(section, "dns_server", "");
}

function collect_dns_action_servers(sections) {
    let servers = [];
    for (let section in array_or_empty(sections)) {
        if (option(section, "action", "") != "dns")
            continue;
        let domains = section_domain_matchers(section);
        if (length(domains) == 0)
            continue;
        let dns_type = option(section, "dns_type", "udp");
        let server_value = decorate_certificate_name(
            section_first_dns_server(section),
            dns_type,
            option(section, "dns_server_name", "")
        );
        let address = xray_dns_server_address(dns_type, server_value);
        if (address == "")
            continue;
        push(servers, {
            address: address,
            tag: dns_action_tag(option(section, ".name", "")),
            domains: domains,
            skipFallback: true,
            timeoutMs: 2000
        });
    }
    return servers;
}

function fake_dns_domain_usable(value) {
    value = trim(as_string(value));
    if (value == "")
        return false;
    return xray_geodata.dat_matcher_usable(value);
}

function fake_dns_alias_matcher(value) {
    value = trim(as_string(value));
    if (index(value, "domain:") == 0)
        return substr(value, 7);
    if (index(value, "full:") == 0)
        return substr(value, 5);
    return "";
}

function collect_byedpi_real_dns_domains(sections) {
    let domains = [];
    for (let section in array_or_empty(sections)) {
        if (option(section, "action", "") != "byedpi")
            continue;
        for (let value in section_domain_matchers(section)) {
            if (fake_dns_domain_usable(value))
                push_unique(domains, value);
        }
    }
    return domains;
}

function collect_fake_dns_domains(sections) {
    let domains = [];
    let unmapped = false;
    let claimed = {};
    push_unique(domains, "full:fakeip.podkop.fyi");
    push_unique(domains, "full:ip.podkop.fyi");
    push_unique(domains, "full:use-application-dns.net");
    for (let section in array_or_empty(sections)) {
        let claim_action = option(section, "action", "");
        if (claim_action != "dns" && claim_action != "byedpi")
            continue;
        for (let value in section_domain_matchers(section)) {
            value = trim(as_string(value));
            if (value != "")
                claimed[value] = true;
        }
    }
    for (let section in array_or_empty(sections)) {
        let action = option(section, "action", "");
        if (action == "dns" || action == "bypass")
            continue;
        if (action != "block" && !connections.is_connections_action(action))
            continue;
        if (section_has_unmapped_domain_list(section))
            unmapped = true;
        for (let value in section_domain_matchers(section)) {
            if (claimed[value])
                continue;
            if (fake_dns_domain_usable(value))
                push_unique(domains, value);
        }
    }
    return { domains, unmapped };
}

function push_interface_dial_dns(servers, domains, dns_type) {
    if (length(domains) == 0)
        return;
    let pinned = false;
    let settings_cert = option(settings_section(), "dns_certificate_name", "");
    let dial_type = option(settings_section(), "dns_type", "udp");
    for (let value in settings_list("dns_server", "8.8.8.8")) {
        value = decorate_certificate_name(value, dial_type, settings_cert);
        let address = xray_dns_server_address(dns_type, value);
        if (address == "")
            continue;
        push(servers, {
            address: address,
            tag: xray_constants.XRAY_DNS_REMOTE_TAG,
            domains: domains,
            skipFallback: true,
            disableCache: true,
            serveStale: false,
            timeoutMs: 2000
        });
        pinned = true;
        break;
    }
    if (!pinned)
        push(servers, {
            address: "8.8.8.8",
            tag: xray_constants.XRAY_DNS_REMOTE_TAG,
            domains: domains,
            skipFallback: true,
            disableCache: true,
            serveStale: false,
            timeoutMs: 2000
        });
}

function dns_cache_ttl() {
    let value = trim(option(settings_section(), "dns_rewrite_ttl", "60"));
    if (match(value, /^[0-9]+$/) == null)
        return 60;
    let ttl = int(value, 10);
    if (ttl == null || ttl < 0)
        return 60;
    if (ttl > 86400)
        return 86400;
    return ttl;
}

function dns_host_has_ip(hosts, name) {
    let existing = hosts[name];
    if (existing == null)
        return false;
    if (type(existing) == "array")
        return length(existing) > 0;
    return match(as_string(existing), /^[0-9]+(\.[0-9]+){3}$/) != null;
}

function remember_unpinned_dns_name(hosts, lookup_names, name) {
    name = lc(trim(as_string(name)));
    if (name == "" || match(name, /^[0-9.]+$/) != null || index(name, ":") >= 0)
        return;
    if (!dns_host_has_ip(hosts, name))
        lookup_names[name] = true;
}

function pin_custom_dns_hosts(hosts, lookup_names) {
    let pending = [];
    for (let name in lookup_names) {
        name = lc(trim(as_string(name)));
        if (name == "" || dns_host_has_ip(hosts, name))
            continue;
        let pinned = dns_pinned_ip(name);
        if (pinned != "") {
            add_dns_host(hosts, name, pinned);
            continue;
        }
        push(pending, name);
    }
    if (length(pending) == 0)
        return;
    let found = hostresolve.resolve_hosts(pending);
    for (let name in pending) {
        let ips = found[name];
        if (type(ips) != "array")
            continue;
        for (let ip in ips) {
            if (match(as_string(ip), /^[0-9]+(\.[0-9]+){3}$/) != null)
                add_dns_host(hosts, name, ip);
        }
    }
}

function primary_dns_config(sections) {
    let fake = collect_fake_dns_domains(sections);
    let dns_type = option(settings_section(), "dns_type", "udp");
    let servers = [];
    for (let server in collect_dns_action_servers(sections))
        push(servers, server);
    let byedpi_domains = collect_byedpi_real_dns_domains(sections);
    if (length(byedpi_domains) > 0) {
        let pinned = false;
        let settings_cert = option(settings_section(), "dns_certificate_name", "");
        for (let value in settings_list("dns_server", "8.8.8.8")) {
            value = decorate_certificate_name(value, dns_type, settings_cert);
            let address = xray_dns_server_address(dns_type, value);
            if (address == "")
                continue;
            push(servers, {
                address: address,
                tag: xray_constants.XRAY_DNS_REMOTE_TAG,
                domains: byedpi_domains,
                skipFallback: true,
                timeoutMs: 2000
            });
            pinned = true;
            break;
        }
        if (!pinned)
            push(servers, {
                address: "8.8.8.8",
                tag: xray_constants.XRAY_DNS_REMOTE_TAG,
                domains: byedpi_domains,
                skipFallback: true,
                timeoutMs: 2000
            });
    }
    let fake_server = {
        address: "fakedns",
        skipFallback: true,
        disableCache: true,
        serveStale: false
    };
    if (length(fake.domains) > 0)
        fake_server.domains = fake.domains;
    push(servers, fake_server);
    // Freedom dials with FakeEnable off, so FakeDNS is skipped. disableFallbackIfMatch
    // would then return nothing. A second match on the real resolver supplies the IP
    // that an interface outbound sends out. disableCache keeps that IP away from clients.
    push_interface_dial_dns(servers, fake.domains, dns_type);

    let hosts = {
        "use-application-dns.net": "127.0.0.1",
        "mask.icloud.com": "127.0.0.1",
        "mask-h2.icloud.com": "127.0.0.1"
    };
    let resolver_hosts = [];
    let lookup_names = {};
    let settings_cert = option(settings_section(), "dns_certificate_name", "");
    for (let value in settings_list("dns_server", "8.8.8.8")) {
        value = decorate_certificate_name(value, dns_type, settings_cert);
        let address = xray_dns_server_address(dns_type, value);
        if (address == "")
            continue;
        push(servers, {
            address: address,
            tag: xray_constants.XRAY_DNS_REMOTE_TAG,
            timeoutMs: 2000
        });
        let mapped = "";
        if (lc(dns_type) == "dot")
            mapped = dot_hostname_for(value);
        else if (lc(dns_type) == "doq")
            mapped = doq_hostname_for(value);
        else if (lc(dns_type) == "doh3")
            mapped = doh3_hostname_for(value);
        else
            mapped = doh_hostname_for(value);
        if (mapped != "") {
            push_unique(resolver_hosts, "full:" + mapped);
            add_dns_host(hosts, mapped, value);
            add_dns_host(hosts, mapped, dns_pinned_ip(mapped));
        }
        let scheme_host = trim(as_string(runtime_url.host(address)));
        if (scheme_host != "" && mapped != scheme_host &&
            match(scheme_host, /^[0-9.]+$/) == null && match(scheme_host, /:/) == null) {
            push_unique(resolver_hosts, "full:" + scheme_host);
            add_dns_host(hosts, scheme_host, value);
            add_dns_host(hosts, scheme_host, dns_pinned_ip(scheme_host));
        }
        remember_unpinned_dns_name(hosts, lookup_names, mapped);
        remember_unpinned_dns_name(hosts, lookup_names, scheme_host);
    }
    for (let section in array_or_empty(sections)) {
        if (option(section, "action", "") != "dns")
            continue;
        let section_type = option(section, "dns_type", "udp");
        let section_server = decorate_certificate_name(
            section_first_dns_server(section),
            section_type,
            option(section, "dns_server_name", "")
        );
        let section_address = xray_dns_server_address(section_type, section_server);
        let section_name = trim(as_string(runtime_url.host(section_address)));
        if (section_name != "" && match(section_name, /^[0-9.]+$/) == null && index(section_name, ":") < 0) {
            push_unique(resolver_hosts, "full:" + section_name);
            add_dns_host(hosts, section_name, dns_server_token(section_server));
            add_dns_host(hosts, section_name, dns_pinned_ip(section_name));
            remember_unpinned_dns_name(hosts, lookup_names, section_name);
        }
    }
    pin_custom_dns_hosts(hosts, lookup_names);
    if (length(servers) == 1)
        push(servers, { address: "8.8.8.8", tag: xray_constants.XRAY_DNS_REMOTE_TAG });

    for (let value in settings_list("bootstrap_dns_server", "77.88.8.8")) {
        let host = dns_server_token(value);
        if (host == "")
            continue;
        let entry = {
            address: host,
            tag: xray_constants.XRAY_DNS_BOOTSTRAP_TAG,
            skipFallback: true
        };
        if (length(resolver_hosts) > 0)
            entry.domains = resolver_hosts;
        push(servers, entry);
    }

    return {
        hosts,
        servers,
        queryStrategy: xray_query_strategy(),
        disableCache: false,
        disableFallbackIfMatch: true,
        enableParallelQuery: true,
        serveStale: true,
        serveExpiredTTL: dns_cache_ttl(),
        timeoutMs: 2000,
        fakedns: [
            { ipPool: xray_constants.FAKEIP_INET4_RANGE, poolSize: 65535 },
            { ipPool: xray_constants.FAKEIP_INET6_RANGE, poolSize: 65535 }
        ]
    };
}

function apply_primary_plane(config, taken) {
    push(config.inbounds, tproxy_inbound(xray_constants.XRAY_TPROXY_TAG, "0.0.0.0"));
    push(config.inbounds, tproxy_inbound(xray_constants.XRAY_TPROXY6_TAG, "::"));
    push(config.inbounds, tproxy_fakeip_inbound(xray_constants.XRAY_TPROXY_FAKEIP_TAG, "0.0.0.0"));
    push(config.inbounds, tproxy_fakeip_inbound(xray_constants.XRAY_TPROXY_FAKEIP6_TAG, "::"));
    push(config.inbounds, dns_inbound());
    push(config.inbounds, dns_inbound_at(
        xray_constants.XRAY_DNS_REDIR_TAG, "0.0.0.0", xray_constants.XRAY_DNS_REDIR_PORT
    ));
    push(config.inbounds, dns_inbound_at(
        xray_constants.XRAY_DNS_REDIR6_TAG, "::", xray_constants.XRAY_DNS_REDIR_PORT
    ));
    if (router_traffic_section_name() != "")
        push(config.inbounds, redirect_inbound());
    push(config.outbounds, dns_outbound());
    taken[xray_constants.XRAY_DNS_OUTBOUND_TAG] = true;

    config.dns = primary_dns_config(enabled_sections_any());

    push(config.routing.rules, {
        type: "field",
        inboundTag: [
            xray_constants.XRAY_DNS_INBOUND_TAG,
            xray_constants.XRAY_DNS_REDIR_TAG,
            xray_constants.XRAY_DNS_REDIR6_TAG
        ],
        outboundTag: xray_constants.XRAY_DNS_OUTBOUND_TAG
    });

    if (engine.need_singbox_sidecar()) {
        push(config.outbounds, singbox_sidecar_outbound());
        taken[xray_constants.SINGBOX_SIDECAR_TAG] = true;
    }
}

function section_socks_route_target(config, section_name) {
    let rule = target_inbound_rule(config, xray_constants.inbound_tag(section_name));
    if (type(rule) != "object")
        return null;
    let balancer = as_string(rule.balancerTag || "");
    if (balancer != "")
        return { balancerTag: balancer };
    let outbound = as_string(rule.outboundTag || "");
    if (outbound != "")
        return { outboundTag: outbound };
    return null;
}

function push_tproxy_rule(config, target, extra) {
    let rule = {
        type: "field",
        inboundTag: tproxy_inbound_tags()
    };
    if (target.balancerTag)
        rule.balancerTag = target.balancerTag;
    else
        rule.outboundTag = target.outboundTag;
    extra = object_or_empty(extra);
    for (let key in extra)
        rule[key] = extra[key];
    push(config.routing.rules, rule);
}

function plane_fallback_tag() {
    if (engine.need_singbox_sidecar())
        return xray_constants.SINGBOX_SIDECAR_TAG;
    return xray_constants.FREEDOM_TAG;
}

function section_tproxy_target(config, section) {
    let name = option(section, ".name", "");
    if (name == "")
        return null;
    if (connections.proxy_core(section) == "xray")
        return section_socks_route_target(config, name);
    return { outboundTag: xray_constants.SINGBOX_SIDECAR_TAG };
}

function section_policy_tproxy_target(section) {
    let action = option(section, "action", "");
    let name = option(section, ".name", "");
    if (action == "bypass")
        return { outboundTag: xray_constants.FREEDOM_TAG };
    if (action == "block")
        return { outboundTag: xray_constants.BLACKHOLE_TAG };
    if (action == "byedpi" || action == "zapret" || action == "zapret2")
        return { outboundTag: xray_constants.outbound_tag(name) };
    return null;
}

function apply_section_tproxy_matchers(config, section, target) {
    if (target == null)
        return;
    let domains = section_domain_matchers(section);
    let ips = section_ip_matchers(section);
    if (length(domains) > 0)
        push_tproxy_rule(config, target, { domain: domains });
    if (length(ips) > 0)
        push_tproxy_rule(config, target, { ip: ips });
}

function apply_section_tproxy_sources(config, section, target) {
    if (target == null)
        return;
    let sources = list_values(section, "fully_routed_ips");
    if (length(sources) > 0)
        push_tproxy_rule(config, target, { source: sources });
}

function tproxy_pin_inbound(tag, listen, port) {
    let inbound = tproxy_inbound(tag, listen);
    inbound.port = int(port);
    return inbound;
}

function apply_section_resolved_pins(config) {
    if (!engine.is_xray_primary())
        return;
    for (let spec in xray_constants.section_pin_specs()) {
        spec = object_or_empty(spec);
        let name = as_string(spec.name || "");
        if (name == "")
            continue;
        let section = null;
        for (let item in enabled_sections_any()) {
            if (option(item, ".name", "") == name) {
                section = item;
                break;
            }
        }
        if (section == null)
            continue;
        let target = section_policy_tproxy_target(section);
        if (target == null)
            target = section_tproxy_target(config, section);
        if (target == null)
            continue;
        let port = int(spec.port || 0);
        if (port <= 0)
            continue;
        push(config.inbounds, tproxy_pin_inbound(xray_constants.section_pin_tag(name), "0.0.0.0", port));
        push(config.inbounds, tproxy_pin_inbound(xray_constants.section_pin6_tag(name), "::", port));
        let rule = {
            type: "field",
            inboundTag: [
                xray_constants.section_pin_tag(name),
                xray_constants.section_pin6_tag(name)
            ]
        };
        if (target.balancerTag)
            rule.balancerTag = target.balancerTag;
        else
            rule.outboundTag = target.outboundTag;
        push(config.routing.rules, rule);
    }
}

function apply_primary_tproxy_routes(config, xray_sections) {
    apply_section_resolved_pins(config);
    for (let section in enabled_sections_any())
        apply_section_tproxy_matchers(config, section, section_policy_tproxy_target(section));

    let sections = enabled_connection_sections();
    if (length(sections) == 0)
        sections = array_or_empty(xray_sections);
    for (let section in sections) {
        let name = option(section, ".name", "");
        if (name == "")
            continue;
        apply_section_tproxy_matchers(config, section, section_tproxy_target(config, section));
    }

    push(config.routing.rules, {
        type: "field",
        inboundTag: tproxy_inbound_tags(),
        ip: [ xray_constants.FAKEIP_INET4_RANGE, xray_constants.FAKEIP_INET6_RANGE ],
        outboundTag: xray_constants.BLACKHOLE_TAG
    });

    for (let section in enabled_sections_any())
        apply_section_tproxy_sources(config, section, section_policy_tproxy_target(section));
    for (let section in sections) {
        let name = option(section, ".name", "");
        if (name == "")
            continue;
        apply_section_tproxy_sources(config, section, section_tproxy_target(config, section));
    }
    push(config.routing.rules, {
        type: "field",
        inboundTag: tproxy_inbound_tags(),
        domain: [ "full:fakeip.podkop.fyi", "full:use-application-dns.net" ],
        outboundTag: xray_constants.FREEDOM_TAG
    });

    push(config.routing.rules, {
        type: "field",
        inboundTag: tproxy_inbound_tags(),
        outboundTag: plane_fallback_tag()
    });
}

function prepend_routing_rule(config, rule) {
    let old = array_or_empty(object_or_empty(config.routing).rules);
    if (type(config.routing) != "object")
        config.routing = { rules: [] };
    config.routing.rules = [];
    push(config.routing.rules, rule);
    for (let existing in old)
        push(config.routing.rules, existing);
}

function dns_proxy_target(config) {
    let settings = settings_section();
    if (!bool_option(settings, "dns_detour_enabled", false))
        return { outboundTag: xray_constants.FREEDOM_TAG };
    let name = option(settings, "dns_detour_section", "");
    if (name == "")
        return { outboundTag: xray_constants.FREEDOM_TAG };
    let target = section_socks_route_target(config, name);
    if (target != null)
        return target;
    return { outboundTag: plane_fallback_tag() };
}

function apply_router_traffic_route(config) {
    let name = router_traffic_section_name();
    if (name == "")
        return;
    let rule = {
        type: "field",
        inboundTag: [ xray_constants.XRAY_REDIRECT_TAG ]
    };
    let target = section_socks_route_target(config, name);
    if (target == null)
        target = { outboundTag: plane_fallback_tag() };
    if (target.balancerTag)
        rule.balancerTag = target.balancerTag;
    else
        rule.outboundTag = as_string(target.outboundTag || plane_fallback_tag());
    prepend_routing_rule(config, rule);
}

function apply_dns_client_routes(config) {
    let bootstrap_rule = {
        type: "field",
        inboundTag: [ xray_constants.XRAY_DNS_BOOTSTRAP_TAG ],
        outboundTag: xray_constants.FREEDOM_TAG
    };
    let remote_rule = {
        type: "field",
        inboundTag: [ xray_constants.XRAY_DNS_REMOTE_TAG ]
    };
    let target = dns_proxy_target(config);
    if (target.balancerTag)
        remote_rule.balancerTag = target.balancerTag;
    else
        remote_rule.outboundTag = as_string(target.outboundTag || xray_constants.FREEDOM_TAG);
    prepend_routing_rule(config, remote_rule);
    prepend_routing_rule(config, bootstrap_rule);
    for (let section in enabled_sections_any()) {
        if (option(section, "action", "") != "dns")
            continue;
        let tag = dns_action_tag(option(section, ".name", ""));
        let rule = {
            type: "field",
            inboundTag: [ tag ],
            outboundTag: xray_constants.FREEDOM_TAG
        };
        if (bool_option(section, "dns_detour_enabled", false)) {
            let detour = option(section, "dns_detour_section", "");
            let target = detour != "" ? section_socks_route_target(config, detour) : null;
            if (target != null && target.balancerTag)
                rule.balancerTag = target.balancerTag;
            else if (target != null && as_string(target.outboundTag || "") != "")
                rule.outboundTag = target.outboundTag;
        }
        prepend_routing_rule(config, rule);
    }
}

function apply_stats_api(config) {
    config.stats = {};
    config.api = {
        tag: xray_constants.XRAY_API_TAG,
        listen: "127.0.0.1:" + as_string(xray_constants.XRAY_API_PORT),
        services: [ "HandlerService", "LoggerService", "StatsService", "RoutingService" ]
    };
    if (type(config.policy) != "object")
        config.policy = {};
    config.policy.system = {
        statsInboundUplink: true,
        statsInboundDownlink: true,
        statsOutboundUplink: true,
        statsOutboundDownlink: true
    };
}

function empty_config() {
    return {
        log: { loglevel: xray_log_level(), access: xray_constants.XRAY_ACCESS_LOG },
        inbounds: [],
        outbounds: [ freedom_outbound(), blackhole_outbound() ],
        routing: {
            domainStrategy: "AsIs",
            rules: [],
            balancers: []
        }
    };
}

function sanitize_matcher_list(values) {
    return usable_xray_matchers(values);
}

function sanitize_routing_rule(rule) {
    if (type(rule) != "object")
        return rule;
    let had_domain = type(rule.domain) == "array";
    let had_ip = type(rule.ip) == "array";
    if (had_domain) {
        rule.domain = sanitize_matcher_list(rule.domain);
        if (length(rule.domain) == 0)
            delete rule.domain;
    }
    if (had_ip) {
        rule.ip = sanitize_matcher_list(rule.ip);
        if (length(rule.ip) == 0)
            delete rule.ip;
    }
    if ((had_domain || had_ip) && rule.domain == null && rule.ip == null)
        return null;
    return rule;
}

function sanitize_generated_config(config) {
    if (type(config) != "object")
        return;
    if (type(config.routing) == "object" && type(config.routing.rules) == "array") {
        let rules = [];
        for (let rule in config.routing.rules) {
            let next = sanitize_routing_rule(rule);
            if (next != null)
                push(rules, next);
        }
        config.routing.rules = rules;
    }
    if (type(config.dns) != "object" || type(config.dns.servers) != "array")
        return;
    for (let server in config.dns.servers) {
        if (type(server) != "object" || type(server.domains) != "array")
            continue;
        server.domains = sanitize_matcher_list(server.domains);
        if (length(server.domains) == 0)
            delete server.domains;
    }
}

function add_byedpi_outbound(config, taken, section) {
    let name = option(section, ".name", "");
    let index = enabled_action_index("byedpi", section);
    if (name == "" || index <= 0)
        return;
    let tag = xray_constants.outbound_tag(name);
    let port = int(sb_constants.BYEDPI_PORT_BASE) + index - 1;
    push(config.outbounds, {
        tag: tag,
        protocol: "socks",
        settings: {
            address: sb_constants.BYEDPI_LISTEN_ADDRESS,
            port: port
        },
        streamSettings: {
            sockopt: xray_outbound.sockopt()
        }
    });
    taken[tag] = true;
}

function add_zapret_outbound(config, taken, section, action_name) {
    let name = option(section, ".name", "");
    let index = enabled_action_index(action_name, section);
    if (name == "" || index <= 0)
        return;
    let tag = xray_constants.outbound_tag(name);
    let base = action_name == "zapret2"
        ? int(sb_constants.ZAPRET2_ROUTE_MARK_BASE)
        : int(sb_constants.ZAPRET_ROUTE_MARK_BASE);
    push(config.outbounds, {
        tag: tag,
        protocol: "freedom",
        settings: {
            domainStrategy: "UseIP"
        },
        streamSettings: {
            sockopt: {
                mark: base + index
            }
        }
    });
    taken[tag] = true;
}

function add_native_policy_outbounds(config, taken) {
    for (let section in enabled_sections_any()) {
        let action = option(section, "action", "");
        if (action == "byedpi")
            add_byedpi_outbound(config, taken, section);
        else if (action == "zapret" || action == "zapret2")
            add_zapret_outbound(config, taken, section, action);
    }
}

function outbound_is_local_socks(outbound) {
    outbound = object_or_empty(outbound);
    if (lc(as_string(outbound.protocol || "")) != "socks")
        return false;
    let address = lc(trim(as_string(object_or_empty(outbound.settings).address || "")));
    return address == "127.0.0.1" || address == "::1" || address == "localhost";
}

function outbound_mark_value(outbound) {
    return int(object_or_empty(object_or_empty(object_or_empty(outbound).streamSettings).sockopt).mark || 0);
}

function outbound_is_provider_direct(outbound) {
    if (lc(as_string(object_or_empty(outbound).protocol || "")) != "freedom")
        return false;
    let mark = outbound_mark_value(outbound);
    if (mark <= 0)
        return false;
    let zapret = int(sb_constants.ZAPRET_ROUTE_MARK_BASE);
    let zapret2 = int(sb_constants.ZAPRET2_ROUTE_MARK_BASE);
    return (mark >= zapret && mark < zapret + 256) || (mark >= zapret2 && mark < zapret2 + 256);
}

function apply_output_interface(config) {
    let iface = output_network_interface();
    if (iface == "")
        return;
    for (let outbound in array_or_empty(config.outbounds)) {
        if (type(outbound) != "object")
            continue;
        if (lc(as_string(outbound.protocol || "")) == "blackhole")
            continue;
        if (outbound_is_local_socks(outbound) || outbound_is_provider_direct(outbound))
            continue;
        if (type(outbound.streamSettings) != "object")
            outbound.streamSettings = {};
        if (type(outbound.streamSettings.sockopt) != "object")
            outbound.streamSettings.sockopt = xray_outbound.sockopt();
        if (trim(as_string(outbound.streamSettings.sockopt.interface || "")) != "")
            continue;
        outbound.streamSettings.sockopt.interface = iface;
    }
}

function apply_bittorrent_bypass(config) {
    if (!bool_option(settings_section(), "exclude_bittorrent", false))
        return;
    prepend_routing_rule(config, {
        type: "field",
        protocol: [ "bittorrent" ],
        outboundTag: xray_constants.FREEDOM_TAG
    });
}

function enabled_server_sections() {
    let result = [];
    if (!uci_core.available())
        return result;
    for (let section in uci_core.section_objects("forkop", "server")) {
        section = object_or_empty(section);
        if (!bool_option(section, "enabled", true))
            continue;
        push(result, section);
    }
    return result;
}

function inbound_tags_of(rule) {
    let value = object_or_empty(rule).inboundTag;
    if (type(value) == "array")
        return value;
    if (value == null || as_string(value) == "")
        return [];
    return [ as_string(value) ];
}

function rule_targets_tproxy(rule) {
    let wanted = {};
    for (let tag in tproxy_inbound_tags())
        wanted[as_string(tag)] = true;
    for (let tag in inbound_tags_of(rule))
        if (wanted[as_string(tag)])
            return true;
    return false;
}

function clone_json(value) {
    try {
        return json(sprintf("%J", value));
    }
    catch (e) {
        return null;
    }
}

function apply_server_target_rule(config, tag, target) {
    let rule = {
        type: "field",
        inboundTag: [ as_string(tag) ]
    };
    target = object_or_empty(target);
    if (as_string(target.balancerTag || "") != "")
        rule.balancerTag = target.balancerTag;
    else
        rule.outboundTag = as_string(target.outboundTag || xray_constants.FREEDOM_TAG);
    push(config.routing.rules, rule);
}

function server_section_target(config, section_name) {
    section_name = as_string(section_name);
    if (section_name == "")
        return null;
    for (let section in enabled_sections_any()) {
        if (option(section, ".name", "") != section_name)
            continue;
        let action = option(section, "action", "");
        if (action == "bypass" || action == "block")
            return null;
        let target = section_policy_tproxy_target(section);
        if (target == null)
            target = section_tproxy_target(config, section);
        return target;
    }
    return null;
}

function apply_xray_server_route(config, section, tag) {
    let mode = option(section, "routing_mode", "rules");
    let name = option(section, ".name", "");
    if (mode == "direct") {
        apply_server_target_rule(config, tag, { outboundTag: xray_constants.FREEDOM_TAG });
        return;
    }
    if (mode == "section") {
        let target = server_section_target(config, option(section, "routing_section", ""));
        if (target == null) {
            warn("Xray server '" + name + "' has no usable routing section; sending it direct\n");
            apply_server_target_rule(config, tag, { outboundTag: xray_constants.FREEDOM_TAG });
            return;
        }
        apply_server_target_rule(config, tag, target);
        return;
    }
    let cloned = [];
    for (let rule in array_or_empty(config.routing.rules)) {
        if (type(rule) != "object" || as_string(rule.type || "") != "field")
            continue;
        if (!rule_targets_tproxy(rule))
            continue;
        if (rule.source != null)
            continue;
        let copy = clone_json(rule);
        if (type(copy) != "object")
            continue;
        copy.inboundTag = [ as_string(tag) ];
        push(cloned, copy);
    }
    for (let rule in cloned)
        push(config.routing.rules, rule);
    if (length(cloned) == 0)
        apply_server_target_rule(config, tag, { outboundTag: plane_fallback_tag() });
}

function listen_port_taken(config, port) {
    port = int(port);
    if (port <= 0)
        return true;
    if (port == int(xray_constants.XRAY_API_PORT))
        return true;
    for (let inbound in array_or_empty(config.inbounds)) {
        if (type(inbound) != "object")
            continue;
        if (int(inbound.port || 0) == port)
            return true;
    }
    return false;
}

function apply_xray_servers(config) {
    if (!engine.is_xray_primary())
        return;
    for (let section in enabled_server_sections()) {
        let name = option(section, ".name", "");
        if (name == "")
            continue;
        let protocol = option(section, "protocol", "vless");
        if (!xray_servers.supported(protocol)) {
            warn("Xray server '" + name + "' protocol " + protocol + " is not supported on Xray; skipped\n");
            continue;
        }
        let tag = sb_constants.server_inbound_tag(name);
        let inbound = xray_servers.build_inbound(section, tag);
        if (type(inbound) != "object") {
            warn("Xray server '" + name + "' is incomplete; skipped\n");
            continue;
        }
        if (listen_port_taken(config, inbound.port)) {
            warn("Xray server '" + name + "' port " + inbound.port + " is already in use; skipped\n");
            continue;
        }
        push(config.inbounds, inbound);
        apply_xray_server_route(config, section, tag);
    }
}

function generate_config(output_path, ports_path) {
    output_path = as_string(output_path || xray_constants.XRAY_CONFIG);
    ports_path = as_string(ports_path || xray_constants.XRAY_PORTS_FILE);

    converted_lists_cache = {};
    let sections = enabled_xray_sections();
    let connection_sections = enabled_connection_sections();
    let config = empty_config();
    let ports = {};
    let nodes_map = {};
    let node_seq = { next: xray_constants.XRAY_NODE_PORT_BASE };
    let cascade = {};
    let deferred = [];
    let fallback_requests = [];
    let taken = {};
    taken[xray_constants.FREEDOM_TAG] = true;
    taken[xray_constants.BLACKHOLE_TAG] = true;

    if (engine.is_xray_primary())
        apply_primary_plane(config, taken);

    for (let i = 0; i < length(sections); i++)
        add_section(config, taken, sections[i], ports, i, sections, connection_sections, cascade, deferred, nodes_map, node_seq, fallback_requests);
    resolve_deferred_xray_detours(config, taken, deferred);
    apply_balancer_fallbacks(config, nodes_map, fallback_requests);

    if (engine.is_xray_primary())
        add_native_policy_outbounds(config, taken);
    if (engine.is_xray_primary())
        apply_dns_client_routes(config);
    if (engine.is_xray_primary())
        apply_router_traffic_route(config);
    if (engine.is_xray_primary())
        apply_primary_tproxy_routes(config, sections);
    if (engine.is_xray_primary())
        apply_xray_servers(config);
    if (engine.is_xray_primary())
        apply_bittorrent_bypass(config);
    if (engine.is_xray_primary())
        apply_dial_strategy(config);
    if (engine.is_xray_primary())
        apply_output_interface(config);
    if (engine.is_xray_primary())
        apply_stats_api(config);

    sanitize_generated_config(config);

    if (type(config.observatory) == "object" && length(array_or_empty(config.observatory.subjectSelector)) == 0)
        delete config.observatory;
    if (length(array_or_empty(config.routing.balancers)) == 0)
        delete config.routing.balancers;

    let parent = "";
    let slash = rindex(output_path, "/");
    if (slash > 0)
        parent = substr(output_path, 0, slash);
    if (parent != "" && parent != "." && !ensure_dir(parent))
        generate_fail("failed to create xray config directory");
    if (!write_json_file(output_path, config))
        generate_fail("failed to write xray config");

    slash = rindex(ports_path, "/");
    parent = slash > 0 ? substr(ports_path, 0, slash) : "";
    if (parent != "" && parent != "." && !ensure_dir(parent))
        generate_fail("failed to create xray ports directory");
    if (!write_json_file(ports_path, ports))
        generate_fail("failed to write xray ports map");

    let cascade_path = xray_constants.XRAY_CASCADE_FILE;
    slash = rindex(cascade_path, "/");
    parent = slash > 0 ? substr(cascade_path, 0, slash) : "";
    if (parent != "" && parent != "." && !ensure_dir(parent))
        generate_fail("failed to create xray cascade directory");
    if (!write_json_file(cascade_path, cascade))
        generate_fail("failed to write xray cascade map");

    let nodes_path = xray_constants.XRAY_NODES_FILE;
    slash = rindex(nodes_path, "/");
    parent = slash > 0 ? substr(nodes_path, 0, slash) : "";
    if (parent != "" && parent != "." && !ensure_dir(parent))
        generate_fail("failed to create xray nodes directory");
    if (!write_json_file(nodes_path, nodes_map))
        generate_fail("failed to write xray nodes map");

    print(sprintf("%J", { sections: length(sections), ports: ports, cascade: cascade, nodes: nodes_map }), "\n");
}

function section_object_by_name(name) {
    name = as_string(name);
    if (!uci_core.available())
        return null;
    for (let section in uci_core.section_objects("forkop", "section")) {
        section = object_or_empty(section);
        if (as_string(section[".name"]) == name)
            return section;
    }
    return null;
}

function collect_download_tags(config, taken, section) {
    let tags = [];
    let display_names = {};
    add_manual_links(config, taken, section, tags, display_names);
    add_subscriptions(config, taken, section, tags, display_names);
    add_json_outbounds(config, taken, section, tags, display_names);
    add_interfaces(config, taken, section, tags, display_names);
    let mask = section_finalmask_spec(section);
    if (mask != null) {
        for (let tag in tags)
            xray_outbound.apply_tcp_finalmask(outbound_by_tag(config, tag), mask);
    }
    return tags;
}

function xray_detour_chain(section) {
    let chain = [];
    let seen = {};
    seen[as_string(section[".name"])] = true;
    let current = section;
    while (true) {
        let target_name = detour_target_name(current);
        if (target_name == "" || seen[target_name])
            break;
        seen[target_name] = true;
        let target = section_object_by_name(target_name);
        if (target == null)
            break;
        if (!connections.is_connections_action(option(target, "action", "")))
            break;
        if (connections.proxy_core(target) != "xray")
            break;
        push(chain, target);
        current = target;
    }
    return chain;
}

function download_bootstrap_addresses() {
    let servers = [];
    for (let value in settings_list("bootstrap_dns_server", "77.88.8.8")) {
        let host = dns_server_token(value);
        if (host == "")
            continue;
        push(servers, {
            address: host,
            skipFallback: true
        });
    }
    if (length(servers) == 0)
        push(servers, { address: "77.88.8.8", skipFallback: true });
    return servers;
}

function strip_download_marks(config) {
    for (let outbound in array_or_empty(config.outbounds)) {
        if (type(outbound) != "object")
            continue;
        let stream = outbound.streamSettings;
        if (type(stream) == "object" && type(stream.sockopt) == "object")
            delete stream.sockopt.mark;
    }
}

function apply_download_domain_strategy(config) {
    for (let outbound in array_or_empty(config.outbounds)) {
        if (type(outbound) != "object")
            continue;
        let protocol = lc(as_string(outbound.protocol || ""));
        if (protocol == "" || protocol == "freedom" || protocol == "blackhole" ||
            protocol == "dns" || protocol == "hysteria")
            continue;
        if (type(outbound.streamSettings) != "object")
            outbound.streamSettings = {};
        if (type(outbound.streamSettings.sockopt) != "object")
            outbound.streamSettings.sockopt = {};
        outbound.streamSettings.sockopt.domainStrategy = "UseIPv4";
    }
}

function download_tag_host(config, tag) {
    let outbound = outbound_by_tag(config, tag);
    if (type(outbound) != "object" || type(outbound.settings) != "object")
        return "";
    return trim(as_string(outbound.settings.address || ""));
}

function download_host_is_name(host) {
    if (host == "")
        return false;
    if (match(host, /^[0-9.]+$/) != null)
        return false;
    if (match(host, /:/) != null)
        return false;
    return true;
}

// A dead name (NXDOMAIN) must not be the dial target. If every name fails
// DNS, keep the original set: the lookup itself may be blocked.
function prefer_resolvable_download_tags(config, tags) {
    let host_by_tag = {};
    let hosts = [];
    for (let tag in tags) {
        let host = download_tag_host(config, tag);
        host_by_tag[as_string(tag)] = host;
        if (download_host_is_name(host))
            push(hosts, host);
    }
    let resolved = {};
    if (length(hosts) > 0) {
        try {
            resolved = object_or_empty(hostresolve.resolve_hosts(hosts));
        }
        catch (e) {
            resolved = {};
        }
    }
    if (type(config.dns) != "object")
        config.dns = {};
    if (length(resolved) > 0) {
        if (type(config.dns.hosts) != "object")
            config.dns.hosts = {};
        for (let host in resolved) {
            let ips = resolved[host];
            if (type(ips) == "array" && length(ips) > 0)
                config.dns.hosts[host] = ips[0];
        }
    }
    let keep = [];
    let dropped = [];
    for (let tag in tags) {
        let host = host_by_tag[as_string(tag)];
        if (!download_host_is_name(host) || type(resolved[lc(host)]) == "array")
            push(keep, tag);
        else
            push(dropped, tag);
    }
    if (length(keep) == 0 || length(dropped) == 0)
        return tags;
    let drop = {};
    for (let tag in dropped)
        drop[as_string(tag)] = true;
    let kept_outbounds = [];
    for (let outbound in array_or_empty(config.outbounds)) {
        let tag = as_string(object_or_empty(outbound).tag);
        if (drop[tag])
            continue;
        push(kept_outbounds, outbound);
    }
    config.outbounds = kept_outbounds;
    warn("xray download socks: skipped unresolved server, using the rest\n");
    return keep;
}

// One local SOCKS inbound. No TPROXY, DNS listen, nft, or packet marks.
function generate_download_socks(section_name, output_path, listen_port) {
    section_name = trim(as_string(section_name));
    output_path = as_string(output_path);
    let port = int(listen_port, 10);
    if (section_name == "" || output_path == "")
        generate_fail("download socks arguments are incomplete");
    if (port == null || port < 1 || port > 65535)
        generate_fail("download socks port is invalid");

    let section = section_object_by_name(section_name);
    if (section == null)
        generate_fail("download socks section was not found: " + section_name);
    if (!connections.is_connections_action(option(section, "action", "")))
        generate_fail("download socks section is not a connection: " + section_name);
    if (connections.proxy_core(section) != "xray")
        generate_fail("download socks section core is not xray: " + section_name);

    let config = {
        log: { loglevel: xray_log_level() },
        dns: {
            servers: download_bootstrap_addresses(),
            queryStrategy: "UseIPv4",
            disableCache: true
        },
        inbounds: [ socks_inbound("forkop-download", port) ],
        outbounds: [ freedom_outbound() ],
        routing: {
            domainStrategy: "AsIs",
            rules: [],
            balancers: []
        }
    };
    let taken = {};
    taken[xray_constants.FREEDOM_TAG] = true;

    let tag_map = {};
    let chain = xray_detour_chain(section);
    for (let i = length(chain) - 1; i >= 0; i--) {
        let item = chain[i];
        tag_map[as_string(item[".name"])] = collect_download_tags(config, taken, item);
    }
    let tags = collect_download_tags(config, taken, section);
    if (length(tags) == 0)
        generate_fail("xray download section '" + section_name + "' has no usable outbounds");
    tags = prefer_resolvable_download_tags(config, tags);

    let target_name = detour_target_name(section);
    let target_tags = array_or_empty(tag_map[target_name]);
    if (target_name != "" && length(target_tags) > 0)
        apply_detour_to_leaf_tags(config, detour_leaf_tags(config, tags), target_tags[0]);
    else if (target_name != "")
        warn("xray download socks: detour '", target_name, "' is not in this process; dialing directly\n");

    let inbound = "forkop-download";
    let pinned = chosen_section_outbound(section_name, tags);
    let strategy = xray_balancer_strategy(section);
    let use_balancer = strategy != "off" && pinned == "" && length(tags) > 1;
    if (use_balancer) {
        let balancer = xray_constants.balancer_tag(section_name);
        let selector = [];
        for (let tag in tags)
            push(selector, tag);
        let balancer_cfg = {
            tag: balancer,
            selector: selector,
            strategy: { type: strategy }
        };
        if (strategy == "leastLoad")
            balancer_cfg.strategy.settings = least_load_settings(section);
        if (strategy == "leastPing" || strategy == "leastLoad")
            balancer_cfg.fallbackTag = tags[0];
        push(config.routing.balancers, balancer_cfg);
        push(config.routing.rules, {
            type: "field",
            inboundTag: [ inbound ],
            balancerTag: balancer
        });
        if (strategy_needs_observatory(strategy, null))
            ensure_observatory(config, section, tags);
    }
    else {
        push(config.routing.rules, {
            type: "field",
            inboundTag: [ inbound ],
            outboundTag: pinned != "" ? pinned : tags[0]
        });
    }

    strip_download_marks(config);
    apply_download_domain_strategy(config);
    if (length(array_or_empty(config.routing.balancers)) == 0)
        delete config.routing.balancers;
    if (type(config.observatory) == "object" && length(array_or_empty(config.observatory.subjectSelector)) == 0)
        delete config.observatory;

    let slash = rindex(output_path, "/");
    let parent = slash > 0 ? substr(output_path, 0, slash) : "";
    if (parent != "" && !ensure_dir(parent))
        generate_fail("failed to create download socks directory");
    if (!write_json_file(output_path, config))
        generate_fail("failed to write download socks config");
}

let mode = ARGV[0] || "";
if (mode == "generate-config")
    generate_config(ARGV[1] || "", ARGV[2] || "");
else if (mode == "download-socks")
    generate_download_socks(ARGV[1] || "", ARGV[2] || "", ARGV[3] || "");
else if (mode == "enabled-sections")
    print(sprintf("%J", enabled_xray_sections()), "\n");
else {
    warn("Usage: xray/generator.uc <generate-config|enabled-sections> ...\n");
    exit(1);
}
