#!/usr/bin/env ucode

let fs = require("fs");
let common = require("core.common");
let uci_core = require("core.uci");
let runtime_constants = require("singbox.constants");
let runtime_country = require("singbox.country");
let runtime_dns = require("singbox.dns");
let runtime_route = require("singbox.route");
let runtime_rulesets = require("singbox.rulesets");
let runtime_servers = require("singbox.servers");
let runtime_subscription = require("singbox.subscription");
let runtime_url = require("core.url");
let runtime_urltest = require("singbox.urltest");
let source_rulesets = require("routing.rulesets");
let list_cache = require("routing.list_cache");
let rule_config = require("config.rule");
let connections = require("config.connections");
let core_ip = require("core.ip");
let hostresolve = require("core.hostresolve");
let engine = require("core.engine");
let subscription_share_link = require("subscription.share_link");
let uci = null;
let fixture_uci_data = null;
let runtime_settings_cache = null;
let runtime_ruleset_folder = runtime_constants.TMP_RULESET_FOLDER;
let runtime_supports_xhttp = true;
let runtime_sing_box_version_cache = null;
let runtime_sing_box_version_text = null;

let as_string = common.as_string;
let read_json_file = common.read_json_file;
let read_stdin = common.read_stdin;
let read_stdin_json = common.read_stdin_json;
let write_json = common.write_json;
let csv_to_json_array = common.csv_to_json_array;
let write_json_file = common.write_json_file;
let strip_internal_fields = common.strip_internal_fields;
let array_or_empty = common.array_or_empty;
let object_or_empty = common.object_or_empty;
let option = common.option;
let list_option = common.list_option;
let bool_option = common.bool_option;
let int_option = common.int_option;
let url_decode = runtime_url.decode;
let url_scheme = runtime_url.scheme;
let url_fragment = runtime_url.fragment;
let url_strip_fragment_value = runtime_url.strip_fragment;
let url_host = runtime_url.host;
let url_port = runtime_url.port;
let url_userinfo = runtime_url.userinfo;
let url_path = runtime_url.path;
let url_query_params = runtime_url.query_params;

const CONFIG_NAME = "forkop";

function parent_dir(path) {
    path = as_string(path);
    let slash = rindex(path, "/");
    return slash <= 0 ? "" : substr(path, 0, slash);
}

function ensure_dir(path) {
    path = as_string(path);
    if (path == "" || path == "/")
        return true;
    if (fs.stat(path) != null)
        return true;

    let parent = parent_dir(path);
    if (parent != "" && !ensure_dir(parent))
        return false;

    return fs.mkdir(path, 0755) || fs.stat(path) != null;
}

function ensure_parent_dir(path) {
    return ensure_dir(parent_dir(path));
}

function atomic_write_json_file(path, value) {
    let stamp = clock();
    let tmp_path = sprintf("%s.%d.%d.tmp", path, stamp[0], stamp[1]);

    if (!ensure_parent_dir(path))
        return false;
    if (!write_json_file(tmp_path, value))
        return false;
    if (!fs.rename(tmp_path, path)) {
        fs.unlink(tmp_path);
        return false;
    }
    return true;
}

function fixture_section_list(type_name) {
    let value = object_or_empty(fixture_uci_data)[type_name];
    if (type(value) == "array")
        return value;
    if (type(value) == "object")
        return [ value ];

    let plural = object_or_empty(fixture_uci_data)[type_name + "s"];
    return type(plural) == "array" ? plural : [];
}

function fixture_get_section(section_name) {
    let fixture = object_or_empty(fixture_uci_data);
    if (section_name == "settings" && type(fixture.settings) == "object")
        return fixture.settings;

    for (let type_name in [ "settings", "server", "section", "subscription_url", "section_interface", "openconnect", "openvpn", "urltest", "priority_group", "priority_level" ]) {
        for (let section in fixture_section_list(type_name)) {
            if (as_string(section[".name"]) == section_name)
                return section;
        }
    }

    return {};
}

function fixture_cursor(path) {
    fixture_uci_data = object_or_empty(read_json_file(path));
    connections.set_item_sections_from_data(fixture_uci_data);
    return {
        load: function(_config_name) {
            return true;
        },
        get_all: function(_config_name, section_name) {
            return fixture_get_section(section_name);
        },
        foreach: function(_config_name, type_name, callback) {
            for (let section in fixture_section_list(type_name))
                callback(section);
        }
    };
}

function use_fixture_cursor(path) {
    uci = fixture_cursor(path);
    runtime_settings_cache = null;
}

function runtime_uci_cursor() {
    return {
        load: function(package_name) {
            return uci_core.load(package_name);
        },
        get_all: function(package_name, section_name) {
            return uci_core.get_all(package_name, section_name);
        },
        foreach: function(package_name, type_name, callback) {
            for (let section in uci_core.section_objects(package_name, type_name))
                callback(section);
        }
    };
}

function uci_cursor() {
    if (uci == null)
        uci = runtime_uci_cursor();
    return uci;
}

function runtime_generate_unsupported(reason) {
    warn(reason, "\n");
    exit(2);
}

function valid_section_name(name) {
    return match(name, /^[A-Za-z0-9_]+$/);
}

function section_enabled(section) {
    return bool_option(section, "enabled", true);
}

function runtime_settings() {
    if (runtime_settings_cache == null)
        runtime_settings_cache = object_or_empty(uci_cursor().get_all(CONFIG_NAME, "settings"));
    return runtime_settings_cache;
}

function settings_update_interval() {
    let settings = runtime_settings();
    if (!bool_option(settings, "list_update_enabled", true))
        return "";

    let update_interval = lc(option(settings, "update_interval", "1d"));
    if (update_interval == "never" || update_interval == "0" || update_interval == "off" || update_interval == "disabled")
        return "";
    return update_interval != "" ? update_interval : "1d";
}

function remote_ruleset_update_interval() {
    let update_interval = settings_update_interval();
    return update_interval != "" ? update_interval : runtime_constants.DISABLED_UPDATE_INTERVAL;
}

function internal_flag(value) {
    return value === true || value == 1 || value == "1" || value == "true" || value == "yes";
}

function subscription_group_outbound(outbound) {
    if (type(outbound) != "object")
        return false;
    let t = as_string(outbound.type);
    return (t == "selector" || t == "urltest") && internal_flag(outbound.__forkop_allow_group);
}

function subscription_urltest_group_outbound(outbound) {
    if (type(outbound) != "object")
        return false;
    return as_string(outbound.type || "") == "urltest" && internal_flag(outbound.__forkop_allow_group);
}

function subscription_outbound_tag(outbound) {
    return type(outbound) == "object" ? as_string(outbound.tag || "") : "";
}

function subscription_visibility_refs(outbounds) {
    let refs = {
        urltest: {},
        detour: {}
    };

    for (let outbound in array_or_empty(outbounds)) {
        if (type(outbound) != "object")
            continue;

        if (subscription_urltest_group_outbound(outbound)) {
            for (let tag_name in array_or_empty(outbound.outbounds)) {
                tag_name = as_string(tag_name);
                if (tag_name != "")
                    refs.urltest[tag_name] = true;
            }
        }

        let detour = as_string(outbound.detour || "");
        if (detour != "")
            refs.detour[detour] = true;
    }

    return refs;
}

function subscription_hidden_outbound(outbound, refs, hide_urltest_group_outbounds, hide_detour_outbounds) {
    if (type(outbound) != "object")
        return false;

    let tag_name = subscription_outbound_tag(outbound);
    let urltest_refs = object_or_empty(object_or_empty(refs).urltest);
    let detour_refs = object_or_empty(object_or_empty(refs).detour);
    let hidden_by_urltest = tag_name != "" && urltest_refs[tag_name];
    let hidden_by_detour = tag_name != "" && detour_refs[tag_name];

    if (hidden_by_urltest && hide_urltest_group_outbounds !== false)
        return true;
    if (hidden_by_detour && hide_detour_outbounds !== false)
        return true;
    return internal_flag(outbound.__forkop_hidden) && !hidden_by_urltest && !hidden_by_detour;
}

function tag(base, postfix) {
    return runtime_constants.tag(base, postfix);
}

function outbound_tag(section_name) {
    return runtime_constants.outbound_tag(section_name);
}

function download_via_proxy_section_option_for_purpose(purpose) {
    purpose = as_string(purpose || "lists");
    if (purpose == "lists")
        return "download_lists_via_proxy_section";
    if (purpose == "components")
        return "download_components_via_proxy_section";
    return "";
}

function download_via_proxy_option_for_purpose(purpose) {
    purpose = as_string(purpose || "lists");
    if (purpose == "lists")
        return "download_lists_via_proxy";
    if (purpose == "components")
        return "download_components_via_proxy";
    return "";
}

function download_via_proxy_section(settings, purpose) {
    let enabled_option = download_via_proxy_option_for_purpose(purpose);
    if (enabled_option == "" || !bool_option(settings, enabled_option, false))
        return "";

    let section_option = download_via_proxy_section_option_for_purpose(purpose);
    let configured = section_option != "" ? option(settings, section_option, "") : "";
    if (configured != "")
        return configured;

    return option(settings, "download_lists_via_proxy_section", "");
}

function download_via_proxy_enabled(settings, purpose) {
    let enabled_option = download_via_proxy_option_for_purpose(purpose);
    return enabled_option != "" && bool_option(settings, enabled_option, false);
}

function download_via_proxy_any_enabled(settings, sections) {
    return download_via_proxy_enabled(settings, "lists") ||
        download_via_proxy_enabled(settings, "components") ||
        length(connections.subscription_download_targets(sections || [])) > 0;
}

function download_detour_tag(settings, purpose) {
    let section_name = download_via_proxy_section(settings, purpose);
    return section_name == "" ? "" : outbound_tag(section_name);
}

function router_traffic_section(settings) {
    if (!bool_option(settings, "route_router_traffic", false))
        return "";
    return option(settings, "route_router_traffic_section", "");
}

function read_command_output(command) {
    let proc = fs.popen(as_string(command), "r");
    if (proc == null)
        return "";
    let output = proc.read("all");
    proc.close();
    return output == null ? "" : as_string(output);
}

function parse_sing_box_core_version(text) {
    text = as_string(text);
    let m = match(text, /sing-box version[ \t]+v?([0-9]+)\.([0-9]+)/);
    if (m != null)
        return { major: int(m[1]), minor: int(m[2]) };

    m = match(text, /(^|[ \t\/])v?([0-9]+)\.([0-9]+)\.[0-9]+/);
    if (m != null)
        return { major: int(m[2]), minor: int(m[3]) };

    return null;
}

function sing_box_major_minor() {
    if (runtime_sing_box_version_cache != null)
        return runtime_sing_box_version_cache;

    let parsed = parse_sing_box_core_version(read_command_output("sing-box version"));
    if (parsed == null)
        parsed = parse_sing_box_core_version(read_command_output("cat /etc/forkop/sing-box-version 2>/dev/null"));
    if (parsed == null)
        parsed = { major: 1, minor: 13 };

    runtime_sing_box_version_cache = parsed;
    return runtime_sing_box_version_cache;
}

function sing_box_version_text() {
    if (runtime_sing_box_version_text != null)
        return runtime_sing_box_version_text;
    let text = read_command_output("sing-box version");
    if (trim(text) == "")
        text = read_command_output("cat /etc/forkop/sing-box-version 2>/dev/null");
    runtime_sing_box_version_text = text;
    return text;
}

function sing_box_is_extended() {
    return index(lc(sing_box_version_text()), "extended") >= 0;
}

function purge_incompatible_sing_box_cache() {
    let v = sing_box_major_minor();
    let cur = as_string(v.major) + "." + as_string(v.minor);
    let stamp_path = "/tmp/sing-box/forkop-core-version";
    let prev = "";
    try {
        prev = trim(as_string(fs.readfile(stamp_path)));
    }
    catch (e) {
        prev = "";
    }
    if (prev != "" && prev != cur) {
        try { fs.unlink("/tmp/sing-box/cache.db"); } catch (e) { }
        try { fs.unlink("/tmp/sing-box/cache.db-shm"); } catch (e) { }
        try { fs.unlink("/tmp/sing-box/cache.db-wal"); } catch (e) { }
    }
    try {
        fs.writefile(stamp_path, cur + "\n");
    }
    catch (e) {
    }
}

function sing_box_at_least_1_14() {
    let v = sing_box_major_minor();
    return v.major > 1 || (v.major == 1 && v.minor >= 14);
}

function sing_box_at_least_1_15() {
    let v = sing_box_major_minor();
    return v.major > 1 || (v.major == 1 && v.minor >= 15);
}

function sing_box_extended_revision() {
    let m = match(sing_box_version_text(), /extended-([0-9]+)\.([0-9]+)\.([0-9]+)/);
    if (m == null)
        return null;
    return { major: int(m[1]), minor: int(m[2]), patch: int(m[3]) };
}

function sing_box_masque_l4_supported() {
    let v = sing_box_extended_revision();
    if (v == null)
        return false;
    if (v.major != 2)
        return v.major > 2;
    if (v.minor != 7)
        return v.minor > 7;
    return v.patch >= 3;
}

const RULESET_HTTP_CLIENT_TAG = "ruleset-http";

function usable_http_client_detour(detour) {
    detour = as_string(detour);
    if (detour == "" || detour == "direct" || detour == runtime_constants.DIRECT_OUTBOUND_TAG)
        return "";
    return detour;
}

function apply_remote_ruleset_http_client(rule_set, purpose) {
    let detour = usable_http_client_detour(download_detour_tag(runtime_settings(), purpose));
    if (detour == "")
        return;
    if (sing_box_at_least_1_14())
        rule_set.http_client = { detour };
    else
        rule_set.download_detour = detour;
}

let missing_ruleset_warned = false;

function empty_ruleset_path() {
    let path = runtime_ruleset_folder + "/empty-ruleset.json";
    if (fs.stat(path) != null)
        return path;
    if (!ensure_dir(runtime_ruleset_folder))
        return "";
    if (write_json_file(path, { version: 2, rules: [] }) == null)
        return "";
    return path;
}

function register_remote_or_cached_ruleset(config, rule_set) {
    let url = as_string(rule_set.url);
    let cached = null;
    let format_value = rule_set.format;

    if (url != "")
        cached = list_cache.local_entry(url, runtime_settings());

    if (type(config.route) != "object")
        config.route = {};
    if (type(config.route.rule_set) != "array")
        config.route.rule_set = [];

    if (type(cached) == "object" && as_string(cached.path) != "") {
        if (cached.format != null && cached.format != "")
            format_value = cached.format;
        push(config.route.rule_set, {
            type: "local",
            tag: rule_set.tag,
            format: format_value,
            path: cached.path
        });
        return;
    }

    // sing-box treats a failed initial remote download as fatal (GitHub EOF
    // aborts the process before DNS/TPROXY listen). A missing cache must not
    // do that: keep the tag on an empty local set until the list updater
    // writes the real file and the next reload picks it up.
    let placeholder = empty_ruleset_path();
    if (placeholder != "") {
        if (!missing_ruleset_warned) {
            missing_ruleset_warned = true;
            warn("A community or remote list is not cached. sing-box will start without it; the next successful list download fills it in.\n");
        }
        push(config.route.rule_set, {
            type: "local",
            tag: rule_set.tag,
            format: "source",
            path: placeholder
        });
        return;
    }

    apply_remote_ruleset_http_client(rule_set, "lists");
    if (rule_set.update_interval == null)
        rule_set.update_interval = remote_ruleset_update_interval();
    push(config.route.rule_set, rule_set);
}

function apply_http_clients(config) {
    if (!sing_box_at_least_1_14())
        return;

    if (type(config.http_clients) != "array")
        config.http_clients = [];

    let found = false;
    for (let client in config.http_clients) {
        if (type(client) == "object" && as_string(client.tag) == RULESET_HTTP_CLIENT_TAG)
            found = true;
    }
    if (!found)
        push(config.http_clients, { tag: RULESET_HTTP_CLIENT_TAG });

    if (type(config.route) != "object")
        config.route = {};
    if (config.route.default_http_client == null)
        config.route.default_http_client = RULESET_HTTP_CLIENT_TAG;
}

function ruleset_tag(section_name, name, kind) {
    kind = as_string(kind);
    return kind == ""
        ? section_name + "-" + name + "-ruleset"
        : section_name + "-" + name + "-" + kind + "-ruleset";
}

function ruleset_registered(config, tag_name) {
    for (let rule_set in array_or_empty(config.route && config.route.rule_set)) {
        if (type(rule_set) == "object" && rule_set.tag == tag_name)
            return true;
    }
    return false;
}

function ensure_custom_ruleset(config, reference) {
    let tag_name;
    let kind = runtime_rulesets.kind_from_reference_hint(reference);

    if (runtime_rulesets.is_community(reference)) {
        tag_name = "builtin-" + reference + "-ruleset";
        kind = "domains";
        if (!ruleset_registered(config, tag_name)) {
            register_remote_or_cached_ruleset(config, {
                type: "remote",
                tag: tag_name,
                format: "binary",
                url: runtime_rulesets.community_url(reference)
            });
        }
        return { tag: tag_name, kind };
    }

    tag_name = "inline-custom-" + runtime_rulesets.hash12(reference) + "-ruleset";
    if (kind == "unknown")
        kind = "domains";
    if (ruleset_registered(config, tag_name))
        return { tag: tag_name, kind };

    let extension = runtime_rulesets.file_extension(reference);
    if (substr(reference, 0, 1) == "/") {
        if (extension != "srs" && extension != "json")
            runtime_generate_unsupported("local rule_set extension is not supported by sing-box config generation");
        push(config.route.rule_set, {
            type: "local",
            tag: tag_name,
            format: extension == "json" ? "source" : "binary",
            path: reference
        });
    }
    else if (substr(reference, 0, 7) == "http://" || substr(reference, 0, 8) == "https://") {
        register_remote_or_cached_ruleset(config, {
            type: "remote",
            tag: tag_name,
            format: runtime_rulesets.remote_format(reference),
            url: reference
        });
    }
    else {
        runtime_generate_unsupported("rule_set reference is not supported by sing-box config generation");
    }

    return { tag: tag_name, kind };
}

function clash_api_config(settings, service_address) {
    let controller = as_string(service_address || "");
    if (bool_option(settings, "enable_yacd", false) && bool_option(settings, "enable_yacd_wan_access", false))
        controller = "0.0.0.0";
    else if (controller == "")
        controller = "127.0.0.1";

    let result = {
        external_controller: controller + ":9090"
    };
    if (bool_option(settings, "enable_yacd", false)) {
        result.external_ui = "ui";
        let secret = option(settings, "yacd_secret_key", "");
        if (secret != "")
            result.secret = secret;
    }
    return result;
}

function cli_bool(value) {
    return value === true || value == "1" || value == "true" || value == "yes" || value == "on";
}

function tproxy_inbound_matcher() {
    if (engine.is_xray_primary())
        return [ runtime_constants.XRAY_PLANE_MIXED_INBOUND_TAG ];
    return [
        runtime_constants.TPROXY_INBOUND_TAG,
        runtime_constants.TPROXY_INBOUND6_TAG
    ];
}

function source_dns_inbound_matcher() {
    return [ runtime_constants.SOURCE_DNS_INBOUND_TAG ];
}

function base_config(settings, service_address, runtime_context) {
    purge_incompatible_sing_box_cache();
    let log_level = option(settings, "log_level", "warn");
    let rewrite_ttl = int_option(settings, "dns_rewrite_ttl", "60");
    let cache_path = option(settings, "cache_path", "/tmp/sing-box/cache.db");
    let dns_config = runtime_dns.config(settings);
    if (dns_config.unsupported)
        runtime_generate_unsupported(dns_config.unsupported);

    let dns_rules = [];
    for (let rule in dns_config.rules)
        push(dns_rules, rule);
    push(dns_rules, { action: "reject", query_type: "HTTPS" });
    push(dns_rules, { action: "reject", domain_suffix: "use-application-dns.net" });
    if (!engine.is_xray_primary()) {
        push(dns_rules, {
            action: "route",
            server: runtime_constants.FAKEIP_DNS_SERVER_TAG,
            rewrite_ttl,
            domain: [ runtime_constants.FAKEIP_TEST_DOMAIN, runtime_constants.CHECK_PROXY_IP_DOMAIN ]
        });
    }

    let dns_servers = [];
    for (let server in dns_config.servers)
        push(dns_servers, server);
    if (!engine.is_xray_primary()) {
        push(dns_servers, {
            type: "fakeip",
            tag: runtime_constants.FAKEIP_DNS_SERVER_TAG,
            inet4_range: runtime_constants.FAKEIP_INET4_RANGE,
            inet6_range: runtime_constants.FAKEIP_INET6_RANGE
        });
    }

    runtime_context = object_or_empty(runtime_context);
    let inbounds = [];
    if (!engine.is_xray_primary()) {
        push(inbounds, { type: "tproxy", tag: runtime_constants.TPROXY_INBOUND_TAG, listen: runtime_constants.TPROXY_INBOUND_ADDRESS, listen_port: runtime_constants.TPROXY_INBOUND_PORT, tcp_fast_open: true, udp_fragment: true });
        push(inbounds, { type: "tproxy", tag: runtime_constants.TPROXY_INBOUND6_TAG, listen: runtime_constants.TPROXY_INBOUND6_ADDRESS, listen_port: runtime_constants.TPROXY_INBOUND_PORT, tcp_fast_open: true, udp_fragment: true });
        push(inbounds, { type: "direct", tag: runtime_constants.DNS_INBOUND_TAG, listen: runtime_constants.DNS_INBOUND_ADDRESS, listen_port: runtime_constants.DNS_INBOUND_PORT });
        if (runtime_context.source_aware_dns)
            push(inbounds, { type: "direct", tag: runtime_constants.SOURCE_DNS_INBOUND_TAG, listen: runtime_constants.SOURCE_DNS_INBOUND_ADDRESS, listen_port: runtime_constants.SOURCE_DNS_INBOUND_PORT });
    }
    else {
        push(inbounds, {
            type: "mixed",
            tag: runtime_constants.XRAY_PLANE_MIXED_INBOUND_TAG,
            listen: runtime_constants.XRAY_PLANE_MIXED_INBOUND_ADDRESS,
            listen_port: runtime_constants.XRAY_PLANE_MIXED_INBOUND_PORT,
            tcp_fast_open: true,
            udp_fragment: true
        });
    }
    for (let inbound in dns_config.inbounds)
        push(inbounds, inbound);

    runtime_context.dns_health_inbounds = dns_config.sniff_inbounds;
    runtime_context.default_domain_resolver = runtime_dns.default_domain_resolver(settings);

    let dns = {
        servers: dns_servers,
        rules: dns_rules,
        final: runtime_constants.DNS_SERVER_TAG,
        strategy: option(settings, "dns_strategy", "prefer_ipv4")
    };
    if (!sing_box_at_least_1_14())
        dns.independent_cache = true;

    let cache_file = {
        enabled: true,
        path: cache_path,
        store_fakeip: !engine.is_xray_primary()
    };
    if (sing_box_is_extended())
        cache_file.store_masque_config = true;
    return {
        log: {
            disabled: false,
            level: log_level,
            timestamp: false
        },
        dns,
        ntp: {},
        certificate: {},
        endpoints: [],
        inbounds,
        outbounds: [
            { type: "direct", tag: runtime_constants.DIRECT_OUTBOUND_TAG },
            { type: "direct", tag: runtime_constants.BYPASS_OUTBOUND_TAG }
        ],
        route: runtime_route.config(settings, runtime_context),
        services: [],
        experimental: {
            cache_file: cache_file,
            clash_api: clash_api_config(settings, service_address)
        }
    };
}

function supported_subscription_outbound(outbound) {
    if (type(outbound) != "object")
        return false;
    let t = as_string(outbound.type);
    if (subscription_group_outbound(outbound))
        return true;
    if (t == "direct" || t == "selector" || t == "urltest" || t == "dns" || t == "block")
        return false;
    return t == "vless" || t == "vmess" || t == "trojan" || t == "shadowsocks" ||
        t == "socks" || t == "hysteria2";
}

function outbound_uses_xhttp(outbound) {
    return type(outbound) == "object" && type(outbound.transport) == "object" &&
        lc(as_string(outbound.transport.type || "")) == "xhttp";
}

function ensure_explicit_outbound_supported(outbound, source, name) {
    if (!runtime_supports_xhttp && outbound_uses_xhttp(outbound))
        runtime_generate_unsupported(as_string(source) + " '" + as_string(name) + "' uses XHTTP transport, but sing-box-extended is not installed");
}

function subscription_outbound_display_name(outbound) {
    return type(outbound) == "object"
        ? as_string(outbound.remark || outbound.tag || "unknown")
        : "unknown";
}

function add_subscription_reference(refs, value) {
    value = as_string(value);
    if (value != "")
        refs[value] = true;
}

function subscription_reference_set(outbounds) {
    let refs = {};
    for (let outbound in array_or_empty(outbounds)) {
        if (type(outbound) != "object")
            continue;
        add_subscription_reference(refs, outbound.tag);
        add_subscription_reference(refs, outbound.remark);
    }
    return refs;
}

function subscription_reference_available(reference, source_refs, retained_refs) {
    reference = as_string(reference);
    return reference == "" || !source_refs[reference] || retained_refs[reference];
}

function subscription_group_has_retained_member(outbound, retained_refs) {
    for (let reference in array_or_empty(outbound.outbounds))
        if (retained_refs[as_string(reference)])
            return true;
    return false;
}

function warn_skipped_subscription_outbound(section_name, outbound, reason) {
    warn("skipped incompatible subscription outbound for rule '", section_name, "': ",
        subscription_outbound_display_name(outbound), " (", reason, ")\n");
}

function compatible_subscription_outbounds(outbounds, section_name) {
    let source_refs = subscription_reference_set(outbounds);
    let retained = [];
    for (let outbound in array_or_empty(outbounds)) {
        if (!supported_subscription_outbound(outbound))
            continue;
        if (!runtime_supports_xhttp && outbound_uses_xhttp(outbound)) {
            warn_skipped_subscription_outbound(section_name, outbound, "XHTTP requires sing-box-extended");
            continue;
        }
        push(retained, outbound);
    }

    while (true) {
        let retained_refs = subscription_reference_set(retained);
        let next = [];
        let changed = false;
        for (let outbound in retained) {
            let detour = as_string(outbound.detour || "");
            if (!subscription_reference_available(detour, source_refs, retained_refs)) {
                warn_skipped_subscription_outbound(section_name, outbound,
                    "detour depends on unavailable outbound '" + detour + "'");
                changed = true;
                continue;
            }
            if (subscription_group_outbound(outbound) &&
                !subscription_group_has_retained_member(outbound, retained_refs)) {
                warn_skipped_subscription_outbound(section_name, outbound, "group has no compatible outbounds");
                changed = true;
                continue;
            }
            push(next, outbound);
        }
        retained = next;
        if (!changed)
            return retained;
    }
}

function copy_subscription_outbound(outbound, new_tag) {
    let copy = {};
    for (let key, value in outbound) {
        if (key != "tag" && key != "remark" && key != "share_link" &&
            key != "__forkop_hidden" && key != "__forkop_allow_group")
            copy[key] = value;
    }
    if (as_string(copy.type || "") == "hysteria2" &&
        type(copy.tls) == "object" &&
        copy.tls.utls != null) {
        let tls = {};
        for (let key, value in copy.tls) {
            if (key != "utls")
                tls[key] = value;
        }
        copy.tls = tls;
    }
    copy.tag = new_tag;
    return copy;
}

function string_array_contains(values, needle) {
    for (let value in array_or_empty(values))
        if (as_string(value) == as_string(needle))
            return true;
    return false;
}

function rewrite_subscription_outbound_references(outbounds, tag_map, source_refs) {
    for (let outbound in outbounds) {
        if (type(outbound) != "object")
            continue;

        let detour = as_string(outbound.detour || "");
        if (detour != "" && tag_map[detour])
            outbound.detour = tag_map[detour];
        else if (detour != "" && source_refs[detour])
            delete outbound.detour;

        if (type(outbound.outbounds) == "array") {
            let rewritten = [];
            for (let tag_name in outbound.outbounds) {
                tag_name = as_string(tag_name);
                if (tag_map[tag_name])
                    push(rewritten, tag_map[tag_name]);
            }
            outbound.outbounds = rewritten;

            if (as_string(outbound.type || "") == "urltest") {
                delete outbound.default;
            }
            else {
                let default_tag = as_string(outbound.default || "");
                if (default_tag != "" && tag_map[default_tag])
                    default_tag = tag_map[default_tag];
                if (default_tag == "" || !string_array_contains(rewritten, default_tag))
                    default_tag = length(rewritten) > 0 ? rewritten[0] : "";
                if (default_tag != "")
                    outbound.default = default_tag;
                else
                    delete outbound.default;
            }
        }
    }
}

function subscription_skip_summary(skipped) {
    let parts = [];
    for (let t in sort(keys(skipped)))
        push(parts, skipped[t] + "x " + t);
    return join("; ", parts);
}

function reportable_skipped_subscription_type(t) {
    return t != "direct" && t != "selector" && t != "urltest" && t != "dns" && t != "block";
}

function urltest_leaf_candidate_outbound(outbound) {
    if (type(outbound) != "object")
        return false;

    let t = lc(as_string(outbound.type || ""));
    return t != "selector" && t != "urltest" && t != "dns" && t != "block";
}

function unique_tag(base, taken) {
    base = as_string(base);
    if (base == "")
        base = "server";
    if (!taken[base])
        return base;
    for (let i = 1; i < 100000; i++) {
        let candidate = base + "-" + i;
        if (!taken[candidate])
            return candidate;
    }
    return base + "-overflow";
}

function reserved_runtime_tag_set(outbounds) {
    let result = {};
    for (let tag_name in keys(object_or_empty(runtime_constants.RESERVED_TAGS)))
        result[tag_name] = true;

    for (let outbound in array_or_empty(outbounds)) {
        if (type(outbound) != "object")
            continue;

        let tag_name = as_string(outbound.tag || "");
        if (tag_name != "")
            result[tag_name] = true;
    }
    return result;
}

function assert_unique_outbound_tags(config) {
    let seen = {};
    for (let outbound in array_or_empty(config.outbounds)) {
        if (type(outbound) != "object")
            runtime_generate_unsupported("generated sing-box outbound is not an object");

        let tag_name = as_string(outbound.tag || "");
        if (tag_name == "")
            runtime_generate_unsupported("generated sing-box outbound has an empty tag");
        if (seen[tag_name])
            runtime_generate_unsupported("generated sing-box config has duplicate outbound tag '" + tag_name + "'");
        seen[tag_name] = true;
    }
}

