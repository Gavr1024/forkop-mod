#!/usr/bin/env ucode
// Ordinary traffic may stay in firewall flow offload.
// Connections Forkop marked for a section speed limit must not: offload
// skips mangle, so the limit would only see the first packets.
// ct mark 0 is the default, so this does not change unmarked flows.

let fs = require("fs");

function shell_quote(value) {
    return "'" + replace(value, /'/g, "'\\''") + "'";
}

function command_from_args(args) {
    let parts = [];
    for (let arg in args)
        push(parts, shell_quote(arg));
    return join(" ", parts);
}

function command_ok(args) {
    return system(command_from_args(args) + " >/dev/null 2>&1") == 0;
}

function command_output(args) {
    let pipe = fs.popen(command_from_args(args) + " 2>/dev/null", "r");
    if (!pipe)
        return "";
    let data = pipe.read("all");
    pipe.close();
    return data == null ? "" : data;
}

function patch_flow_offload(wait) {
    let nft = getenv("FORKOP_NFT_BIN");
    if (nft == null || nft == "")
        nft = "nft";
    if (!command_ok([ "command", "-v", nft ]))
        return;

    let tries = wait ? 8 : 1;
    let ready = false;
    let i = 0;
    while (i < tries) {
        if (command_ok([ nft, "list", "chain", "inet", "fw4", "forward" ])) {
            ready = true;
            break;
        }
        i++;
        if (i < tries)
            system("sleep 1");
    }
    if (!ready)
        return;

    let text = command_output([ nft, "-a", "list", "chain", "inet", "fw4", "forward" ]);
    for (let line in split(text, "\n")) {
        if (index(line, "flow add @") < 0 && index(line, "flow offload @") < 0)
            continue;
        if (index(line, "ct mark 0") >= 0)
            continue;
        let handle = match(line, /# handle ([0-9]+)/);
        if (!handle)
            continue;
        let named = match(line, /flow (add|offload) @([A-Za-z0-9_]+)/);
        let setname = named ? named[2] : "ft";
        system(command_from_args([
            nft, "replace", "rule", "inet", "fw4", "forward",
            "handle", handle[1],
            "ct", "mark", "0",
            "meta", "l4proto", "{", "tcp,", "udp", "}",
            "flow", "add", "@" + setname
        ]) + " >/dev/null 2>&1");
    }
}

patch_flow_offload(ARGV[0] == "wait");
