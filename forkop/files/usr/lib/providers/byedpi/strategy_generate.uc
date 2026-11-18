#!/usr/bin/env ucode

// Builds a small pack of ciadpi strategies from the same options the checker accepts.
// The checker still decides which line opens sites. This file only writes the lines.

let rng_state = 1;

function as_string(value) {
    return value == null ? "" : "" + value;
}

function write_json(value) {
    print(sprintf("%J\n", value));
}

function rng_set(seed) {
    rng_state = int(seed);
    if (rng_state < 1)
        rng_state = 1;
}

function rng_next() {
    rng_state = (1664525 * rng_state + 1013904223) % 2147483647;
    if (rng_state < 1)
        rng_state = 1;
    return rng_state;
}

function rng_int(limit) {
    return int(rng_next() % limit);
}

function pick(items) {
    return items[rng_int(length(items))];
}

function between(low, high) {
    return low + rng_int(high - low + 1);
}

let FAKE = [ "-f-1", "-f1", "-f-30", "-f-43", "-f-200", "-f-250" ];
let AUTO = [ "-As", "-Ar", "-At", "-At,r,s", "-Ar,s" ];
let SPLIT_AT = [ 1, 2, 3, 5, 6, 8, 10, 12, 15, 20, 25, 30 ];

function token_name(token) {
    return length(token) >= 2 ? substr(token, 0, 2) : token;
}

function position_key(token) {
    let name = token_name(token);
    if (name != "-s" && name != "-d" && name != "-o" && name != "-q" && name != "-f" && name != "-r" && name != "-O")
        return "";
    return substr(token, 2);
}

function push_fresh(tokens, used, token) {
    let key = position_key(token);
    if (key != "" && used[key])
        return false;
    push(tokens, token);
    if (key != "")
        used[key] = true;
    return true;
}

function finish_group(tokens) {
    let fake = false;
    let signed = false;
    for (let token in tokens) {
        if (token_name(token) == "-f")
            fake = true;
        if (token == "-S")
            signed = true;
    }
    if (fake && !signed && rng_int(100) < 35)
        push(tokens, "-S");
    return tokens;
}

function token_at(kind, position, suffix) {
    return sprintf("%s%d%s", kind, position, suffix);
}

function split_ladder() {
    let position = pick([ 1, 3 ]);
    let tokens = [];
    let used = {};
    let steps = between(4, 7);
    for (let step = 0; step < steps; step++) {
        let kind = step % 2 == 0 ? "-d" : "-s";
        push_fresh(tokens, used, token_at(kind, position, "+s"));
        position += pick([ 2, 3, 4, 5 ]);
        if (position > 40)
            break;
    }
    return finish_group(tokens);
}

function split_and_disorder() {
    let tokens = [];
    let used = {};
    let pairs = between(2, 4);
    let early = [ 1, 2, 3, 5, 6, 8 ];
    for (let n = 0; n < pairs; n++) {
        let suffix = pick([ "+s", "+sm" ]);
        for (let attempt = 0; attempt < 8; attempt++) {
            if (push_fresh(tokens, used, token_at("-s", pick(SPLIT_AT), suffix)))
                break;
        }
        for (let attempt = 0; attempt < 8; attempt++) {
            if (push_fresh(tokens, used, token_at("-d", pick(early), "+s")))
                break;
        }
    }
    return finish_group(tokens);
}

function fake_packet() {
    let early = [ 1, 2, 3, 5, 6, 8, 10, 12 ];
    let tokens = [];
    let used = {};
    push_fresh(tokens, used, pick(FAKE));
    push(tokens, token_at("-t", pick([ 4, 5, 6, 7, 8 ]), ""));
    for (let attempt = 0; attempt < 8; attempt++) {
        if (push_fresh(tokens, used, token_at("-s", pick(early), "+s")))
            break;
    }
    if (rng_int(100) < 50) {
        for (let attempt = 0; attempt < 6; attempt++) {
            if (push_fresh(tokens, used, token_at("-o", pick([ 1, 2 ]), "")))
                break;
        }
    }
    return finish_group(tokens);
}

function range_split() {
    let tokens = [];
    let used = {};
    let start = pick([ 1, 2, 3, 5 ]);
    let width = pick([ 3, 4, 5 ]);
    let suffix = pick([ "+s", "+sm" ]);
    push_fresh(tokens, used, sprintf("-s%d:%d%s", start, start + width, suffix));
    for (let attempt = 0; attempt < 6; attempt++) {
        if (push_fresh(tokens, used, token_at("-d", pick([ 1, 2, 3 ]), "+s")))
            break;
    }
    for (let attempt = 0; attempt < 6; attempt++) {
        if (push_fresh(tokens, used, pick(FAKE)))
            break;
    }
    return finish_group(tokens);
}

