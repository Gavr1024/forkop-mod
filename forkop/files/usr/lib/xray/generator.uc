#!/usr/bin/env ucode

let fs = require("fs");
let uci_core = require("core.uci");
let connections = require("config.connections");
let parser = require("subscription.parser");
let runtime_subscription = require("singbox.subscription");
let runtime_url = require("core.url");
let xray_constants = require("xray.constants");
let xray_outbound = require("xray.outbound");
let xray_geodata = require("xray.geodata");
let engine = require("core.engine");
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

function global_freedom_fragment_spec() {
    let settings = settings_section();
    if (!bool_option(settings, "xray_freedom_fragment", false))
        return null;
    return {
        enabled: true,
        length: option(settings, "xray_freedom_fragment_length", "100-200"),
        interval: option(settings, "xray_freedom_fragment_interval", "10-20")
    };
}

function section_finalmask_spec(section) {
    if (!bool_option(section, "xray_finalmask", false))
        return null;
    return {
        enabled: true,
        length: option(section, "xray_finalmask_length", "100-200"),
        interval: option(section, "xray_finalmask_interval", "10-20")
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

function add_converted(config, taken, ir, tag_base, display_names, display_name) {
    let tag = unique_tag(tag_base, taken);
    let converted = xray_outbound.convert_ir(ir, tag);
    if (converted == null)
        return "";
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
        let tag = add_converted(config, taken, ir, tag_base, display_names, ir.tag || ir.remark);
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
        let tag = add_converted(config, taken, parsed, tag_base, display_names, parsed.tag);
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
            let tag = add_converted(config, taken, outbound, display, display_names, display);
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

function add_section(config, taken, section, ports, index, xray_sections, connection_sections, cascade, deferred, nodes_map, node_seq) {
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
    if (length(tags) > 1 && pinned == "") {
        let balancer = xray_constants.balancer_tag(section_name);
        let selector = [];
        for (let tag in tags)
            push(selector, tag);
        let balancer_cfg = {
            tag: balancer,
            selector: selector
        };
        if (section_uses_urltest(section)) {
            balancer_cfg.fallbackTag = tags[0];
            balancer_cfg.strategy = { type: "leastPing" };
        }
        else
            balancer_cfg.strategy = { type: "random" };
        push(config.routing.balancers, balancer_cfg);
        push(config.routing.rules, {
            type: "field",
            inboundTag: [ inbound ],
            balancerTag: balancer
        });
        if (section_uses_urltest(section)) {
            if (type(config.observatory) != "object")
                config.observatory = {
                    subjectSelector: [],
                    probeUrl: urltest_probe_url(section),
                    probeInterval: urltest_interval(section),
                    enableConcurrency: true
                };
            for (let tag in tags)
                push(config.observatory.subjectSelector, tag);
        }
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
            network: network
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

function resolve_host_ips(host) {
    host = trim(as_string(host));
    if (host == "" || match(host, /^[A-Za-z0-9._-]+$/) == null)
        return [];
    let ips = [];
    for (let dns_server in [ "8.8.8.8", "77.88.8.8" ]) {
        let pipe = fs.popen("timeout 3 nslookup '" + replace(host, /'/g, "") + "' " + dns_server + " 2>/dev/null", "r");
        if (!pipe)
            continue;
        let raw = pipe.read("all");
        pipe.close();
        for (let line in split(as_string(raw), /\n/)) {
            line = trim(replace(line, /\r/g, ""));
            let matched = match(line, /^Address[ \t]*[0-9]*:[ \t]*([^ \t]+)/);
            let addr = matched ? trim(as_string(matched[1])) : line;
            let v4port = match(addr, /^([0-9]+(\.[0-9]+){3}):[0-9]+$/);
            if (v4port)
                addr = as_string(v4port[1]);
            if (match(addr, /^[0-9]+(\.[0-9]+){3}$/) == null)
                continue;
            if (addr == dns_server || index(addr, "198.18.") == 0 || index(addr, "198.19.") == 0)
                continue;
            push_unique(ips, addr);
        }
        if (length(ips) > 0)
            return ips;
    }
    return ips;
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
        for (let host in section_user_domain_hosts(section)) {
            for (let ip in resolve_host_ips(host))
                push_unique(result, ip);
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
            destOverride: [ "fakedns" ],
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
            as_string(outbound.settings.domainStrategy || "") != "")
            continue;
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
    let space = index(value, " ");
    if (space > 0)
        value = trim(substr(value, 0, space));
    return value;
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

function xray_dns_server_address(dns_type, value) {
    value = dns_server_token(value);
    if (value == "")
        return "";
    let existing = lc(runtime_url.scheme(value));
    if (existing == "https" || existing == "h3" || existing == "quic" ||
        existing == "tls" || existing == "tcp" || existing == "udp")
        return value;

    let host = trim(as_string(runtime_url.host(value)));
    if (host == "")
        host = value;
    let path = as_string(runtime_url.path(value));
    let port = as_string(runtime_url.port(value));
    dns_type = lc(as_string(dns_type || "udp"));
    if (dns_type == "doh") {
        let mapped = doh_hostname_for(host);
        if (mapped != "")
            host = mapped;
        if (path == "" || path == "/")
            path = "/dns-query";
        return "https://" + host + path;
    }
    if (dns_type == "dot") {
        let mapped = dot_hostname_for(host);
        if (mapped != "")
            host = mapped;
        if (port == "")
            port = "853";
        return "tls://" + host + ":" + port;
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
        let address = xray_dns_server_address(dns_type, section_first_dns_server(section));
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

function section_uses_interface_outbound(section) {
    let items = [];
    try {
        items = connections.interfaces(section);
    }
    catch (e) {
        items = [];
    }
    for (let item in array_or_empty(items)) {
        if (trim(as_string(item)) != "")
            return true;
    }
    return false;
}

function collect_fake_dns_domains(sections) {
    let domains = [];
    let unmapped = false;
    let claimed = {};
    push_unique(domains, "full:fakeip.podkop.fyi");
    push_unique(domains, "full:ip.podkop.fyi");
    push_unique(domains, "full:use-application-dns.net");
    for (let section in array_or_empty(sections)) {
        if (option(section, "action", "") != "dns")
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
        if (section_uses_interface_outbound(section))
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

function primary_dns_config(sections) {
    let fake = collect_fake_dns_domains(sections);
    let dns_type = option(settings_section(), "dns_type", "udp");
    let servers = [];
    for (let server in collect_dns_action_servers(sections))
        push(servers, server);
    let fake_server = { address: "fakedns", skipFallback: true };
    if (length(fake.domains) > 0)
        fake_server.domains = fake.domains;
    push(servers, fake_server);

    let hosts = {
        "use-application-dns.net": "127.0.0.1",
        "mask.icloud.com": "127.0.0.1",
        "mask-h2.icloud.com": "127.0.0.1"
    };
    let resolver_hosts = [];
    for (let value in settings_list("dns_server", "8.8.8.8")) {
        let address = xray_dns_server_address(dns_type, value);
        if (address == "")
            continue;
        push(servers, {
            address: address,
            tag: xray_constants.XRAY_DNS_REMOTE_TAG,
            timeoutMs: 2000
        });
        if (lc(dns_type) == "dot") {
            let doh_address = xray_dns_server_address("doh", value);
            if (doh_address != "" && doh_address != address)
                push(servers, {
                    address: doh_address,
                    tag: xray_constants.XRAY_DNS_REMOTE_TAG,
                    timeoutMs: 2000
                });
            let doh_host = doh_hostname_for(value);
            if (doh_host != "") {
                push_unique(resolver_hosts, "full:" + doh_host);
                add_dns_host(hosts, doh_host, value);
            }
        }
        let mapped = lc(dns_type) == "dot" ? dot_hostname_for(value) : doh_hostname_for(value);
        if (mapped != "") {
            push_unique(resolver_hosts, "full:" + mapped);
            add_dns_host(hosts, mapped, value);
        }
        let scheme_host = trim(as_string(runtime_url.host(address)));
        if (scheme_host != "" && mapped != scheme_host &&
            match(scheme_host, /^[0-9.]+$/) == null && match(scheme_host, /:/) == null) {
            push_unique(resolver_hosts, "full:" + scheme_host);
            add_dns_host(hosts, scheme_host, value);
        }
    }
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
        disableFallbackIfMatch: true,
        enableParallelQuery: true,
        serveStale: true,
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

function apply_primary_tproxy_routes(config, xray_sections) {
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
        log: { loglevel: "warning", access: xray_constants.XRAY_ACCESS_LOG },
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
    let taken = {};
    taken[xray_constants.FREEDOM_TAG] = true;
    taken[xray_constants.BLACKHOLE_TAG] = true;

    if (engine.is_xray_primary())
        apply_primary_plane(config, taken);

    for (let i = 0; i < length(sections); i++)
        add_section(config, taken, sections[i], ports, i, sections, connection_sections, cascade, deferred, nodes_map, node_seq);
    resolve_deferred_xray_detours(config, taken, deferred);

    if (engine.is_xray_primary())
        add_native_policy_outbounds(config, taken);
    if (engine.is_xray_primary())
        apply_dns_client_routes(config);
    if (engine.is_xray_primary())
        apply_router_traffic_route(config);
    if (engine.is_xray_primary())
        apply_primary_tproxy_routes(config, sections);
    if (engine.is_xray_primary())
        apply_dial_strategy(config);
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

let mode = ARGV[0] || "";
if (mode == "generate-config")
    generate_config(ARGV[1] || "", ARGV[2] || "");
else if (mode == "enabled-sections")
    print(sprintf("%J", enabled_xray_sections()), "\n");
else {
    warn("Usage: xray/generator.uc <generate-config|enabled-sections> ...\n");
    exit(1);
}