function add_subscription_source_with_state(config, section, source_index, source_entry, taken, selector_tags, urltest_candidate_tags, state, show_metadata, include_urltest_groups, hide_urltest_group_outbounds, hide_detour_outbounds, node_prefix) {
    let section_name = section[".name"];
    let source_section = runtime_subscription.source_id(section_name, source_index);
    if (!runtime_subscription.source_cache_is_current(
        source_section,
        source_entry,
        connections.subscription_user_agent(section, source_entry),
        connections.subscription_hwid(section, source_entry)
    ))
        return 0;

    let source_outbounds = runtime_subscription.read_source_outbounds(source_section);
    if (length(source_outbounds) == 0)
        return 0;

    let skipped = {};
    for (let outbound in source_outbounds) {
        if (supported_subscription_outbound(outbound))
            continue;
        let t = type(outbound) == "object" ? as_string(outbound.type || "missing-type") : "non-object";
        if (reportable_skipped_subscription_type(t))
            skipped[t] = (skipped[t] || 0) + 1;
    }
    let outbounds = compatible_subscription_outbounds(source_outbounds, section_name);

    if (show_metadata !== false)
        runtime_subscription.merge_source_metadata(state, section_name, source_section, source_index, source_entry);
    let visibility_refs = subscription_visibility_refs(outbounds);
    if (include_urltest_groups === false)
        hide_urltest_group_outbounds = false;
    node_prefix = trim(as_string(node_prefix));
    let prepared = [];
    let display_names = [];
    let source_links = [];
    let group_flags = [];
    let hidden_flags = [];
    let tag_map = {};
    for (let i = 0; i < length(outbounds); i++) {
        let outbound = outbounds[i];
        if (include_urltest_groups === false && subscription_urltest_group_outbound(outbound))
            continue;
        let display_name = as_string(outbound.remark || outbound.tag || ("server-" + (i + 1)));
        let base = as_string(outbound.tag || outbound.remark || ("server-" + (i + 1)));
        if (node_prefix != "") {
            display_name = node_prefix + " " + display_name;
            base = display_name;
        }
        let new_tag = unique_tag(base, taken);
        taken[new_tag] = true;
        tag_map[base] = new_tag;
        if (as_string(outbound.tag || "") != "")
            tag_map[as_string(outbound.tag)] = new_tag;
        if (as_string(outbound.remark || "") != "")
            tag_map[as_string(outbound.remark)] = new_tag;
        push(prepared, copy_subscription_outbound(outbound, new_tag));
        push(display_names, display_name);
        let source_link = as_string(outbound.share_link || "");
        if (!subscription_share_link.is_copyable_link(source_link))
            source_link = subscription_share_link.serialize_outbound_link(outbound);
        push(source_links, source_link);
        push(group_flags, subscription_group_outbound(outbound));
        push(hidden_flags, subscription_hidden_outbound(outbound, visibility_refs, hide_urltest_group_outbounds, hide_detour_outbounds));
    }

    if (length(keys(skipped)) > 0)
        warn("skipped unsupported subscription outbounds for rule '", section_name, "': ", subscription_skip_summary(skipped), "\n");

    rewrite_subscription_outbound_references(prepared, tag_map, subscription_reference_set(source_outbounds));
    let added = 0;
    for (let i = 0; i < length(prepared); i++) {
        let outbound = prepared[i];
        let is_group = group_flags[i] === true;
        if (is_group && length(array_or_empty(outbound.outbounds)) == 0) {
            warn("skipped empty subscription group for rule '", section_name, "': ", as_string(display_names[i] || outbound.tag || "unknown"), "\n");
            continue;
        }

        push(config.outbounds, outbound);
        added++;
        if (!is_group)
            push(urltest_candidate_tags, outbound.tag);
        runtime_subscription.remember_source_outbound(
            state,
            outbound.tag,
            display_names[i],
            outbound,
            source_links[i]
        );
        if (hidden_flags[i] !== true) {
            push(selector_tags, outbound.tag);
            runtime_subscription.remember_urltest_group(state, outbound.tag, display_names[i], outbound);
        }
    }
    return added;
}

function duration_to_seconds(value) {
    value = as_string(value);
    if (value == "")
        return null;
    if (match(value, /^[0-9]+$/) != null)
        return int(value, 10);

    let suffix = substr(value, length(value) - 1);
    let number = substr(value, 0, length(value) - 1);
    if (match(number, /^[0-9]+$/) == null)
        return null;

    let multiplier = null;
    if (suffix == "s")
        multiplier = 1;
    else if (suffix == "m")
        multiplier = 60;
    else if (suffix == "h")
        multiplier = 3600;
    else if (suffix == "d")
        multiplier = 86400;

    return multiplier == null ? null : int(number, 10) * multiplier;
}

function urltest_check_interval(section, urltest_id) {
    let interval = connections.urltest_check_interval(section, urltest_id);
    return interval != "" ? interval : "3m";
}

function legacy_urltest_idle_timeout(section, urltest_id) {
    if (urltest_id != "urltest")
        return "";

    let settings = connections.urltest_settings(section, urltest_id);
    if (type(settings) == "object" && as_string(settings[".type"] || "") == "urltest")
        return "";

    let interval = urltest_check_interval(section, urltest_id);
    let interval_seconds = duration_to_seconds(interval);
    let default_idle_seconds = duration_to_seconds(runtime_constants.URLTEST_DEFAULT_IDLE_TIMEOUT);
    return interval_seconds != null && interval_seconds > default_idle_seconds ? interval : "";
}

function urltest_idle_timeout(section, urltest_id) {
    let configured = connections.urltest_idle_timeout(section, urltest_id);
    return configured != "" ? configured : legacy_urltest_idle_timeout(section, urltest_id);
}

function supported_urltest_filter_mode(mode) {
    return mode == "include" || mode == "exclude" || mode == "mixed";
}

function filter_mode_uses_include(mode) {
    return mode == "include" || mode == "mixed";
}

function filter_mode_uses_exclude(mode) {
    return mode == "exclude" || mode == "mixed";
}

function configured_country_filter(mode, include_countries, exclude_countries) {
    return (filter_mode_uses_include(mode) && length(array_or_empty(include_countries)) > 0) ||
        (filter_mode_uses_exclude(mode) && length(array_or_empty(exclude_countries)) > 0);
}

function section_needs_country_is(section) {
    let dashboard_mode = connections.dashboard_filter_mode(section);
    if (connections.dashboard_detect_server_country(section) == "country_is" &&
        configured_country_filter(
            dashboard_mode,
            connections.dashboard_include_countries(section),
            connections.dashboard_exclude_countries(section)
        ))
        return true;

    for (let urltest_id in connections.urltests(section)) {
        let mode = connections.urltest_filter_mode(section, urltest_id);
        if (connections.urltest_detect_server_country(section, urltest_id) == "country_is" &&
            configured_country_filter(
                mode,
                connections.urltest_include_countries(section, urltest_id),
                connections.urltest_exclude_countries(section, urltest_id)
            ))
            return true;
    }

    for (let group_id in connections.priority_groups(section)) {
        for (let level_id in connections.priority_levels(group_id)) {
            if (connections.priority_level_direct(group_id, level_id))
                continue;
            let mode = connections.priority_level_filter_mode(group_id, level_id);
            if (connections.priority_level_detect_server_country(group_id, level_id) == "country_is" &&
                configured_country_filter(
                    mode,
                    connections.priority_level_include_countries(group_id, level_id),
                    connections.priority_level_exclude_countries(group_id, level_id)
                ))
                return true;
        }
    }
    return false;
}

function section_has_direct_priority_level(section) {
    for (let group_id in connections.priority_groups(section))
        for (let level_id in connections.priority_levels(group_id))
            if (connections.priority_level_direct(group_id, level_id))
                return true;
    return false;
}

function urltest_country_metadata(section, urltest_id, state) {
    let metadata = object_or_empty(object_or_empty(state.outboundMetadata).countries);
    let detect_method = connections.urltest_detect_server_country(section, urltest_id);
    if (detect_method == "flag_emoji")
        return runtime_urltest.countries_from_flag_names(object_or_empty(object_or_empty(state.outboundMetadata).names));
    return metadata;
}

function array_contains(values, needle) {
    for (let value in array_or_empty(values)) {
        if (value == needle)
            return true;
    }
    return false;
}

function unique_string_array(values) {
    let result = [];
    let seen = {};
    for (let value in array_or_empty(values)) {
        value = as_string(value);
        if (value == "" || seen[value])
            continue;
        seen[value] = true;
        push(result, value);
    }
    return result;
}

function object_keys_set(values) {
    let result = {};
    for (let value in array_or_empty(values))
        result[value] = true;
    return result;
}

function tag_display_name(tag, names) {
    let name = as_string(object_or_empty(names)[tag] || "");
    return name != "" ? name : tag;
}

function regex_match_set(tags, names, regexes) {
    return object_keys_set(runtime_urltest.regex_matching_tag_array(tags, names, regexes));
}

function tag_name_filter_matches(tag, names, name_filter, regex_set) {
    let name = tag_display_name(tag, names);
    return array_contains(name_filter, name) || regex_set[tag];
}

function tag_country_filter_matches(tag, countries, country_filter) {
    let country = uc(as_string(object_or_empty(countries)[tag] || ""));
    return country != "" && array_contains(country_filter, country);
}

function tag_attribute_filter_matches(tag, metadata, selected_values) {
    selected_values = array_or_empty(selected_values);
    if (length(selected_values) == 0)
        return true;

    let value = lc(as_string(object_or_empty(metadata)[tag] || ""));
    if (value == "")
        return false;
    for (let selected in selected_values)
        if (lc(as_string(selected)) == value)
            return true;
    return false;
}

function proxy_parameter_filter_matches_all(tag, metadata, protocols, transports, securities) {
    metadata = object_or_empty(metadata);
    return tag_attribute_filter_matches(tag, metadata.protocols, protocols) &&
        tag_attribute_filter_matches(tag, metadata.transports, transports) &&
        tag_attribute_filter_matches(tag, metadata.securities, securities);
}

function proxy_parameter_filter_matches_any(tag, metadata, protocols, transports, securities) {
    metadata = object_or_empty(metadata);
    return (length(array_or_empty(protocols)) > 0 &&
            tag_attribute_filter_matches(tag, metadata.protocols, protocols)) ||
        (length(array_or_empty(transports)) > 0 &&
            tag_attribute_filter_matches(tag, metadata.transports, transports)) ||
        (length(array_or_empty(securities)) > 0 &&
            tag_attribute_filter_matches(tag, metadata.securities, securities));
}

function name_or_country_filter_configured(name_filter, regexes, country_filter) {
    return length(array_or_empty(name_filter)) > 0 ||
        length(array_or_empty(regexes)) > 0 ||
        length(array_or_empty(country_filter)) > 0;
}

function urltest_all_candidate_outbounds(urltest_candidate_tags) {
    return unique_string_array(urltest_candidate_tags);
}

function urltest_matching_candidate_outbounds(urltest_candidate_tags, names, countries, name_filter, regexes, country_filter,
    metadata, proxy_parameters_enabled, proxy_parameters_operator, protocols, transports, securities, additional_matches) {
    names = object_or_empty(names);
    countries = object_or_empty(countries);
    country_filter = runtime_urltest.normalized_country_list(country_filter);

    let regex_set = regex_match_set(urltest_candidate_tags, names, regexes);
    let base_filter_configured = name_or_country_filter_configured(name_filter, regexes, country_filter);
    let additional_set = object_keys_set(additional_matches);
    let result = [];

    for (let tag in array_or_empty(urltest_candidate_tags)) {
        let base_matches = tag_name_filter_matches(tag, names, name_filter, regex_set) ||
            tag_country_filter_matches(tag, countries, country_filter);
        let matches = additional_set[tag] || base_matches;
        if (proxy_parameters_enabled && proxy_parameters_operator == "or") {
            matches = additional_set[tag] || base_matches || proxy_parameter_filter_matches_any(
                tag, metadata, protocols, transports, securities
            );
        }
        else if (proxy_parameters_enabled) {
            if (!base_filter_configured)
                base_matches = true;
            matches = additional_set[tag] ||
                (base_matches && proxy_parameter_filter_matches_all(
                    tag, metadata, protocols, transports, securities
                ));
        }

        if (matches)
            push(result, tag);
    }

    return unique_string_array(result);
}

function urltest_exclude_outbounds(all_outbounds, excluded_outbounds) {
    let excluded = object_keys_set(excluded_outbounds);
    let result = [];
    for (let tag in array_or_empty(all_outbounds)) {
        if (!excluded[tag])
            push(result, tag);
    }
    return result;
}

function filter_candidate_outbounds(filter_mode, urltest_candidate_tags, names, countries, metadata,
    include_names, include_regex, include_countries,
    include_proxy_parameters, include_protocols, include_transports, include_securities,
    exclude_names, exclude_regex, exclude_countries,
    exclude_proxy_parameters, exclude_protocols, exclude_transports, exclude_securities,
    include_additional_matches, exclude_additional_matches) {
    let all_outbounds = urltest_all_candidate_outbounds(urltest_candidate_tags);
    if (filter_mode == "" || filter_mode == "disabled")
        return all_outbounds;
    if (!supported_urltest_filter_mode(filter_mode))
        return all_outbounds;

    let include_outbounds = urltest_matching_candidate_outbounds(
        urltest_candidate_tags,
        names,
        countries,
        include_names,
        include_regex,
        include_countries,
        metadata,
        include_proxy_parameters,
        "and",
        include_protocols,
        include_transports,
        include_securities,
        include_additional_matches
    );
    let exclude_outbounds = urltest_matching_candidate_outbounds(
        urltest_candidate_tags,
        names,
        countries,
        exclude_names,
        exclude_regex,
        exclude_countries,
        metadata,
        exclude_proxy_parameters,
        "or",
        exclude_protocols,
        exclude_transports,
        exclude_securities,
        exclude_additional_matches
    );

    if (filter_mode == "include")
        return include_outbounds;
    if (filter_mode == "exclude")
        return urltest_exclude_outbounds(all_outbounds, exclude_outbounds);
    if (filter_mode == "mixed")
        return urltest_exclude_outbounds(include_outbounds, exclude_outbounds);
    return all_outbounds;
}

function urltest_filtered_outbounds(section, urltest_id, urltest_candidate_tags, state) {
    return filter_candidate_outbounds(
        connections.urltest_filter_mode(section, urltest_id),
        urltest_candidate_tags,
        object_or_empty(object_or_empty(state.outboundMetadata).names),
        urltest_country_metadata(section, urltest_id, state),
        object_or_empty(state.outboundMetadata),
        connections.urltest_include_outbounds(section, urltest_id),
        connections.urltest_include_regex(section, urltest_id),
        connections.urltest_include_countries(section, urltest_id),
        connections.urltest_include_proxy_parameters(section, urltest_id),
        connections.urltest_include_protocols(section, urltest_id),
        connections.urltest_include_transports(section, urltest_id),
        connections.urltest_include_securities(section, urltest_id),
        connections.urltest_exclude_outbounds(section, urltest_id),
        connections.urltest_exclude_regex(section, urltest_id),
        connections.urltest_exclude_countries(section, urltest_id),
        connections.urltest_exclude_proxy_parameters(section, urltest_id),
        connections.urltest_exclude_protocols(section, urltest_id),
        connections.urltest_exclude_transports(section, urltest_id),
        connections.urltest_exclude_securities(section, urltest_id)
    );
}

function priority_level_country_metadata(group_id, level_id, state) {
    let metadata = object_or_empty(object_or_empty(state.outboundMetadata).countries);
    let detect_method = connections.priority_level_detect_server_country(group_id, level_id);
    if (detect_method == "flag_emoji")
        return runtime_urltest.countries_from_flag_names(object_or_empty(object_or_empty(state.outboundMetadata).names));
    return metadata;
}

function priority_level_filtered_outbounds(group_id, level_id, urltest_candidate_tags, state) {
    if (connections.priority_level_direct(group_id, level_id))
        return [ runtime_constants.DIRECT_OUTBOUND_TAG ];

    return filter_candidate_outbounds(
        connections.priority_level_filter_mode(group_id, level_id),
        urltest_candidate_tags,
        object_or_empty(object_or_empty(state.outboundMetadata).names),
        priority_level_country_metadata(group_id, level_id, state),
        object_or_empty(state.outboundMetadata),
        connections.priority_level_include_outbounds(group_id, level_id),
        connections.priority_level_include_regex(group_id, level_id),
        connections.priority_level_include_countries(group_id, level_id),
        connections.priority_level_include_proxy_parameters(group_id, level_id),
        connections.priority_level_include_protocols(group_id, level_id),
        connections.priority_level_include_transports(group_id, level_id),
        connections.priority_level_include_securities(group_id, level_id),
        connections.priority_level_exclude_outbounds(group_id, level_id),
        connections.priority_level_exclude_regex(group_id, level_id),
        connections.priority_level_exclude_countries(group_id, level_id),
        connections.priority_level_exclude_proxy_parameters(group_id, level_id),
        connections.priority_level_exclude_protocols(group_id, level_id),
        connections.priority_level_exclude_transports(group_id, level_id),
        connections.priority_level_exclude_securities(group_id, level_id)
    );
}

function dashboard_country_metadata(section, state) {
    let metadata = object_or_empty(object_or_empty(state.outboundMetadata).countries);
    if (connections.dashboard_detect_server_country(section) == "flag_emoji")
        return runtime_urltest.countries_from_flag_names(object_or_empty(object_or_empty(state.outboundMetadata).names));
    return metadata;
}

function selected_group_outbounds(group_names, group_outbounds) {
    group_outbounds = object_or_empty(group_outbounds);
    let result = [];
    for (let group_name in array_or_empty(group_names))
        for (let tag_name in array_or_empty(group_outbounds[group_name]))
            push(result, tag_name);
    return unique_string_array(result);
}

function remember_dashboard_group_outbounds(group_outbounds, group_name, outbounds) {
    group_name = as_string(group_name);
    if (group_name == "")
        return;

    let combined = array_or_empty(group_outbounds[group_name]);
    for (let tag_name in array_or_empty(outbounds))
        push(combined, tag_name);
    group_outbounds[group_name] = unique_string_array(combined);
}

function dashboard_filtered_outbounds(section, selector_tags, state, group_outbounds) {
    return filter_candidate_outbounds(
        connections.dashboard_filter_mode(section),
        selector_tags,
        object_or_empty(object_or_empty(state.outboundMetadata).names),
        dashboard_country_metadata(section, state),
        object_or_empty(state.outboundMetadata),
        connections.dashboard_include_outbounds(section),
        connections.dashboard_include_regex(section),
        connections.dashboard_include_countries(section),
        connections.dashboard_include_proxy_parameters(section),
        connections.dashboard_include_protocols(section),
        connections.dashboard_include_transports(section),
        connections.dashboard_include_securities(section),
        connections.dashboard_exclude_outbounds(section),
        connections.dashboard_exclude_regex(section),
        connections.dashboard_exclude_countries(section),
        connections.dashboard_exclude_proxy_parameters(section),
        connections.dashboard_exclude_protocols(section),
        connections.dashboard_exclude_transports(section),
        connections.dashboard_exclude_securities(section),
        selected_group_outbounds(connections.dashboard_include_groups(section), group_outbounds),
        selected_group_outbounds(connections.dashboard_exclude_groups(section), group_outbounds)
    );
}

function priority_levels_with_outbounds(group_id, urltest_candidate_tags, state) {
    let result = [];
    let assigned = {};

    for (let level_id in connections.priority_levels(group_id)) {
        let outbounds = [];
        for (let tag_name in priority_level_filtered_outbounds(group_id, level_id, urltest_candidate_tags, state)) {
            if (!assigned[tag_name]) {
                assigned[tag_name] = true;
                push(outbounds, tag_name);
            }
        }

        push(result, {
            id: level_id,
            displayName: connections.priority_level_display_name(group_id, level_id),
            order: int(connections.priority_level_order(group_id, level_id), 10),
            direct: connections.priority_level_direct(group_id, level_id),
            filter_mode: connections.priority_level_filter_mode(group_id, level_id),
            detect_server_country: connections.priority_level_detect_server_country(group_id, level_id),
            outbounds
        });
    }

    return result;
}

function priority_group_outbounds(levels) {
    let result = [];
    let seen = {};
    for (let level in array_or_empty(levels)) {
        for (let tag_name in array_or_empty(level.outbounds)) {
            tag_name = as_string(tag_name);
            if (tag_name != "" && !seen[tag_name]) {
                seen[tag_name] = true;
                push(result, tag_name);
            }
        }
    }
    return result;
}

function urltest_outbound_tag(section_name, urltest_id) {
    urltest_id = as_string(urltest_id);
    return urltest_id == "urltest"
        ? outbound_tag(section_name + "-urltest")
        : outbound_tag(section_name + "-urltest-" + urltest_id);
}

function priority_outbound_tag(section_name, group_id) {
    return outbound_tag(section_name + "-priority-" + as_string(group_id));
}

function add_urltest_outbound(config, section, urltest_id, urltest_candidate_tags, state) {
    let section_name = section[".name"];
    let urltest_outbounds = urltest_filtered_outbounds(section, urltest_id, urltest_candidate_tags, state);
    let urltest_tag = urltest_outbound_tag(section_name, urltest_id);
    let display_name = connections.urltest_display_name(section, urltest_id);
    let urltest_outbound = {
        type: "urltest",
        tag: urltest_tag,
        outbounds: urltest_outbounds,
        url: connections.urltest_testing_url(section, urltest_id),
        interval: urltest_check_interval(section, urltest_id),
        tolerance: int(connections.urltest_tolerance(section, urltest_id), 10),
        interrupt_exist_connections: connections.urltest_interrupt_exist_connections(section, urltest_id)
    };
    let idle_timeout = urltest_idle_timeout(section, urltest_id);
    if (idle_timeout != "")
        urltest_outbound.idle_timeout = idle_timeout;

    runtime_subscription.remember_outbound_metadata(state, urltest_tag, display_name, urltest_outbound);
    runtime_subscription.remember_urltest_group_config(state, urltest_tag, {
        displayName: display_name,
        outbounds: urltest_outbounds,
        url: urltest_outbound.url,
        interval: urltest_outbound.interval,
        tolerance: urltest_outbound.tolerance,
        idle_timeout: urltest_outbound.idle_timeout,
        interrupt_exist_connections: urltest_outbound.interrupt_exist_connections
    });

    if (length(urltest_outbounds) == 0)
        return {
            tag: "",
            outbounds: []
        };

    push(config.outbounds, urltest_outbound);
    return {
        tag: urltest_tag,
        outbounds: urltest_outbounds
    };
}

function add_priority_group_outbound(config, section, group_id, urltest_candidate_tags, state) {
    let section_name = section[".name"];
    let levels = priority_levels_with_outbounds(group_id, urltest_candidate_tags, state);
    let outbounds = priority_group_outbounds(levels);
    let priority_tag = priority_outbound_tag(section_name, group_id);
    let display_name = connections.priority_group_display_name(section, group_id);
    let outbound = {
        type: "selector",
        tag: priority_tag,
        outbounds,
        default: outbounds[0],
        interrupt_exist_connections: connections.priority_group_interrupt_exist_connections(section, group_id)
    };

    runtime_subscription.remember_outbound_metadata(state, priority_tag, display_name, outbound);
    runtime_subscription.remember_priority_group(state, priority_tag, {
        id: group_id,
        tag: priority_tag,
        section: section_name,
        displayName: display_name,
        health_url: connections.priority_group_health_url(section, group_id),
        active_check_interval: connections.priority_group_active_check_interval(section, group_id),
        check_timeout: connections.priority_group_check_timeout(section, group_id),
        recovery_check_interval: connections.priority_group_recovery_check_interval(section, group_id),
        pick_fastest: connections.priority_group_pick_fastest(section, group_id),
        switch_to_faster_same_priority: connections.priority_group_switch_to_faster_same_priority(section, group_id),
        fastest_check_interval: connections.priority_group_fastest_check_interval(section, group_id),
        interrupt_exist_connections: connections.priority_group_interrupt_exist_connections(section, group_id),
        pin_dashboard: connections.priority_group_pin_dashboard(section, group_id),
        outbounds,
        levels
    });

    if (length(outbounds) == 0)
        return {
            tag: "",
            outbounds: []
        };

    push(config.outbounds, outbound);
    return {
        tag: priority_tag,
        outbounds
    };
}

function add_proxy_selector(config, section, selector_tags, urltest_candidate_tags, state) {
    let section_name = section[".name"];
    let selector_tag = outbound_tag(section_name);
    let selector_outbounds = selector_tags;
    let selector_default = selector_tags[0];
    let urltest_tags = [];
    let priority_tags = [];
    let group_outbounds = {};

    for (let urltest_id in connections.urltests(section)) {
        let urltest = add_urltest_outbound(config, section, urltest_id, urltest_candidate_tags, state);
        remember_dashboard_group_outbounds(
            group_outbounds,
            connections.urltest_display_name(section, urltest_id),
            urltest.outbounds
        );
        if (urltest.tag == "")
            continue;

        push(urltest_tags, urltest.tag);
    }

    for (let group_id in connections.priority_groups(section)) {
        let priority = add_priority_group_outbound(config, section, group_id, urltest_candidate_tags, state);
        remember_dashboard_group_outbounds(
            group_outbounds,
            connections.priority_group_display_name(section, group_id),
            priority.outbounds
        );
        if (priority.tag == "")
            continue;

        push(priority_tags, priority.tag);
    }

    selector_outbounds = dashboard_filtered_outbounds(section, selector_tags, state, group_outbounds);
    selector_default = selector_outbounds[0];
    if (length(urltest_tags) > 0 || length(priority_tags) > 0) {
        for (let tag in urltest_tags)
            push(selector_outbounds, tag);
        for (let tag in priority_tags)
            push(selector_outbounds, tag);
        selector_default = length(urltest_tags) > 0 ? urltest_tags[0] : priority_tags[0];
    }

    if (length(selector_outbounds) == 0)
        runtime_generate_unsupported("dashboard server filtering produced no usable outbounds");

    push(config.outbounds, {
        type: "selector",
        tag: selector_tag,
        outbounds: selector_outbounds,
        default: selector_default,
        interrupt_exist_connections: true
    });
}

function outbound_detour_tag_for_section(section) {
    if (!bool_option(section, "outbound_detour_enabled", false))
        return "";

    let detour_section = option(section, "outbound_detour_section", "");
    return detour_section == "" ? "" : outbound_tag(detour_section);
}

function apply_section_detour_to_connection_outbounds(config, start_index, detour_tag) {
    if (detour_tag == "")
        return;

    let outbounds = array_or_empty(config.outbounds);
    for (let i = int(start_index || 0); i < length(outbounds); i++) {
        let outbound = outbounds[i];
        if (type(outbound) != "object")
            continue;

        let outbound_type = lc(as_string(outbound.type || ""));
        if (outbound_type == "" ||
            outbound_type == "selector" ||
            outbound_type == "urltest" || outbound_type == "dns" ||
            outbound_type == "block")
            continue;

        // A local SOCKS bridge (ovpn-via-*, xray sidecar) is the cascade hop.
        // Giving it the section detour makes its dial to 127.0.0.1 go back
        // through the same proxy, so WireGuard/OpenVPN loop onto that port.
        if (outbound_type == "socks") {
            let bridge = lc(trim(as_string(outbound.server || "")));
            if (bridge == "127.0.0.1" || bridge == "::1" || bridge == "localhost")
                continue;
        }

        // Preserve subscription chains: only their terminal dial outbound receives the section detour.
        if (as_string(outbound.detour || "") == "")
            outbound.detour = detour_tag;
    }
}

function mixed_proxy_enabled_action(action) {
    return action == "connection" || action == "proxy" || action == "outbound" || action == "vpn" ||
        action == "byedpi" || action == "zapret" || action == "zapret2";
}

function add_mixed_proxy_for_section(config, section, service_address) {
    if (!bool_option(section, "mixed_proxy_enabled", false))
        return;

    let action = option(section, "action", "");
    if (!mixed_proxy_enabled_action(action))
        runtime_generate_unsupported("mixed proxy inbound is not supported for action " + action);

    let listen_port_value = option(section, "mixed_proxy_port", "");
    if (match(listen_port_value, /^[0-9]+$/) == null)
        runtime_generate_unsupported("mixed proxy port is invalid");
    let listen_port = int(listen_port_value, 10);
    if (listen_port < 1 || listen_port > 65535)
        runtime_generate_unsupported("mixed proxy port is invalid");

    let listen = as_string(service_address || "");
    if (listen == "")
        runtime_generate_unsupported("mixed proxy listen address is not set");

    let inbound = {
        type: "mixed",
        tag: runtime_constants.inbound_tag(section[".name"] + "-mixed"),
        listen,
        listen_port
    };

    if (bool_option(section, "mixed_proxy_auth_enabled", false)) {
        let username = option(section, "mixed_proxy_username", "");
        let password = option(section, "mixed_proxy_password", "");
        if (username == "" || password == "")
            runtime_generate_unsupported("mixed proxy authentication is enabled but username or password is empty");
        inbound.users = [{ username, password }];
    }
    push(config.inbounds, inbound);
    push(config.route.rules, {
        action: "route",
        inbound: inbound.tag,
        outbound: runtime_constants.outbound_tag(section[".name"])
    });
}

function add_service_mixed_proxy_inbound(config, tag_name, listen_port, outbound) {
    push(config.inbounds, {
        type: "mixed",
        tag: tag_name,
        listen: runtime_constants.SERVICE_MIXED_INBOUND_ADDRESS,
        listen_port
    });
    push(config.route.rules, {
        action: "route",
        inbound: tag_name,
        outbound
    });
}

function service_mixed_proxy_inbound_tag_for_purpose(purpose) {
    return as_string(purpose || "lists") == "components"
        ? runtime_constants.inbound_tag("service-components")
        : runtime_constants.SERVICE_MIXED_INBOUND_TAG;
}

function service_mixed_proxy_port_for_purpose(purpose) {
    return runtime_constants.SERVICE_MIXED_INBOUND_PORT +
        (as_string(purpose || "lists") == "components" ? 1 : 0);
}

function add_global_download_service_mixed_proxy(config, settings, purpose) {
    let outbound = download_detour_tag(settings, purpose);
    if (outbound == "")
        return;

    add_service_mixed_proxy_inbound(
        config,
        service_mixed_proxy_inbound_tag_for_purpose(purpose),
        service_mixed_proxy_port_for_purpose(purpose),
        outbound
    );
}

function add_subscription_download_service_mixed_proxies(config, sections) {
    for (let target in connections.subscription_download_targets(sections)) {
        let port = connections.subscription_download_target_port(sections, target, runtime_constants.SERVICE_MIXED_INBOUND_PORT);
        if (port <= 0)
            runtime_generate_unsupported("subscription download proxy port could not be resolved");

        add_service_mixed_proxy_inbound(
            config,
            runtime_constants.inbound_tag("service-subscription-" + target),
            port,
            outbound_tag(target)
        );
    }
}

function add_service_mixed_proxy(config, settings, sections) {
    if (!download_via_proxy_any_enabled(settings, sections))
        return;

    add_global_download_service_mixed_proxy(config, settings, "lists");
    add_global_download_service_mixed_proxy(config, settings, "components");
    add_subscription_download_service_mixed_proxies(config, sections);

    if (download_via_proxy_enabled(settings, "lists") && download_detour_tag(settings, "lists") == "")
        runtime_generate_unsupported("download lists via proxy section is not set");
    if (download_via_proxy_enabled(settings, "components") && download_detour_tag(settings, "components") == "")
        runtime_generate_unsupported("download components via proxy section is not set");
}

function parse_port(value) {
    value = as_string(value);
    if (match(value, /^[0-9]+$/) == null)
        return null;
    let port = int(value, 10);
    return port >= 1 && port <= 65535 ? port : null;
}

function bool_query(value) {
    return value == "1" || value == "true";
}

function base64_decode_value(value) {
    value = replace(as_string(value), /[\r\n\t ]/g, "");
    value = replace(replace(value, /-/g, "+"), /_/g, "/");
    while (length(value) % 4 != 0)
        value += "=";
    try {
        return b64dec(value);
    }
    catch (e) {
        return null;
    }
}

function shadowsocks_userinfo_valid(value) {
    value = as_string(value);
    let first = index(value, ":");
    if (first <= 0 || first >= length(value) - 1)
        return false;
    let rest = substr(value, first + 1);
    let second = index(rest, ":");
    return second < 0 || index(substr(rest, second + 1), ":") < 0;
}

function split_host_port(value) {
    value = as_string(value);
    if (substr(value, 0, 1) == "[") {
        let close = index(value, "]");
        if (close > 0 && substr(value, close + 1, 1) == ":")
            return [ substr(value, 1, close - 1), substr(value, close + 2) ];
    }

    let colon = rindex(value, ":");
    if (colon < 0)
        return [ "", "" ];
    return [ substr(value, 0, colon), substr(value, colon + 1) ];
}

function tls_alpn_array(value, transport) {
    value = as_string(value);
    transport = lc(as_string(transport));
    if (value == "" && transport == "xhttp")
        return [ "h2", "http/1.1" ];
    if (value != "" && (transport == "ws" || transport == "httpupgrade"))
        return [ "http/1.1" ];
    return value == "" ? [] : split(value, ",");
}