function oob_group() {
    let early = [ 1, 2, 3, 5, 6, 8 ];
    let tokens = [];
    let used = {};
    for (let attempt = 0; attempt < 6; attempt++) {
        if (push_fresh(tokens, used, token_at("-o", pick([ 1, 2 ]), "")))
            break;
    }
    for (let attempt = 0; attempt < 6; attempt++) {
        if (push_fresh(tokens, used, token_at("-q", pick([ 1, 2, 7 ]), "")))
            break;
    }
    for (let attempt = 0; attempt < 6; attempt++) {
        if (push_fresh(tokens, used, token_at("-r", pick([ 1, 2, 3, 5 ]), "+s")))
            break;
    }
    for (let attempt = 0; attempt < 8; attempt++) {
        if (push_fresh(tokens, used, token_at("-s", pick(early), "+s")))
            break;
    }
    return finish_group(tokens);
}

function build_group() {
    let which = rng_int(5);
    if (which == 0)
        return split_ladder();
    if (which == 1)
        return split_and_disorder();
    if (which == 2)
        return fake_packet();
    if (which == 3)
        return range_split();
    return oob_group();
}

function group_fits(group, used) {
    let local = {};
    for (let token in group) {
        let key = position_key(token);
        if (key != "" && (used[key] || local[key]))
            return false;
        if (key != "")
            local[key] = true;
    }
    return true;
}

function one_strategy() {
    let tokens = [];
    let used = {};
    if (rng_int(100) < 40) {
        push(tokens, "-n");
        push(tokens, "{sni}");
        push(tokens, "-Qr");
    }
    let groups = between(1, 3);
    for (let number = 0; number < groups; number++) {
        let group = build_group();
        let split = number > 0 && rng_int(100) < 50;
        if (number > 0 && !split && !group_fits(group, used)) {
            split = true;
            for (let attempt = 0; attempt < 6 && !group_fits(group, {}); attempt++)
                group = build_group();
        }
        if (split) {
            push(tokens, pick(AUTO));
            used = {};
        }
        for (let token in group) {
            push(tokens, token);
            let key = position_key(token);
            if (key != "")
                used[key] = true;
        }
    }
    return join(" ", tokens);
}

function split_words(value) {
    value = replace(as_string(value), /[\t\r\n]/g, " ");
    value = replace(value, / +/g, " ");
    value = replace(value, /^ /, "");
    value = replace(value, / $/, "");
    return value == "" ? [] : split(value, " ");
}

function option_name(token) {
    return length(token) >= 2 ? substr(token, 0, 2) : token;
}

function mutable_kind(token) {
    let name = option_name(token);
    if (name == "-t")
        return "ttl";
    if (name == "-s" || name == "-d" || name == "-o" || name == "-q" || name == "-f" || name == "-r" || name == "-O")
        return "pos";
    return "";
}

function digits_end(text, start) {
    let at = start;
    while (at < length(text) && match(substr(text, at, 1), /[0-9]/) != null)
        at++;
    return at;
}

function nudge_position_value(value, delta) {
    let sign = 1;
    let start = 0;
    if (substr(value, 0, 1) == "-") {
        sign = -1;
        start = 1;
    }
    let end = digits_end(value, start);
    if (end == start)
        return value;
    let number = sign * int(substr(value, start, end - start));
    let next = number + delta;
    if (number < 0 && next > -1)
        next = -1;
    if (number > 0 && next < 1)
        next = 1;
    if (number == 0)
        next = delta >= 0 ? 1 : -1;
    return sprintf("%d%s", next, substr(value, end));
}

function nudge_token(token, delta) {
    let kind = mutable_kind(token);
    let name = option_name(token);
    let value = substr(token, 2);
    if (kind == "ttl") {
        if (match(value, /^[0-9]+$/) == null)
            return token;
        let next = int(value) + delta;
        if (next < 1)
            next = 1;
        if (next > 255)
            next = 255;
        return sprintf("-t%d", next);
    }
    if (kind != "pos" || value == "")
        return token;
    return name + nudge_position_value(value, delta);
}

