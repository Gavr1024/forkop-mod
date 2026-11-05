#!/usr/bin/env ucode

// Optional LAN relay of the provider's single IPv6 block.
// Off by default. While on, phones can send IPv6 to the router.
// Forkop still intercepts that traffic. Stopping Forkop, or turning the
// option off, puts the previous dhcp settings back.

let fs = require("fs");
let uci = require("core.uci");

const STATE_DIR = getenv("FORKOP_RUNTIME_STATE_DIR") || "/var/run/forkop";
const STATE_FILE = getenv("FORKOP_IPV6_RELAY_STATE") || (STATE_DIR + "/ipv6-relay.json");
const ODHCPD_INIT = getenv("ODHCPD_INIT") || "/etc/init.d/odhcpd";

function as_string(value) {
    return value == null ? "" : "" + value;
}

function object_or_empty(value) {
    return type(value) == "object" && value != null ? value : {};
}

function shell_quote(value) {
    return "'" + replace(as_string(value), /'/g, "'\\''") + "'";
}

function log(message, level) {
    level = as_string(level || "info");
    system("logger -t " + shell_quote("forkop") + " " + shell_quote("[" + level + "] " + as_string(message)) + " >/dev/null 2>&1");
}

function command_output(command) {
    let pipe = fs.popen(command + " 2>/dev/null", "r");
    if (pipe == null)
        return "";
    let data = pipe.read("all");
    pipe.close();
    return data == null ? "" : as_string(data);
}

function read_state() {
    let data = fs.readfile(STATE_FILE);
    if (data == null)
        return null;
    try {
        let parsed = json(data);
        return type(parsed) == "object" ? parsed : null;
    }
    catch (e) {
        return null;
    }
}

function write_state(state) {
    system("mkdir -p " + shell_quote(STATE_DIR) + " >/dev/null 2>&1");
    return fs.writefile(STATE_FILE, sprintf("%J\n", state)) != null;
}

function clear_state() {
    try { fs.unlink(STATE_FILE); } catch (e) {}
}

function relay_enabled() {
    let value = lc(trim(as_string(uci.get("forkop.settings.ipv6_lan_relay"))));
    return value == "1" || value == "true" || value == "yes" || value == "on";
}

function dhcp_sections() {
    return uci.section_objects("dhcp", "dhcp");
}

function find_lan_section() {
    let fallback = null;
    for (let section in dhcp_sections()) {
        if (type(section) != "object")
            continue;
        let iface = trim(as_string(section.interface || ""));
        let name = as_string(section[".name"] || "");
        if (iface == "lan" || name == "lan")
            return section;
        if (fallback == null && iface == "br-lan")
            fallback = section;
    }
    return fallback;
}

function find_dhcp_by_interface(interface_name) {
    interface_name = trim(as_string(interface_name));
    for (let section in dhcp_sections()) {
        if (type(section) != "object")
            continue;
        if (trim(as_string(section.interface || "")) == interface_name)
            return section;
    }
    return null;
}

function network_name_for_device(device) {
    device = trim(as_string(device));
    if (device == "" || device == "lo")
        return "";
    for (let section in uci.section_objects("network", "interface")) {
        if (type(section) != "object")
            continue;
        let name = as_string(section[".name"] || "");
        let dev = trim(as_string(section.device || section.ifname || ""));
        if (name == "loopback")
            continue;
        if (dev == device || name == device)
            return name;
    }
    return "";
}

function default_ipv6_device() {
    let text = command_output("ip -6 route show default");
    let found = match(text, /dev ([A-Za-z0-9._:-]+)/);
    return found ? as_string(found[1]) : "";
}

function device_has_global_ipv6(device) {
    if (device == "")
        return false;
    let text = command_output("ip -6 addr show dev " + shell_quote(device) + " scope global");
    return match(text, /inet6 [0-9a-fA-F:]/) != null;
}

function saved_option(section, key) {
    if (section == null || type(section) != "object")
        return "";
    return trim(as_string(section[key] || ""));
}

function set_or_delete(path, value) {
    value = as_string(value);
    if (value == "")
        uci.delete(path);
    else
        uci.set(path, value);
}

function restart_odhcpd() {
    if (fs.stat(ODHCPD_INIT) == null) {
        log("odhcpd is not installed, so provider IPv6 was not shared", "warn");
        return false;
    }
    return system(shell_quote(ODHCPD_INIT) + " restart >/dev/null 2>&1") == 0;
}

function restore_saved(entry) {
    if (type(entry) != "object")
        return;
    let name = as_string(entry.name || "");
    if (name == "")
        return;
    if (entry.created == true) {
        uci.delete("dhcp." + name);
        return;
    }
    let options = type(entry.options) == "object" ? entry.options : {};
    for (let key in [ "dhcpv6", "ra", "ndp", "master", "ignore", "interface" ])
        set_or_delete("dhcp." + name + "." + key, as_string(options[key] || ""));
}

function restore() {
    let state = read_state();
    if (state == null)
        return true;
    restore_saved(state.lan);
    restore_saved(state.wan);
    if (!uci.commit("dhcp")) {
        log("Could not restore the previous IPv6 settings", "warn");
        return false;
    }
    clear_state();
    restart_odhcpd();
    log("Provider IPv6 sharing is off. Previous IPv6 settings restored", "info");
    return true;
}

function same_as_current(lan_name, wan_name, wan_interface) {
    return uci.get("dhcp." + lan_name + ".dhcpv6") == "relay" &&
        uci.get("dhcp." + lan_name + ".ra") == "relay" &&
        uci.get("dhcp." + lan_name + ".ndp") == "relay" &&
        uci.get("dhcp." + wan_name + ".dhcpv6") == "relay" &&
        uci.get("dhcp." + wan_name + ".ra") == "relay" &&
        uci.get("dhcp." + wan_name + ".ndp") == "relay" &&
        uci.get("dhcp." + wan_name + ".master") == "1" &&
        uci.get("dhcp." + wan_name + ".interface") == wan_interface;
}

function sync() {
    if (!relay_enabled())
        return restore();

    let device = default_ipv6_device();
    if (!device_has_global_ipv6(device)) {
        log("Provider IPv6 sharing is on, but the router has no global IPv6 yet. Nothing was changed", "warn");
        return true;
    }
    let upstream = network_name_for_device(device);
    if (upstream == "" || upstream == "lan") {
        log("Provider IPv6 sharing is on, but the upstream interface for " + device + " was not found. Nothing was changed", "warn");
        return true;
    }
    let lan = find_lan_section();
    if (lan == null) {
        log("Provider IPv6 sharing is on, but the LAN DHCP section was not found. Nothing was changed", "warn");
        return true;
    }
    let lan_name = as_string(lan[".name"] || "");
    let existing = read_state();
    if (existing != null && existing.active == true && as_string(existing.upstream || "") == upstream &&
        same_as_current(lan_name, as_string(object_or_empty(existing.wan).name || ""), upstream))
        return true;

    if (existing != null)
        restore();

    lan = find_lan_section();
    if (lan == null)
        return true;
    lan_name = as_string(lan[".name"] || "");
    let wan = find_dhcp_by_interface(upstream);
    let created = false;
    let wan_name = "";
    let wan_options = {};
    if (wan == null) {
        wan_name = as_string(uci.add("dhcp", "dhcp"));
        created = wan_name != "";
        if (!created) {
            log("Could not add the upstream IPv6 relay section", "warn");
            return false;
        }
    }
    else {
        wan_name = as_string(wan[".name"] || "");
        if (wan_name == lan_name) {
            log("Provider IPv6 sharing needs a separate upstream interface. Nothing was changed", "warn");
            return true;
        }
        wan_options = {
            dhcpv6: saved_option(wan, "dhcpv6"),
            ra: saved_option(wan, "ra"),
            ndp: saved_option(wan, "ndp"),
            master: saved_option(wan, "master"),
            ignore: saved_option(wan, "ignore"),
            interface: saved_option(wan, "interface")
        };
    }

    let state = {
        active: true,
        upstream: upstream,
        lan: {
            name: lan_name,
            created: false,
            options: {
                dhcpv6: saved_option(lan, "dhcpv6"),
                ra: saved_option(lan, "ra"),
                ndp: saved_option(lan, "ndp"),
                master: saved_option(lan, "master"),
                ignore: saved_option(lan, "ignore"),
                interface: saved_option(lan, "interface")
            }
        },
        wan: {
            name: wan_name,
            created: created,
            options: wan_options
        }
    };
    if (!write_state(state)) {
        log("Could not remember the previous IPv6 settings, so nothing was changed", "warn");
        if (created)
            uci.delete("dhcp." + wan_name);
        return false;
    }

    uci.set("dhcp." + lan_name + ".dhcpv6", "relay");
    uci.set("dhcp." + lan_name + ".ra", "relay");
    uci.set("dhcp." + lan_name + ".ndp", "relay");
    uci.delete("dhcp." + lan_name + ".master");
    uci.set("dhcp." + wan_name + ".interface", upstream);
    uci.set("dhcp." + wan_name + ".dhcpv6", "relay");
    uci.set("dhcp." + wan_name + ".ra", "relay");
    uci.set("dhcp." + wan_name + ".ndp", "relay");
    uci.set("dhcp." + wan_name + ".master", "1");
    if (created)
        uci.set("dhcp." + wan_name + ".ignore", "1");
    if (!uci.commit("dhcp")) {
        log("Could not save provider IPv6 sharing", "warn");
        restore();
        return false;
    }
    if (!restart_odhcpd())
        log("Provider IPv6 settings were saved, but odhcpd did not restart", "warn");
    log("Sharing provider IPv6 from " + upstream + " (" + device + ") with the LAN", "info");
    return true;
}

let mode = as_string(ARGV[0] || "");
if (mode == "sync")
    exit(sync() ? 0 : 1);
if (mode == "restore")
    exit(restore() ? 0 : 1);
warn("Usage: ipv6/relay.uc <sync|restore>\n");
exit(1);