function apply_link_tls(outbound, scheme, query) {
    query = object_or_empty(query);
    let security = as_string(query.security || "");
    if (security == "" && (scheme == "hysteria2" || scheme == "hy2"))
        security = "tls";

    if (security == "" || security == "none")
        return;
    if (security != "tls" && security != "reality") {
        warn("unknown manual proxy link security '", security, "' ignored\n");
        return;
    }

    let tls = { enabled: true };
    if (as_string(query.sni || "") != "")
        tls.server_name = as_string(query.sni);
    if (bool_query(query.allowInsecure || query.insecure || ""))
        tls.insecure = true;

    let alpn = tls_alpn_array(query.alpn, query.type);
    if (length(alpn) > 0)
        tls.alpn = alpn;

    if (scheme != "hysteria2" && scheme != "hy2" && as_string(query.fp || "") != "") {
        tls.utls = {
            enabled: true,
            fingerprint: as_string(query.fp)
        };
    }
    if (security == "reality") {
        tls.reality = {
            enabled: true,
            public_key: as_string(query.pbk || ""),
            short_id: as_string(query.sid || "")
        };
    }
    outbound.tls = tls;
}

function csv_array(value) {
    value = as_string(value);
    if (value == "")
        return [];
    let result = [];
    for (let item in split(value, ",")) {
        item = trim(as_string(item));
        if (item != "")
            push(result, item);
    }
    return result;
}

function optional_query_string(object, key, value) {
    value = as_string(value);
    if (value != "")
        object[key] = value;
}

function optional_query_number(object, key, value) {
    value = as_string(value);
    if (value != "" && match(value, /^[0-9]+$/) != null)
        object[key] = int(value, 10);
}

function apply_link_transport(outbound, query) {
    let transport = lc(as_string(object_or_empty(query).type || ""));
    if (transport == "" || transport == "tcp" || transport == "raw")
        return;

    if (transport == "h2")
        transport = "http";

    let result = { type: transport };
    if (transport == "http") {
        optional_query_string(result, "path", query.path);
        let hosts = csv_array(query.host);
        if (length(hosts) > 0)
            result.host = hosts;
    }
    else if (transport == "ws") {
        result.path = as_string(query.path || "");
        if (as_string(query.host || "") != "")
            result.headers = { Host: as_string(query.host) };
        optional_query_number(result, "max_early_data", query.ed);
    }
    else if (transport == "grpc") {
        optional_query_string(result, "service_name", query.serviceName);
    }
    else if (transport == "httpupgrade") {
        optional_query_string(result, "path", query.path);
        optional_query_string(result, "host", query.host);
    }
    else if (transport == "xhttp") {
        let mode = as_string(query.mode || "auto");
        if (mode != "auto" && mode != "packet-up" && mode != "stream-up" && mode != "stream-one")
            mode = "auto";
        result.mode = mode;
        result.path = as_string(query.path || "") != "" ? as_string(query.path) : "/";
        result.x_padding_bytes = "100-1000";
        result.no_grpc_header = false;
        result.sc_max_each_post_bytes = 1000000;
        result.sc_min_posts_interval_ms = 30;
        optional_query_string(result, "host", as_string(query.host || "") != "" ? query.host : query.sni);
    }
    else {
        warn("unknown manual proxy link transport '", transport, "' ignored\n");
        return;
    }

    outbound.transport = result;
}

function manual_socks_outbound(link, tag_name) {
    let scheme = url_scheme(link);
    let host = url_host(link);
    let port = parse_port(url_port(link));
    if (host == "" || port == null)
        runtime_generate_unsupported("manual SOCKS proxy link is invalid");

    let outbound = {
        type: "socks",
        tag: tag_name,
        server: host,
        server_port: port,
        version: scheme == "socks4" || scheme == "socks4a" ? "4" : "5"
    };
    if (scheme == "socks5") {
        let userinfo = url_userinfo(link);
        if (userinfo != "") {
            let colon = index(userinfo, ":");
            outbound.username = colon >= 0 ? substr(userinfo, 0, colon) : userinfo;
            if (colon >= 0)
                outbound.password = substr(userinfo, colon + 1);
        }
    }
    return outbound;
}

function manual_shadowsocks_outbound(link, tag_name) {
    let raw = url_strip_fragment_value(url_decode(link));
    let body = substr(raw, 5);
    let question = index(body, "?");
    let query_string = "";
    if (question >= 0) {
        query_string = substr(body, question + 1);
        body = substr(body, 0, question);
    }

    let at = rindex(body, "@");
    let userinfo = "";
    let hostport = "";
    if (at >= 0) {
        userinfo = substr(body, 0, at);
        hostport = substr(body, at + 1);
    }
    else {
        let decoded = base64_decode_value(body);
        if (decoded == null)
            runtime_generate_unsupported("manual Shadowsocks proxy link is invalid");
        at = rindex(decoded, "@");
        if (at < 0)
            runtime_generate_unsupported("manual Shadowsocks proxy link is invalid");
        userinfo = substr(decoded, 0, at);
        hostport = substr(decoded, at + 1);
    }

    userinfo = url_decode(userinfo);
    if (!shadowsocks_userinfo_valid(userinfo)) {
        let decoded = base64_decode_value(userinfo);
        if (decoded == null)
            runtime_generate_unsupported("manual Shadowsocks proxy link is invalid");
        userinfo = decoded;
    }

    let cred_colon = index(userinfo, ":");
    let host_port = split_host_port(hostport);
    let port = parse_port(host_port[1]);
    if (cred_colon <= 0 || host_port[0] == "" || port == null)
        runtime_generate_unsupported("manual Shadowsocks proxy link is invalid");

    let outbound = {
        type: "shadowsocks",
        tag: tag_name,
        server: host_port[0],
        server_port: port,
        method: substr(userinfo, 0, cred_colon),
        password: substr(userinfo, cred_colon + 1)
    };
    let query = url_query_params("ss://placeholder/?" + query_string);
    if (as_string(query.plugin || "") != "")
        outbound.plugin = as_string(query.plugin);
    if (as_string(query["plugin-opts"] || "") != "")
        outbound.plugin_opts = as_string(query["plugin-opts"]);
    return outbound;
}

function manual_vless_outbound(link, tag_name) {
    let query = url_query_params(link);

    let host = url_host(link);
    let port = parse_port(url_port(link));
    let uuid = url_userinfo(link);
    if (host == "" || port == null || uuid == "")
        runtime_generate_unsupported("manual VLESS proxy link is invalid");

    let outbound = {
        type: "vless",
        tag: tag_name,
        server: host,
        server_port: port,
        uuid
    };
    let flow = as_string(query.flow || "");
    if (flow != "")
        outbound.flow = flow;
    let encryption = as_string(query.encryption || "");
    if (encryption != "" && encryption != "none")
        outbound.encryption = encryption;
    let packet_encoding = as_string(query.packetEncoding || "");
    if (packet_encoding == "xudp" || packet_encoding == "packetaddr")
        outbound.packet_encoding = packet_encoding;
    apply_link_tls(outbound, "vless", query);
    apply_link_transport(outbound, query);
    return outbound;
}

function vmess_json_value(value) {
    return value == null ? "" : as_string(value);
}

function manual_vmess_outbound(link, tag_name) {
    let encoded = substr(url_strip_fragment_value(link), 8);
    let decoded = base64_decode_value(encoded);
    if (decoded == null)
        runtime_generate_unsupported("manual VMess proxy link is invalid");

    if (index(decoded, "\r") >= 0 || index(decoded, "\n") >= 0)
        decoded = replace(decoded, /[\r\n]/g, "");
    decoded = trim(decoded);

    let vmess;
    try {
        vmess = json(decoded);
    }
    catch (e) {
        runtime_generate_unsupported("manual VMess proxy link is invalid");
    }
    if (type(vmess) != "object")
        runtime_generate_unsupported("manual VMess proxy link is invalid");

    let host = vmess_json_value(vmess.add);
    let port = parse_port(vmess_json_value(vmess.port));
    let uuid = vmess_json_value(vmess.id);
    if (host == "" || port == null || uuid == "")
        runtime_generate_unsupported("manual VMess proxy link is invalid");

    let outbound = {
        type: "vmess",
        tag: tag_name,
        server: host,
        server_port: port,
        uuid,
        security: vmess_json_value(vmess.scy) != "" ? vmess_json_value(vmess.scy) : "auto"
    };

    if (vmess_json_value(vmess.aid) != "")
        outbound.alter_id = int(vmess.aid || 0);

    let network = lc(vmess_json_value(vmess.net));
    if (vmess.tls === true || vmess.tls == "tls" || vmess.tls == "true") {
        let tls = { enabled: true };
        optional_query_string(tls, "server_name", vmess_json_value(vmess.sni));
        let alpn = tls_alpn_array(vmess_json_value(vmess.alpn), network);
        if (length(alpn) > 0)
            tls.alpn = alpn;
        if (vmess_json_value(vmess.fp) != "") {
            tls.utls = {
                enabled: true,
                fingerprint: vmess_json_value(vmess.fp)
            };
        }
        outbound.tls = tls;
    }

    if (network == "ws") {
        outbound.transport = {
            type: "ws",
            path: vmess_json_value(vmess.path) != "" ? vmess_json_value(vmess.path) : "/"
        };
        if (vmess_json_value(vmess.host) != "")
            outbound.transport.headers = { Host: vmess_json_value(vmess.host) };
    }
    else if (network == "grpc") {
        outbound.transport = { type: "grpc" };
        optional_query_string(outbound.transport, "service_name", vmess_json_value(vmess.path));
    }
    else if (network == "http" || network == "h2") {
        outbound.transport = { type: "http" };
        optional_query_string(outbound.transport, "path", vmess_json_value(vmess.path));
        let hosts = csv_array(vmess_json_value(vmess.host));
        if (length(hosts) > 0)
            outbound.transport.host = hosts;
    }

    return outbound;
}

function manual_trojan_outbound(link, tag_name) {
    let query = url_query_params(link);

    let host = url_host(link);
    let port = parse_port(url_port(link));
    let password = url_userinfo(link);
    if (host == "" || port == null || password == "")
        runtime_generate_unsupported("manual Trojan proxy link is invalid");

    let outbound = {
        type: "trojan",
        tag: tag_name,
        server: host,
        server_port: port,
        password
    };
    apply_link_tls(outbound, "trojan", query);
    apply_link_transport(outbound, query);
    return outbound;
}

function manual_hysteria2_outbound(link, tag_name) {
    let query = url_query_params(link);
    let host = url_host(link);
    let port = parse_port(as_string(query.mport || "") != "" ? query.mport : url_port(link));
    let password = url_userinfo(link);
    if (host == "" || port == null || password == "")
        runtime_generate_unsupported("manual Hysteria2 proxy link is invalid");

    let outbound = {
        type: "hysteria2",
        tag: tag_name,
        server: host,
        server_port: port,
        password
    };
    if (as_string(query.obfs || "") != "")
        outbound.obfs = { type: as_string(query.obfs), password: as_string(query["obfs-password"] || "") };
    if (as_string(query.upmbps || "") != "")
        outbound.up_mbps = int(query.upmbps, 10);
    if (as_string(query.downmbps || "") != "")
        outbound.down_mbps = int(query.downmbps, 10);
    apply_link_tls(outbound, url_scheme(link), query);
    return outbound;
}

function sing_box_at_least_1_11() {
    let v = sing_box_major_minor();
    return v.major > 1 || (v.major == 1 && v.minor >= 11);
}

function wireguard_scheme(scheme) {
    scheme = lc(as_string(scheme));
    return scheme == "wireguard" || scheme == "wg" || scheme == "awg" || scheme == "amneziawg" || scheme == "warp";
}

function wireguard_key(value) {
    value = trim(as_string(value));
    if (value == "")
        return "";
    value = replace(replace(value, /-/g, "+"), /_/g, "/");
    while (length(value) % 4 != 0)
        value += "=";
    return value;
}

function wireguard_cidr_list(value, fallback) {
    let items = [];
    for (let item in split(as_string(value), ",")) {
        item = trim(item);
        if (item == "")
            continue;
        if (index(item, "/") < 0)
            item += index(item, ":") >= 0 ? "/128" : "/32";
        push(items, item);
    }
    return length(items) > 0 ? items : fallback;
}

function wireguard_reserved(value) {
    value = trim(as_string(value));
    if (value == "")
        return null;
    let parts = split(value, ",");
    if (length(parts) != 3)
        return null;
    let result = [];
    for (let part in parts) {
        part = trim(part);
        if (match(part, /^[0-9]+$/) == null)
            return null;
        let number = int(part, 10);
        if (number < 0 || number > 255)
            return null;
        push(result, number);
    }
    return result;
}

function wireguard_query_value(query, names) {
    query = object_or_empty(query);
    for (let name in names) {
        let want = lc(name);
        for (let key in query) {
            if (lc(key) != want)
                continue;
            let value = trim(as_string(query[key] || ""));
            if (value != "")
                return value;
        }
    }
    return "";
}

function wireguard_conf_text(link) {
    link = as_string(link);
    if (index(lc(link), "[interface]") >= 0)
        return link;
    let marker = index(link, "://");
    let body = marker >= 0 ? substr(url_strip_fragment_value(link), marker + 3) : url_strip_fragment_value(link);
    if (index(body, "@") >= 0 || index(body, "?") >= 0)
        return "";
    let decoded = base64_decode_value(body);
    if (decoded == null || index(lc(decoded), "[interface]") < 0)
        return "";
    return decoded;
}

function wireguard_fields_from_conf_lines(text) {
    let section_name = "";
    let fields = {};
    for (let line in split(replace(as_string(text), /\r/g, ""), "\n")) {
        line = trim(line);
        if (line == "" || substr(line, 0, 1) == "#" || substr(line, 0, 1) == ";")
            continue;
        if (substr(line, 0, 1) == "[") {
            section_name = lc(trim(replace(replace(line, "[", ""), "]", "")));
            continue;
        }
        let eq = index(line, "=");
        if (eq < 0)
            continue;
        let key = lc(replace(trim(substr(line, 0, eq)), /_/g, ""));
        let value = trim(substr(line, eq + 1));
        if (section_name == "peer" && key == "endpoint")
            fields.endpoint = value;
        else if (section_name == "peer" && key == "publickey")
            fields.publickey = value;
        else if (section_name == "peer" && key == "presharedkey")
            fields.presharedkey = value;
        else if (section_name == "peer" && key == "allowedips")
            fields.allowedips = value;
        else if (section_name == "peer" && key == "persistentkeepalive")
            fields.keepalive = value;
        else if (section_name == "interface")
            fields[key] = value;
    }
    return fields;
}

function wireguard_conf_flat_fields(text) {
    let flat = replace(replace(replace(as_string(text), /\\n/g, " "), /\r/g, " "), /\n/g, " ");
    flat = replace(flat, /\t/g, " ");
    let lower = lc(flat);
    let names = [ "headerprotectionkey", "contentpaddingaddition", "maxhandshakeattempts", "persistentkeepalive", "rekeyaftertime", "rejectaftertime", "keepalivetimeout", "rekeytimeout", "randomtrailers", "disablecookies", "presharedkey", "privatekey", "listenport", "publickey", "allowedips", "endpoint", "address", "jmin", "jmax", "s1", "s2", "s3", "s4", "h1", "h2", "h3", "h4", "i1", "i2", "i3", "i4", "i5", "jc", "mtu", "dns" ];
    let found = [];
    let i = 0;
    while (i < length(lower)) {
        let hit = -1;
        let hit_name = "";
        for (let name in names) {
            if (length(name) > length(lower) - i)
                continue;
            if (substr(lower, i, length(name)) != name)
                continue;
            if (i > 0 && match(substr(lower, i - 1, 1), /[a-z0-9_]/) != null)
                continue;
            let j = i + length(name);
            while (j < length(lower) && (substr(lower, j, 1) == " " || substr(lower, j, 1) == "_"))
                j++;
            if (j >= length(lower) || substr(lower, j, 1) != "=")
                continue;
            if (hit < 0 || length(name) > length(hit_name)) {
                hit = j;
                hit_name = name;
            }
        }
        if (hit_name == "") {
            i++;
            continue;
        }
        push(found, [ hit_name, hit, i ]);
        i = hit + 1;
    }
    let fields = {};
    for (let n = 0; n < length(found); n++) {
        let start = found[n][1] + 1;
        let end = n + 1 < length(found) ? found[n + 1][2] : length(flat);
        let value = trim(substr(flat, start, end - start));
        let bracket = index(value, "[");
        if (bracket >= 0)
            value = trim(substr(value, 0, bracket));
        if (length(value) > 1 && substr(value, 0, 1) == "\"" && substr(value, length(value) - 1, 1) == "\"")
            value = trim(substr(value, 1, length(value) - 2));
        let name = found[n][0];
        if (name == "persistentkeepalive")
            fields.keepalive = value;
        else if (name != "dns" && value != "")
            fields[name] = value;
    }
    return fields;
}

function wireguard_fields_from_conf(text) {
    let fields = wireguard_fields_from_conf_lines(text);
    if (trim(as_string(fields.privatekey || "")) != "" && trim(as_string(fields.publickey || "")) != "" && trim(as_string(fields.endpoint || "")) != "")
        return fields;
    let flat = wireguard_conf_flat_fields(text);
    for (let key in flat)
        if (trim(as_string(fields[key] || "")) == "")
            fields[key] = flat[key];
    return fields;
}

function wireguard_uri_endpoint(link) {
    let host = url_host(link);
    let port = url_port(link);
    let colon = rindex(host, ":");
    if (colon > 0 && index(substr(host, 0, colon), ":") < 0) {
        let tail = substr(host, colon + 1);
        if (match(tail, /^[0-9]+$/) != null) {
            host = substr(host, 0, colon);
            if (port == "")
                port = tail;
        }
    }
    return host + ":" + port;
}

function wireguard_fields_from_uri(link) {
    let query = url_query_params(link);
    let fields = {
        privatekey: url_userinfo(link),
        endpoint: wireguard_uri_endpoint(link),
        publickey: wireguard_query_value(query, [ "publickey", "public_key", "peerpublickey", "peer_public_key", "serverpublickey", "server_public_key" ]),
        address: wireguard_query_value(query, [ "address", "ip", "localaddress", "local_address", "localip", "local_ip" ]),
        allowedips: wireguard_query_value(query, [ "allowedips", "allowed_ips" ]),
        mtu: wireguard_query_value(query, [ "mtu" ]),
        keepalive: wireguard_query_value(query, [ "keepalive", "persistentkeepalive" ]),
        presharedkey: wireguard_query_value(query, [ "presharedkey", "preshared_key", "psk" ]),
        reserved: wireguard_query_value(query, [ "reserved", "client_id" ]),
        listenport: wireguard_query_value(query, [ "listenport", "listen_port" ])
    };
    if (fields.privatekey == "")
        fields.privatekey = wireguard_query_value(query, [ "privatekey", "private_key" ]);
    let awg_names = {
        jc: [ "jc" ],
        jmin: [ "jmin" ],
        jmax: [ "jmax" ],
        s1: [ "s1" ],
        s2: [ "s2" ],
        s3: [ "s3" ],
        s4: [ "s4" ],
        h1: [ "h1" ],
        h2: [ "h2" ],
        h3: [ "h3" ],
        h4: [ "h4" ],
        i1: [ "i1" ],
        i2: [ "i2" ],
        i3: [ "i3" ],
        i4: [ "i4" ],
        i5: [ "i5" ],
        headerprotectionkey: [ "headerprotectionkey", "header_protection_key" ],
        contentpaddingaddition: [ "contentpaddingaddition", "content_padding_addition" ],
        rekeyaftertime: [ "rekeyaftertime", "rekey_after_time" ],
        rekeytimeout: [ "rekeytimeout", "rekey_timeout" ],
        rejectaftertime: [ "rejectaftertime", "reject_after_time" ],
        keepalivetimeout: [ "keepalivetimeout", "keepalive_timeout" ],
        maxhandshakeattempts: [ "maxhandshakeattempts", "max_handshake_attempts" ],
        randomtrailers: [ "randomtrailers", "random_trailers" ],
        disablecookies: [ "disablecookies", "disable_cookies" ]
    };
    for (let key in awg_names)
        fields[key] = wireguard_query_value(query, awg_names[key]);
    return fields;
}

function awg_flag_enabled(value) {
    value = lc(trim(as_string(value || "")));
    return value == "1" || value == "on" || value == "true" || value == "yes";
}

function awg_version_from_fields(fields) {
    fields = object_or_empty(fields);
    if (awg_flag_enabled(fields.randomtrailers) || awg_flag_enabled(fields.disablecookies))
        return "3.1";
    for (let key in [ "headerprotectionkey", "contentpaddingaddition", "rekeyaftertime", "rekeytimeout", "rejectaftertime", "keepalivetimeout", "maxhandshakeattempts" ])
        if (trim(as_string(fields[key] || "")) != "")
            return "3.0";
    if (match(trim(as_string(fields.keepalive || "")), /^[0-9]+-[0-9]+$/) != null)
        return "3.0";
    for (let key in [ "jc", "jmin", "jmax", "s1", "s2", "s3", "s4", "h1", "h2", "h3", "h4", "i1", "i2", "i3", "i4", "i5" ])
        if (trim(as_string(fields[key] || "")) != "")
            return "2.0";
    return "";
}

function wireguard_has_awg(fields) {
    for (let key in [ "jc", "jmin", "jmax", "s1", "s2", "s3", "s4", "h1", "h2", "h3", "h4", "i1", "i2", "i3", "i4", "i5", "headerprotectionkey", "contentpaddingaddition", "rekeyaftertime", "rekeytimeout", "rejectaftertime", "keepalivetimeout", "maxhandshakeattempts" ])
        if (trim(as_string(fields[key] || "")) != "")
            return true;
    return awg_flag_enabled(fields.randomtrailers) || awg_flag_enabled(fields.disablecookies);
}

function wireguard_endpoint_from_fields(fields, tag_name) {
    fields = object_or_empty(fields);
    let private_key = wireguard_key(fields.privatekey);
    let public_key = wireguard_key(fields.publickey);
    let endpoint = trim(as_string(fields.endpoint || ""));
    let host_port = split_host_port(endpoint);
    let host = host_port[0];
    let port = parse_port(host_port[1]);
    if (private_key == "" || public_key == "" || host == "" || port == null) {
        let why = "Endpoint";
        if (private_key == "")
            why = "PrivateKey";
        else if (public_key == "")
            why = "PublicKey";
        runtime_generate_unsupported("manual WireGuard link is invalid: missing " + why);
    }

    let peer = {
        address: host,
        port: port,
        public_key: public_key,
        allowed_ips: wireguard_cidr_list(fields.allowedips, [ "0.0.0.0/0", "::/0" ])
    };
    let preshared = wireguard_key(fields.presharedkey);
    if (preshared != "")
        peer.pre_shared_key = preshared;
    if (trim(as_string(fields.keepalive || "")) != "" && match(trim(fields.keepalive), /^[0-9]+$/) != null)
        peer.persistent_keepalive_interval = int(fields.keepalive, 10);
    let reserved = wireguard_reserved(fields.reserved);
    if (reserved != null && !sing_box_is_extended())
        peer.reserved = reserved;

    let addresses = wireguard_cidr_list(fields.address, []);
    if (length(addresses) == 0)
        runtime_generate_unsupported("manual WireGuard link has no local address");

    let result = {
        type: "wireguard",
        tag: tag_name,
        system: false,
        address: addresses,
        private_key: private_key,
        peers: [ peer ],
        routing_mark: runtime_constants.OUTBOUND_MARK,
        domain_resolver: runtime_constants.BOOTSTRAP_DNS_SERVER_TAG
    };
    let awg = wireguard_has_awg(fields);
    if (awg && !runtime_supports_xhttp)
        runtime_generate_unsupported("AmneziaWG needs sing-box-extended");
    let mtu = trim(as_string(fields.mtu || ""));
    if (awg) {
        let mtu_value = match(mtu, /^[0-9]+$/) != null ? int(mtu, 10) : 0;
        result.mtu = mtu_value >= 576 && mtu_value <= 1500 ? mtu_value : 1280;
    }
    else if (match(mtu, /^[0-9]+$/) != null && int(mtu, 10) > 0) {
        result.mtu = int(mtu, 10);
    }
    let amnezia = {};
    let amnezia_set = false;
    for (let key in [ "jc", "jmin", "jmax", "s1", "s2", "s3", "s4" ]) {
        let value = trim(as_string(fields[key] || ""));
        if (match(value, /^[0-9]+$/) != null) {
            amnezia[key] = int(value, 10);
            amnezia_set = true;
        }
    }
    let range_names = {
        h1: "h1",
        h2: "h2",
        h3: "h3",
        h4: "h4",
        contentpaddingaddition: "content_padding_addition",
        rekeyaftertime: "rekey_after_time",
        rekeytimeout: "rekey_timeout",
        rejectaftertime: "reject_after_time",
        keepalivetimeout: "keepalive_timeout",
        maxhandshakeattempts: "max_handshake_attempts"
    };
    for (let key in range_names) {
        let value = trim(as_string(fields[key] || ""));
        if (match(value, /^[0-9]+$/) != null)
            amnezia[range_names[key]] = int(value, 10);
        else if (match(value, /^[0-9]+-[0-9]+$/) != null)
            amnezia[range_names[key]] = value;
        else
            continue;
        amnezia_set = true;
    }
    for (let key in [ "i1", "i2", "i3", "i4", "i5" ]) {
        let value = trim(as_string(fields[key] || ""));
        if (value != "") {
            amnezia[key] = value;
            amnezia_set = true;
        }
    }
    let protection = wireguard_key(fields.headerprotectionkey);
    if (protection != "") {
        amnezia.header_protection_key = protection;
        amnezia_set = true;
    }
    if (awg_flag_enabled(fields.randomtrailers)) {
        amnezia.random_trailers = true;
        amnezia_set = true;
    }
    if (awg_flag_enabled(fields.disablecookies)) {
        amnezia.disable_cookies = true;
        amnezia_set = true;
    }
    if (amnezia_set)
        result.amnezia = amnezia;
    if (trim(as_string(fields.listenport || "")) != "" && match(trim(fields.listenport), /^[0-9]+$/) != null) {
        let listen_port = int(fields.listenport, 10);
        if (listen_port >= 1 && listen_port <= 65535)
            result.listen_port = listen_port;
    }
    let awg_version = awg_version_from_fields(fields);
    if (awg_version != "")
        result.__protocol = "AmneziaWG " + awg_version;
    return result;
}

function bit_reader(data) {
    return { data: as_string(data), i: 0, n: length(as_string(data)), bit: 0 };
}

function bit_one(st) {
    if (st.i >= st.n)
        return -1;
    let value = (ord(substr(st.data, st.i, 1)) >> st.bit) & 1;
    st.bit++;
    if (st.bit == 8) {
        st.bit = 0;
        st.i++;
    }
    return value;
}

function bit_many(st, count) {
    let value = 0;
    let shift = 1;
    for (let n = 0; n < count; n++) {
        let bit = bit_one(st);
        if (bit < 0)
            return -1;
        if (bit)
            value += shift;
        shift *= 2;
    }
    return value;
}

function bit_align(st) {
    if (st.bit != 0) {
        st.bit = 0;
        st.i++;
    }
}

function huff_build(lengths) {
    let max_len = 0;
    for (let item in lengths)
        if (item > max_len)
            max_len = item;
    let counts = [];
    for (let i = 0; i <= max_len; i++)
        push(counts, 0);
    for (let item in lengths)
        if (item > 0)
            counts[item]++;
    let next = [ 0 ];
    let code = 0;
    for (let bits = 1; bits <= max_len; bits++) {
        code = (code + counts[bits - 1]) * 2;
        push(next, code);
    }
    let table = {};
    for (let sym = 0; sym < length(lengths); sym++) {
        let len = lengths[sym];
        if (len > 0) {
            if (type(table[len]) != "object")
                table[len] = {};
            table[len]["" + next[len]] = sym;
            next[len]++;
        }
    }
    return table;
}

function huff_decode(st, table) {
    let code = 0;
    for (let len = 1; len <= 15; len++) {
        let bit = bit_one(st);
        if (bit < 0)
            return -1;
        code = code * 2 + bit;
        if (type(table[len]) == "object" && table[len]["" + code] != null)
            return table[len]["" + code];
    }
    return -1;
}

function inflate_repeat(items, value, count) {
    for (let i = 0; i < count; i++)
        push(items, value);
}

function inflate_raw(data) {
    let length_base = [ 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258 ];
    let length_extra = [ 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0 ];
    let distance_base = [ 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577 ];
    let distance_extra = [ 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13 ];
    let code_order = [ 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 ];
    let st = bit_reader(data);
    let out = "";
    while (true) {
        let final_block = bit_one(st);
        let block_type = bit_many(st, 2);
        if (final_block < 0 || block_type < 0)
            return "";
        if (block_type == 0) {
            bit_align(st);
            let size = bit_many(st, 16);
            bit_many(st, 16);
            if (size < 0 || st.i + size > st.n)
                return "";
            out += substr(st.data, st.i, size);
            st.i += size;
        }
        else if (block_type == 1 || block_type == 2) {
            let literal;
            let distance;
            if (block_type == 1) {
                let literal_lengths = [];
                inflate_repeat(literal_lengths, 8, 144);
                inflate_repeat(literal_lengths, 9, 112);
                inflate_repeat(literal_lengths, 7, 24);
                inflate_repeat(literal_lengths, 8, 8);
                literal = huff_build(literal_lengths);
                let distance_lengths = [];
                inflate_repeat(distance_lengths, 5, 32);
                distance = huff_build(distance_lengths);
            }
            else {
                let literal_count = bit_many(st, 5) + 257;
                let distance_count = bit_many(st, 5) + 1;
                let code_count = bit_many(st, 4) + 4;
                if (literal_count < 257 || distance_count < 1 || code_count < 4)
                    return "";
                let code_lengths = [];
                inflate_repeat(code_lengths, 0, 19);
                for (let i = 0; i < code_count; i++)
                    code_lengths[code_order[i]] = bit_many(st, 3);
                let code_table = huff_build(code_lengths);
                let lengths = [];
                while (length(lengths) < literal_count + distance_count) {
                    let symbol = huff_decode(st, code_table);
                    if (symbol < 0)
                        return "";
                    if (symbol < 16) {
                        push(lengths, symbol);
                    }
                    else if (symbol == 16) {
                        if (length(lengths) == 0)
                            return "";
                        inflate_repeat(lengths, lengths[length(lengths) - 1], bit_many(st, 2) + 3);
                    }
                    else if (symbol == 17) {
                        inflate_repeat(lengths, 0, bit_many(st, 3) + 3);
                    }
                    else {
                        inflate_repeat(lengths, 0, bit_many(st, 7) + 11);
                    }
                }
                let literal_lengths = [];
                let distance_lengths = [];
                for (let i = 0; i < literal_count; i++)
                    push(literal_lengths, lengths[i]);
                for (let i = literal_count; i < literal_count + distance_count; i++)
                    push(distance_lengths, lengths[i]);
                literal = huff_build(literal_lengths);
                distance = huff_build(distance_lengths);
            }
            while (true) {
                let symbol = huff_decode(st, literal);
                if (symbol < 0)
                    return "";
                if (symbol < 256) {
                    out += chr(symbol);
                }
                else if (symbol == 256) {
                    break;
                }
                else {
                    let index = symbol - 257;
                    if (index < 0 || index >= length(length_base))
                        return "";
                    let extra = bit_many(st, length_extra[index]);
                    if (extra < 0)
                        return "";
                    let size = length_base[index] + extra;
                    let distance_symbol = huff_decode(st, distance);
                    if (distance_symbol < 0 || distance_symbol >= length(distance_base))
                        return "";
                    extra = bit_many(st, distance_extra[distance_symbol]);
                    if (extra < 0)
                        return "";
                    let dist = distance_base[distance_symbol] + extra;
                    if (dist <= 0 || dist > length(out))
                        return "";
                    for (let i = 0; i < size; i++)
                        out += substr(out, length(out) - dist, 1);
                }
            }
        }
        else {
            return "";
        }
        if (final_block)
            break;
    }
    return out;
}