function vary_once(tokens) {
    let indexes = [];
    for (let i = 0; i < length(tokens); i++)
        if (mutable_kind(tokens[i]) != "")
            push(indexes, i);
    if (length(indexes) == 0)
        return join(" ", tokens);
    let copy = [];
    for (let token in tokens)
        push(copy, token);
    let changes = length(indexes) == 1 ? 1 : between(1, 2);
    let touched = {};
    let shifts = [ -2, -1, 1, 2 ];
    for (let n = 0; n < changes; n++) {
        let slot = indexes[rng_int(length(indexes))];
        if (touched[slot])
            continue;
        touched[slot] = true;
        let old = copy[slot];
        if (mutable_kind(old) != "pos") {
            copy[slot] = nudge_token(old, pick([ -1, 1 ]));
            continue;
        }
        let occupied = {};
        for (let i = 0; i < length(copy); i++) {
            if (i == slot)
                continue;
            let key = position_key(copy[i]);
            if (key != "")
                occupied[key] = true;
        }
        for (let attempt = 0; attempt < 4; attempt++) {
            let next = nudge_token(old, shifts[rng_int(4)]);
            let key = position_key(next);
            if (next == old || (key != "" && occupied[key]))
                continue;
            copy[slot] = next;
            break;
        }
    }
    return join(" ", copy);
}

function generate_from_base(count, seed, base) {
    rng_set(seed);
    let tokens = split_words(base);
    let original = join(" ", tokens);
    let found = [];
    let seen = {};
    if (original != "") {
        push(found, original);
        seen[original] = true;
    }
    let attempts = 0;
    let limit = count * 30;
    if (limit < 60)
        limit = 60;
    while (length(found) < count && attempts < limit) {
        attempts++;
        let line = vary_once(tokens);
        if (line == "" || seen[line])
            continue;
        seen[line] = true;
        push(found, line);
    }
    return found;
}

function clamped_count(value) {
    let text = as_string(value);
    if (match(text, /^[0-9]+$/) == null)
        return 30;
    let number = int(text);
    if (number < 1)
        return 1;
    if (number > 50)
        return 50;
    return number;
}

function generate_pack(count, seed) {
    rng_set(seed);
    let found = [];
    let seen = {};
    let attempts = 0;
    let limit = count * 20;
    if (limit < 100)
        limit = 100;
    while (length(found) < count && attempts < limit) {
        attempts++;
        let line = one_strategy();
        if (seen[line])
            continue;
        seen[line] = true;
        push(found, line);
    }
    return found;
}

function main_generate(count_text, seed_text, base_text) {
    let count = clamped_count(count_text);
    let seed = int(as_string(seed_text));
    if (seed < 1)
        seed = 1;
    let base = trim(as_string(base_text));
    if (base != "")
        write_json({ strategies: generate_from_base(count, seed, base) });
    else
        write_json({ strategies: generate_pack(count, seed) });
}

function fresh_line_ok(line) {
    let tokens = split_words(line);
    let used = {};
    let fake = false;
    let signed = false;
    for (let token in tokens) {
        if (token_name(token) == "-A") {
            if (signed && !fake)
                return false;
            used = {};
            fake = false;
            signed = false;
            continue;
        }
        if (token_name(token) == "-a")
            return false;
        if (token == "-S")
            signed = true;
        if (token_name(token) == "-f")
            fake = true;
        let key = position_key(token);
        if (key != "") {
            if (used[key])
                return false;
            used[key] = true;
        }
    }
    if (signed && !fake)
        return false;
    return true;
}

let mode = ARGV[0] || "";

if (mode == "generate")
    main_generate(ARGV[1] || "30", ARGV[2] || "1", ARGV[3] || "");
else if (mode == "self-check") {
    let first = generate_pack(30, 7);
    let second = generate_pack(30, 7);
    if (length(first) != 30 || join("\n", first) != join("\n", second))
        exit(1);
    let seen = {};
    for (let line in first) {
        if (seen[line] || index(line, "--port") >= 0 || index(line, "-D") >= 0)
            exit(1);
        if (substr(line, 0, 3) == "-p " || substr(line, 0, 3) == "-i ")
            exit(1);
        if (!fresh_line_ok(line))
            exit(1);
        seen[line] = true;
    }
    let base = "-d1+s -s3+s -t8 -a1";
    let varied = generate_from_base(5, 3, base);
    let again = generate_from_base(5, 3, base);
    if (length(varied) < 2 || varied[0] != base || join("\n", varied) != join("\n", again))
        exit(1);
    if (index(varied[1], "-S") >= 0)
        exit(1);
    print("ok\n");
}
else {
    warn("Usage: providers/byedpi/strategy_generate.uc generate <count> <seed>\n");
    exit(1);
}
