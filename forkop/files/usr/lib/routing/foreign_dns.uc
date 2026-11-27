#!/usr/bin/env ucode

function as_string(value) {
    return value == null ? "" : "" + value;
}

function trim(value) {
    return replace(as_string(value), /^[ \t\r\n]+|[ \t\r\n]+$/g, "");
}

function lower(value) {
    value = as_string(value);
    if (type(lc) == "function")
        return lc(value);
    return value;
}

function providers() {
    return [
        { names: [ "dns.google", "dns.google.com" ], v4: [ "8.8.8.8", "8.8.4.4" ], v6: [ "2001:4860:4860::8888", "2001:4860:4860::8844" ] },
        { names: [ "cloudflare-dns.com", "one.one.one.one" ], v4: [ "1.1.1.1", "1.0.0.1" ], v6: [ "2606:4700:4700::1111", "2606:4700:4700::1001" ] },
        { names: [ "dns.quad9.net" ], v4: [ "9.9.9.9", "149.112.112.112" ], v6: [ "2620:fe::fe", "2620:fe::9" ] },
        { names: [ "dns.adguard-dns.com", "dns-unfiltered.adguard-dns.com" ], v4: [ "94.140.14.14", "94.140.15.15" ], v6: [ "2a10:50c0::ad1:ff", "2a10:50c0::ad2:ff" ] },
        { names: [ "doh.opendns.com", "dns.opendns.com" ], v4: [ "208.67.222.222", "208.67.220.220" ], v6: [ "2620:119:35::35", "2620:119:53::53" ] },
        { names: [ "dns.nextdns.io" ], v4: [ "45.90.28.167", "45.90.30.167" ], v6: [] },
        { names: [ "dns.mullvad.net" ], v4: [ "194.242.2.2" ], v6: [ "2a07:e340::2" ] },
        { names: [ "dns.sb", "doh.dns.sb" ], v4: [ "185.222.222.222", "45.11.45.11" ], v6: [] },
        { names: [ "common.dot.dns.yandex.net", "dns.yandex.net" ], v4: [ "77.88.8.8", "77.88.8.1" ], v6: [ "2a02:6b8::feed:0ff", "2a02:6b8:0:1::feed:0ff" ] },
        { names: [ "dns.alidns.com" ], v4: [ "223.5.5.5", "223.6.6.6" ], v6: [ "2400:3200::1", "2400:3200:baba::1" ] },
        { names: [ "doh.pub" ], v4: [ "1.12.12.12", "120.53.53.53" ], v6: [] },
        { names: [ "dns.controld.com" ], v4: [ "76.76.2.0", "76.76.10.0" ], v6: [] }
    ];
}

function enabled(settings) {
    let value = as_string(settings && settings.block_foreign_dns);
    return value == "1" || value == "true" || value == "yes" || value == "on";
}

function normalize_name(value) {
    value = lower(trim(value));
    if (substr(value, 0, 1) == ".")
        value = substr(value, 1);
    if (length(value) > 0 && substr(value, length(value) - 1, 1) == ".")
        value = substr(value, 0, length(value) - 1);
    return value;
}

function host_from_server(value) {
    value = lower(trim(value));
    let scheme = index(value, "://");
    if (scheme >= 0)
        value = substr(value, scheme + 3);
    let slash = index(value, "/");
    if (slash >= 0)
        value = substr(value, 0, slash);
    if (substr(value, 0, 1) == "[") {
        let end = index(value, "]");
        if (end > 1)
            return normalize_name(substr(value, 1, end - 1));
    }
    let colon = index(value, ":");
    if (colon > 0 && index(substr(value, colon + 1), ":") < 0)
        value = substr(value, 0, colon);
    return normalize_name(value);
}

function name_valid(value) {
    value = normalize_name(value);
    if (match(value, /^[0-9.]+$/) != null || index(value, ":") >= 0)
        return false;
    return match(value, /^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$/) != null;
}

