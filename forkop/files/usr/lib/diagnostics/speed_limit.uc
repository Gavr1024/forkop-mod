#!/usr/bin/env ucode

let fs = require("fs");
let uci = require("uci").cursor();

const CONFIG = getenv("FORKOP_CONFIG_NAME") || "forkop";
const TABLE = getenv("NFT_TABLE_NAME") || "ForkopTable";

function as_string(value) {
    return value == null ? "" : "" + value;
}

function speed_number(name, key) {
    let raw = trim(as_string(uci.get(CONFIG, name, key)));
    if (raw == "" || match(raw, /^[0-9]+$/) == null)
        return 0;
    let value = int(raw);
    if (value < 1 || value > 10000)
        return 0;
    return value;
}

function speed_down(name) {
    let down = speed_number(name, "speed_limit_down_mbit");
    let up = speed_number(name, "speed_limit_up_mbit");
    if (down > 0)
        return down;
    if (up > 0)
        return 0;
    return speed_number(name, "speed_limit_mbit");
}

function speed_up(name) {
    let down = speed_number(name, "speed_limit_down_mbit");
    let up = speed_number(name, "speed_limit_up_mbit");
    if (up > 0)
        return up;
    if (down > 0)
        return 0;
    return speed_number(name, "speed_limit_mbit");
}

function chain_name(section_name, direction) {
    let name = replace(as_string(section_name), /[^A-Za-z0-9_]/g, "");
    if (name == "")
        name = "section";
    if (length(name) > 20)
        name = substr(name, 0, 20);
    return "forkop_lim_" + name + "_" + direction;
}

function command_output(args) {
    let parts = [];
    for (let arg in args)
        push(parts, "'" + replace(as_string(arg), /'/g, "'\\''") + "'");
    let pipe = fs.popen(join(" ", parts) + " 2>/dev/null", "r");
    if (!pipe)
        return "";
    let data = pipe.read("all");
    pipe.close();
    return data == null ? "" : as_string(data);
}

function load_table() {
    let text = command_output([ "nft", "list", "table", "inet", TABLE ]);
    let chains = {};
    let jumps = {};
    let current = "";
    for (let line in split(text, "\n")) {
        let header = match(line, /chain[ \t]+([A-Za-z0-9_]+)/);
        if (header != null) {
            current = header[1];
            chains[current] = { present: true, packets: null };
            continue;
        }
        let jumped = match(line, /counter packets [0-9]+ bytes ([0-9]+) jump[ \t]+(forkop_lim_[A-Za-z0-9_]+)/);
        if (jumped != null) {
            let key = jumped[2];
            if (type(jumps[key]) != "object")
                jumps[key] = { bytes: 0 };
            jumps[key].bytes += int(jumped[1]);
        }
        if (current == "")
            continue;
        let found = match(line, /counter packets ([0-9]+) bytes [0-9]+ drop/);
        if (found == null)
            continue;
        let known = chains[current];
        let add = int(found[1]);
        known.packets = known.packets == null ? add : known.packets + add;
    }
    return { chains: chains, jumps: jumps };
}

function chain_stat(table, chain) {
    let known = table.chains[chain];
    if (type(known) != "object")
        return { present: false, packets: null, bytes: null };
    let jump = table.jumps[chain];
    known.bytes = type(jump) == "object" ? jump.bytes : 0;
    return known;
}

function section_label(name) {
    let label = trim(as_string(uci.get(CONFIG, name, "label")));
    return label != "" ? label : name;
}

function detour_target(name) {
    if (as_string(uci.get(CONFIG, name, "outbound_detour_enabled")) != "1")
        return "";
    return trim(as_string(uci.get(CONFIG, name, "outbound_detour_section")));
}

function final_hop(name) {
    let seen = {};
    let current = name;
    let guard = 0;
    while (guard < 8) {
        guard++;
        if (seen[current])
            break;
        seen[current] = true;
        let next = detour_target(current);
        if (next == "" || next == current)
            break;
        current = next;
    }
    return current;
}

function hop_has_egress(name) {
    if (as_string(uci.get(CONFIG, name, "enabled")) == "0")
        return false;
    if (as_string(uci.get(CONFIG, name, "speed_limit_enabled")) == "0")
        return false;
    if (as_string(uci.get(CONFIG, name, "speed_limit_place")) != "egress")
        return false;
    return speed_down(name) > 0 || speed_up(name) > 0;
}

function status() {
    let sections = {};
    let table = load_table();
    uci.foreach(CONFIG, "section", function(section) {
        let name = as_string(section[".name"]);
        if (name == "")
            return;
        if (as_string(uci.get(CONFIG, name, "speed_limit_enabled")) == "0")
            return;
        if (as_string(uci.get(CONFIG, name, "enabled")) == "0")
            return;
        let action = as_string(uci.get(CONFIG, name, "action"));
        if (action == "block" || action == "")
            return;
        let down = speed_down(name);
        let up = speed_up(name);
        if (down < 1 && up < 1)
            return;
        let place = as_string(uci.get(CONFIG, name, "speed_limit_place")) == "egress" ? "egress" : "ingress";
        let shared = action == "byedpi" && place == "egress";
        let owner = shared ? "allbyedpi" : name;
        let down_stat = down > 0 ? chain_stat(table, chain_name(owner, "down")) : { present: true, packets: null, bytes: null };
        let up_stat = up > 0 ? chain_stat(table, chain_name(owner, "up")) : { present: true, packets: null, bytes: null };
        let active = (down < 1 || down_stat.present) && (up < 1 || up_stat.present);
        let hop = final_hop(name);
        let cascaded = place == "egress" && hop != name;
        sections[name] = {
            place: place,
            down: down,
            up: up,
            active: active,
            shared: shared,
            down_dropped: down_stat.packets,
            up_dropped: up_stat.packets,
            down_bytes: down_stat.bytes,
            up_bytes: up_stat.bytes,
            cascade: cascaded,
            cascade_label: cascaded ? section_label(hop) : "",
            cascade_limit: cascaded ? hop_has_egress(hop) : false
        };
    });
    print(sprintf("%J\n", { success: true, sections: sections }));
}

if ((ARGV[0] || "") == "status")
    status();
else {
    warn("Usage: diagnostics/speed_limit.uc status\n");
    exit(1);
}