function inflate_zlib(data) {
    data = as_string(data);
    if (length(data) >= 2 && (ord(substr(data, 0, 1)) & 15) == 8) {
        let flags = ord(substr(data, 1, 1));
        data = substr(data, 2);
        if ((flags & 32) != 0)
            data = substr(data, 4);
    }
    return inflate_raw(data);
}

function vpn_walk_conf(value) {
    let stack = [ value ];
    let cursor = 0;
    while (cursor < length(stack)) {
        let item = stack[cursor];
        cursor++;
        if (type(item) == "string") {
            let lower = lc(item);
            if (index(lower, "[interface]") >= 0 && index(lower, "[peer]") >= 0)
                return item;
        }
        else if (type(item) == "array") {
            for (let child in item)
                push(stack, child);
        }
        else if (type(item) == "object" && item != null) {
            for (let key in item)
                push(stack, item[key]);
        }
    }
    return "";
}

function vpn_ini_slice(text) {
    text = trim(as_string(text));
    let lower = lc(text);
    let at = index(lower, "[interface]");
    if (at < 0 || index(lower, "[peer]") < 0)
        return "";
    return trim(substr(text, at));
}

function vpn_conf_text(text) {
    text = trim(as_string(text));
    if (text == "")
        return "";
    if (substr(text, 0, 1) == "{") {
        try {
            let inner = json(text);
            if (type(inner) == "object") {
                let config = vpn_ini_slice(inner.config);
                if (config != "")
                    return config;
            }
        }
        catch (e) {
        }
    }
    return vpn_ini_slice(text);
}

function vpn_fold(key) {
    return lc(replace(as_string(key), /_/g, ""));
}

function vpn_take(bag, key, value, force) {
    value = trim(as_string(value));
    if (value == "" || lc(value) == "null")
        return;
    if (force && bag["lock_" + key])
        return;
    if (!force && trim(as_string(bag[key] || "")) != "")
        return;
    bag[key] = value;
    if (force)
        bag["lock_" + key] = 1;
}

function vpn_collect(root, bag) {
    let names = {
        clientprivkey: "privatekey",
        clientprivatekey: "privatekey",
        serverpubkey: "publickey",
        serverpublickey: "publickey",
        pskkey: "presharedkey",
        presharedkey: "presharedkey",
        psk: "presharedkey",
        clientip: "address",
        clientaddress: "address",
        allowedips: "allowedips",
        hostname: "host",
        serverip: "host",
        serveraddress: "host",
        port: "port",
        endpoint: "endpoint",
        mtu: "mtu",
        persistentkeepalive: "keepalive",
        junkpacketcount: "jc",
        jc: "jc",
        junkpacketminsize: "jmin",
        jmin: "jmin",
        junkpacketmaxsize: "jmax",
        jmax: "jmax",
        initpacketjunksize: "s1",
        s1: "s1",
        responsepacketjunksize: "s2",
        s2: "s2",
        cookiereplypacketjunksize: "s3",
        s3: "s3",
        transportpacketjunksize: "s4",
        s4: "s4",
        initpacketmagicheader: "h1",
        h1: "h1",
        responsepacketmagicheader: "h2",
        h2: "h2",
        underloadpacketmagicheader: "h3",
        h3: "h3",
        transportpacketmagicheader: "h4",
        h4: "h4",
        specialjunk1: "i1",
        i1: "i1",
        specialjunk2: "i2",
        i2: "i2",
        specialjunk3: "i3",
        i3: "i3",
        specialjunk4: "i4",
        i4: "i4",
        specialjunk5: "i5",
        i5: "i5",
        headerprotectionkey: "headerprotectionkey",
        contentpaddingaddition: "contentpaddingaddition",
        rekeyaftertime: "rekeyaftertime",
        rekeytimeout: "rekeytimeout",
        rejectaftertime: "rejectaftertime",
        keepalivetimeout: "keepalivetimeout",
        maxhandshakeattempts: "maxhandshakeattempts",
        randomtrailers: "randomtrailers",
        disablecookies: "disablecookies"
    };
    let stack = [ root ];
    let cursor = 0;
    while (cursor < length(stack)) {
        let value = stack[cursor];
        cursor++;
        if (type(value) == "array") {
            for (let child in value)
                push(stack, child);
            continue;
        }
        if (type(value) != "object" || value == null)
            continue;
        let wg_object = false;
        for (let key in value) {
            let folded = vpn_fold(key);
            if (folded == "clientprivkey" || folded == "clientprivatekey" || folded == "serverpubkey" || folded == "serverpublickey" || folded == "privatekey" || folded == "jc" || folded == "lastconfig")
                wg_object = true;
        }
        for (let key in value) {
            let child = value[key];
            let mapped = names[vpn_fold(key)];
            if (type(child) == "array") {
                if (mapped == "allowedips") {
                    let parts = [];
                    for (let item in child) {
                        if (type(item) == "object" || type(item) == "array")
                            continue;
                        let text = trim(as_string(item));
                        if (text != "")
                            push(parts, text);
                    }
                    if (length(parts) > 0)
                        vpn_take(bag, "allowedips", join(", ", parts), wg_object);
                }
                continue;
            }
            if (type(child) == "object")
                continue;
            if (mapped != null)
                vpn_take(bag, mapped, child, wg_object);
        }
        for (let key in value) {
            let child = value[key];
            if (type(child) == "object" || type(child) == "array")
                push(stack, child);
            else if (type(child) == "string" && substr(trim(child), 0, 1) == "{") {
                try {
                    push(stack, json(child));
                }
                catch (e) {
                }
            }
        }
    }
}

function vpn_synth_conf(data) {
    let bag = {};
    vpn_collect(data, bag);
    let private_key = trim(as_string(bag.privatekey || ""));
    let public_key = trim(as_string(bag.publickey || ""));
    let host = trim(as_string(bag.host || ""));
    let port = trim(as_string(bag.port || ""));
    if ((host == "" || port == "") && index(as_string(bag.endpoint || ""), ":") >= 0) {
        let parts = split_host_port(bag.endpoint);
        if (host == "")
            host = trim(as_string(parts[0] || ""));
        if (port == "")
            port = trim(as_string(parts[1] || ""));
    }
    let address = trim(as_string(bag.address || ""));
    if (private_key == "" || public_key == "" || host == "" || port == "" || address == "")
        return "";
    let labels = {
        mtu: "MTU",
        jc: "Jc",
        jmin: "Jmin",
        jmax: "Jmax",
        s1: "S1",
        s2: "S2",
        s3: "S3",
        s4: "S4",
        h1: "H1",
        h2: "H2",
        h3: "H3",
        h4: "H4",
        i1: "I1",
        i2: "I2",
        i3: "I3",
        i4: "I4",
        i5: "I5",
        headerprotectionkey: "HeaderProtectionKey",
        contentpaddingaddition: "ContentPaddingAddition",
        rekeyaftertime: "RekeyAfterTime",
        rekeytimeout: "RekeyTimeout",
        rejectaftertime: "RejectAfterTime",
        keepalivetimeout: "KeepaliveTimeout",
        maxhandshakeattempts: "MaxHandshakeAttempts",
        randomtrailers: "RandomTrailers",
        disablecookies: "DisableCookies"
    };
    let lines = [ "[Interface]", "PrivateKey = " + private_key, "Address = " + address ];
    for (let key in labels) {
        let value = trim(as_string(bag[key] || ""));
        if (value != "")
            push(lines, labels[key] + " = " + value);
    }
    push(lines, "[Peer]");
    push(lines, "PublicKey = " + public_key);
    let psk = trim(as_string(bag.presharedkey || ""));
    if (psk != "")
        push(lines, "PresharedKey = " + psk);
    let allowed = trim(as_string(bag.allowedips || ""));
    if (allowed == "")
        allowed = "0.0.0.0/0, ::/0";
    push(lines, "AllowedIPs = " + allowed);
    push(lines, "Endpoint = " + host + ":" + port);
    let keep = trim(as_string(bag.keepalive || ""));
    if (keep != "")
        push(lines, "PersistentKeepalive = " + keep);
    return join("\n", lines);
}

function vpn_apply_placeholders(conf, data, extra) {
    conf = as_string(conf);
    if (index(conf, "$") < 0)
        return conf;
    let bag = {};
    vpn_collect(data, bag);
    extra = object_or_empty(extra);
    for (let key in extra) {
        let value = trim(as_string(extra[key] || ""));
        if (value != "")
            bag[key] = value;
    }
    let host = trim(as_string(bag.host || ""));
    let port = trim(as_string(bag.port || ""));
    if ((host == "" || port == "") && index(as_string(bag.endpoint || ""), ":") >= 0) {
        let parts = split_host_port(bag.endpoint);
        if (host == "")
            host = trim(as_string(parts[0] || ""));
        if (port == "")
            port = trim(as_string(parts[1] || ""));
    }
    let address = trim(as_string(bag.address || ""));
    let client_ip = address;
    let cidr = index(address, ":") >= 0 ? "128" : "32";
    let slash = index(address, "/");
    if (slash >= 0) {
        client_ip = substr(address, 0, slash);
        cidr = substr(address, slash + 1);
    }
    if (trim(as_string(bag.privatekey || "")) != "")
        conf = replace(conf, /\$WIREGUARD_CLIENT_PRIVATE_KEY/g, bag.privatekey);
    if (trim(as_string(bag.publickey || "")) != "")
        conf = replace(conf, /\$WIREGUARD_SERVER_PUBLIC_KEY/g, bag.publickey);
    if (trim(as_string(bag.presharedkey || "")) != "")
        conf = replace(conf, /\$WIREGUARD_PSK/g, bag.presharedkey);
    if (client_ip != "") {
        conf = replace(conf, /\$WIREGUARD_CLIENT_IP/g, client_ip);
        conf = replace(conf, /\$AWG_CLIENT_IP/g, client_ip);
    }
    if (cidr != "")
        conf = replace(conf, /\$WIREGUARD_SUBNET_CIDR/g, cidr);
    if (host != "") {
        conf = replace(conf, /\$WIREGUARD_SERVER_IP/g, host);
        conf = replace(conf, /\$AWG_SERVER_IP/g, host);
        conf = replace(conf, /\$SERVER_IP_ADDRESS/g, host);
        conf = replace(conf, /\$SERVER_ADDRESS/g, host);
    }
    if (port != "") {
        conf = replace(conf, /\$WIREGUARD_SERVER_PORT/g, port);
        conf = replace(conf, /\$AWG_SERVER_PORT/g, port);
    }
    if (trim(as_string(bag.keepalive || "")) != "")
        conf = replace(conf, /\$PERSISTENT_KEEPALIVE/g, bag.keepalive);
    if (trim(as_string(bag.jc || "")) != "")
        conf = replace(conf, /\$JUNK_PACKET_COUNT/g, bag.jc);
    if (trim(as_string(bag.jmin || "")) != "")
        conf = replace(conf, /\$JUNK_PACKET_MIN_SIZE/g, bag.jmin);
    if (trim(as_string(bag.jmax || "")) != "")
        conf = replace(conf, /\$JUNK_PACKET_MAX_SIZE/g, bag.jmax);
    if (trim(as_string(bag.s1 || "")) != "")
        conf = replace(conf, /\$INIT_PACKET_JUNK_SIZE/g, bag.s1);
    if (trim(as_string(bag.s2 || "")) != "")
        conf = replace(conf, /\$RESPONSE_PACKET_JUNK_SIZE/g, bag.s2);
    if (trim(as_string(bag.s3 || "")) != "")
        conf = replace(conf, /\$COOKIE_REPLY_PACKET_JUNK_SIZE/g, bag.s3);
    if (trim(as_string(bag.s4 || "")) != "")
        conf = replace(conf, /\$TRANSPORT_PACKET_JUNK_SIZE/g, bag.s4);
    if (trim(as_string(bag.h1 || "")) != "")
        conf = replace(conf, /\$INIT_PACKET_MAGIC_HEADER/g, bag.h1);
    if (trim(as_string(bag.h2 || "")) != "")
        conf = replace(conf, /\$RESPONSE_PACKET_MAGIC_HEADER/g, bag.h2);
    if (trim(as_string(bag.h3 || "")) != "")
        conf = replace(conf, /\$UNDERLOAD_PACKET_MAGIC_HEADER/g, bag.h3);
    if (trim(as_string(bag.h4 || "")) != "")
        conf = replace(conf, /\$TRANSPORT_PACKET_MAGIC_HEADER/g, bag.h4);
    return conf;
}

function vpn_conf_complete(conf) {
    conf = as_string(conf);
    if (index(lc(conf), "[interface]") < 0 || index(lc(conf), "[peer]") < 0)
        return false;
    let fields = wireguard_fields_from_conf(conf);
    if (index(as_string(fields.privatekey || ""), "$") >= 0 || index(as_string(fields.publickey || ""), "$") >= 0)
        return false;
    if (index(as_string(fields.address || ""), "$") >= 0 || index(as_string(fields.endpoint || ""), "$") >= 0)
        return false;
    return trim(as_string(fields.privatekey || "")) != "" && trim(as_string(fields.publickey || "")) != "" && trim(as_string(fields.address || "")) != "" && trim(as_string(fields.endpoint || "")) != "";
}

let vpn_last_error = "";