function raw_list(settings, key) {
    let value = settings ? settings[key] : null;
    if (value == null)
        return [];
    if (type(value) == "array")
        return value;
    let text = trim(value);
    return text == "" ? [] : split(text, /[ \t]+/);
}

function entered_exceptions(settings) {
    let result = [];
    for (let value in raw_list(settings, "block_foreign_dns_except")) {
        value = normalize_name(value);
        if (value != "")
            push(result, value);
    }
    return result;
}

function exceptions(settings) {
    let result = [];
    let seen = {};
    for (let value in raw_list(settings, "block_foreign_dns_except")) {
        value = normalize_name(value);
        if (!name_valid(value) || seen[value])
            continue;
        seen[value] = true;
        push(result, value);
    }
    return result;
}

function covers(name, other) {
    name = normalize_name(name);
    other = normalize_name(other);
    if (name == "" || other == "")
        return false;
    if (name == other)
        return true;
    return length(name) > length(other) + 1 &&
        substr(name, length(name) - length(other) - 1) == "." + other;
}

function provider_excepted(provider, exception_names) {
    for (let name in provider.names)
        for (let exception in exception_names)
            if (covers(name, exception) || covers(exception, name))
                return true;
    return false;
}

function resolver_names(settings) {
    let result = [];
    let seen = {};
    for (let key in [ "dns_server", "bootstrap_dns_server" ]) {
        for (let value in raw_list(settings, key)) {
            let host = host_from_server(value);
            if (!name_valid(host) || seen[host])
                continue;
            seen[host] = true;
            push(result, host);
        }
    }
    let certificate = normalize_name(settings ? settings.dns_certificate_name : "");
    if (name_valid(certificate))
        push(result, certificate);
    return result;
}

function name_is_resolver(name, resolvers) {
    for (let resolver in resolvers)
        if (covers(name, resolver) || covers(resolver, name))
            return true;
    return false;
}

function selected_providers(settings, want_excepted) {
    let exception_names = exceptions(settings);
    let result = [];
    for (let provider in providers())
        if (provider_excepted(provider, exception_names) == want_excepted)
            push(result, provider);
    return result;
}

function names_of(provider_list, settings, skip_resolvers) {
    let resolvers = skip_resolvers ? resolver_names(settings) : [];
    let result = [];
    let seen = {};
    for (let provider in provider_list) {
        for (let name in provider.names) {
            if (seen[name] || (skip_resolvers && name_is_resolver(name, resolvers)))
                continue;
            seen[name] = true;
            push(result, name);
        }
    }
    return result;
}

function addresses_of(provider_list, family) {
    let result = [];
    let seen = {};
    for (let provider in provider_list) {
        for (let address in provider[family]) {
            if (seen[address])
                continue;
            seen[address] = true;
            push(result, address);
        }
    }
    return result;
}

function blocked_names(settings) {
    if (!enabled(settings))
        return [];
    return names_of(selected_providers(settings, false), settings, false);
}

function sinkhole_names(settings) {
    if (!enabled(settings))
        return [];
    return names_of(selected_providers(settings, false), settings, true);
}

function blocked_v4(settings) {
    if (!enabled(settings))
        return [];
    return addresses_of(selected_providers(settings, false), "v4");
}

function blocked_v6(settings) {
    if (!enabled(settings))
        return [];
    return addresses_of(selected_providers(settings, false), "v6");
}

function allowed_v4(settings) {
    if (!enabled(settings))
        return [];
    return addresses_of(selected_providers(settings, true), "v4");
}

function allowed_v6(settings) {
    if (!enabled(settings))
        return [];
    return addresses_of(selected_providers(settings, true), "v6");
}

return {
    enabled,
    name_valid,
    entered_exceptions,
    exceptions,
    blocked_names,
    sinkhole_names,
    blocked_v4,
    blocked_v6,
    allowed_v4,
    allowed_v6
};