function vpn_quote(value) {
    return "'" + replace(as_string(value), /'/g, "'\\''") + "'";
}

function vpn_new_keypair() {
    let script_path = "/tmp/forkop/vpn-keygen.sh";
    let path = "/tmp/forkop/vpn-keygen.out";
    system("mkdir -p /tmp/forkop");
    fs.writefile(script_path, "#!/bin/sh\npriv=\npub=\nif command -v wg >/dev/null 2>&1; then\n priv=$(wg genkey)\n pub=$(printf '%s' \"$priv\" | wg pubkey)\nelif command -v awg >/dev/null 2>&1; then\n priv=$(awg genkey)\n pub=$(printf '%s' \"$priv\" | awg pubkey)\nelif command -v openssl >/dev/null 2>&1; then\n pem=/tmp/forkop/vpn-x25519.pem\n openssl genpkey -algorithm X25519 -out \"$pem\" >/dev/null 2>&1\n priv=$(openssl pkey -in \"$pem\" -outform DER 2>/dev/null | tail -c 32 | base64 | tr -d '\\n')\n pub=$(openssl pkey -in \"$pem\" -pubout -outform DER 2>/dev/null | tail -c 32 | base64 | tr -d '\\n')\n rm -f \"$pem\"\nfi\nprintf '%s\\n%s\\n' \"$priv\" \"$pub\"\n");
    system("sh " + vpn_quote(script_path) + " > " + vpn_quote(path) + " 2>/dev/null");
    let lines = split(trim(as_string(fs.readfile(path) || "")), "\n");
    if (length(lines) < 2)
        return null;
    let private_key = trim(lines[0]);
    let public_key = trim(lines[1]);
    if (length(private_key) < 40 || length(public_key) < 40)
        return null;
    return { private: private_key, public: public_key };
}

function vpn_keypair(endpoint) {
    let path = "/etc/forkop/vpn-api-keys.json";
    let all = null;
    try {
        all = json(fs.readfile(path));
    }
    catch (e) {
        all = null;
    }
    if (type(all) != "object" || all == null)
        all = {};
    let saved = all[endpoint];
    if (type(saved) == "object" && length(trim(as_string(saved.private || ""))) >= 40 && length(trim(as_string(saved.public || ""))) >= 40)
        return saved;
    let created = vpn_new_keypair();
    if (created == null)
        return null;
    all[endpoint] = created;
    system("mkdir -p /etc/forkop");
    fs.writefile(path, sprintf("%J\n", all));
    return created;
}

function vpn_http_post(url, body, header_value) {
    let out = "/tmp/forkop/vpn-api.out";
    system("mkdir -p /tmp/forkop");
    system("rm -f " + vpn_quote(out));
    let content = "Content-Type: application/json";
    let auth = "Authorization: Api-Key " + header_value;
    let cmd = "if command -v curl >/dev/null 2>&1; then curl -fsS --max-time 20 -o " + vpn_quote(out) +
        " -H " + vpn_quote(content) + " -H " + vpn_quote(auth) + " --data " + vpn_quote(body) + " " + vpn_quote(url) +
        "; elif command -v uclient-fetch >/dev/null 2>&1; then uclient-fetch -q -T 20 -O " + vpn_quote(out) +
        " --header=" + vpn_quote(content) + " --header=" + vpn_quote(auth) + " --post-data=" + vpn_quote(body) + " " + vpn_quote(url) +
        "; elif command -v wget >/dev/null 2>&1; then wget -q -T 20 -O " + vpn_quote(out) +
        " --header=" + vpn_quote(content) + " --header=" + vpn_quote(auth) + " --post-data=" + vpn_quote(body) + " " + vpn_quote(url) +
        "; else exit 1; fi";
    if (system(cmd + " >/dev/null 2>&1") != 0)
        return "";
    return as_string(fs.readfile(out) || "");
}
function vpn_protocol_blob(container) {
    if (type(container) != "object" || container == null)
        return null;
    let name = lc(as_string(container.container || ""));
    if (index(name, "awg") >= 0 && type(container.awg) == "object")
        return container.awg;
    if (index(name, "wireguard") >= 0 && type(container.wireguard) == "object")
        return container.wireguard;
    if (type(container.awg) == "object")
        return container.awg;
    if (type(container.wireguard) == "object")
        return container.wireguard;
    return null;
}

function vpn_blob_conf(blob) {
    if (type(blob) != "object" || blob == null)
        return "";
    let last = blob.last_config;
    if (type(last) == "object") {
        let inner = vpn_conf_text(last.config);
        if (inner == "")
            inner = vpn_synth_conf(last);
        return inner;
    }
    last = trim(as_string(last || ""));
    if (last == "")
        return vpn_synth_conf(blob);
    let conf = vpn_conf_text(last);
    if (conf == "")
        conf = vpn_synth_conf(blob);
    return conf;
}

function vpn_choose_container(data) {
    if (type(data) != "object" || data == null || type(data.containers) != "array")
        return null;
    let want = lc(as_string(data.defaultContainer || ""));
    let fallback = null;
    for (let container in data.containers) {
        if (type(container) != "object")
            continue;
        let blob = vpn_protocol_blob(container);
        if (blob == null)
            continue;
        let name = lc(as_string(container.container || ""));
        if (want != "" && name == want)
            return blob;
        if (fallback == null)
            fallback = blob;
    }
    return fallback;
}

function vpn_merge_version_fields(conf, data) {
    conf = as_string(conf);
    if (conf == "" || data == null)
        return conf;
    let bag = {};
    vpn_collect(data, bag);
    let labels = {
        randomtrailers: "RandomTrailers",
        disablecookies: "DisableCookies"
    };
    let lower = lc(conf);
    let lines = [];
    for (let key in labels) {
        let value = trim(as_string(bag[key] || ""));
        if (value == "" || index(lower, lc(labels[key])) >= 0)
            continue;
        push(lines, labels[key] + " = " + value);
    }
    if (length(lines) == 0)
        return conf;
    let at = index(lower, "[peer]");
    if (at < 0)
        return conf + "\n" + join("\n", lines);
    return trim(substr(conf, 0, at)) + "\n" + join("\n", lines) + "\n" + substr(conf, at);
}

function vpn_finish_conf(conf, primary, fallback) {
    conf = vpn_apply_placeholders(conf, primary, {});
    if (!vpn_conf_complete(conf) && fallback != null)
        conf = vpn_apply_placeholders(conf, fallback, {});
    if (vpn_conf_complete(conf))
        return vpn_merge_version_fields(vpn_merge_version_fields(conf, primary), fallback);
    let synth = vpn_apply_placeholders(vpn_synth_conf(primary), primary, {});
    if (!vpn_conf_complete(synth) && fallback != null)
        synth = vpn_apply_placeholders(synth, fallback, {});
    return vpn_conf_complete(synth) ? vpn_merge_version_fields(vpn_merge_version_fields(synth, primary), fallback) : "";
}

function vpn_link_conf(link, allow_api) {
    function vpn_api_conf(data) {
        if (type(data) != "object" || data == null)
            return "";
        let endpoint = trim(as_string(data.api_endpoint || data.apiEndpoint || ""));
        let api_key = trim(as_string(data.api_key || data.apiKey || ""));
        if (endpoint == "" || api_key == "")
            return "";
        let keys = vpn_keypair(endpoint);
        if (keys == null) {
            vpn_last_error = "vpn:// API link needs wg or openssl to create a WireGuard key";
            return "";
        }
        let uuid = trim(as_string(fs.readfile("/proc/sys/kernel/random/uuid") || ""));
        if (uuid == "")
            uuid = "forkop-router";
        let body = sprintf("%J", {
            public_key: keys.public,
            os_version: "linux",
            app_version: "4.8.12.9",
            uuid: uuid
        });
        let response = trim(vpn_http_post(endpoint, body, api_key));
        if (response == "") {
            vpn_last_error = "vpn:// API did not answer";
            return "";
        }
        let payload = response;
        if (substr(payload, 0, 1) == "{") {
            try {
                let parsed = json(payload);
                let config = trim(as_string(parsed.config || ""));
                if (config == "" && type(parsed.client) == "object")
                    config = trim(as_string(parsed.client.config || ""));
                if (config != "")
                    payload = config;
            }
            catch (e) {
            }
        }
        let conf = "";
        if (substr(lc(payload), 0, 6) == "vpn://")
            conf = vpn_link_conf(payload, false);
        else
            conf = payload;
        conf = vpn_apply_placeholders(conf, {}, { privatekey: keys.private });
        if (!vpn_conf_complete(conf)) {
            vpn_last_error = "vpn:// API answer has no WireGuard or AmneziaWG config";
            return "";
        }
        return conf;
    }

    if (allow_api == null)
        allow_api = true;
    let body = url_strip_fragment_value(link);
    let marker = index(body, "://");
    body = marker >= 0 ? substr(body, marker + 3) : body;
    let raw = base64_decode_value(body);
    if (raw == null || length(raw) < 6)
        return "";
    let plain = vpn_conf_text(raw);
    if (vpn_conf_complete(plain))
        return plain;
    let text = inflate_zlib(substr(raw, 4));
    if (vpn_conf_text(text) == "" && index(text, "{") < 0)
        text = inflate_zlib(raw);
    if (text == "" || (vpn_conf_text(text) == "" && index(text, "{") < 0)) {
        let trimmed = trim(raw);
        if (substr(trimmed, 0, 1) == "{" || substr(trimmed, 0, 1) == "[")
            text = trimmed;
    }
    if (text == "")
        return "";
    let direct = vpn_conf_text(text);
    if (vpn_conf_complete(direct))
        return direct;
    let data;
    try {
        data = json(text);
    }
    catch (e) {
        return "";
    }
    if (type(data) != "object" && type(data) != "array")
        return "";
    let chosen = vpn_choose_container(data);
    let conf = chosen != null ? vpn_blob_conf(chosen) : "";
    if (conf == "")
        conf = vpn_conf_text(vpn_walk_conf(data));
    if (conf == "")
        conf = vpn_synth_conf(data);
    let ready = vpn_finish_conf(conf, chosen != null ? chosen : data, data);
    if (ready != "")
        return ready;
    if (allow_api) {
        let fetched = vpn_api_conf(data);
        if (vpn_conf_complete(fetched))
            return fetched;
    }
    return "";
}

function manual_wireguard_endpoint(link, tag_name) {
    if (!sing_box_at_least_1_11())
        runtime_generate_unsupported("WireGuard needs sing-box 1.11 or newer");
    if (url_scheme(link) == "vpn") {
        let unpacked = vpn_link_conf(link, true);
        if (unpacked == "")
            runtime_generate_unsupported(vpn_last_error != "" ? vpn_last_error : "vpn:// link could not be unpacked or has no WireGuard config");
        return wireguard_endpoint_from_fields(wireguard_fields_from_conf(unpacked), tag_name);
    }
    let conf = wireguard_conf_text(link);
    let fields = conf != "" ? wireguard_fields_from_conf(conf) : wireguard_fields_from_uri(link);
    return wireguard_endpoint_from_fields(fields, tag_name);
}

function manual_link_outbound(link, tag_name) {
    let scheme = url_scheme(link);
    if (scheme == "vmess")
        return manual_vmess_outbound(link, tag_name);

    link = url_strip_fragment_value(url_decode(link));
    scheme = url_scheme(link);
    if (scheme == "socks4" || scheme == "socks4a" || scheme == "socks5")
        return manual_socks_outbound(link, tag_name);
    if (scheme == "ss")
        return manual_shadowsocks_outbound(link, tag_name);
    if (scheme == "vless")
        return manual_vless_outbound(link, tag_name);
    if (scheme == "trojan")
        return manual_trojan_outbound(link, tag_name);
    if (scheme == "hysteria2" || scheme == "hy2")
        return manual_hysteria2_outbound(link, tag_name);
    runtime_generate_unsupported("manual proxy link scheme is not supported by sing-box config generation yet");
}
function connection_item_tag(section_name, kind, item_index) {
    return outbound_tag(section_name + "-" + as_string(kind) + "-" + item_index);
}

function add_connection_subscriptions(config, state, section, taken, selector_tags, urltest_candidate_tags) {
    let subscription_urls = connections.subscription_urls(section);

    for (let i = 0; i < length(subscription_urls); i++)
        add_subscription_source_with_state(
            config,
            section,
            i + 1,
            subscription_urls[i],
            taken,
            selector_tags,
            urltest_candidate_tags,
            state,
            connections.subscription_dashboard_metadata_enabled(section, subscription_urls[i]),
            connections.subscription_include_urltest_groups(section, subscription_urls[i]),
            connections.subscription_hide_urltest_group_outbounds(section, subscription_urls[i]),
            connections.subscription_hide_detour_outbounds(section, subscription_urls[i]),
            connections.subscription_node_prefix(section, subscription_urls[i])
        );
}

function add_interface_connection_outbound(config, state, section, interface_index, interface_name, taken, selector_tags, urltest_candidate_tags) {
    let section_name = section[".name"];
    let tag_name = connection_item_tag(section_name, "interface", interface_index);
    if (taken[tag_name])
        tag_name = unique_tag(tag_name, taken);
    taken[tag_name] = true;

    let domain_resolver = "";
    if (connections.interface_domain_resolver_enabled(section, interface_name)) {
        domain_resolver = runtime_constants.domain_resolver_tag(section_name + "-interface-" + interface_index);
        let dns_server = runtime_dns.server_from_options(
            domain_resolver,
            connections.interface_domain_resolver_dns_type(section, interface_name),
            connections.interface_domain_resolver_dns_server(section, interface_name),
            tag_name
        );
        if (dns_server.unsupported)
            runtime_generate_unsupported(dns_server.unsupported);
        push(config.dns.servers, dns_server);
    }

    let outbound = {
        type: "direct",
        tag: tag_name,
        bind_interface: interface_name,
        domain_resolver,
        routing_mark: runtime_constants.OUTBOUND_MARK
    };
    if (domain_resolver == "")
        delete outbound.domain_resolver;

    push(config.outbounds, outbound);
    push(selector_tags, tag_name);
    push(urltest_candidate_tags, tag_name);
    runtime_subscription.remember_outbound_metadata(state, tag_name, interface_name, outbound);
}

function add_connection_interfaces(config, state, section, taken, selector_tags, urltest_candidate_tags) {
    let items = connections.interfaces(section);
    for (let i = 0; i < length(items); i++)
        add_interface_connection_outbound(config, state, section, i + 1, items[i], taken, selector_tags, urltest_candidate_tags);
}

function openconnect_peer_fingerprint(value) {
    value = trim(as_string(value));
    value = replace(value, /[ \t]/g, "");
    if (value == "")
        return "";
    let lower = lc(value);
    if (substr(lower, 0, 11) == "pin-sha256:")
        return value;
    return replace(value, /:/g, "");
}

function openconnect_flavor(section) {
    let flavor = lc(option(section, "flavor", ""));
    if (flavor == "")
        flavor = lc(option(section, "openconnect_flavor", "anyconnect"));
    for (let item in [ "anyconnect", "gp", "fortinet", "f5", "pulse", "nc" ])
        if (item == flavor)
            return flavor;
    return "anyconnect";
}

function openconnect_shell_quote(value) {
    return "'" + replace(as_string(value), /'/g, "'\\''") + "'";
}

function openconnect_is_ipv4(value) {
    return match(trim(as_string(value)), /^[0-9]+(\.[0-9]+){3}$/) != null;
}

function openconnect_server_target(value) {
    value = trim(as_string(value));
    value = replace(value, /^[A-Za-z][A-Za-z0-9+.-]*:\/\//, "");
    let slash = index(value, "/");
    if (slash >= 0)
        value = substr(value, 0, slash);
    let host = value;
    let port = "";
    let matched = match(value, /^(.*):([0-9]+)$/);
    if (matched) {
        let parsed_port = int(matched[2], 10);
        if (parsed_port > 0 && parsed_port < 65536) {
            host = matched[1];
            port = as_string(parsed_port);
        }
    }
    return { host: host, port: port };
}

function openconnect_bootstrap_resolvers() {
    let resolvers = [];
    for (let value in list_option(runtime_settings(), "bootstrap_dns_server")) {
        value = trim(as_string(value));
        let hash = index(value, "#");
        if (hash >= 0)
            value = substr(value, 0, hash);
        value = replace(value, /^[A-Za-z][A-Za-z0-9+.-]*:\/\//, "");
        if (openconnect_is_ipv4(value))
            push(resolvers, value);
    }
    if (length(resolvers) == 0)
        push(resolvers, "77.88.8.8");
    return resolvers;
}

function openconnect_nslookup_ipv4(host, resolver) {
    let stamp = clock();
    let path = sprintf("/tmp/forkop/oc-dns-%d-%d.out", stamp[0], stamp[1]);
    system("mkdir -p /tmp/forkop");
    system(
        "nslookup " + openconnect_shell_quote(host) + " " + openconnect_shell_quote(resolver) +
        " </dev/null >" + openconnect_shell_quote(path) + " 2>/dev/null & " +
        "pid=$!; i=0; " +
        "while [ \"$i\" -lt 5 ]; do kill -0 \"$pid\" 2>/dev/null || break; sleep 1; i=$((i+1)); done; " +
        "kill \"$pid\" 2>/dev/null; wait \"$pid\" 2>/dev/null"
    );
    let raw = "";
    try {
        raw = fs.readfile(path);
    }
    catch (e) {
        raw = "";
    }
    fs.unlink(path);
    for (let ip in hostresolve.parse_nslookup(raw, resolver))
        if (openconnect_is_ipv4(ip))
            return ip;
    return "";
}

function openconnect_direct_ipv4(host, attempts) {
    host = lc(trim(host));
    if (openconnect_is_ipv4(host))
        return host;
    if (host == "" || match(host, /^[a-z0-9._-]+$/) == null)
        return "";

    let limit = int(attempts || 0);
    if (limit <= 0)
        limit = 4;
    let tries = 0;
    while (tries < limit) {
        for (let resolver in openconnect_bootstrap_resolvers()) {
            let ip = openconnect_nslookup_ipv4(host, resolver);
            if (ip != "")
                return ip;
        }
        tries++;
        if (tries < limit)
            system("sleep 2");
    }
    return "";
}

function openconnect_log(message) {
    system("logger -t forkop " + openconnect_shell_quote("[error] " + as_string(message)) + " >/dev/null 2>&1");
}

function openconnect_notice(message) {
    system("logger -t forkop " + openconnect_shell_quote("[info] " + as_string(message)) + " >/dev/null 2>&1");
}

function openconnect_parse_cookie(raw) {
    for (let line in split(as_string(raw), "\n")) {
        line = trim(line);
        let matched = match(line, /^COOKIE=(.*)$/);
        if (!matched)
            continue;
        let value = trim(matched[1]);
        let quote = substr(value, 0, 1);
        if ((quote == "'" || quote == "\"") && substr(value, -1) == quote && length(value) >= 2)
            value = substr(value, 1, length(value) - 2);
        return trim(value);
    }
    return "";
}

function openconnect_parse_sha(raw) {
    for (let line in split(as_string(raw), "\n")) {
        let pin = match(line, /pin-sha256:[A-Za-z0-9+/=]+/);
        if (pin)
            return openconnect_peer_fingerprint(pin[0]);
        let labeled = match(line, /SHA256:[ \t]*([0-9A-Fa-f:]+)/);
        if (labeled && length(replace(labeled[1], /:/g, "")) >= 32)
            return openconnect_peer_fingerprint(labeled[1]);
        let plain = match(line, /sha256:([0-9A-Fa-f]+)/);
        if (plain && length(plain[1]) >= 32)
            return openconnect_peer_fingerprint(plain[1]);
    }
    return "";
}

function openconnect_peer_key(server) {
    return lc(trim(as_string(server)));
}

function openconnect_peer_store() {
    let parsed = null;
    try {
        parsed = json(fs.readfile("/etc/forkop/oc-peer.json"));
    }
    catch (e) {
        parsed = null;
    }
    if (type(parsed) != "object" || parsed == null)
        return {};
    return parsed;
}

function openconnect_peer_get(server) {
    let item = openconnect_peer_store()[openconnect_peer_key(server)];
    if (type(item) != "object" || item == null)
        return {};
    return item;
}

function openconnect_peer_put(server, patch) {
    let key = openconnect_peer_key(server);
    if (key == "")
        return;
    let all = openconnect_peer_store();
    let item = all[key];
    if (type(item) != "object" || item == null)
        item = {};
    patch = object_or_empty(patch);
    for (let field in patch)
        item[field] = patch[field];
    all[key] = item;
    system("mkdir -p /etc/forkop >/dev/null 2>&1");
    fs.writefile("/etc/forkop/oc-peer.json", sprintf("%J\n", all));
}

function openconnect_cookie_auto(client) {
    return bool_option(client, "cookie_auto", true);
}

let openconnect_dns_deadline = 0;

function openconnect_saved_ipv4(host) {
    let saved = trim(as_string(openconnect_peer_get(lc(trim(host))).ip || ""));
    if (!openconnect_is_ipv4(saved))
        return "";
    return saved;
}

function openconnect_remember_ipv4(host, ip) {
    host = lc(trim(host));
    ip = trim(as_string(ip));
    if (host == "" || openconnect_is_ipv4(host) || !openconnect_is_ipv4(ip))
        return;
    openconnect_peer_put(host, { ip: ip });
}

function openconnect_resolve_ipv4(host, label) {
    host = lc(trim(host));
    if (openconnect_is_ipv4(host))
        return host;
    if (host == "" || match(host, /^[a-z0-9._-]+$/) == null)
        return "";
    let ip = openconnect_direct_ipv4(host, 1);
    if (ip != "") {
        openconnect_remember_ipv4(host, ip);
        return ip;
    }
    let saved = openconnect_saved_ipv4(host);
    if (saved != "") {
        openconnect_notice("OpenConnect '" + label + "' is using the saved address " + saved + ".");
        return saved;
    }
    if (openconnect_dns_deadline == 0)
        openconnect_dns_deadline = clock()[0] + 60;
    while (clock()[0] < openconnect_dns_deadline) {
        ip = openconnect_direct_ipv4(host, 1);
        if (ip != "") {
            openconnect_remember_ipv4(host, ip);
            return ip;
        }
        if (clock()[0] + 3 >= openconnect_dns_deadline)
            break;
        system("sleep 3");
    }
    return "";
}

function openconnect_servercert(fingerprint) {
    fingerprint = trim(as_string(fingerprint));
    if (fingerprint == "")
        return "";
    let lower = lc(fingerprint);
    if (substr(lower, 0, 11) == "pin-sha256:" || substr(lower, 0, 7) == "sha256:")
        return fingerprint;
    return "sha256:" + fingerprint;
}

function openconnect_failure_text(raw, password) {
    let lines = [];
    for (let line in split(as_string(raw), "\n")) {
        if (index(line, "COOKIE=") >= 0)
            continue;
        if (password != "" && index(line, password) >= 0)
            line = replace(line, password, "***");
        line = trim(line);
        if (line != "")
            push(lines, line);
    }
    let reason = join(" ", lines);
    if (length(reason) > 180)
        reason = substr(reason, 0, 180);
    return reason;
}

function openconnect_port_from_map(path, name) {
    let parsed = null;
    try {
        parsed = json(fs.readfile(path));
    }
    catch (e) {
        return 0;
    }
    if (type(parsed) != "object" || parsed == null)
        return 0;
    let port = int(parsed[name] || 0);
    if (port <= 0 || port >= 65536)
        return 0;
    return port;
}

function openconnect_port_listening(port) {
    port = int(port || 0);
    if (port <= 0)
        return false;
    let needle = ":" + sprintf("%04X", port);
    for (let path in [ "/proc/net/tcp", "/proc/net/tcp6" ]) {
        let data = fs.readfile(path);
        if (data == null)
            continue;
        for (let line in split(as_string(data), "\n")) {
            if (index(line, needle) < 0)
                continue;
            if (match(line, /[ \t]0A[ \t]/) != null)
                return true;
        }
    }
    return false;
}

function openconnect_detour_socks_port(section) {
    let name = trim(option(section, "outbound_detour_section", ""));
    if (name == "")
        return 0;
    let cascade = openconnect_port_from_map("/var/run/forkop/openconnect-cascade.json", name);
    if (cascade > 0 && openconnect_port_listening(cascade))
        return cascade;
    let port = openconnect_port_from_map("/var/run/forkop/xray-ports.json", name);
    if (port <= 0)
        return 0;
    let attempt = 0;
    while (attempt < 15) {
        if (openconnect_port_listening(port))
            return port;
        system("sleep 1");
        attempt++;
    }
    return openconnect_port_listening(port) ? port : 0;
}

function openconnect_duration(value) {
    value = trim(as_string(value));
    if (match(value, /^[0-9]+(ms|s|m|h)$/) == null)
        return "";
    return value;
}

function openconnect_cookie_worth_retry(raw) {
    let text = lc(as_string(raw));
    if (index(text, "authentication failed") >= 0)
        return false;
    if (index(text, "login failed") >= 0)
        return false;
    if (index(text, "invalid credentials") >= 0)
        return false;
    if (index(text, "auth failed") >= 0)
        return false;
    return true;
}

function openconnect_run_auth(server, username, password, auth_group, fingerprint, proxy_port, flavor, suffix, insecure) {
    let out_path = "/tmp/forkop/oc-auth-" + suffix + ".out";
    let pass_path = "/tmp/forkop/oc-auth-" + suffix + ".pass";
    system("mkdir -p /tmp/forkop");
    if (fs.writefile(pass_path, password + "\n") == null)
        return null;
    system("chmod 600 " + openconnect_shell_quote(pass_path) + " >/dev/null 2>&1");
    let protocol = trim(as_string(flavor));
    if (protocol == "")
        protocol = "anyconnect";
    let command = "openconnect --protocol=" + openconnect_shell_quote(protocol) +
        " --authenticate --non-inter --passwd-on-stdin --user=" +
        openconnect_shell_quote(username);
    if (trim(auth_group) != "")
        command += " --authgroup=" + openconnect_shell_quote(auth_group);
    let servercert = openconnect_servercert(fingerprint);
    if (servercert != "")
        command += " --servercert=" + openconnect_shell_quote(servercert);
    proxy_port = int(proxy_port || 0);
    if (proxy_port > 0)
        command += " --proxy=" + openconnect_shell_quote("socks5://127.0.0.1:" + proxy_port);
    command += " " + openconnect_shell_quote(server) +
        " <" + openconnect_shell_quote(pass_path) +
        " >" + openconnect_shell_quote(out_path) + " 2>&1 & " +
        "pid=$!; i=0; " +
        "while [ \"$i\" -lt 10 ]; do kill -0 \"$pid\" 2>/dev/null || break; sleep 1; i=$((i+1)); done; " +
        "kill \"$pid\" 2>/dev/null; wait \"$pid\" 2>/dev/null";
    system(command);
    let raw = "";
    try {
        raw = fs.readfile(out_path);
    }
    catch (e) {
        raw = "";
    }
    system("rm -f " + openconnect_shell_quote(pass_path) + " " + openconnect_shell_quote(out_path) + " >/dev/null 2>&1");
    return raw;
}

let openconnect_last_auth_raw = "";

function openconnect_group_required(raw) {
    let text = lc(as_string(raw));
    if (index(text, "authentication group") >= 0)
        return true;
    if (index(text, "authgroup") >= 0)
        return true;
    if (index(text, "auth group") >= 0)
        return true;
    if (index(text, "select your group") >= 0)
        return true;
    return false;
}

function openconnect_fetch_cookie(label, server, username, password, auth_group, fingerprint, proxy_port, flavor, soft, max_tries, quiet, insecure) {
    if (trim(username) == "" || password == "") {
        if (!soft && !quiet)
            openconnect_log("OpenConnect '" + label + "' was not started: username and password are required to obtain a session cookie.");
        return "";
    }
    let stamp = clock();
    let fingerprint_now = fingerprint;
    let tries = 0;
    let raw = "";
    let limit = int(max_tries || 0);
    if (limit <= 0)
        limit = 3;
    openconnect_last_auth_raw = "";
    while (tries < limit) {
        raw = openconnect_run_auth(server, username, password, auth_group, fingerprint_now, proxy_port, flavor, sprintf("%d-%d-%d", stamp[0], stamp[1], tries), insecure);
        if (raw == null) {
            if (!soft)
                openconnect_log("OpenConnect '" + label + "' was not started: could not store credentials for openconnect.");
            return "";
        }
        let learned = openconnect_parse_sha(raw);
        if (learned != "")
            openconnect_peer_put(server, { sha: learned });
        let cookie = openconnect_parse_cookie(raw);
        openconnect_last_auth_raw = raw;
        if (cookie != "") {
            openconnect_notice("OpenConnect '" + label + "' obtained a session cookie.");
            return cookie;
        }
        if (learned != "" && learned != openconnect_peer_fingerprint(fingerprint_now) &&
            (trim(as_string(fingerprint_now)) == "" || insecure)) {
            openconnect_notice("OpenConnect '" + label + "' learned the server certificate and will retry.");
            let replace_saved = trim(as_string(fingerprint_now)) != "";
            fingerprint_now = learned;
            if (!replace_saved)
                continue;
        }
        tries++;
        if (tries < limit && openconnect_cookie_worth_retry(raw)) {
            openconnect_notice("OpenConnect '" + label + "' login did not finish, retrying.");
            system("sleep 2");
            continue;
        }
        break;
    }
    if (quiet)
        return "";
    let reason = openconnect_failure_text(raw, password);
    let message = "OpenConnect '" + label + "' " + (soft ? "could not obtain a direct session cookie." : "was not started: openconnect did not return a session cookie.");
    if (reason != "")
        message += " " + reason;
    if (soft)
        openconnect_notice(message);
    else
        openconnect_log(message);
    return "";
}

function add_openconnect_connection(config, state, section, taken, selector_tags, urltest_candidate_tags) {
    if (!sing_box_at_least_1_14())
        return;

    let index = 0;
    for (let client in connections.openconnect_clients(section)) {
        index++;
        let server = trim(option(client, "server", ""));
        if (server == "")
            continue;

        let label = trim(option(client, "name", ""));
        if (label == "")
            label = "OpenConnect " + index;
        let tag_name = unique_tag(section[".name"] + "-openconnect-" + index, taken);
        let endpoint = {
            type: "openconnect",
            tag: tag_name,
            system: false,
            server: server,
            flavor: openconnect_flavor(client),
            routing_mark: runtime_constants.OUTBOUND_MARK,
            domain_resolver: runtime_constants.BOOTSTRAP_DNS_SERVER_TAG
        };
        let username = option(client, "username", "");
        if (username == "")
            username = option(client, "openconnect_username", "");
        if (username != "")
            endpoint.username = username;
        let password = option(client, "password", "");
        if (password == "")
            password = option(client, "openconnect_password", "");
        if (password != "")
            endpoint.password = password;
        let auth_group = option(client, "auth_group", "");
        if (auth_group == "")
            auth_group = option(client, "openconnect_auth_group", "");
        if (auth_group != "")
            endpoint.auth_group = auth_group;
        if (bool_option(client, "insecure", false) || bool_option(client, "openconnect_insecure", false))
            endpoint.tls = { insecure: true };
        let skip_cert = type(endpoint.tls) == "object" && endpoint.tls.insecure == true;
        let fingerprint = openconnect_peer_fingerprint(option(client, "server_sha", ""));
        let saved_target = openconnect_server_target(server);
        let saved_key = saved_target.port == "" ? saved_target.host : saved_target.host + ":" + saved_target.port;
        if (fingerprint == "")
            fingerprint = openconnect_peer_fingerprint(openconnect_peer_get(saved_key).sha);
        if (fingerprint != "") {
            if (type(endpoint.tls) != "object")
                endpoint.tls = {};
            endpoint.tls.peer_fingerprint = fingerprint;
        }
        if (bool_option(client, "advanced", false)) {
            if (openconnect_cookie_auto(client)) {
                let cookie = trim(option(client, "cookie", ""));
                if (cookie != "")
                    endpoint.cookie = cookie;
            }
            if (bool_option(client, "no_udp", false))
                endpoint.no_udp = true;
            if (bool_option(client, "disable_ipv6", false))
                endpoint.ipv6_disabled = true;
            let mtu = int(option(client, "mtu", "0"));
            if (mtu > 0)
                endpoint.mtu = mtu;
            let dpd_interval = openconnect_duration(option(client, "dpd_interval", ""));
            if (dpd_interval != "")
                endpoint.dpd_interval = dpd_interval;
            let reconnect_timeout = openconnect_duration(option(client, "reconnect_timeout", ""));
            if (reconnect_timeout != "")
                endpoint.reconnect_timeout = reconnect_timeout;
            if (bool_option(client, "keepalive", false))
                endpoint.tcp_keep_alive_enabled = true;
            if (bool_option(client, "compression_disabled", false))
                endpoint.compression_disabled = true;
            if (bool_option(client, "on_demand", false) && sing_box_at_least_1_15())
                endpoint.on_demand = true;
            let server_name = trim(option(client, "server_name", ""));
            if (server_name != "") {
                if (type(endpoint.tls) != "object")
                    endpoint.tls = {};
                endpoint.tls.server_name = server_name;
            }
            let cert = trim(option(client, "client_certificate", ""));
            let key = trim(option(client, "client_key", ""));
            if (cert != "" && key != "") {
                if (type(endpoint.tls) != "object")
                    endpoint.tls = {};
                endpoint.tls.client_certificate = [ cert ];
                endpoint.tls.client_key = [ key ];
                let key_password = option(client, "client_key_password", "");
                if (key_password != "")
                    endpoint.tls.client_key_password = key_password;
            }
        }
        let detour_tag = outbound_detour_tag_for_section(section);
        if (detour_tag != "") {
            let target = openconnect_server_target(server);
            let ip = openconnect_resolve_ipv4(target.host, label);
            if (ip == "") {
                openconnect_log("OpenConnect '" + label + "' was not started: direct DNS did not resolve " + target.host + ".");
                continue;
            }
            endpoint.server = target.port == "" ? ip : "https://" + ip + ":" + target.port;
            endpoint.detour = detour_tag;
            let existing_name = type(endpoint.tls) == "object" ? trim(as_string(endpoint.tls.server_name || "")) : "";
            if (existing_name == "" && !openconnect_is_ipv4(target.host)) {
                if (type(endpoint.tls) != "object")
                    endpoint.tls = {};
                endpoint.tls.server_name = target.host;
            }
            if (trim(as_string(endpoint.cookie || "")) == "" && openconnect_cookie_auto(client)) {
                let auth_host = openconnect_is_ipv4(target.host) && existing_name != "" ? existing_name : target.host;
                if (type(endpoint.tls) == "object") {
                    let configured_name = trim(as_string(endpoint.tls.server_name || ""));
                    if (configured_name != "" && openconnect_is_ipv4(target.host))
                        auth_host = configured_name;
                }
                let auth_server = target.port == "" ? auth_host : auth_host + ":" + target.port;
                let proxy_port = openconnect_detour_socks_port(section);
                if (proxy_port <= 0) {
                    openconnect_log("OpenConnect '" + label + "' was not started: cascade SOCKS port is not ready.");
                    continue;
                }
                let cookie = openconnect_fetch_cookie(label, auth_server, username, password, auth_group, fingerprint, proxy_port, openconnect_flavor(client), false, 0, false, skip_cert);
                if (cookie == "")
                    continue;
                endpoint.cookie = cookie;
                let learned_sha = openconnect_peer_fingerprint(openconnect_peer_get(saved_key).sha);
                if (option(client, "server_sha", "") == "" && learned_sha != "") {
                    if (type(endpoint.tls) != "object")
                        endpoint.tls = {};
                    endpoint.tls.peer_fingerprint = learned_sha;
                }
            }
        }
        else if (trim(as_string(endpoint.cookie || "")) == "" && username != "" && password != "" &&
            openconnect_cookie_auto(client)) {
            let target = openconnect_server_target(server);
            let auth_host = target.host;
            if (type(endpoint.tls) == "object") {
                let configured_name = trim(as_string(endpoint.tls.server_name || ""));
                if (configured_name != "" && openconnect_is_ipv4(target.host))
                    auth_host = configured_name;
            }
            let auth_server = target.port == "" ? auth_host : auth_host + ":" + target.port;
            let flavor = openconnect_flavor(client);
            let cookie = openconnect_fetch_cookie(label, auth_server, username, password, auth_group, fingerprint, 0, flavor, true, 0, false, skip_cert);
            if (cookie == "" && trim(auth_group) == "" && openconnect_group_required(openconnect_last_auth_raw))
                cookie = openconnect_fetch_cookie(label, auth_server, username, password, "all", fingerprint, 0, flavor, true, 0, false, skip_cert);
            if (cookie != "")
                endpoint.cookie = cookie;
            let learned_sha = openconnect_peer_fingerprint(openconnect_peer_get(saved_key).sha);
            if (option(client, "server_sha", "") == "" && learned_sha != "") {
                if (type(endpoint.tls) != "object")
                    endpoint.tls = {};
                endpoint.tls.peer_fingerprint = learned_sha;
            }
        }
        if (type(config.endpoints) != "array")
            config.endpoints = [];
        push(config.endpoints, endpoint);
        push(selector_tags, tag_name);
        push(urltest_candidate_tags, tag_name);
        runtime_subscription.remember_outbound_metadata(state, tag_name, label, { type: "OpenConnect" });
        let probe_port = int(config.__oc_probe_next || 0);
        if (probe_port < 4700)
            probe_port = 4700;
        config.__oc_probe_next = probe_port + 1;
        if (type(config.__oc_probe_ports) != "object" || config.__oc_probe_ports == null)
            config.__oc_probe_ports = {};
        config.__oc_probe_ports[tag_name] = probe_port;
        if (type(config.inbounds) != "array")
            config.inbounds = [];
        let probe_tag = "oc-probe-" + tag_name;
        push(config.inbounds, {
            type: "mixed",
            tag: probe_tag,
            listen: "127.0.0.1",
            listen_port: probe_port
        });
        if (type(config.route) != "object" || config.route == null)
            config.route = { rules: [] };
        if (type(config.route.rules) != "array")
            config.route.rules = [];
        push(config.route.rules, {
            action: "route",
            inbound: probe_tag,
            outbound: tag_name
        });
    }
}

function openvpn_extract_block(text, tag_name) {
    let start = "<" + tag_name + ">";
    let from = index(text, start);
    if (from < 0)
        return "";
    let rest = substr(text, from + length(start));
    let end_at = index(rest, "</" + tag_name + ">");
    if (end_at < 0)
        return "";
    return trim(substr(rest, 0, end_at));
}

function openvpn_tokens(line) {
    let parts = [];
    for (let part in split(line, /[ \t]+/)) {
        part = trim(as_string(part));
        if (part != "")
            push(parts, part);
    }
    return parts;
}

function openvpn_network(value) {
    value = lc(trim(as_string(value)));
    if (index(value, "tcp") == 0)
        return "tcp";
    if (index(value, "udp") == 0)
        return "udp";
    return "";
}

function openvpn_seconds(value) {
    value = trim(as_string(value));
    if (match(value, /^[0-9]+$/) == null)
        return "";
    return value + "s";
}

function openvpn_pem_blocks(value) {
    let text = replace(as_string(value), /\r/g, "");
    let blocks = [];
    while (index(text, "-----BEGIN ") >= 0) {
        let start = index(text, "-----BEGIN ");
        let rest = substr(text, start);
        let end_at = index(rest, "-----END ");
        if (end_at < 0)
            break;
        let tail = substr(rest, end_at);
        let line_end = index(tail, "\n");
        let block = line_end < 0 ? rest : substr(rest, 0, end_at + line_end);
        block = trim(block);
        if (index(block, "-----BEGIN ") >= 0 && index(block, "-----END ") >= 0)
            push(blocks, block);
        text = line_end < 0 ? "" : substr(rest, end_at + line_end + 1);
    }
    return blocks;
}

function openvpn_pem_or_empty(value) {
    value = trim(as_string(value));
    if (index(value, "-----BEGIN ") < 0)
        return "";
    return value;
}

function openvpn_parse_config(text) {
    text = replace(as_string(text), /\r/g, "");
    let parsed = {
        remotes: [],
        remote_random: false,
        username: "",
        password: "",
        ca: openvpn_extract_block(text, "ca"),
        cert: openvpn_extract_block(text, "cert"),
        key: openvpn_extract_block(text, "key"),
        secret: openvpn_extract_block(text, "secret"),
        control_type: "",
        control_key: "",
        key_direction: "",
        ca_path: "",
        cert_path: "",
        key_path: "",
        secret_path: "",
        control_path: "",
        network: "",
        data_ciphers: [],
        data_ciphers_fallback: "",
        auth: "",
        mtu: 0,
        ping: "",
        ping_restart: "",
        route_no_pull: false,
        server_name: "",
        server_name_type: "",
        remote_certificate_tls: "",
        compression: "",
        compression_lzo: "",
        block_ipv6: false,
        local_address: "",
        peer_address: "",
        default_port: 1194
    };
    let auth_block = openvpn_extract_block(text, "auth-user-pass");
    if (auth_block != "") {
        let auth_lines = split(auth_block, "\n");
        parsed.username = trim(as_string(auth_lines[0] || ""));
        parsed.password = trim(as_string(auth_lines[1] || ""));
    }
    for (let tag_name in [ "tls-crypt-v2", "tls-crypt", "tls-auth" ]) {
        let block = openvpn_extract_block(text, tag_name);
        if (block == "")
            continue;
        parsed.control_type = replace(tag_name, /-/g, "_");
        parsed.control_key = block;
        break;
    }

    let skipping = false;
    for (let line in split(text, "\n")) {
        line = trim(replace(as_string(line), /\r/g, ""));
        let opener = match(line, /^<([A-Za-z0-9_-]+)>/);
        if (opener) {
            let tag_name = lc(as_string(opener[1]));
            if (tag_name != "connection")
                skipping = true;
            continue;
        }
        if (match(line, /^<\//) != null) {
            skipping = false;
            continue;
        }
        if (skipping || line == "" || match(line, /^[#;]/) != null)
            continue;
        let tokens = openvpn_tokens(line);
        if (length(tokens) == 0)
            continue;
        let key_name = lc(tokens[0]);
        if (key_name == "remote" && length(tokens) >= 2) {
            let network = length(tokens) >= 4 ? openvpn_network(tokens[3]) : "";
            let port = length(tokens) >= 3 ? int(tokens[2]) : 0;
            push(parsed.remotes, {
                server: tokens[1],
                port: port,
                network: network
            });
        }
        else if (key_name == "port" && length(tokens) >= 2)
            parsed.default_port = int(tokens[1]);
        else if (key_name == "proto" && length(tokens) >= 2) {
            let network = openvpn_network(tokens[1]);
            if (network != "")
                parsed.network = network;
        }
        else if (key_name == "remote-random")
            parsed.remote_random = true;
        else if (key_name == "ca" && length(tokens) >= 2 && parsed.ca == "")
            parsed.ca_path = tokens[1];
        else if (key_name == "cert" && length(tokens) >= 2 && parsed.cert == "")
            parsed.cert_path = tokens[1];
        else if (key_name == "key" && length(tokens) >= 2 && parsed.key == "")
            parsed.key_path = tokens[1];
        else if (key_name == "secret" && length(tokens) >= 2 && parsed.secret == "")
            parsed.secret_path = tokens[1];
        else if ((key_name == "tls-auth" || key_name == "tls-crypt" || key_name == "tls-crypt-v2") && parsed.control_key == "") {
            parsed.control_type = replace(key_name, /-/g, "_");
            if (length(tokens) >= 2)
                parsed.control_path = tokens[1];
            if (key_name == "tls-auth" && length(tokens) >= 3)
                parsed.key_direction = tokens[2] == "0" ? "server" : "client";
        }
        else if (key_name == "key-direction" && length(tokens) >= 2)
            parsed.key_direction = tokens[1] == "0" ? "server" : "client";
        else if (key_name == "data-ciphers" && length(tokens) >= 2) {
            for (let cipher in split(tokens[1], ":")) {
                cipher = trim(cipher);
                if (cipher != "")
                    push(parsed.data_ciphers, cipher);
            }
        }
        else if (key_name == "data-ciphers-fallback" && length(tokens) >= 2)
            parsed.data_ciphers_fallback = tokens[1];
        else if (key_name == "cipher" && length(tokens) >= 2 && length(parsed.data_ciphers) == 0)
            push(parsed.data_ciphers, tokens[1]);
        else if (key_name == "auth" && length(tokens) >= 2)
            parsed.auth = tokens[1];
        else if (key_name == "tun-mtu" && length(tokens) >= 2)
            parsed.mtu = int(tokens[1]);
        else if (key_name == "ping" && length(tokens) >= 2)
            parsed.ping = openvpn_seconds(tokens[1]);
        else if (key_name == "ping-restart" && length(tokens) >= 2)
            parsed.ping_restart = openvpn_seconds(tokens[1]);
        else if (key_name == "route-nopull")
            parsed.route_no_pull = true;
        else if (key_name == "block-ipv6")
            parsed.block_ipv6 = true;
        else if (key_name == "remote-cert-tls" && length(tokens) >= 2)
            parsed.remote_certificate_tls = lc(tokens[1]);
        else if (key_name == "verify-x509-name" && length(tokens) >= 2) {
            parsed.server_name = tokens[1];
            parsed.server_name_type = length(tokens) >= 3 ? lc(tokens[2]) : "name";
        }
        else if (key_name == "compress" && length(tokens) >= 2)
            parsed.compression = lc(tokens[1]);
        else if (key_name == "comp-lzo")
            parsed.compression_lzo = length(tokens) >= 2 ? lc(tokens[1]) : "adaptive";
        else if (key_name == "ifconfig" && length(tokens) >= 3) {
            parsed.local_address = tokens[1];
            parsed.peer_address = tokens[2];
        }
    }
    let fallback_port = int(parsed.default_port || 0);
    if (fallback_port <= 0)
        fallback_port = 1194;
    let filled = [];
    for (let remote in parsed.remotes) {
        remote = object_or_empty(remote);
        if (int(remote.port || 0) <= 0)
            remote.port = fallback_port;
        push(filled, remote);
    }
    parsed.remotes = filled;
    return parsed;
}

function openvpn_assign_material(target, inline_key, path_key, inline_value, path_value) {
    let blocks = openvpn_pem_blocks(inline_value);
    path_value = trim(as_string(path_value));
    if (length(blocks) > 0)
        target[inline_key] = blocks;
    else if (path_value != "")
        target[path_key] = path_value;
}

function openvpn_fill_tls(endpoint, parsed, client) {
    if (type(endpoint.tls) != "object")
        endpoint.tls = {};
    openvpn_assign_material(endpoint.tls, "certificate", "certificate_path", parsed.ca, parsed.ca_path);
    openvpn_assign_material(endpoint.tls, "client_certificate", "client_certificate_path", parsed.cert, parsed.cert_path);
    openvpn_assign_material(endpoint.tls, "client_key", "client_key_path", parsed.key, parsed.key_path);
    let has_cert = endpoint.tls.client_certificate != null || trim(as_string(endpoint.tls.client_certificate_path || "")) != "";
    let has_key = endpoint.tls.client_key != null || trim(as_string(endpoint.tls.client_key_path || "")) != "";
    if (has_cert != has_key) {
        delete endpoint.tls.client_certificate;
        delete endpoint.tls.client_certificate_path;
        delete endpoint.tls.client_key;
        delete endpoint.tls.client_key_path;
    }
    let key_password = option(client, "client_key_password", "");
    if (key_password != "")
        endpoint.tls.client_key_password = key_password;
    if (parsed.server_name != "") {
        endpoint.tls.server_name = parsed.server_name;
        if (parsed.server_name_type == "subject" || parsed.server_name_type == "name" || parsed.server_name_type == "name-prefix")
            endpoint.tls.server_name_type = parsed.server_name_type;
    }
    if (parsed.remote_certificate_tls == "server" || parsed.remote_certificate_tls == "client" || parsed.remote_certificate_tls == "none")
        endpoint.tls.remote_certificate_tls = parsed.remote_certificate_tls;
    if (parsed.control_key != "" || parsed.control_path != "") {
        let wrap = { type: parsed.control_type != "" ? parsed.control_type : "tls_auth" };
        openvpn_assign_material(wrap, "key", "key_path", parsed.control_key, parsed.control_path);
        if (wrap.key == null && trim(as_string(wrap.key_path || "")) == "")
            wrap = null;
        if (wrap != null && wrap.type == "tls_auth" && (parsed.key_direction == "server" || parsed.key_direction == "client"))
            wrap.direction = parsed.key_direction;
        if (wrap != null)
            endpoint.tls.control_wrap = wrap;
    }
}

function openvpn_apply_common(endpoint, parsed, client) {
    let static_key = as_string(endpoint.mode) == "static_key";
    if (!static_key) {
        if (parsed.username != "")
            endpoint.username = parsed.username;
        if (parsed.password != "")
            endpoint.password = parsed.password;
        let username = trim(option(client, "username", ""));
        let password = option(client, "password", "");
        if (username != "")
            endpoint.username = username;
        if (password != "")
            endpoint.password = password;
        if (length(parsed.data_ciphers) > 0)
            endpoint.data_ciphers = parsed.data_ciphers;
        if (parsed.data_ciphers_fallback != "")
            endpoint.data_ciphers_fallback = parsed.data_ciphers_fallback;
        if (parsed.auth != "")
            endpoint.auth = parsed.auth;
    }
    else if (length(parsed.data_ciphers) > 0) {
        endpoint.cipher = parsed.data_ciphers[0];
    }
    if (parsed.remote_random)
        endpoint.remote_random = true;
    if (parsed.network != "")
        endpoint.network = parsed.network;
    if (parsed.mtu > 0)
        endpoint.mtu = parsed.mtu;
    if (parsed.ping != "")
        endpoint.ping_interval = parsed.ping;
    if (parsed.ping_restart != "")
        endpoint.ping_restart = parsed.ping_restart;
    if (parsed.route_no_pull)
        endpoint.route_no_pull = true;
    if (parsed.block_ipv6)
        endpoint.block_ipv6 = true;
    if (parsed.compression != "")
        endpoint.compression = parsed.compression;
    if (parsed.compression_lzo != "")
        endpoint.compression_lzo = parsed.compression_lzo;
    if (parsed.compression != "" && parsed.compression != "none" && parsed.compression != "no" && parsed.compression != "disabled" && parsed.compression != "off")
        endpoint.allow_compression = "yes";
    if (parsed.compression_lzo != "" && parsed.compression_lzo != "none" && parsed.compression_lzo != "no" && parsed.compression_lzo != "disabled" && parsed.compression_lzo != "off")
        endpoint.allow_compression = "yes";
    endpoint.route_no_pull = true;
    if (bool_option(client, "advanced", false)) {
        let mtu = int(option(client, "mtu", "0"));
        if (mtu > 0)
            endpoint.mtu = mtu;
        if (bool_option(client, "on_demand", false) && sing_box_at_least_1_15())
            endpoint.on_demand = true;
        if (bool_option(client, "allow_compression", false))
            endpoint.allow_compression = "yes";
        let ping_interval = openconnect_duration(option(client, "ping_interval", ""));
        if (ping_interval != "")
            endpoint.ping_interval = ping_interval;
        let ping_restart = openconnect_duration(option(client, "ping_restart", ""));
        if (ping_restart != "")
            endpoint.ping_restart = ping_restart;
    }
}

function openvpn_from_parsed(parsed, client) {
    if (parsed.secret != "" || parsed.secret_path != "") {
        if (parsed.local_address == "" || parsed.peer_address == "")
            return null;
        let endpoint = {
            type: "openvpn-client",
            mode: "static_key",
            system: false,
            address: [ parsed.local_address + "/32" ],
            peer_address: parsed.peer_address,
            topology: "p2p",
            routing_mark: runtime_constants.OUTBOUND_MARK,
            domain_resolver: runtime_constants.BOOTSTRAP_DNS_SERVER_TAG
        };
        openvpn_assign_material(endpoint, "static_key", "static_key_path", parsed.secret, parsed.secret_path);
        if (parsed.key_direction == "server" || parsed.key_direction == "client")
            endpoint.key_direction = parsed.key_direction;
        openvpn_apply_common(endpoint, parsed, client);
        return endpoint;
    }
    let endpoint = {
        type: "openvpn-client",
        mode: "tls",
        system: false,
        routing_mark: runtime_constants.OUTBOUND_MARK,
        domain_resolver: runtime_constants.BOOTSTRAP_DNS_SERVER_TAG
    };
    openvpn_fill_tls(endpoint, parsed, client);
    if (endpoint.tls.certificate == null && trim(as_string(endpoint.tls.certificate_path || "")) == "")
        return null;
    openvpn_apply_common(endpoint, parsed, client);
    return endpoint;
}

function openvpn_set_remotes(endpoint, remotes, network) {
    let usable = [];
    for (let remote in remotes) {
        remote = object_or_empty(remote);
        let server = trim(as_string(remote.server || ""));
        let port = int(remote.port || 0);
        if (server == "" || port <= 0 || port >= 65536)
            continue;
        let item = { server: server, server_port: port };
        let item_network = remote.network != "" ? remote.network : network;
        if (item_network == "tcp" || item_network == "udp")
            item.network = item_network;
        push(usable, item);
    }
    if (length(usable) == 0)
        return false;
    if (length(usable) == 1) {
        endpoint.server = usable[0].server;
        endpoint.server_port = usable[0].server_port;
        if (usable[0].network)
            endpoint.network = usable[0].network;
        return true;
    }
    endpoint.servers = usable;
    return true;
}

function openvpn_endpoint_from_client(client) {
    let source = lc(trim(option(client, "source", "config")));
    if (source == "manual") {
        let parsed = {
            remotes: [{
                server: trim(option(client, "server", "")),
                port: int(option(client, "server_port", "1194")),
                network: openvpn_network(option(client, "network", "udp"))
            }],
            remote_random: false,
            username: "",
            password: "",
            ca: option(client, "ca", ""),
            cert: option(client, "client_certificate", ""),
            key: option(client, "client_key", ""),
            secret: "",
            control_type: "",
            control_key: "",
            key_direction: "",
            ca_path: "",
            cert_path: "",
            key_path: "",
            secret_path: "",
            control_path: "",
            network: openvpn_network(option(client, "network", "udp")),
            data_ciphers: [],
            data_ciphers_fallback: "",
            auth: "",
            mtu: 0,
            ping: "",
            ping_restart: "",
            route_no_pull: false,
            server_name: "",
            server_name_type: "",
            remote_certificate_tls: "server",
            compression: "",
            compression_lzo: "",
            block_ipv6: false,
            local_address: "",
            peer_address: ""
        };
        let ciphers = trim(option(client, "data_ciphers", ""));
        if (ciphers != "") {
            for (let cipher in split(replace(ciphers, /[ \t]+/g, ""), ":"))
                if (trim(cipher) != "")
                    push(parsed.data_ciphers, trim(cipher));
        }
        parsed.auth = trim(option(client, "auth", ""));
        if (bool_option(client, "advanced", false)) {
            let control_type = lc(trim(option(client, "control_type", "")));
            if (control_type == "tls_auth" || control_type == "tls_crypt" || control_type == "tls_crypt_v2") {
                parsed.control_type = control_type;
                parsed.control_key = option(client, "control_key", "");
                parsed.key_direction = lc(trim(option(client, "key_direction", "")));
            }
            parsed.server_name = trim(option(client, "server_name", ""));
        }
        let endpoint = openvpn_from_parsed(parsed, client);
        if (endpoint == null || !openvpn_set_remotes(endpoint, parsed.remotes, parsed.network))
            return null;
        return endpoint;
    }
    let parsed = openvpn_parse_config(option(client, "config", ""));
    if (length(parsed.remotes) == 0 && parsed.secret == "" && parsed.secret_path == "")
        return null;
    let endpoint = openvpn_from_parsed(parsed, client);
    if (endpoint == null)
        return null;
    if (parsed.secret == "" && parsed.secret_path == "" && !openvpn_set_remotes(endpoint, parsed.remotes, parsed.network))
        return null;
    if ((parsed.secret != "" || parsed.secret_path != "") && length(parsed.remotes) > 0)
        openvpn_set_remotes(endpoint, parsed.remotes, parsed.network);
    return endpoint;
}

function openvpn_detour_section(name) {
    let found = [];
    uci_cursor().load(CONFIG_NAME);
    uci_cursor().foreach(CONFIG_NAME, "section", function(section) {
        if (as_string(section[".name"]) == name)
            push(found, section);
    });
    return length(found) > 0 ? found[length(found) - 1] : null;
}

function openvpn_apply_detour(config, section, taken, endpoint, label) {
    let detour_tag = outbound_detour_tag_for_section(section);
    if (detour_tag == "")
        return true;
    let name = trim(option(section, "outbound_detour_section", ""));
    let target = openvpn_detour_section(name);
    if (target != null && connections.proxy_core(target) == "xray") {
        let port = openconnect_port_from_map("/var/run/forkop/xray-ports.json", name);
        if (port <= 0) {
            openconnect_log("OpenVPN '" + label + "' was not started: cascade SOCKS port is not ready.");
            return false;
        }
        if (type(config.__ovpn_via) != "object" || config.__ovpn_via == null)
            config.__ovpn_via = {};
        let existing = as_string(config.__ovpn_via[name] || "");
        if (existing != "") {
            endpoint.detour = existing;
            return true;
        }
        let via_tag = unique_tag("ovpn-via-" + name, taken);
        push(config.outbounds, {
            type: "socks",
            tag: via_tag,
            server: "127.0.0.1",
            server_port: port,
            version: "5",
            udp_fragment: true,
            routing_mark: runtime_constants.OUTBOUND_MARK
        });
        config.__ovpn_via[name] = via_tag;
        endpoint.detour = via_tag;
        return true;
    }
    endpoint.detour = detour_tag;
    return true;
}


function add_manual_proxy_link(config, state, section, manual_index, link, taken, selector_tags, urltest_candidate_tags) {
    let section_name = section[".name"];
    let tag_name = outbound_tag(section_name + "-" + manual_index);
    if (taken[tag_name])
        tag_name = unique_tag(tag_name, taken);
    taken[tag_name] = true;

    let display_name = url_fragment(link);
    if (display_name == "")
        display_name = tag_name;

    if (wireguard_scheme(url_scheme(link)) || url_scheme(link) == "vpn" || wireguard_conf_text(link) != "") {
        let endpoint = manual_wireguard_endpoint(link, tag_name);
        if (!openvpn_apply_detour(config, section, taken, endpoint, display_name))
            return "";
        if (as_string(endpoint.detour || "") != "")
            delete endpoint.listen_port;
        let protocol_name = trim(as_string(endpoint.__protocol || ""));
        delete endpoint.__protocol;
        if (protocol_name == "")
            protocol_name = url_scheme(link) == "warp" ? "WARP" : (type(endpoint.amnezia) == "object" ? "AmneziaWG" : "WireGuard");
        if (wireguard_conf_text(link) != "" && url_scheme(link) == "" && type(endpoint.peers) == "array" && length(endpoint.peers) > 0)
            display_name = as_string(endpoint.peers[0].address) + ":" + endpoint.peers[0].port;
        if (type(config.endpoints) != "array")
            config.endpoints = [];
        push(config.endpoints, endpoint);
        push(selector_tags, tag_name);
        push(urltest_candidate_tags, tag_name);
        state.links[tag_name] = as_string(link);
        runtime_subscription.remember_outbound_metadata(state, tag_name, display_name, {
            type: protocol_name
        });
        return tag_name;
    }

    let outbound = manual_link_outbound(link, tag_name);
    ensure_explicit_outbound_supported(outbound, "manual outbound", display_name);
    push(config.outbounds, outbound);
    push(selector_tags, tag_name);
    push(urltest_candidate_tags, tag_name);

    state.links[tag_name] = as_string(link);
    runtime_subscription.remember_outbound_metadata(state, tag_name, display_name, outbound);
    return tag_name;
}

function add_connection_manual_links(config, state, section, taken, selector_tags, urltest_candidate_tags) {
    let section_name = section[".name"];
    let manual_links = connections.connection_urls(section);
    for (let i = 0; i < length(manual_links); i++) {
        let link = manual_links[i];
        add_manual_proxy_link(
            config,
            state,
            section,
            i + 1,
            link,
            taken,
            selector_tags,
            urltest_candidate_tags
        );
    }
}

function warp_extended_endpoint(client, tag_name, host, port) {
    let device = trim(option(client, "device_id", ""));
    let token = trim(option(client, "access_token", ""));
    let private_key = trim(option(client, "private_key", ""));
    if (device == "" || token == "" || private_key == "")
        return null;
    let endpoint = {
        type: "warp",
        tag: tag_name,
        system: false,
        address: host,
        port: int(port, 10),
        profile: {
            id: device,
            private_key: private_key,
            auth_token: token,
            recreate: false
        },
        routing_mark: runtime_constants.OUTBOUND_MARK,
        domain_resolver: runtime_constants.BOOTSTRAP_DNS_SERVER_TAG
    };
    let keepalive = trim(option(client, "keepalive", "25"));
    if (match(keepalive, /^[0-9]+$/) != null && int(keepalive, 10) > 0)
        endpoint.persistent_keepalive_interval = int(keepalive, 10);
    let license = trim(option(client, "license", ""));
    if (license != "")
        endpoint.profile.license_key = license;
    return endpoint;
}

function add_warp_profiles(config, state, section, taken, selector_tags, urltest_candidate_tags) {
    let section_name = as_string(section[".name"]);
    let extended = sing_box_is_extended();
    let n = 0;
    for (let client in connections.warp_clients(section)) {
        n++;
        let private_key = trim(option(client, "private_key", ""));
        let public_key = trim(option(client, "public_key", ""));
        let host = trim(option(client, "endpoint_host", ""));
        let port = trim(option(client, "endpoint_port", "2408"));
        if (match(port, /^[0-9]+$/) == null)
            port = "2408";
        let v4 = trim(option(client, "address_v4", ""));
        if (private_key == "" || host == "" || v4 == "" || (!extended && public_key == "")) {
            warn("skipped incomplete WARP profile in section '", section_name, "'\n");
            continue;
        }
        let addresses = [ index(v4, "/") < 0 ? v4 + "/32" : v4 ];
        let v6 = trim(option(client, "address_v6", ""));
        if (v6 != "" && !bool_option(client, "ipv4_only", false))
            push(addresses, index(v6, "/") < 0 ? v6 + "/128" : v6);
        let label = trim(option(client, "name", ""));
        if (label == "")
            label = "WARP " + n;
        let tag_name = unique_tag(section_name + "-warp-" + n, taken);
        let endpoint = null;
        if (extended) {
            endpoint = warp_extended_endpoint(client, tag_name, host, port);
            if (endpoint == null) {
                warn("sing-box-extended skipped WARP '", label, "': the profile has no device id or token. Use New address once.\n");
                continue;
            }
        }
        else {
            endpoint = wireguard_endpoint_from_fields({
                privatekey: private_key,
                publickey: public_key,
                endpoint: host + ":" + port,
                address: join(",", addresses),
                reserved: option(client, "reserved", ""),
                mtu: option(client, "mtu", "1280"),
                keepalive: option(client, "keepalive", "25"),
                allowedips: "0.0.0.0/0,::/0"
            }, tag_name);
        }
        if (!openvpn_apply_detour(config, section, taken, endpoint, label))
            continue;
        if (bool_option(client, "ipv4_only", false))
            endpoint.domain_resolver = {
                server: runtime_constants.BOOTSTRAP_DNS_SERVER_TAG,
                strategy: "ipv4_only"
            };
        if (as_string(endpoint.detour || "") != "") {
            delete endpoint.listen_port;
            if (extended && type(endpoint.profile) == "object")
                endpoint.profile.detour = endpoint.detour;
        }
        taken[tag_name] = true;
        if (type(config.endpoints) != "array")
            config.endpoints = [];
        push(config.endpoints, endpoint);
        push(selector_tags, tag_name);
        push(urltest_candidate_tags, tag_name);
        runtime_subscription.remember_outbound_metadata(state, tag_name, label, { type: "WARP WIREGUARD" });
    }
}

function add_masque_profiles(config, state, section, taken, selector_tags, urltest_candidate_tags) {
    let section_name = as_string(section[".name"]);
    let clients = connections.masque_clients(section);
    if (length(clients) == 0)
        return;
    if (!sing_box_is_extended()) {
        warn("skipped WARP MASQUE profiles in section '", section_name, "': need sing-box-extended\n");
        return;
    }
    let n = 0;
    for (let client in clients) {
        n++;
        let label = trim(option(client, "name", ""));
        if (label == "")
            label = "WARP MASQUE " + n;
        let tag_name = unique_tag(section_name + "-masque-" + n, taken);
        let profile = {
            recreate: false,
            detour: runtime_constants.DIRECT_OUTBOUND_TAG
        };
        let license = trim(option(client, "license", ""));
        if (license != "")
            profile.license_key = license;
        let endpoint = {
            type: "masque",
            tag: tag_name,
            system: false,
            name: "masque" + n,
            use_http2: false,
            use_ipv6: !bool_option(client, "ipv4_only", true),
            profile: profile,
            routing_mark: runtime_constants.OUTBOUND_MARK
        };
        let port = trim(option(client, "endpoint_port", "443"));
        if (port != "443" && port != "500" && port != "1701" && port != "4500" && port != "4443" && port != "8443" && port != "8095")
            port = "443";
        if (port != "443") {
            endpoint.address = "162.159.198.1";
            endpoint.port = int(port, 10);
        }
        let l4 = bool_option(client, "l4_proxy", false);
        let handshake = trim(option(client, "handshake_timeout", ""));
        let handshake_seconds = 0;
        if (match(handshake, /^[0-9]+$/) != null)
            handshake_seconds = int(handshake, 10);
        if (handshake_seconds == null || handshake_seconds < 0)
            handshake_seconds = 0;
        if (handshake_seconds > 300)
            handshake_seconds = 300;
        if ((l4 || handshake_seconds > 0) && !sing_box_masque_l4_supported())
            warn("WARP MASQUE '", label, "': TCP-only and handshake timeout need sing-box-extended 2.7.3 or newer, so they were not written\n");
        else {
            if (l4)
                endpoint.use_l4_proxy = true;
            if (handshake_seconds > 0)
                endpoint.handshake_timeout = handshake_seconds + "s";
        }
        if (!openvpn_apply_detour(config, section, taken, endpoint, label))
            continue;
        if (as_string(endpoint.detour || "") != "" && type(endpoint.profile) == "object")
            endpoint.profile.detour = endpoint.detour;
        taken[tag_name] = true;
        push(config.outbounds, endpoint);
        push(selector_tags, tag_name);
        push(urltest_candidate_tags, tag_name);
        runtime_subscription.remember_outbound_metadata(state, tag_name, label, { type: "WARP MASQUE" });
    }
}

function openvpn_add_probe(config, tag_name) {
    let probe_port = int(config.__oc_probe_next || 0);
    if (probe_port < 4700)
        probe_port = 4700;
    config.__oc_probe_next = probe_port + 1;
    if (type(config.__oc_probe_ports) != "object" || config.__oc_probe_ports == null)
        config.__oc_probe_ports = {};
    config.__oc_probe_ports[tag_name] = probe_port;
    if (type(config.inbounds) != "array")
        config.inbounds = [];
    let probe_tag = "ovpn-probe-" + tag_name;
    push(config.inbounds, {
        type: "mixed",
        tag: probe_tag,
        listen: "127.0.0.1",
        listen_port: probe_port
    });
    if (type(config.route) != "object" || config.route == null)
        config.route = { rules: [] };
    if (type(config.route.rules) != "array")
        config.route.rules = [];
    push(config.route.rules, {
        action: "route",
        inbound: probe_tag,
        outbound: tag_name
    });
}

function add_openvpn_connection(config, state, section, taken, selector_tags, urltest_candidate_tags) {
    if (!sing_box_at_least_1_14())
        return;
    let index = 0;
    for (let client in connections.openvpn_clients(section)) {
        index++;
        let label = trim(option(client, "name", ""));
        if (label == "")
            label = "OpenVPN " + index;
        let endpoint = openvpn_endpoint_from_client(client);
        if (endpoint == null) {
            openconnect_log("OpenVPN '" + label + "' was not started: configuration is incomplete.");
            continue;
        }
        let tag_name = unique_tag(section[".name"] + "-openvpn-" + index, taken);
        endpoint.tag = tag_name;
        if (!openvpn_apply_detour(config, section, taken, endpoint, label))
            continue;
        if (type(config.endpoints) != "array")
            config.endpoints = [];
        push(config.endpoints, endpoint);
        push(selector_tags, tag_name);
        push(urltest_candidate_tags, tag_name);
        runtime_subscription.remember_outbound_metadata(state, tag_name, label, { type: "OpenVPN" });
        openvpn_add_probe(config, tag_name);
    }
}

function parse_outbound_json(value) {
    try {
        value = json(as_string(value));
    }
    catch (e) {
        return null;
    }

    return type(value) == "object" ? value : null;
}

function rewrite_json_outbound_references(outbounds, tag_map) {
    for (let outbound in array_or_empty(outbounds)) {
        if (type(outbound) != "object")
            continue;

        for (let key in [ "detour", "default" ]) {
            let reference = as_string(outbound[key] || "");
            if (reference != "" && tag_map[reference])
                outbound[key] = tag_map[reference];
        }

        if (type(outbound.outbounds) == "array") {
            let rewritten = [];
            for (let tag_name in outbound.outbounds) {
                tag_name = as_string(tag_name);
                if (tag_name != "")
                    push(rewritten, as_string(tag_map[tag_name] || tag_name));
            }
            outbound.outbounds = rewritten;
        }
    }
}

function prepare_json_connection_outbounds(section, taken) {
    let items = connections.outbound_jsons(section);
    let prepared = [];
    let outbounds = [];
    let tag_map = {};
    let legacy_tags = [];

    for (let i = 0; i < length(items); i++) {
        let outbound = parse_outbound_json(items[i]);
        if (outbound == null)
            runtime_generate_unsupported("JSON outbound is invalid");

        let display_name = trim(as_string(outbound.tag || ""));
        let legacy_tag = connection_item_tag(section[".name"], "json", i + 1);
        let base = display_name != "" ? display_name : legacy_tag;
        let tag_name = unique_tag(base, taken);
        ensure_explicit_outbound_supported(outbound, "JSON outbound", display_name != "" ? display_name : legacy_tag);
        taken[tag_name] = true;
        if (display_name != "" && !tag_map[display_name])
            tag_map[display_name] = tag_name;
        push(legacy_tags, [ legacy_tag, tag_name ]);

        outbound.tag = tag_name;
        push(outbounds, outbound);
        push(prepared, {
            outbound,
            displayName: display_name != "" ? display_name : "JSON outbound " + (i + 1)
        });
    }

    for (let entry in legacy_tags)
        if (!tag_map[entry[0]])
            tag_map[entry[0]] = entry[1];

    rewrite_json_outbound_references(outbounds, tag_map);
    return prepared;
}

function add_connection_json_outbounds(config, state, section, taken, selector_tags, urltest_candidate_tags) {
    for (let item in prepare_json_connection_outbounds(section, taken)) {
        let outbound = item.outbound;
        let tag_name = outbound.tag;
        push(config.outbounds, outbound);
        push(selector_tags, tag_name);
        if (urltest_leaf_candidate_outbound(outbound))
            push(urltest_candidate_tags, tag_name);
        runtime_subscription.remember_outbound_metadata(state, tag_name, item.displayName, outbound);
        runtime_subscription.remember_urltest_group(state, tag_name, item.displayName, outbound);
    }
}

function insert_route_rules_after_system(config, extra) {
    extra = array_or_empty(extra);
    if (length(extra) == 0)
        return;
    if (type(config.route) != "object")
        config.route = {};
    let rules = array_or_empty(config.route.rules);
    let insert_at = 0;
    for (let i = 0; i < length(rules); i++) {
        let action = as_string(object_or_empty(rules[i]).action || "");
        if (action == "sniff" || action == "hijack-dns")
            insert_at = i + 1;
        else
            break;
    }
    let result = [];
    for (let i = 0; i < insert_at; i++)
        push(result, rules[i]);
    for (let rule in extra)
        push(result, rule);
    for (let i = insert_at; i < length(rules); i++)
        push(result, rules[i]);
    config.route.rules = result;
}

function add_xray_cascade_inbounds(config) {
    let cascade = object_or_empty(read_json_file("/var/run/forkop/xray-cascade.json"));
    let extra = [];
    for (let name in cascade) {
        let port = int(cascade[name] || 0, 10);
        if (as_string(name) == "" || port <= 0)
            continue;
        let inbound_name = "xray-cascade-in-" + as_string(name);
        push(config.inbounds, {
            type: "socks",
            tag: inbound_name,
            listen: "127.0.0.1",
            listen_port: port,
            udp_fragment: true
        });
        push(extra, {
            action: "route",
            inbound: inbound_name,
            outbound: outbound_tag(name)
        });
    }
    insert_route_rules_after_system(config, extra);
}

function strip_redirect_inbound_network(config) {
    for (let inbound in array_or_empty(config.inbounds)) {
        if (type(inbound) != "object")
            continue;
        if (as_string(inbound.type) == "redirect" && inbound.network != null)
            delete inbound.network;
    }
}

function add_router_traffic_redirect(config, settings) {
    if (engine.is_xray_primary())
        return;
    let section_name = router_traffic_section(settings);
    if (section_name == "")
        return;

    push(config.inbounds, {
        type: "redirect",
        tag: runtime_constants.REDIRECT_INBOUND_TAG,
        listen: runtime_constants.REDIRECT_INBOUND_ADDRESS,
        listen_port: runtime_constants.REDIRECT_INBOUND_PORT
    });
    insert_route_rules_after_system(config, [{
        action: "route",
        inbound: runtime_constants.REDIRECT_INBOUND_TAG,
        outbound: outbound_tag(section_name)
    }]);
}

function xray_clash_type(protocol, kind) {
    if (as_string(kind) == "iface")
        return "Direct";
    let proto = lc(as_string(protocol || ""));
    if (proto == "vless")
        return "VLESS";
    if (proto == "vmess")
        return "VMess";
    if (proto == "trojan")
        return "Trojan";
    if (proto == "shadowsocks")
        return "Shadowsocks";
    if (proto == "hysteria" || proto == "hysteria2" || proto == "hy2")
        return "Hysteria2";
    if (proto == "socks")
        return "SOCKS";
    if (proto == "freedom" || proto == "direct")
        return "Direct";
    return "Socks";
}

function read_xray_section_nodes(section_name, fallback_port, fallback_name) {
    let all = object_or_empty(read_json_file("/var/run/forkop/xray-nodes.json"));
    let nodes = array_or_empty(all[as_string(section_name)]);
    if (length(nodes) > 0)
        return nodes;
    fallback_port = int(fallback_port || 0, 10);
    if (fallback_port <= 0)
        return [];
    return [{
        tag: as_string(section_name) + "-xray",
        port: fallback_port,
        name: as_string(fallback_name || "Xray"),
        kind: "proxy",
        protocol: ""
    }];
}

function add_xray_sidecar_outbound(config, section, taken) {
    let section_name = section[".name"];
    let ports = object_or_empty(read_json_file("/var/run/forkop/xray-ports.json"));
    if (type(ports) != "object")
        ports = {};
    let port = int(ports[section_name] || 0, 10);
    if (port <= 0)
        runtime_generate_unsupported("xray sidecar port is missing for " + section_name + "; generate xray config first");

    taken = type(taken) == "object" ? taken : {};
    let selector_tag = outbound_tag(section_name);
    taken[selector_tag] = true;
    // One SOCKS into the section inbound. Xray leastPing/leastLoad owns node choice.
    let balance_tag = unique_tag(section_name + "-xray", taken);
    taken[balance_tag] = true;
    push(config.outbounds, {
        type: "socks",
        tag: balance_tag,
        server: "127.0.0.1",
        server_port: port,
        version: "5",
        udp_fragment: true,
        routing_mark: runtime_constants.OUTBOUND_MARK,
        domain_resolver: runtime_constants.DNS_SERVER_TAG
    });

    let state = runtime_subscription.new_section_state(section_name);
    let links = connections.connection_urls(section);
    let link_index = 0;
    for (let node in read_xray_section_nodes(section_name, port, "Xray")) {
        node = object_or_empty(node);
        let tag = as_string(node.tag || "");
        if (tag == "" || int(node.port || 0, 10) <= 0)
            continue;
        let display_name = as_string(node.name || tag);
        runtime_subscription.remember_outbound_metadata(
            state,
            tag,
            display_name,
            { type: xray_clash_type(node.protocol, node.kind) }
        );
        if (as_string(node.kind || "proxy") != "iface" && link_index < length(links)) {
            state.links[tag] = as_string(links[link_index]);
            link_index++;
        }
    }

    push(config.outbounds, {
        type: "selector",
        tag: selector_tag,
        outbounds: [ balance_tag ],
        default: balance_tag,
        interrupt_exist_connections: true
    });

    if (!atomic_write_json_file(runtime_subscription.section_cache_path(section_name), state))
        runtime_generate_unsupported("failed to write section cache for " + section_name);
}

function add_connections_outbound(config, section, taken) {
    let section_name = section[".name"];
    let selector_tags = [];
    let urltest_candidate_tags = [];
    let state = runtime_subscription.new_section_state(section_name);
    let cascade_start = length(array_or_empty(config.outbounds));

    add_connection_manual_links(config, state, section, taken, selector_tags, urltest_candidate_tags);
    add_warp_profiles(config, state, section, taken, selector_tags, urltest_candidate_tags);
    add_masque_profiles(config, state, section, taken, selector_tags, urltest_candidate_tags);
    add_connection_subscriptions(config, state, section, taken, selector_tags, urltest_candidate_tags);
    // Apply before interface and JSON items are added: those source kinds are intentionally excluded.
    apply_section_detour_to_connection_outbounds(
        config,
        cascade_start,
        outbound_detour_tag_for_section(section)
    );
    add_connection_interfaces(config, state, section, taken, selector_tags, urltest_candidate_tags);
    add_openconnect_connection(config, state, section, taken, selector_tags, urltest_candidate_tags);
    add_openvpn_connection(config, state, section, taken, selector_tags, urltest_candidate_tags);
    add_connection_json_outbounds(config, state, section, taken, selector_tags, urltest_candidate_tags);

    if (length(selector_tags) == 0)
        runtime_generate_unsupported("connection section has no usable outbounds");

    if (section_needs_country_is(section)) {
        let previous_state = read_json_file(runtime_subscription.section_cache_path(section_name));
        state.outboundMetadata.countries = runtime_country.detect(
            state.servers,
            previous_state,
            option(runtime_settings(), "bootstrap_dns_server", "77.88.8.8")
        );
    }
    if (section_has_direct_priority_level(section))
        state.outboundMetadata.names[runtime_constants.DIRECT_OUTBOUND_TAG] = "Direct";

    state.urltestCandidateTags = unique_string_array(urltest_candidate_tags);
    add_proxy_selector(config, section, selector_tags, urltest_candidate_tags, state);
    if (!atomic_write_json_file(runtime_subscription.section_cache_path(section_name), state))
        runtime_generate_unsupported("failed to write section cache for " + section_name);
}

function enabled_action_index(sections, target_section, action_name) {
    let index = 0;
    for (let section in sections) {
        if (option(section, "action", "") != action_name)
            continue;
        index++;
        if (section[".name"] == target_section[".name"])
            return index;
    }
    return 0;
}

function add_zapret_outbound(config, section, sections) {
    let index = enabled_action_index(sections, section, "zapret");
    if (index <= 0)
        runtime_generate_unsupported("unable to resolve Zapret index for " + section[".name"]);
    push(config.outbounds, {
        type: "direct",
        tag: outbound_tag(section[".name"]),
        routing_mark: runtime_constants.ZAPRET_ROUTE_MARK_BASE + index
    });
}

function add_zapret2_outbound(config, section, sections) {
    let index = enabled_action_index(sections, section, "zapret2");
    if (index <= 0)
        runtime_generate_unsupported("unable to resolve Zapret2 index for " + section[".name"]);
    push(config.outbounds, {
        type: "direct",
        tag: outbound_tag(section[".name"]),
        routing_mark: runtime_constants.ZAPRET2_ROUTE_MARK_BASE + index
    });
}

function add_byedpi_outbound(config, section, sections) {
    let index = enabled_action_index(sections, section, "byedpi");
    if (index <= 0)
        runtime_generate_unsupported("unable to resolve ByeDPI index for " + section[".name"]);
    push(config.outbounds, {
        type: "socks",
        tag: outbound_tag(section[".name"]),
        server: runtime_constants.BYEDPI_LISTEN_ADDRESS,
        server_port: runtime_constants.BYEDPI_PORT_BASE + index - 1,
        version: "5"
    });
}

function ensure_community_ruleset(config, section_name, community) {
    if (!runtime_rulesets.is_community(community))
        runtime_generate_unsupported("unknown community list " + community);

    let tag_name = ruleset_tag(section_name, community, "community");
    if (!ruleset_registered(config, tag_name)) {
        register_remote_or_cached_ruleset(config, {
            type: "remote",
            tag: tag_name,
            format: "binary",
            url: runtime_rulesets.community_url(community),
            update_interval: remote_ruleset_update_interval()
        });
    }
    return {
        tag: tag_name,
        kind: "domains"
    };
}

function domain_ip_list_ruleset_tag(section_name) {
    return ruleset_tag(section_name, "lists", "");
}

function domain_ip_list_ruleset_path(section_name) {
    return runtime_ruleset_folder + "/" + domain_ip_list_ruleset_tag(section_name) + ".json";
}

function reference_is_local(reference) {
    return substr(as_string(reference), 0, 1) == "/";
}

function source_file_exists(path) {
    return fs.readfile(path) != null;
}

function rebuild_local_domain_ip_list_ruleset(section_name, references, domains_only) {
    let ruleset_path = domain_ip_list_ruleset_path(section_name);
    let has_local = false;

    for (let reference in references) {
        if (reference_is_local(reference)) {
            has_local = true;
            break;
        }
    }

    if (!has_local)
        return;

    fs.unlink(ruleset_path);
    source_rulesets.create_source(ruleset_path);

    for (let reference in references) {
        reference = as_string(reference);
        if (!reference_is_local(reference))
            continue;
        if (!source_file_exists(reference)) {
            warn("local domain/IP list not found: ", reference, "\n");
            continue;
        }

        source_rulesets.import_plain_list(reference, ruleset_path, "domain_suffix", "domains", "5000");
        if (!domains_only)
            source_rulesets.import_plain_list(reference, ruleset_path, "ip_cidr", "subnets", "5000");
    }
}

function add_domain_ip_list_ruleset(config, section_name, rule_set_tags, dns_rule_set_tags, references, domains_only) {
    if (length(references) == 0)
        return;

    rebuild_local_domain_ip_list_ruleset(section_name, references, domains_only);

    let ruleset_path = domain_ip_list_ruleset_path(section_name);
    if (!source_rulesets.has_rules(ruleset_path))
        return;

    let tag_name = domain_ip_list_ruleset_tag(section_name);
    if (!ruleset_registered(config, tag_name)) {
        push(config.route.rule_set, {
            type: "local",
            tag: tag_name,
            format: "source",
            path: ruleset_path
        });
    }

    if (!domains_only)
        push(rule_set_tags, tag_name);
    if (source_rulesets.has_domain_matchers(ruleset_path))
        push(dns_rule_set_tags, tag_name);
}

function exclusion_fix_marker() {
    return "forkop-exclusions-fix-5";
}

function looks_like_ipv4(value) {
    value = trim(as_string(value));
    let matched = match(value, /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/);
    if (matched == null)
        return false;
    return true;
}

function looks_like_ipv4_cidr(value) {
    value = trim(as_string(value));
    let matched = match(value, /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\/[0-9]+$/);
    if (matched == null)
        return false;
    return true;
}

function looks_like_ipv6(value) {
    value = trim(as_string(value));
    if (value == "")
        return false;
    if (index(value, ":") < 0)
        return false;
    if (index(value, "/") >= 0)
        return false;
    let matched = match(value, /^[0-9A-Fa-f:]+$/);
    if (matched == null)
        return false;
    return true;
}

function looks_like_ipv6_cidr(value) {
    value = trim(as_string(value));
    let slash = index(value, "/");
    if (slash <= 0)
        return false;
    if (looks_like_ipv6(substr(value, 0, slash)) != true)
        return false;
    let prefix = substr(value, slash + 1);
    let matched = match(prefix, /^[0-9]+$/);
    if (matched == null)
        return false;
    return true;
}

function is_valid_ip(value) {
    if (looks_like_ipv4(value) == true)
        return true;
    if (looks_like_ipv6(value) == true)
        return true;
    return false;
}

function is_valid_ip_or_cidr(value) {
    if (looks_like_ipv4(value) == true)
        return true;
    if (looks_like_ipv4_cidr(value) == true)
        return true;
    if (looks_like_ipv6(value) == true)
        return true;
    if (looks_like_ipv6_cidr(value) == true)
        return true;
    return false;
}

function hostname_key(value) {
    value = lc(trim(as_string(value)));
    let matched = match(value, /\.lan$/);
    if (matched != null)
        value = substr(value, 0, length(value) - 4);
    return value;
}

function read_text_if_exists(path) {
    let data = null;
    try {
        data = fs.readfile(path);
    }
    catch (e) {
        return "";
    }
    if (data == null)
        return "";
    return as_string(data);
}

function ip_from_lease_line(line, wanted) {
    line = trim(as_string(line));
    if (line == "")
        return "";
    let fields = split(line, /[ \t]+/);
    if (length(fields) < 4)
        return "";
    if (hostname_key(fields[3]) != wanted)
        return "";
    let ip = trim(as_string(fields[2]));
    if (is_valid_ip(ip) == true)
        return ip;
    return "";
}

function ip_from_hosts_line(line, wanted) {
    line = trim(as_string(line));
    if (line == "")
        return "";
    if (substr(line, 0, 1) == "#")
        return "";
    let fields = split(line, /[ \t]+/);
    if (length(fields) < 2)
        return "";
    let ip = trim(as_string(fields[0]));
    if (is_valid_ip(ip) != true)
        return "";
    for (let field in fields) {
        if (hostname_key(field) == wanted)
            return ip;
    }
    return "";
}
function lease_lookup_paths() {
    return [
        "/tmp/dhcp.leases",
        "/var/dhcp.leases",
        "/tmp/run/dhcp.leases",
        "/tmp/hosts/odhcpd",
        "/tmp/hosts/dhcp",
        "/etc/hosts"
    ];
}

function append_unique_ip(result, seen, ip) {
    ip = trim(as_string(ip));
    if (ip == "" || seen[ip])
        return;
    if (is_valid_ip(ip) != true)
        return;
    seen[ip] = true;
    push(result, ip);
}

function note_lease_pair(ip_to_name, name_to_ips, ip, name) {
    ip = trim(as_string(ip));
    name = hostname_key(name);
    if (is_valid_ip(ip) != true)
        return;
    if (name == "" || name == "*")
        return;
    ip_to_name[ip] = name;
    if (type(name_to_ips[name]) != "array")
        name_to_ips[name] = [];
    let exists = false;
    for (let current in name_to_ips[name])
        if (current == ip)
            exists = true;
    if (!exists)
        push(name_to_ips[name], ip);
}

function build_lease_index() {
    let ip_to_name = {};
    let name_to_ips = {};
    for (let path in lease_lookup_paths()) {
        let data = read_text_if_exists(path);
        if (data == "")
            continue;
        for (let line in split(data, "\n")) {
            line = trim(replace(as_string(line), /\r/g, ""));
            if (line == "" || substr(line, 0, 1) == "#")
                continue;
            let fields = split(line, /[ \t]+/);
            if (length(fields) < 2)
                continue;
            if (length(fields) >= 4 && is_valid_ip(trim(as_string(fields[2]))) == true)
                note_lease_pair(ip_to_name, name_to_ips, fields[2], fields[3]);
            if (is_valid_ip(trim(as_string(fields[0]))) == true) {
                let i = 1;
                while (i < length(fields)) {
                    note_lease_pair(ip_to_name, name_to_ips, fields[0], fields[i]);
                    i++;
                }
            }
        }
    }
    return { ip_to_name, name_to_ips };
}

function ips_from_dhcp_lease_name(name) {
    let wanted = hostname_key(name);
    let index = build_lease_index();
    if (wanted == "" || type(index.name_to_ips[wanted]) != "array")
        return [];
    return index.name_to_ips[wanted];
}

function ip_from_dhcp_lease_name(name) {
    let ips = ips_from_dhcp_lease_name(name);
    return length(ips) > 0 ? ips[0] : "";
}

function expanded_ips_for_source_value(value) {
    value = trim(as_string(value));
    let result = [];
    let seen = {};
    if (value == "")
        return result;
    if (is_valid_ip_or_cidr(value) == true && is_valid_ip(value) != true) {
        append_unique_ip(result, seen, value);
        if (length(result) == 0)
            push(result, value);
        return result;
    }
    let index = build_lease_index();
    let name = "";
    if (is_valid_ip(value) == true) {
        append_unique_ip(result, seen, value);
        name = as_string(index.ip_to_name[value] || "");
    }
    else {
        name = hostname_key(value);
    }
    if (name != "" && type(index.name_to_ips[name]) == "array")
        for (let ip in index.name_to_ips[name])
            append_unique_ip(result, seen, ip);
    return result;
}

function normalized_ip_or_cidr_list(values) {
    let result = [];
    let seen = {};
    let items = [];
    try {
        items = array_or_empty(values);
    }
    catch (e) {
        return result;
    }
    for (let raw in items) {
        let expanded = [];
        try {
            expanded = expanded_ips_for_source_value(raw);
        }
        catch (e) {
            warn(exclusion_fix_marker(), " expanded_ips_for_source_value: ", e, "\n");
            expanded = [];
        }
        if (length(expanded) == 0) {
            let value = trim(as_string(raw));
            let usable = false;
            try {
                usable = is_valid_ip_or_cidr(value);
            }
            catch (e) {
                usable = false;
            }
            if (usable == true)
                push(expanded, value);
        }
        for (let value in expanded) {
            if (seen[value])
                continue;
            seen[value] = true;
            push(result, value);
        }
    }
    return result;
}

function object_has_keys(value) {
    if (type(value) != "object")
        return false;
    for (let key in value)
        return true;
    return false;
}

function copy_rule_object(rule) {
    let copy = {};
    if (type(rule) != "object")
        return copy;
    for (let key, value in rule)
        copy[key] = value;
    return copy;
}

function settings_routing_excluded_ips() {
    let result = [];
    try {
        result = normalized_ip_or_cidr_list(list_option(runtime_settings(), "routing_excluded_ips"));
    }
    catch (e) {
        warn(exclusion_fix_marker(), " settings_routing_excluded_ips: ", e, "\n");
        result = [];
    }
    return result;
}

function section_excluded_source_ips(section) {
    let result = [];
    try {
        result = normalized_ip_or_cidr_list(list_option(section, "excluded_source_ips"));
    }
    catch (e) {
        warn(exclusion_fix_marker(), " section_excluded_source_ips: ", e, "\n");
        result = [];
    }
    return result;
}

function apply_source_exclusions(rule, excluded) {
    try {
        excluded = normalized_ip_or_cidr_list(excluded);
    }
    catch (e) {
        warn(exclusion_fix_marker(), " apply_source_exclusions: ", e, "\n");
        return rule;
    }
    if (length(excluded) == 0 || type(rule) != "object")
        return rule;

    try {
        let exclude_rule = {
            source_ip_cidr: length(excluded) == 1 ? excluded[0] : excluded,
            invert: true
        };

        let source = copy_rule_object(rule);
        if (as_string(source.type) == "logical" && as_string(source.mode) == "and" && type(source.rules) == "array") {
            let next_rules = [];
            for (let item in source.rules)
                push(next_rules, item);
            push(next_rules, exclude_rule);
            source.rules = next_rules;
            return source;
        }

        let include_rule = {};
        for (let key in [ "inbound", "source_ip_cidr", "domain", "domain_suffix", "domain_keyword", "domain_regex", "rule_set", "ip_cidr", "port", "port_range", "query_type" ])
            if (source[key] != null)
                include_rule[key] = source[key];

        let wrapped = {
            type: "logical",
            mode: "and",
            rules: object_has_keys(include_rule) ? [ include_rule, exclude_rule ] : [ exclude_rule ],
            action: source.action
        };
        if (source.outbound != null)
            wrapped.outbound = source.outbound;
        if (source.server != null)
            wrapped.server = source.server;
        if (source.rewrite_ttl != null)
            wrapped.rewrite_ttl = source.rewrite_ttl;
        return wrapped;
    }
    catch (e) {
        warn(exclusion_fix_marker(), " apply_source_exclusions wrap: ", e, "\n");
        return rule;
    }
}

function prepend_item(list, item) {
    let result = [ item ];
    for (let value in array_or_empty(list))
        push(result, value);
    return result;
}

function prepend_all(list, items) {
    let result = [];
    for (let item in array_or_empty(items))
        push(result, item);
    for (let value in array_or_empty(list))
        push(result, value);
    return result;
}

function dns_server_tag_exists(config, tag_name) {
    for (let server in array_or_empty(object_or_empty(config.dns).servers))
        if (as_string(server.tag) == as_string(tag_name))
            return true;
    return false;
}

function ensure_excluded_dns_servers(config) {
    if (type(config.dns) != "object")
        config.dns = {};
    if (type(config.dns.servers) != "array")
        config.dns.servers = [];

    let settings = runtime_settings();
    if (!dns_server_tag_exists(config, runtime_constants.EXCLUDED_DNS_SERVER_TAG))
        push(config.dns.servers, runtime_dns.excluded_tls_config(settings));
    if (!dns_server_tag_exists(config, runtime_constants.EXCLUDED_DNS_HTTPS_TAG))
        push(config.dns.servers, runtime_dns.excluded_https_config(settings));
}

function excluded_non_fakeip_rule(inbound, source) {
    return {
        type: "logical",
        mode: "and",
        rules: [
            {
                inbound,
                source_ip_cidr: source
            },
            {
                match_response: true,
                ip_cidr: [
                    runtime_constants.FAKEIP_INET4_RANGE,
                    runtime_constants.FAKEIP_INET6_RANGE
                ],
                invert: true
            }
        ],
        action: "route",
        server: runtime_constants.BOOTSTRAP_DNS_SERVER_TAG,
        disable_cache: true
    };
}
function single_or_array(values) {
    return length(values) == 1 ? values[0] : values;
}

function add_global_routing_exclusions(config) {
    let excluded = [];
    try {
        excluded = settings_routing_excluded_ips();
    }
    catch (e) {
        warn(exclusion_fix_marker(), " add_global_routing_exclusions: ", e, "\n");
        return;
    }
    if (length(excluded) == 0)
        return;

    // When Xray owns TPROXY/DNS, excluded LAN clients never hit the sidecar.
    // The DNS-exclusion rules reference SOURCE_DNS inbound that does not exist.
    if (engine.is_xray_primary())
        return;

    try {
        if (type(config.dns) != "object")
            config.dns = {};
        if (type(config.dns.rules) != "array")
            config.dns.rules = [];

        ensure_excluded_dns_servers(config);

        let inbound = source_dns_inbound_matcher();
        let source = single_or_array(excluded);
        let fakeip_proof = [
            {
                action: "evaluate",
                server: runtime_constants.BOOTSTRAP_DNS_SERVER_TAG,
                inbound,
                source_ip_cidr: source,
                disable_cache: true
            },
            excluded_non_fakeip_rule(inbound, source),
            {
                action: "route",
                server: runtime_constants.EXCLUDED_DNS_SERVER_TAG,
                inbound,
                source_ip_cidr: source,
                disable_cache: true
            },
            {
                action: "route",
                server: runtime_constants.EXCLUDED_DNS_HTTPS_TAG,
                inbound,
                source_ip_cidr: source,
                disable_cache: true
            }
        ];
        if (!sing_box_at_least_1_14()) {
            fakeip_proof = [
                {
                    action: "route",
                    server: runtime_constants.EXCLUDED_DNS_SERVER_TAG,
                    inbound,
                    source_ip_cidr: source,
                    disable_cache: true
                },
                {
                    action: "route",
                    server: runtime_constants.EXCLUDED_DNS_HTTPS_TAG,
                    inbound,
                    source_ip_cidr: source,
                    disable_cache: true
                }
            ];
        }
        config.dns.rules = prepend_all(config.dns.rules, fakeip_proof);

        insert_route_rules_after_system(config, [{
            action: "route",
            outbound: runtime_constants.BYPASS_OUTBOUND_TAG,
            inbound: tproxy_inbound_matcher(),
            source_ip_cidr: single_or_array(excluded)
        }]);
    }
    catch (e) {
        warn(exclusion_fix_marker(), " add_global_routing_exclusions apply: ", e, "\n");
    }
}

function legacy_condition_values(section, key) {
    let raw_values = object_or_empty(section)[key];
    let list_values = type(raw_values) == "array"
        ? raw_values
        : [];
    let option_text_values = type(raw_values) == "array" || key == "domain"
        ? []
        : rule_config.text_list_values(raw_values, "comma-space");
    let text_value = option(section, key + "_text", "");
    let text_values = rule_config.text_list_values(text_value, "comma-space");

    if (bool_option(section, key + "_text_mode", false) || bool_option(section, "conditions_text_mode", false))
        return text_values;
    if (length(list_values) > 0)
        return list_values;
    if (length(option_text_values) > 0)
        return option_text_values;
    return text_values;
}

function combined_domain_source_values(section) {
    let values = [];
    if (type(object_or_empty(section)["domain"]) != "array") {
        for (let value in rule_config.text_list_values(option(section, "domain", ""), "comma-space"))
            if (as_string(value) != "")
                push(values, as_string(value));
    }
    for (let value in rule_config.text_list_values(option(section, "domain_suffix_text", ""), "comma-space"))
        if (as_string(value) != "")
            push(values, as_string(value));
    for (let value in list_option(section, "domain_suffix"))
        if (as_string(value) != "")
            push(values, as_string(value));
    return values;
}

function domain_suffix_condition_value_kind(value) {
    return rule_config.prefixed_domain_kind_value(value);
}

function domain_conditions(section) {
    let result = {
        domain: [],
        domain_suffix: [],
        domain_keyword: [],
        domain_regex: []
    };

    for (let key in [ "domain", "domain_keyword", "domain_regex" ]) {
        for (let value in legacy_condition_values(section, key)) {
            let normalized = rule_config.domain_value_for_key(value, key);
            if (normalized != null)
                push(result[key], normalized);
        }
    }

    for (let value in combined_domain_source_values(section)) {
        let normalized = domain_suffix_condition_value_kind(value);
        if (normalized != null)
            push(result[normalized.kind], normalized.value);
    }

    return result;
}

function add_domain_array(rule, key, values) {
    if (length(values) > 0)
        rule[key] = values;
}

function push_dns_matcher_rule(config, rule) {
    push(config.dns.rules, rule);
}

function section_dns_server(section) {
    if (engine.is_xray_primary())
        return runtime_constants.DNS_SERVER_TAG;
    return option(section, "action", "") == "bypass"
        ? runtime_constants.DNS_SERVER_TAG
        : runtime_constants.FAKEIP_DNS_SERVER_TAG;
}

function copy_dns_matchers(matchers) {
    let copy = {};
    for (let key, value in matchers)
        copy[key] = value;
    return copy;
}

function add_source_dns_matchers(rule, source_ip_cidr) {
    if (length(source_ip_cidr) == 0)
        return;

    rule.inbound = source_dns_inbound_matcher();
    rule.source_ip_cidr = single_or_array(source_ip_cidr);
}

function add_source_aware_bypass_dns_rules(config, matchers, rewrite_ttl, excluded) {
    excluded = array_or_empty(excluded);

    if (sing_box_at_least_1_14()) {
        let evaluate_rule = copy_dns_matchers(matchers);
        evaluate_rule.action = "evaluate";
        evaluate_rule.server = runtime_constants.DNS_SERVER_TAG;
        push_dns_matcher_rule(config, apply_source_exclusions(evaluate_rule, excluded));

        push_dns_matcher_rule(config, apply_source_exclusions({
            type: "logical",
            mode: "and",
            rules: [
                copy_dns_matchers(matchers),
                {
                    match_response: true,
                    ip_cidr: [ runtime_constants.FAKEIP_INET4_RANGE, runtime_constants.FAKEIP_INET6_RANGE ],
                    invert: true
                }
            ],
            action: "route",
            server: runtime_constants.DNSMASQ_DNS_SERVER_TAG,
            rewrite_ttl
        }, excluded));
    }
    else {
        let legacy = copy_dns_matchers(matchers);
        legacy.action = "route";
        legacy.server = runtime_constants.DNSMASQ_DNS_SERVER_TAG;
        legacy.ip_cidr = [ runtime_constants.FAKEIP_INET4_RANGE, runtime_constants.FAKEIP_INET6_RANGE ];
        legacy.invert = true;
        legacy.rewrite_ttl = rewrite_ttl;
        push_dns_matcher_rule(config, apply_source_exclusions(legacy, excluded));
    }

    let fallback = copy_dns_matchers(matchers);
    fallback.action = "route";
    fallback.server = runtime_constants.DNS_SERVER_TAG;
    fallback.query_type = [ "A", "AAAA" ];
    fallback.rewrite_ttl = rewrite_ttl;
    push_dns_matcher_rule(config, apply_source_exclusions(fallback, excluded));
}

function add_section_dns_matcher_rule(config, section, matchers, rewrite_ttl) {
    let source_ip_cidr = legacy_condition_values(section, "source_ip_cidr");
    let excluded = section_excluded_source_ips(section);
    add_source_dns_matchers(matchers, source_ip_cidr);

    if (option(section, "action", "") == "bypass" && length(source_ip_cidr) > 0) {
        add_source_aware_bypass_dns_rules(config, matchers, rewrite_ttl, excluded);
        return;
    }

    matchers.action = "route";
    matchers.server = section_dns_server(section);
    matchers.rewrite_ttl = rewrite_ttl;
    push_dns_matcher_rule(config, apply_source_exclusions(matchers, excluded));
}

function source_aware_dns_sources(sections) {
    let seen = {};
    let values = [];

    for (let value in settings_routing_excluded_ips()) {
        value = trim(as_string(value));
        if (value != "" && !seen[value]) {
            seen[value] = true;
            push(values, value);
        }
    }

    for (let section in sections) {
        let action = option(section, "action", "");
        let candidates = [];
        if (connections.has_dns_matchers(section))
            for (let value in legacy_condition_values(section, "source_ip_cidr"))
                push(candidates, value);
        if (action == "bypass" || action == "dns")
            for (let value in list_option(section, "fully_routed_ips"))
                push(candidates, value);

        for (let value in candidates) {
            value = trim(as_string(value));
            if (value != "" && !seen[value]) {
                seen[value] = true;
                push(values, value);
            }
        }
    }

    return values;
}

function add_source_aware_dns_support(config, source_ip_cidr) {
    if (length(source_ip_cidr) == 0)
        return;

    push(config.dns.servers, {
        type: "udp",
        tag: runtime_constants.DNSMASQ_DNS_SERVER_TAG,
        server: "127.0.0.1",
        server_port: 53
    });
}

function add_source_aware_dns_fallback(config, source_ip_cidr) {
    if (length(source_ip_cidr) == 0)
        return;

    let rule = {
        action: "route",
        server: runtime_constants.DNSMASQ_DNS_SERVER_TAG,
        rewrite_ttl: int_option(runtime_settings(), "dns_rewrite_ttl", "60")
    };
    add_source_dns_matchers(rule, source_ip_cidr);
    push_dns_matcher_rule(config, rule);
}

function dns_action_server_tag(section_name) {
    return runtime_constants.tag(section_name, "dns-server");
}

function dns_action_detour_tag(section) {
    if (!bool_option(section, "dns_detour_enabled", false))
        return "";
    let target_section = option(section, "dns_detour_section", "");
    return target_section == "" ? "" : outbound_tag(target_section);
}

function add_dns_server_for_section(config, section) {
    let server = runtime_dns.server_from_options(
        dns_action_server_tag(section[".name"]),
        option(section, "dns_type", "udp"),
        runtime_dns.with_certificate_name(
            option(section, "dns_server", ""),
            option(section, "dns_type", "udp"),
            option(section, "dns_server_name", "")
        ),
        dns_action_detour_tag(section)
    );
    if (server.unsupported)
        runtime_generate_unsupported(server.unsupported);
    push(config.dns.servers, server);
}

function add_dns_action_rules_for_section(config, section) {
    let domains = domain_conditions(section);
    let domain = domains.domain;
    let domain_suffix = domains.domain_suffix;
    let domain_keyword = domains.domain_keyword;
    let domain_regex = domains.domain_regex;
    let rule_set_tags = [];
    let section_name = section[".name"];
    let source_ip_cidr = legacy_condition_values(section, "source_ip_cidr");
    let fully_routed_ips = list_option(section, "fully_routed_ips");

    for (let community in connections.community_lists(section)) {
        let ensured = ensure_community_ruleset(config, section_name, as_string(community));
        push(rule_set_tags, ensured.tag);
    }
    for (let reference in connections.rule_sets(section)) {
        let ensured = ensure_custom_ruleset(config, as_string(reference));
        if (ensured.kind == "domains")
            push(rule_set_tags, ensured.tag);
    }
    add_domain_ip_list_ruleset(
        config,
        section_name,
        [],
        rule_set_tags,
        list_option(section, "domain_ip_lists"),
        true
    );

    let rewrite_ttl = int_option(runtime_settings(), "dns_rewrite_ttl", "60");
    let server_tag = dns_action_server_tag(section_name);
    let excluded = section_excluded_source_ips(section);
    let has_inline_domains = length(domain) > 0 || length(domain_suffix) > 0 ||
        length(domain_keyword) > 0 || length(domain_regex) > 0;

    if (length(fully_routed_ips) > 0) {
        let dns_rule = {
            action: "route",
            server: server_tag,
            rewrite_ttl
        };
        add_source_dns_matchers(dns_rule, fully_routed_ips);
        push_dns_matcher_rule(config, apply_source_exclusions(dns_rule, excluded));
    }
    if (has_inline_domains) {
        let dns_rule = {
            action: "route",
            server: server_tag,
            rewrite_ttl
        };
        add_domain_array(dns_rule, "domain", domain);
        add_domain_array(dns_rule, "domain_suffix", domain_suffix);
        add_domain_array(dns_rule, "domain_keyword", domain_keyword);
        add_domain_array(dns_rule, "domain_regex", domain_regex);
        add_source_dns_matchers(dns_rule, source_ip_cidr);
        push_dns_matcher_rule(config, apply_source_exclusions(dns_rule, excluded));
    }
    if (length(rule_set_tags) > 0) {
        let dns_rule = {
            action: "route",
            server: server_tag,
            rewrite_ttl,
            rule_set: single_or_array(rule_set_tags)
        };
        add_source_dns_matchers(dns_rule, source_ip_cidr);
        push_dns_matcher_rule(config, apply_source_exclusions(dns_rule, excluded));
    }
    if (!has_inline_domains && length(rule_set_tags) == 0 && length(fully_routed_ips) == 0)
        runtime_generate_unsupported("DNS action '" + section_name + "' has no domain matchers");
}

function normalize_port_number_value(value) {
    return rule_config.normalize_port_number_value(value);
}

function add_port_matchers(rule, section) {
    let values = [];
    for (let value in list_option(section, "ports"))
        push(values, value);
    for (let value in rule_config.text_list_values(option(section, "ports_text", ""), "comma-space"))
        push(values, value);

    let ports = [];
    let port_ranges = [];
    let seen = {};
    for (let value in values) {
        value = trim(as_string(value));
        if (value == "" || seen[value])
            continue;
        seen[value] = true;

        let dash = index(value, "-");
        if (dash < 0) {
            let port = normalize_port_number_value(value);
            if (port != null)
                push(ports, port);
            continue;
        }

        let start = normalize_port_number_value(substr(value, 0, dash));
        let end = normalize_port_number_value(substr(value, dash + 1));
        if (start != null && end != null && start <= end)
            push(port_ranges, start == end ? as_string(start) : sprintf("%d:%d", start, end));
    }

    if (length(ports) > 0)
        rule.port = ports;
    if (length(port_ranges) > 0)
        rule.port_range = port_ranges;
}

function add_fully_routed_ips_rules(config, section) {
    let source_ip_cidr = list_option(section, "fully_routed_ips");
    if (length(source_ip_cidr) == 0)
        return;

    let excluded = section_excluded_source_ips(section);
    if (option(section, "action", "") == "bypass") {
        let dns_matchers = {};
        add_source_dns_matchers(dns_matchers, source_ip_cidr);
        add_source_aware_bypass_dns_rules(
            config,
            dns_matchers,
            int_option(runtime_settings(), "dns_rewrite_ttl", "60"),
            excluded
        );
    }

    let target = runtime_route.target(section, outbound_tag(section[".name"]));
    if (target.unsupported)
        runtime_generate_unsupported(target.unsupported);

    if (engine.is_xray_primary() && connections.proxy_core(section) == "sing-box") {
        let spec = engine.fullroute_sidecar_spec(section[".name"]);
        if (spec == null)
            return;
        push(config.inbounds, {
            type: "mixed",
            tag: spec.inbound_tag,
            listen: "127.0.0.1",
            listen_port: spec.port,
            tcp_fast_open: true,
            udp_fragment: true
        });
        let route_rule = {
            action: target.action,
            inbound: spec.inbound_tag
        };
        if (target.outbound)
            route_rule.outbound = target.outbound;
        push(config.route.rules, route_rule);
        return;
    }

    let route_rule = {
        action: target.action,
        inbound: tproxy_inbound_matcher()
    };
    if (target.outbound)
        route_rule.outbound = target.outbound;
    route_rule.source_ip_cidr = single_or_array(source_ip_cidr);
    push(config.route.rules, apply_source_exclusions(route_rule, excluded));
}

function add_combined_route_for_section(config, section) {
    let domains = domain_conditions(section);
    let domain = domains.domain;
    let domain_suffix = domains.domain_suffix;
    let domain_keyword = domains.domain_keyword;
    let domain_regex = domains.domain_regex;
    let ip_cidr = legacy_condition_values(section, "ip_cidr");
    let source_ip_cidr = legacy_condition_values(section, "source_ip_cidr");
    let rule_set_tags = [];
    let dns_rule_set_tags = [];
    let section_name = section[".name"];

    add_fully_routed_ips_rules(config, section);

    for (let community in connections.community_lists(section)) {
        let ensured = ensure_community_ruleset(config, section_name, as_string(community));
        push(rule_set_tags, ensured.tag);
        push(dns_rule_set_tags, ensured.tag);
    }
    for (let reference in connections.rule_sets(section)) {
        let ensured = ensure_custom_ruleset(config, as_string(reference));
        push(rule_set_tags, ensured.tag);
        if (ensured.kind == "domains")
            push(dns_rule_set_tags, ensured.tag);
    }
    for (let reference in connections.rule_sets_with_subnets(section)) {
        let ensured = ensure_custom_ruleset(config, as_string(reference));
        push(rule_set_tags, ensured.tag);
        if (ensured.kind == "domains")
            push(dns_rule_set_tags, ensured.tag);
    }
    add_domain_ip_list_ruleset(
        config,
        section_name,
        rule_set_tags,
        dns_rule_set_tags,
        list_option(section, "domain_ip_lists"),
        false
    );

    let target = runtime_route.target(section, outbound_tag(section_name));
    if (target.unsupported)
        runtime_generate_unsupported(target.unsupported);
    let route_rule = {
        action: target.action,
        inbound: tproxy_inbound_matcher()
    };
    if (target.outbound)
        route_rule.outbound = target.outbound;
    add_domain_array(route_rule, "domain", domain);
    add_domain_array(route_rule, "domain_suffix", domain_suffix);
    add_domain_array(route_rule, "domain_keyword", domain_keyword);
    add_domain_array(route_rule, "domain_regex", domain_regex);
    if (length(ip_cidr) > 0)
        route_rule.ip_cidr = ip_cidr;
    if (length(source_ip_cidr) > 0)
        route_rule.source_ip_cidr = source_ip_cidr;
    add_port_matchers(route_rule, section);
    if (length(rule_set_tags) > 0)
        route_rule.rule_set = single_or_array(rule_set_tags);

    let excluded = section_excluded_source_ips(section);
    let has_route_matchers = route_rule.domain != null || route_rule.domain_suffix != null ||
        route_rule.domain_keyword != null || route_rule.domain_regex != null ||
        route_rule.ip_cidr != null || route_rule.port != null || route_rule.port_range != null ||
        route_rule.rule_set != null;
    if (has_route_matchers) {
        let resolve = runtime_route.resolve_rule_for_section(section, route_rule);
        if (type(resolve) == "object" && resolve.warning)
            warn(resolve.warning, "\n");
        else if (type(resolve) == "object" && resolve.rule)
            push(config.route.rules, apply_source_exclusions(resolve.rule, excluded));
        push(config.route.rules, apply_source_exclusions(route_rule, excluded));
    }

    let rewrite_ttl = int_option(runtime_settings(), "dns_rewrite_ttl", "60");
    if (length(domain) > 0 || length(domain_suffix) > 0 || length(domain_keyword) > 0 || length(domain_regex) > 0) {
        let dns_rule = {};
        add_domain_array(dns_rule, "domain", domain);
        add_domain_array(dns_rule, "domain_suffix", domain_suffix);
        add_domain_array(dns_rule, "domain_keyword", domain_keyword);
        add_domain_array(dns_rule, "domain_regex", domain_regex);
        add_section_dns_matcher_rule(config, section, dns_rule, rewrite_ttl);
    }
    if (length(dns_rule_set_tags) > 0) {
        add_section_dns_matcher_rule(config, section, {
            rule_set: single_or_array(dns_rule_set_tags)
        }, rewrite_ttl);
    }
}

function unsupported_matcher_key(section) {
    let unsupported_options = [
        "subnet", "subnet_text",
        "local_domain_lists", "local_subnet_lists",
        "remote_domain_lists", "remote_subnet_lists"
    ];
    for (let key in unsupported_options) {
        if (length(list_option(section, key)) > 0 || option(section, key, "") != "")
            return key;
    }
    return "";
}

function add_outbound_for_section(config, section, taken, sections) {
    let action = option(section, "action", "");
    let section_name = section[".name"];
    if (!valid_section_name(section_name))
        runtime_generate_unsupported("section name is not safe for sing-box config generation");
    let unsupported_matcher = unsupported_matcher_key(section);
    if (unsupported_matcher != "")
        runtime_generate_unsupported("section has unsupported matcher " + unsupported_matcher);

    if (connections.is_connections_action(action)) {
        if (connections.proxy_core(section) == "xray")
            add_xray_sidecar_outbound(config, section, taken);
        else
            add_connections_outbound(config, section, taken);
    }
    else if (action == "zapret")
        add_zapret_outbound(config, section, sections);
    else if (action == "zapret2")
        add_zapret2_outbound(config, section, sections);
    else if (action == "byedpi")
        add_byedpi_outbound(config, section, sections);
    else if (action == "bypass") {
        /* route-only action */
    }
    else if (action == "block") {
        /* route-only action */
    }
    else if (action == "dns") {
        add_dns_server_for_section(config, section);
    }
    else {
        runtime_generate_unsupported("unsupported action " + action);
    }
}

function reserve_section_outbound_tags(sections, taken) {
    for (let section in sections) {
        let action = option(section, "action", "");
        if (connections.is_connections_action(action) ||
            action == "byedpi" || action == "zapret" || action == "zapret2")
            taken[outbound_tag(section[".name"])] = true;

        if (!connections.is_connections_action(action))
            continue;

        for (let urltest_id in connections.urltests(section))
            taken[urltest_outbound_tag(section[".name"], urltest_id)] = true;
        for (let group_id in connections.priority_groups(section))
            taken[priority_outbound_tag(section[".name"], group_id)] = true;
    }
}

function add_route_for_section(config, section) {
    if (option(section, "action", "") == "dns")
        add_dns_action_rules_for_section(config, section);
    else
        add_combined_route_for_section(config, section);
}

function add_service_route_rules(config, sections) {
    add_global_routing_exclusions(config);

    let first = null;
    for (let section in sections) {
        let action = option(section, "action", "");
        if (connections.is_connections_action(action) ||
            action == "byedpi" || action == "zapret" || action == "zapret2") {
            first = section;
            break;
        }
    }
    if (first != null) {
        push(config.route.rules, {
            action: "route",
            inbound: tproxy_inbound_matcher(),
            outbound: outbound_tag(first[".name"]),
            domain: runtime_constants.CHECK_PROXY_IP_DOMAIN
        });
    }
    push(config.route.rules, {
        action: "route-options",
        domain: runtime_constants.FAKEIP_TEST_DOMAIN,
        override_port: 8443
    });
}

function deferred_section_set(value) {
    let result = {};
    for (let name in split(trim(as_string(value)), /[ \t\r\n]+/)) {
        name = as_string(name);
        if (name != "")
            result[name] = true;
    }
    return result;
}

function enabled_sections(deferred_sections) {
    let deferred = deferred_section_set(deferred_sections);
    let result = [];
    uci_cursor().foreach(CONFIG_NAME, "section", function(section) {
        if (section_enabled(section) && !deferred[as_string(section[".name"])])
            push(result, section);
    });
    return result;
}

function openconnect_servers_without_cookie() {
    let disabled = {};
    uci_cursor().load(CONFIG_NAME);
    for (let section in enabled_sections("")) {
        for (let client in connections.openconnect_clients(section)) {
            if (openconnect_cookie_auto(client))
                continue;
            let server = trim(option(client, "server", ""));
            if (server == "")
                continue;
            let target = openconnect_server_target(server);
            let key = target.port == "" ? target.host : target.host + ":" + target.port;
            disabled[openconnect_peer_key(key)] = true;
        }
    }
    return disabled;
}

function enabled_servers() {
    let result = [];
    uci_cursor().foreach(CONFIG_NAME, "server", function(section) {
        if (section_enabled(section))
            push(result, section);
    });
    return result;
}

function section_by_name(sections, name) {
    name = as_string(name);
    for (let section in sections)
        if (as_string(section[".name"]) == name)
            return section;
    return null;
}

function sidecar_inbound_exists(config, tag_name) {
    tag_name = as_string(tag_name);
    for (let inbound in array_or_empty(config.inbounds))
        if (type(inbound) == "object" && as_string(inbound.tag) == tag_name)
            return true;
    return false;
}

function ensure_dns_detour_sidecars(config, sections) {
    if (!engine.is_xray_primary())
        return;
    let extra = [];
    for (let spec in engine.fullroute_sidecar_specs()) {
        let section = section_by_name(sections, spec.name);
        if (section == null)
            continue;
        if (!sidecar_inbound_exists(config, spec.inbound_tag)) {
            push(config.inbounds, {
                type: "mixed",
                tag: spec.inbound_tag,
                listen: "127.0.0.1",
                listen_port: spec.port,
                tcp_fast_open: true,
                udp_fragment: true
            });
        }
        let target = runtime_route.target(section, outbound_tag(spec.name));
        if (target.unsupported)
            continue;
        let rule = {
            action: target.action,
            inbound: spec.inbound_tag
        };
        if (target.outbound)
            rule.outbound = target.outbound;
        push(extra, rule);
    }
    insert_route_rules_after_system(config, extra);
}

function add_server_routes(config, servers, sections) {
    for (let server in servers) {
        runtime_servers.add_sniff_rule(config, server);

        let inbound = runtime_constants.server_inbound_tag(server[".name"]);
        let routing_mode = option(server, "routing_mode", "rules");
        if (routing_mode == "rules") {
            runtime_servers.clone_rules_for_inbound(
                config,
                runtime_constants.TPROXY_INBOUND_TAG,
                inbound,
                runtime_constants.CHECK_PROXY_IP_DOMAIN
            );
        }
        else if (routing_mode == "direct") {
            push(config.route.rules, {
                action: "route",
                inbound,
                outbound: runtime_constants.DIRECT_OUTBOUND_TAG
            });
        }
        else if (routing_mode == "section") {
            let routing_section_name = option(server, "routing_section", "");
            let routing_section = section_by_name(sections, routing_section_name);
            if (routing_section == null)
                runtime_generate_unsupported("server references missing routing section " + routing_section_name);
            let action = option(routing_section, "action", "");
            if (action == "bypass" || action == "block")
                runtime_generate_unsupported("server routing section " + routing_section_name + " cannot use action " + action);
            let target = runtime_route.target(routing_section, outbound_tag(routing_section[".name"]));
            if (target.unsupported)
                runtime_generate_unsupported(target.unsupported);
            let rule = {
                action: target.action,
                inbound
            };
            if (target.outbound)
                rule.outbound = target.outbound;
            push(config.route.rules, rule);
        }
        else {
            runtime_generate_unsupported("unsupported server routing_mode " + routing_mode);
        }
    }
}

function write_openconnect_probe_ports(config) {
    let ports = type(config) == "object" ? object_or_empty(config.__oc_probe_ports) : {};
    let dir = "/var/run/forkop";
    if (fs.stat(dir) == null)
        system("mkdir -p " + dir + " >/dev/null 2>&1");
    fs.writefile(dir + "/openconnect-probe.json", sprintf("%J\n", ports));
}

function generate_config(output_path, service_address, mwan3_active, supports_xhttp, deferred_sections) {
    runtime_supports_xhttp = supports_xhttp == null || as_string(supports_xhttp) == ""
        ? true
        : cli_bool(supports_xhttp);
    let cursor = uci_cursor();
    cursor.load(CONFIG_NAME);
    runtime_settings_cache = object_or_empty(cursor.get_all(CONFIG_NAME, "settings"));
    let settings = runtime_settings_cache;

    let sections = enabled_sections(deferred_sections);
    let servers = engine.is_xray_primary() ? [] : enabled_servers();
    if (length(sections) == 0 && length(servers) == 0 && trim(as_string(deferred_sections)) == "")
        runtime_generate_unsupported("no enabled sections");

    let source_aware_dns = source_aware_dns_sources(sections);
    let config = base_config(settings, service_address, {
        mwan3_active: cli_bool(mwan3_active),
        source_aware_dns: length(source_aware_dns) > 0
    });
    add_source_aware_dns_support(config, source_aware_dns);
    let taken = reserved_runtime_tag_set(config.outbounds);
    reserve_section_outbound_tags(sections, taken);
    for (let server in servers)
        runtime_servers.add_server(config, server);
    for (let section in sections)
        add_outbound_for_section(config, section, taken, sections);
    add_service_route_rules(config, sections);
    for (let section in sections)
        add_route_for_section(config, section);
    add_source_aware_dns_fallback(config, source_aware_dns);
    add_server_routes(config, servers, sections);
    add_service_mixed_proxy(config, settings, sections);
    for (let section in sections)
        add_mixed_proxy_for_section(config, section, service_address);
    add_xray_cascade_inbounds(config);
    ensure_dns_detour_sidecars(config, sections);
    add_router_traffic_redirect(config, settings);

    assert_unique_outbound_tags(config);
    apply_http_clients(config);
    write_openconnect_probe_ports(config);
    strip_internal_fields(config);
    strip_redirect_inbound_network(config);
    if (!write_json_file(output_path, config)) {
        warn("failed to write ", output_path, "\n");
        exit(1);
    }
}

function generate_config_fixture(fixture_path, output_path, service_address, mwan3_active, supports_xhttp, deferred_sections) {
    use_fixture_cursor(fixture_path);
    runtime_subscription.set_section_cache_dir(output_path + ".section-cache");
    runtime_ruleset_folder = output_path + ".rulesets";
    generate_config(output_path, service_address, mwan3_active, supports_xhttp, deferred_sections);
}

function stdin_length() {
    let value = read_stdin_json();
    if (type(value) == "array" || type(value) == "object")
        print(length(value), "\n");
    else
        print("0\n");
}

function stdin_contains(needle) {
    return index(read_stdin(), as_string(needle)) >= 0;
}

function stdin_regex_matches(pattern) {
    pattern = as_string(pattern);
    if (pattern == "")
        return false;

    try {
        return match(read_stdin(), regexp(pattern)) != null;
    }
    catch (e) {
        return false;
    }
}

function ip_addr_first_inet4() {
    for (let line in split(read_stdin(), "\n")) {
        let fields = split(trim(as_string(line)), /[ \t]+/);
        if (length(fields) < 2 || fields[0] != "inet")
            continue;

        let slash = index(fields[1], "/");
        print(slash >= 0 ? substr(fields[1], 0, slash) : fields[1], "\n");
        return;
    }
}

function stdin_first_dns_a_address() {
    for (let line in split(read_stdin(), "\n")) {
        line = as_string(line);
        if (match(line, /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) != null) {
            print(line, "\n");
            return;
        }
    }
}

function stdin_first_dns_aaaa_address() {
    for (let line in split(read_stdin(), "\n")) {
        line = as_string(line);
        if (match(line, /^[0-9A-Fa-f:]+$/) != null) {
            print(line, "\n");
            return;
        }
    }
}

function stdin_first_nslookup_address() {
    for (let line in split(read_stdin(), "\n")) {
        line = as_string(line);
        if (match(line, /^Address[ \t]*[0-9]*:[ \t]*[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) == null &&
            match(line, /^Address[ \t]*[0-9]*:[ \t]*[0-9A-Fa-f:]+$/) == null)
            continue;

        let fields = split(trim(line), /[ \t]+/);
        if (length(fields) > 0)
            print(fields[length(fields) - 1], "\n");
        return;
    }
}

function stdin_first_field() {
    let data = read_stdin();
    let newline = index(data, "\n");
    let line = newline >= 0 ? substr(data, 0, newline) : data;
    let fields = split(trim(as_string(line)), /[ \t\r\n]+/);

    if (length(fields) > 0 && fields[0] != "")
        print(fields[0], "\n");
}

function array_append_string(value) {
    let result = array_or_empty(read_stdin_json());
    push(result, as_string(value));
    write_json(result);
}

function normalized_country_list() {
    write_json(runtime_urltest.normalized_country_list(read_stdin_json()));
}

function urltest_filter(mode, tags_path, names_path, countries_path, names_filter_path, regex_tags_path, countries_filter_path) {
    write_json(runtime_urltest.filter_array(
        mode,
        read_json_file(tags_path),
        read_json_file(names_path),
        read_json_file(countries_path),
        read_json_file(names_filter_path),
        read_json_file(regex_tags_path),
        read_json_file(countries_filter_path)
    ));
}

function object_nonempty_stdin() {
    let value = read_stdin_json();
    return (type(value) == "array" || type(value) == "object") && length(value) > 0;
}

function strip_download_routing_marks(config) {
    for (let outbound in array_or_empty(config.outbounds)) {
        if (type(outbound) != "object")
            continue;
        delete outbound.routing_mark;
    }
}

function drop_missing_download_detours(config) {
    let known = {};
    for (let outbound in array_or_empty(config.outbounds)) {
        if (type(outbound) != "object")
            continue;
        let tag_name = as_string(outbound.tag || "");
        if (tag_name != "")
            known[tag_name] = true;
    }
    for (let outbound in array_or_empty(config.outbounds)) {
        if (type(outbound) != "object")
            continue;
        let detour = as_string(outbound.detour || "");
        if (detour == "" || known[detour])
            continue;
        warn("download socks: detour '", detour, "' is not in this process; dialing directly\n");
        delete outbound.detour;
    }
}

function download_bootstrap_servers(settings) {
    let values = list_option(settings, "bootstrap_dns_server");
    if (length(values) == 0)
        values = [ "77.88.8.8" ];
    let servers = [];
    let index = 0;
    for (let value in values) {
        value = trim(as_string(value));
        if (value == "")
            continue;
        index++;
        let tag_name = index == 1
            ? runtime_constants.BOOTSTRAP_DNS_SERVER_TAG
            : runtime_constants.BOOTSTRAP_DNS_SERVER_TAG + "-" + index;
        let server = runtime_url.host(value);
        let port = runtime_url.port(value);
        push(servers, {
            type: "udp",
            tag: tag_name,
            server: server != "" ? server : value,
            server_port: port != "" ? int(port, 10) : 53
        });
    }
    if (length(servers) == 0)
        push(servers, {
            type: "udp",
            tag: runtime_constants.BOOTSTRAP_DNS_SERVER_TAG,
            server: "77.88.8.8",
            server_port: 53
        });
    return servers;
}

function uci_section_by_name(section_name) {
    section_name = as_string(section_name);
    let found = [];
    uci_cursor().load(CONFIG_NAME);
    uci_cursor().foreach(CONFIG_NAME, "section", function(section) {
        if (as_string(section[".name"]) == section_name)
            push(found, section);
    });
    return length(found) > 0 ? found[length(found) - 1] : null;
}

function section_detour_chain(section) {
    let chain = [];
    let seen = {};
    seen[as_string(section[".name"])] = true;
    let current = section;
    while (true) {
        let target_name = outbound_detour_tag_for_section(current) == ""
            ? ""
            : option(current, "outbound_detour_section", "");
        target_name = as_string(target_name);
        if (target_name == "" || seen[target_name])
            break;
        seen[target_name] = true;
        let target = uci_section_by_name(target_name);
        if (target == null)
            break;
        if (!connections.is_connections_action(option(target, "action", "")))
            break;
        if (connections.proxy_core(target) != "sing-box")
            break;
        push(chain, target);
        current = target;
    }
    return chain;
}

// Local SOCKS for one section. No TPROXY, DNS listen, nft, or routing marks.
function generate_download_socks(section_name, output_path, listen_port, keep_marks) {
    section_name = trim(as_string(section_name));
    output_path = as_string(output_path);
    listen_port = int(listen_port, 10);
    if (!valid_section_name(section_name))
        runtime_generate_unsupported("download socks section name is not safe");
    if (output_path == "")
        runtime_generate_unsupported("download socks output path is empty");
    if (listen_port == null || listen_port < 1 || listen_port > 65535)
        runtime_generate_unsupported("download socks port is invalid");

    runtime_settings_cache = null;
    let section = uci_section_by_name(section_name);
    if (section == null)
        runtime_generate_unsupported("download socks section was not found: " + section_name);
    if (!connections.is_connections_action(option(section, "action", "")))
        runtime_generate_unsupported("download socks section is not a connection: " + section_name);
    if (connections.proxy_core(section) != "sing-box")
        runtime_generate_unsupported("download socks section core is not sing-box: " + section_name);

    let settings = runtime_settings();
    let inbound_tag = "forkop-download";
    let config = {
        log: {
            disabled: false,
            level: option(settings, "log_level", "warn"),
            timestamp: false
        },
        dns: {
            servers: download_bootstrap_servers(settings),
            rules: [],
            final: runtime_constants.BOOTSTRAP_DNS_SERVER_TAG,
            strategy: option(settings, "dns_strategy", "prefer_ipv4")
        },
        inbounds: [{
            type: "mixed",
            tag: inbound_tag,
            listen: "127.0.0.1",
            listen_port: listen_port
        }],
        outbounds: [
            { type: "direct", tag: runtime_constants.DIRECT_OUTBOUND_TAG }
        ],
        route: {
            rules: [{
                action: "route",
                inbound: inbound_tag,
                outbound: outbound_tag(section_name)
            }],
            rule_set: [],
            final: runtime_constants.DIRECT_OUTBOUND_TAG,
            auto_detect_interface: true,
            default_domain_resolver: runtime_constants.BOOTSTRAP_DNS_SERVER_TAG
        }
    };
    if (!sing_box_at_least_1_14())
        config.dns.independent_cache = true;

    runtime_subscription.set_section_cache_dir(output_path + ".sections");
    let taken = {};
    taken[runtime_constants.DIRECT_OUTBOUND_TAG] = true;
    let chain = section_detour_chain(section);
    for (let i = length(chain) - 1; i >= 0; i--)
        add_connections_outbound(config, chain[i], taken);
    add_connections_outbound(config, section, taken);
    drop_missing_download_detours(config);
    if (keep_marks)
        config.route.default_mark = runtime_constants.OUTBOUND_MARK;
    else
        strip_download_routing_marks(config);
    strip_internal_fields(config);
    if (!ensure_parent_dir(output_path) || !write_json_file(output_path, config))
        runtime_generate_unsupported("failed to write download socks config");
}

function openconnect_cascade_dir() {
    return "/var/run/forkop/oc-cascade";
}

function openconnect_tcp_listening(port) {
    port = int(port || 0);
    if (port <= 0)
        return false;
    let needle = ":" + sprintf("%04X", port);
    for (let path in [ "/proc/net/tcp", "/proc/net/tcp6" ]) {
        let data = fs.readfile(path);
        if (data == null)
            continue;
        for (let line in split(as_string(data), "\n")) {
            if (index(line, needle) < 0)
                continue;
            if (match(line, /[ \t]0A[ \t]/) != null)
                return true;
        }
    }
    return false;
}

function openconnect_shell_join(args) {
    let parts = [];
    for (let arg in args)
        push(parts, openconnect_shell_quote(arg));
    return join(" ", parts);
}

function openconnect_client_needs_cascade_cookie(client) {
    if (trim(option(client, "server", "")) == "")
        return false;
    if (bool_option(client, "advanced", false) && trim(option(client, "cookie", "")) != "")
        return false;
    if (trim(option(client, "username", option(client, "openconnect_username", ""))) == "" ||
        option(client, "password", option(client, "openconnect_password", "")) == "")
        return false;
    return openconnect_cookie_auto(client);
}

function openconnect_singbox_detour_names() {
    let names = [];
    let seen = {};
    uci_cursor().load(CONFIG_NAME);
    for (let section in enabled_sections("")) {
        if (!bool_option(section, "outbound_detour_enabled", false))
            continue;
        if (!connections.is_connections_action(option(section, "action", "")))
            continue;
        let target_name = trim(option(section, "outbound_detour_section", ""));
        if (target_name == "" || seen[target_name])
            continue;
        let needs_cookie = false;
        for (let client in connections.openconnect_clients(section)) {
            if (openconnect_client_needs_cascade_cookie(client)) {
                needs_cookie = true;
                break;
            }
        }
        if (!needs_cookie)
            continue;
        let target = uci_section_by_name(target_name);
        if (target == null || connections.proxy_core(target) != "sing-box")
            continue;
        if (!section_enabled(target) || !connections.is_connections_action(option(target, "action", "")))
            continue;
        seen[target_name] = true;
        push(names, target_name);
    }
    return names;
}

function stop_openconnect_cascade() {
    let dir = openconnect_cascade_dir();
    let raw = "";
    try {
        raw = fs.readfile(dir + "/pids");
    }
    catch (e) {
        raw = "";
    }
    for (let pid in split(as_string(raw), "\n")) {
        pid = trim(pid);
        if (match(pid, /^[0-9]+$/) == null)
            continue;
        system("kill " + pid + " >/dev/null 2>&1");
    }
    system("mkdir -p /var/run/forkop " + openconnect_shell_quote(dir) + " >/dev/null 2>&1");
    fs.writefile("/var/run/forkop/openconnect-cascade.json", "{}\n");
    try {
        fs.unlink(dir + "/pids");
    }
    catch (e) { }
}

function prepare_openconnect_cascade() {
    stop_openconnect_cascade();
    let names = openconnect_singbox_detour_names();
    if (length(names) == 0)
        return 0;
    let bin = getenv("FORKOP_SING_BOX_BIN") || getenv("SING_BOX_BIN") || "/usr/bin/sing-box";
    if (fs.stat(bin) == null) {
        openconnect_log("OpenConnect cascade proxy was not started: sing-box binary is missing.");
        return 1;
    }
    let dir = openconnect_cascade_dir();
    system("mkdir -p " + openconnect_shell_quote(dir) + " >/dev/null 2>&1");
    let ports = {};
    let pids = [];
    let index = 0;
    for (let name in names) {
        let port = 39220 + index;
        index++;
        let cfg = dir + "/" + name + ".json";
        let log_path = dir + "/" + name + ".log";
        let pid_path = dir + "/" + name + ".pid";
        generate_download_socks(name, cfg, port, true);
        if (system(openconnect_shell_join([ bin, "check", "-c", cfg ]) + " >" + openconnect_shell_quote(log_path) + " 2>&1") != 0) {
            openconnect_log("OpenConnect cascade proxy for '" + name + "' was rejected by sing-box.");
            stop_openconnect_cascade();
            return 1;
        }
        let started = system(
            "setsid " + openconnect_shell_join([ bin, "run", "-c", cfg, "-D", dir ]) +
            " >>" + openconnect_shell_quote(log_path) + " 2>&1 1000>&- & echo $! > " +
            openconnect_shell_quote(pid_path)
        );
        if (started != 0) {
            openconnect_log("OpenConnect cascade proxy for '" + name + "' failed to start.");
            stop_openconnect_cascade();
            return 1;
        }
        let ready = false;
        let attempt = 0;
        while (attempt < 8) {
            if (openconnect_tcp_listening(port)) {
                ready = true;
                break;
            }
            system("sleep 1");
            attempt++;
        }
        if (!ready) {
            openconnect_log("OpenConnect cascade proxy for '" + name + "' is not listening.");
            stop_openconnect_cascade();
            return 1;
        }
        ports[name] = port;
        let pid = trim(as_string(fs.readfile(pid_path)));
        if (pid != "")
            push(pids, pid);
        openconnect_notice("OpenConnect cascade proxy for '" + name + "' is listening on port " + port + ".");
    }
    if (fs.writefile("/var/run/forkop/openconnect-cascade.json", sprintf("%J\n", ports)) == null) {
        openconnect_log("OpenConnect cascade proxy ports could not be saved.");
        stop_openconnect_cascade();
        return 1;
    }
    fs.writefile(dir + "/pids", join("\n", pids) + "\n");
    return 0;
}

function openconnect_detour_name(tag_name) {
    tag_name = as_string(tag_name);
    if (length(tag_name) > 4 && substr(tag_name, length(tag_name) - 4) == "-out")
        return substr(tag_name, 0, length(tag_name) - 4);
    return tag_name;
}

function openconnect_endpoint_key(endpoint) {
    let target = openconnect_server_target(as_string(endpoint.server || ""));
    let host = target.host;
    if (type(endpoint.tls) == "object") {
        let name = trim(as_string(endpoint.tls.server_name || ""));
        if (name != "")
            host = name;
    }
    return target.port == "" ? host : host + ":" + target.port;
}

function openconnect_recent_log() {
    let pipe = fs.popen("logread -e sing-box 2>/dev/null | tail -n 250", "r");
    if (!pipe)
        return "";
    let data = pipe.read("all");
    pipe.close();
    return data == null ? "" : as_string(data);
}

function openconnect_endpoint_failed(log_text, tag_name) {
    let failed = false;
    let healthy = false;
    let needle = "endpoint/openconnect[" + tag_name + "]";
    for (let line in split(log_text, "\n")) {
        if (index(line, needle) < 0)
            continue;
        let lower = lc(line);
        if (index(lower, "cstp remains active") >= 0)
            healthy = true;
        if (index(lower, "not ready") >= 0)
            continue;
        if (index(lower, "handshake") >= 0 || index(lower, "authentication") >= 0 ||
            index(lower, "certificate") >= 0 || index(lower, "cstp tls") >= 0)
            failed = true;
    }
    return failed && !healthy;
}

function openconnect_proxy_port_for_detour(name) {
    if (trim(as_string(name)) == "")
        return 0;
    let cascade = openconnect_port_from_map("/var/run/forkop/openconnect-cascade.json", name);
    if (cascade > 0)
        return cascade;
    return openconnect_port_from_map("/var/run/forkop/xray-ports.json", name);
}

function openconnect_singbox_config_path() {
    runtime_settings_cache = null;
    let path = trim(option(runtime_settings(), "config_path", ""));
    if (path == "")
        path = "/etc/sing-box/config.json";
    return path;
}

function repair_openconnect_auth() {
    system("mkdir -p /var/run/forkop >/dev/null 2>&1");
    if (fs.stat("/var/run/forkop/oc-auth-repaired") != null)
        return 0;
    fs.writefile("/var/run/forkop/oc-auth-repaired", "1\n");
    if (system("command -v openconnect >/dev/null 2>&1") != 0) {
        openconnect_notice("OpenConnect helper package is not installed; sing-box will log in by itself.");
        return 0;
    }
    let path = openconnect_singbox_config_path();
    let config = null;
    try {
        config = json(fs.readfile(path));
    }
    catch (e) {
        config = null;
    }
    if (type(config) != "object" || config == null)
        return 0;
    let no_cookie = openconnect_servers_without_cookie();
    let waiting = false;
    for (let endpoint in array_or_empty(config.endpoints)) {
        if (type(endpoint) != "object" || as_string(endpoint.type) != "openconnect")
            continue;
        if (no_cookie[openconnect_peer_key(openconnect_endpoint_key(endpoint))])
            continue;
        if (trim(as_string(endpoint.cookie || "")) == "" && trim(as_string(endpoint.username || "")) != "")
            waiting = true;
    }
    if (!waiting)
        return 0;
    system("sleep 3");
    let log_text = openconnect_recent_log();
    let pending = [];
    for (let endpoint in array_or_empty(config.endpoints)) {
        if (type(endpoint) != "object" || as_string(endpoint.type) != "openconnect")
            continue;
        let tag_name = as_string(endpoint.tag || "");
        if (tag_name == "" || trim(as_string(endpoint.cookie || "")) != "")
            continue;
        if (trim(as_string(endpoint.username || "")) == "" || as_string(endpoint.password || "") == "")
            continue;
        if (no_cookie[openconnect_peer_key(openconnect_endpoint_key(endpoint))])
            continue;
        if (!openconnect_endpoint_failed(log_text, tag_name))
            continue;
        push(pending, endpoint);
    }
    if (length(pending) == 0)
        return 0;
    let need_proxy = false;
    for (let endpoint in pending) {
        if (trim(as_string(endpoint.detour || "")) == "")
            continue;
        openconnect_peer_put(openconnect_endpoint_key(endpoint), { helper: true });
        need_proxy = true;
    }
    if (need_proxy)
        prepare_openconnect_cascade();
    let changed = false;
    for (let endpoint in pending) {
        let key = openconnect_endpoint_key(endpoint);
        let label = as_string(endpoint.tag || key);
        let detour_name = openconnect_detour_name(endpoint.detour);
        let proxy_port = 0;
        if (trim(as_string(endpoint.detour || "")) != "") {
            proxy_port = openconnect_proxy_port_for_detour(detour_name);
            if (proxy_port <= 0) {
                openconnect_log("OpenConnect '" + label + "' helper skipped: cascade SOCKS port is not ready.");
                continue;
            }
        }
        let fingerprint = type(endpoint.tls) == "object" ? trim(as_string(endpoint.tls.peer_fingerprint || "")) : "";
        let skip_cert = type(endpoint.tls) == "object" && endpoint.tls.insecure == true;
        let flavor = trim(as_string(endpoint.flavor || "anyconnect"));
        let auth_group = trim(as_string(endpoint.auth_group || ""));
        let cookie = openconnect_fetch_cookie(
            label, key, endpoint.username, endpoint.password, auth_group, fingerprint, proxy_port, flavor, proxy_port <= 0, 0, false, skip_cert
        );
        if (cookie == "" && auth_group == "" && openconnect_group_required(openconnect_last_auth_raw))
            cookie = openconnect_fetch_cookie(
                label, key, endpoint.username, endpoint.password, "all", fingerprint, proxy_port, flavor, proxy_port <= 0, 0, false, skip_cert
            );
        let learned_sha = openconnect_peer_fingerprint(openconnect_peer_get(key).sha);
        if (fingerprint == "" && learned_sha != "") {
            if (type(endpoint.tls) != "object")
                endpoint.tls = {};
            endpoint.tls.peer_fingerprint = learned_sha;
            changed = true;
        }
        if (cookie != "") {
            endpoint.cookie = cookie;
            openconnect_peer_put(key, { helper: true });
            changed = true;
        }
    }
    if (need_proxy)
        stop_openconnect_cascade();
    if (!changed)
        return 0;
    if (fs.writefile(path, sprintf("%J\n", config)) == null) {
        openconnect_log("OpenConnect helper could not update the sing-box configuration.");
        return 1;
    }
    openconnect_notice("OpenConnect helper filled in a session cookie or certificate after sing-box could not log in.");
    return 2;
}

let mode = ARGV[0] || "";

if (mode == "generate-config")
    generate_config(ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5] || "");
else if (mode == "generate-config-fixture")
    generate_config_fixture(ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5], ARGV[6] || "");
else if (mode == "download-socks")
    generate_download_socks(ARGV[1] || "", ARGV[2] || "", ARGV[3] || "", ARGV[4] == "1");
else if (mode == "prepare-openconnect-cascade")
    exit(prepare_openconnect_cascade());
else if (mode == "repair-openconnect-auth")
    exit(repair_openconnect_auth());
else if (mode == "stop-openconnect-cascade")
    stop_openconnect_cascade();
else if (mode == "stdin-length")
    stdin_length();
else if (mode == "stdin-contains")
    exit(stdin_contains(ARGV[1]) ? 0 : 1);
else if (mode == "stdin-regex-matches")
    exit(stdin_regex_matches(ARGV[1]) ? 0 : 1);
else if (mode == "csv-to-json-array")
    csv_to_json_array(ARGV[1]);
else if (mode == "ip-addr-first-inet4")
    ip_addr_first_inet4();
else if (mode == "stdin-first-dns-a-address")
    stdin_first_dns_a_address();
else if (mode == "stdin-first-dns-aaaa-address")
    stdin_first_dns_aaaa_address();
else if (mode == "stdin-first-nslookup-address")
    stdin_first_nslookup_address();
else if (mode == "stdin-first-field")
    stdin_first_field();
else if (mode == "array-append-string")
    array_append_string(ARGV[1]);
else if (mode == "normalized-country-list")
    normalized_country_list();
else if (mode == "urltest-filter")
    urltest_filter(ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5], ARGV[6], ARGV[7]);
else if (mode == "object-nonempty")
    exit(object_nonempty_stdin() ? 0 : 1);
else {
    warn("Usage: singbox/generator.uc <operation> ...\n");
    exit(1);
}
