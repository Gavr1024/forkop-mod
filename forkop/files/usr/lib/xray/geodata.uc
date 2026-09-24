#!/usr/bin/env ucode

let fs = require("fs");
let uci_core = require("core.uci");
let connections = require("config.connections");
let engine = require("core.engine");
let list_cache = require("routing.list_cache");
let singbox_rulesets = require("singbox.rulesets");
let xray_constants = require("xray.constants");
let dat_contains_cache = {};
let dropped_matcher_log = {};

const CONFIG_NAME = getenv("FORKOP_CONFIG_NAME") || "forkop";
const SING_BOX_BIN = getenv("FORKOP_SING_BOX_BIN") || "/usr/bin/sing-box";
const ITDOG_RAW_BASE = "https://raw.githubusercontent.com/itdoginfo/allow-domains/main";
const MAX_INLINE_MATCHERS = 8000;
const MAX_DECOMPILE_BYTES = 524288;
const DECOMPILE_TIMEOUT_SECONDS = 8;
const QUICK_FETCH_SECONDS = 20;

const GEOSITE_TAGS = {
    russia_inside: "russia-inside",
    russia_outside: "russia-outside",
    ukraine_inside: "ukraine-inside"
};

const ITDOG_SITE_CODE = {
    anime: "anime",
    block: "block",
    geoblock: "geoblock",
    hodca: "hodca",
    news: "news",
    porn: "porn",
    youtube: "youtube",
    hdrezka: "hdrezka",
    tiktok: "tiktok",
    google_ai: "google-ai",
    google_play: "google-play",
    discord: "discord",
    meta: "meta",
    twitter: "twitter",
    cloudflare: "cloudflare",
    cloudfront: "cloudfront",
    digitalocean: "digitalocean",
    hetzner: "hetzner",
    ovh: "ovh",
    telegram: "telegram",
    roblox: "roblox"
};

const ITDOG_GEOSITE_ATTR = {
    anime: true,
    block: true,
    geoblock: true,
    hodca: true,
    news: true,
    porn: true,
    youtube: true,
    hdrezka: true,
    tiktok: true,
    meta: true,
    twitter: true,
    discord: true
};

const LST_PATHS = {
    anime: "Categories/anime.lst",
    block: "Categories/block.lst",
    geoblock: "Categories/geoblock.lst",
    hodca: "Categories/hodca.lst",
    news: "Categories/news.lst",
    porn: "Categories/porn.lst",
    youtube: "Services/youtube.lst",
    hdrezka: "Services/hdrezka.lst",
    tiktok: "Services/tiktok.lst",
    google_ai: "Services/google_ai.lst",
    google_play: "Services/google_play.lst",
    discord: "Services/discord.lst",
    meta: "Services/meta.lst",
    twitter: "Services/twitter.lst",
    cloudflare: "Services/cloudflare.lst",
    cloudfront: "Services/cloudfront.lst",
    digitalocean: "Services/digitalocean.lst",
    hetzner: "Services/hetzner.lst",
    ovh: "Services/ovh.lst",
    telegram: "Services/telegram.lst",
    roblox: "Services/roblox.lst"
};

const SUBNET_SERVICES = {
    twitter: true,
    meta: true,
    telegram: true,
    cloudflare: true,
    hetzner: true,
    ovh: true,
    digitalocean: true,
    cloudfront: true,
    discord: true,
    roblox: true
};

const V2FLY_GEOSITE = {
    youtube: "youtube",
    discord: "discord",
    telegram: "telegram",
    github: "github",
    twitter: "twitter",
    tiktok: "tiktok",
    cloudflare: "cloudflare",
    cloudfront: "cloudfront",
    digitalocean: "digitalocean",
    hetzner: "hetzner",
    ovh: "ovh",
    roblox: "roblox"
};

const V2FLY_GEOSITE_DAT_URL = "https://github.com/v2fly/domain-list-community/releases/latest/download/dlc.dat";
const LOYALSOLDIER_GEOSITE_DAT_URL = "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat";
const ADLIST_DAT_URL = "https://github.com/zxc-rv/ad-filter/releases/latest/download/adlist.dat";
const ADLIST_DAT = "/usr/share/xray/adlist.dat";
const ADLIST_DAT_ETC = "/etc/xray/adlist.dat";
const ADLIST_CODE = "hagezi-pro";
const SUPERCELL_JSON_URL = "https://raw.githubusercontent.com/ushan0v/sing-box-supercell-ruleset/main/supercell.json";
const GITHUB_LIST_URL = "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/geo/geosite/github.list";

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

function file_exists(path) {
    return fs.stat(as_string(path)) != null;
}

function file_size(path) {
    let st = fs.stat(as_string(path));
    if (st == null)
        return 0;
    return int(st.size || st.length || 0);
}

function file_mtime(path) {
    let st = fs.stat(as_string(path));
    if (st == null)
        return 0;
    return int(st.mtime || 0);
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

function log_message(message, level) {
    level = as_string(level || "info");
    message = as_string(message);
    system("logger -t forkop '[" + replace(level, /'/g, "") + "] " +
        replace(message, /'/g, "") + "' >/dev/null 2>&1");
}

function cache_dir() {
    return xray_constants.XRAY_LIST_CACHE_DIR;
}

function allow_domains_dat_present() {
    return file_size(xray_constants.ALLOW_DOMAINS_DAT) > 0 ||
        file_size(xray_constants.ALLOW_DOMAINS_DAT_ETC) > 0;
}

function shell_quote(value) {
    return "'" + replace(as_string(value), /'/g, "'\\''") + "'";
}

function dat_contains(path, needle) {
    path = as_string(path);
    needle = as_string(needle);
    if (file_size(path) == 0 || needle == "")
        return false;
    let key = path + "\t" + needle;
    if (dat_contains_cache[key] != null)
        return dat_contains_cache[key];
    let found = system("grep -a -i -F -q -- " + shell_quote(needle) + " " + shell_quote(path) + " >/dev/null 2>&1") == 0;
    dat_contains_cache[key] = found;
    return found;
}

function looks_like_v2fly_dat(path) {
    return dat_contains(path, "category-ads-all") ||
        dat_contains(path, "geolocation-cn");
}

function looks_like_html_or_json(path) {
    let fh = fs.open(as_string(path), "r");
    if (!fh)
        return true;
    let head = as_string(fh.read(64));
    fh.close();
    head = trim(head);
    if (head == "")
        return true;
    let start = lc(substr(head, 0, 16));
    return index(start, "<!") == 0 ||
        index(start, "<html") == 0 ||
        index(start, "<?xml") == 0 ||
        substr(head, 0, 1) == "<" ||
        substr(head, 0, 1) == "{" ||
        substr(head, 0, 1) == "[";
}

function looks_like_itdog_dat(path) {
    if (file_size(path) < 32768)
        return false;
    if (looks_like_html_or_json(path))
        return false;
    return dat_contains(path, "russia-inside") || dat_contains(path, "RUSSIA-INSIDE");
}

function looks_like_adlist_dat(path) {
    if (file_size(path) < 32768)
        return false;
    if (looks_like_html_or_json(path))
        return false;
    return dat_contains(path, "hagezi-pro") || dat_contains(path, "HAGEZI-PRO");
}

function adlist_dat_path() {
    if (file_size(ADLIST_DAT) > 0 && looks_like_adlist_dat(ADLIST_DAT))
        return ADLIST_DAT;
    if (file_size(ADLIST_DAT_ETC) > 0 && looks_like_adlist_dat(ADLIST_DAT_ETC))
        return ADLIST_DAT_ETC;
    return "";
}

function copy_file(src, dest) {
    src = as_string(src);
    dest = as_string(dest);
    if (src == "" || dest == "" || src == dest || file_size(src) == 0)
        return false;
    let slash = rindex(dest, "/");
    if (slash > 0 && !ensure_dir(substr(dest, 0, slash)))
        return false;
    system("cp -f " + shell_quote(src) + " " + shell_quote(dest) + " >/dev/null 2>&1");
    return file_size(dest) > 0;
}

const GEODATA_RAM_DIR = "/tmp/forkop-geodata";

function dat_publish_targets(name) {
    name = as_string(name);
    if (name == "allow-domains.dat")
        return [ xray_constants.ALLOW_DOMAINS_DAT, xray_constants.ALLOW_DOMAINS_DAT_ETC ];
    if (name == "geosite.dat" || name == "v2fly-geosite.dat")
        return [ xray_constants.XRAY_LOCATION_ASSET + "/geosite.dat" ];
    if (name == "adlist.dat")
        return [ ADLIST_DAT, ADLIST_DAT_ETC ];
    return [];
}

function flash_dat_plain(name) {
    return cache_dir() + "/" + as_string(name);
}

function flash_dat_gz(name) {
    return flash_dat_plain(name) + ".gz";
}

function ram_dat_path(name) {
    return GEODATA_RAM_DIR + "/" + as_string(name);
}

function materialize_flash_dat(name) {
    name = as_string(name);
    let gz = flash_dat_gz(name);
    let plain = flash_dat_plain(name);
    let ram = ram_dat_path(name);
    if (file_size(gz) > 0) {
        if (!ensure_dir(GEODATA_RAM_DIR))
            return "";
        let recorded = 0;
        try { recorded = int(trim(fs.readfile(gz + ".size") || "0")); } catch (e) { recorded = 0; }
        if (!(file_size(ram) > 0 && (recorded <= 0 || file_size(ram) == recorded))) {
            if (!list_cache.gunzip_file(gz, ram))
                return "";
        }
        return file_size(ram) > 0 ? ram : "";
    }
    if (file_size(plain) > 0)
        return plain;
    return "";
}

function publish_dat(name) {
    let ram = materialize_flash_dat(name);
    if (ram == "")
        return false;
    let ok = false;
    for (let dest in dat_publish_targets(name)) {
        dest = as_string(dest);
        if (dest == "" || dest == ram)
            continue;
        let slash = rindex(dest, "/");
        if (slash > 0)
            ensure_dir(substr(dest, 0, slash));
        if (system("ln -sfn " + shell_quote(ram) + " " + shell_quote(dest)) == 0 && file_size(dest) > 0)
            ok = true;
    }
    return ok;
}

function persist_dat_to_flash(src, name) {
    if (!list_cache.persist_enabled())
        return false;
    name = trim(as_string(name));
    src = as_string(src);
    if (name == "" || file_size(src) == 0)
        return false;
    if (!ensure_dir(cache_dir()))
        return false;
    let gz = flash_dat_gz(name);
    let recorded = 0;
    try { recorded = int(trim(fs.readfile(gz + ".size") || "0")); } catch (e) { recorded = 0; }
    if (!(file_size(gz) > 0 && recorded == file_size(src))) {
        if (!list_cache.gzip_file(src, gz))
            return copy_file(src, flash_dat_plain(name));
        try { fs.writefile(gz + ".size", as_string(file_size(src)) + "\n"); } catch (e2) { }
    }
    try { fs.unlink(flash_dat_plain(name)); } catch (e3) { }
    publish_dat(name);
    return file_size(gz) > 0;
}

function download_scratch(name) {
    if (!ensure_dir(GEODATA_RAM_DIR))
        return "";
    return GEODATA_RAM_DIR + "/" + as_string(name);
}

function forget_v2fly_scratch() {
    try { fs.unlink(cache_dir() + "/v2fly-geosite.dat"); } catch (e) { }
    try { fs.unlink(cache_dir() + "/v2fly-geosite.dat.gz"); } catch (e2) { }
    try { fs.unlink(cache_dir() + "/v2fly-geosite.dat.gz.size"); } catch (e3) { }
    try { fs.unlink(GEODATA_RAM_DIR + "/v2fly-geosite.dat"); } catch (e4) { }
    try { fs.unlink(GEODATA_RAM_DIR + "/v2fly-geosite.dat.gz"); } catch (e5) { }
    try { fs.unlink(GEODATA_RAM_DIR + "/v2fly-geosite.dat.gz.size"); } catch (e6) { }
}

function restore_flash_dat() {
    if (!list_cache.persist_enabled())
        return;
    ensure_dir(xray_constants.XRAY_LOCATION_ASSET);
    ensure_dir("/etc/xray");
    if (!looks_like_itdog_dat(xray_constants.ALLOW_DOMAINS_DAT) &&
        !looks_like_itdog_dat(xray_constants.ALLOW_DOMAINS_DAT_ETC)) {
        let flash = materialize_flash_dat("allow-domains.dat");
        if (flash == "")
            flash = cache_dir() + "/allow-domains.dat";
        if (looks_like_itdog_dat(flash)) {
            copy_file(flash, xray_constants.ALLOW_DOMAINS_DAT);
            copy_file(flash, xray_constants.ALLOW_DOMAINS_DAT_ETC);
            log_message("restored allow-domains.dat from flash cache", "info");
        }
    }
    let geosite_dest = xray_constants.XRAY_LOCATION_ASSET + "/geosite.dat";
    if (!looks_like_v2fly_dat(geosite_dest)) {
        let flash = materialize_flash_dat("geosite.dat");
        if (flash == "" || !looks_like_v2fly_dat(flash))
            flash = materialize_flash_dat("v2fly-geosite.dat");
        if (looks_like_v2fly_dat(flash) && copy_file(flash, geosite_dest))
            log_message("restored v2fly geosite.dat from flash cache", "info");
    }
    if (adlist_dat_path() == "") {
        let flash = materialize_flash_dat("adlist.dat");
        if (flash == "")
            flash = cache_dir() + "/adlist.dat";
        if (looks_like_adlist_dat(flash)) {
            copy_file(flash, ADLIST_DAT);
            copy_file(flash, ADLIST_DAT_ETC);
            log_message("restored adlist.dat from flash cache", "info");
        }
    }
    if (looks_like_itdog_dat(xray_constants.ALLOW_DOMAINS_DAT))
        persist_dat_to_flash(xray_constants.ALLOW_DOMAINS_DAT, "allow-domains.dat");
    let geosite_now = xray_constants.XRAY_LOCATION_ASSET + "/geosite.dat";
    if (looks_like_v2fly_dat(geosite_now))
        persist_dat_to_flash(geosite_now, "geosite.dat");
    if (looks_like_adlist_dat(ADLIST_DAT))
        persist_dat_to_flash(ADLIST_DAT, "adlist.dat");
    if (file_size(flash_dat_gz("geosite.dat")) > 0)
        forget_v2fly_scratch();
}

function geosite_dat_candidates() {
    return [
        xray_constants.XRAY_LOCATION_ASSET + "/geosite.dat",
        "/etc/xray/geosite.dat",
        "/usr/share/v2ray/geosite.dat",
        "/usr/share/v2ray-geosite/geosite.dat"
    ];
}

function xray_geosite_dat() {
    let dest = xray_constants.XRAY_LOCATION_ASSET + "/geosite.dat";
    if (file_size(dest) > 0 && looks_like_v2fly_dat(dest))
        return dest;
    return "";
}

function salvage_itdog_dat(path) {
    if (!looks_like_itdog_dat(path))
        return false;
    if (allow_domains_dat_present())
        return true;
    if (copy_file(path, xray_constants.ALLOW_DOMAINS_DAT)) {
        copy_file(xray_constants.ALLOW_DOMAINS_DAT, xray_constants.ALLOW_DOMAINS_DAT_ETC);
        persist_dat_to_flash(xray_constants.ALLOW_DOMAINS_DAT, "allow-domains.dat");
        log_message("using itdoginfo geosite.dat as allow-domains.dat from " + path, "info");
        return true;
    }
    return false;
}

function allow_domains_dat_paths() {
    return [
        xray_constants.ALLOW_DOMAINS_DAT,
        xray_constants.ALLOW_DOMAINS_DAT_ETC
    ];
}

function allow_domains_has_tag(tag) {
    tag = trim(as_string(tag));
    if (tag == "")
        return false;
    let path = xray_constants.ALLOW_DOMAINS_DAT;
    if (!looks_like_itdog_dat(path))
        return false;
    let at = index(tag, "@");
    let base = at > 0 ? substr(tag, 0, at) : tag;
    let attr = at > 0 ? substr(tag, at + 1) : "";
    if (!dat_contains(path, base))
        return false;
    if (attr != "" && !dat_contains(path, attr))
        return false;
    return true;
}

function purge_unusable_allow_domains_dat() {
    if (!allow_domains_dat_present())
        return;
    if (looks_like_itdog_dat(xray_constants.ALLOW_DOMAINS_DAT) ||
        looks_like_itdog_dat(xray_constants.ALLOW_DOMAINS_DAT_ETC))
        return;
    log_message(
        "allow-domains.dat is not itdog geosite (" +
        as_string(file_size(xray_constants.ALLOW_DOMAINS_DAT)) + " bytes); removing so it can be re-fetched",
        "warn"
    );
    for (let path in allow_domains_dat_paths()) {
        system("rm -f " + shell_quote(path) + " >/dev/null 2>&1");
    }
    for (let key in dat_contains_cache)
        dat_contains_cache[key] = null;
}

function stage_geosite_dat_inner() {
    purge_unusable_allow_domains_dat();
    restore_flash_dat();
    let dest = xray_constants.XRAY_LOCATION_ASSET + "/geosite.dat";
    if (file_size(dest) > 0 && looks_like_itdog_dat(dest) && !looks_like_v2fly_dat(dest)) {
        salvage_itdog_dat(dest);
        system("rm -f " + shell_quote(dest) + " >/dev/null 2>&1");
        for (let key in dat_contains_cache)
            dat_contains_cache[key] = null;
        log_message("removed itdoginfo dat from geosite.dat path (it is not v2fly)", "info");
    }

    if (xray_geosite_dat() != "") {
        persist_dat_to_flash(dest, "geosite.dat");
        return true;
    }

    for (let src in geosite_dat_candidates()) {
        if (src == dest || file_size(src) == 0)
            continue;
        if (looks_like_itdog_dat(src) && !looks_like_v2fly_dat(src)) {
            salvage_itdog_dat(src);
            continue;
        }
        if (!looks_like_v2fly_dat(src))
            continue;
        if (copy_file(src, dest)) {
            persist_dat_to_flash(dest, "geosite.dat");
            log_message("staged v2fly geosite.dat for Xray from " + src, "info");
            return true;
        }
    }
    return xray_geosite_dat() != "";
}

function stage_geosite_dat() {
    try {
        return stage_geosite_dat_inner();
    }
    catch (e) {
        log_message("stage_geosite_dat failed: " + e, "warn");
        return false;
    }
}

function v2fly_geosite_present() {
    stage_geosite_dat();
    return xray_geosite_dat() != "";
}

function geosite_has_tag(tag) {
    tag = trim(as_string(tag));
    if (tag == "")
        return false;
    let path = xray_geosite_dat();
    if (path == "")
        return false;
    return dat_contains(path, tag);
}

function dat_code(value) {
    let at = index(value, "@");
    return at > 0 ? substr(value, 0, at) : value;
}

function parse_dat_matcher(value) {
    value = trim(as_string(value));
    if (index(value, "geosite:") == 0)
        return { kind: "geosite", file: "geosite.dat", code: dat_code(substr(value, 8)) };
    if (index(value, "geoip:") == 0)
        return { kind: "geoip", file: "geoip.dat", code: dat_code(substr(value, 6)) };
    if (index(value, "ext:") == 0) {
        let rest = substr(value, 4);
        let colon = index(rest, ":");
        if (colon <= 0)
            return { kind: "ext", file: "", code: "" };
        return {
            kind: "ext",
            file: substr(rest, 0, colon),
            code: dat_code(substr(rest, colon + 1))
        };
    }
    return null;
}

function resolve_asset_dat(file) {
    file = trim(as_string(file));
    if (file == "")
        return "";
    if (substr(file, 0, 1) == "/")
        return file_size(file) > 0 ? file : "";
    let path = xray_constants.XRAY_LOCATION_ASSET + "/" + file;
    return file_size(path) > 0 ? path : "";
}

function itdog_ext_matcher_ok(value, path) {
    value = trim(as_string(value));
    let prefix = "ext:allow-domains.dat:";
    if (index(value, prefix) != 0)
        return false;
    if (!looks_like_itdog_dat(path))
        return false;
    let tag = substr(value, length(prefix));
    if (index(tag, "@") <= 0) {
        if (tag == "russia-inside" || tag == "russia-outside" || tag == "ukraine-inside" || tag == "ukraine")
            return allow_domains_has_tag(tag);
        for (let name in ITDOG_SITE_CODE)
            if (as_string(ITDOG_SITE_CODE[name]) == tag)
                return allow_domains_has_tag(tag);
        return false;
    }
    let attr = substr(tag, index(tag, "@") + 1);
    if (ITDOG_GEOSITE_ATTR[replace(attr, "-", "_")] != true &&
        ITDOG_GEOSITE_ATTR[attr] != true)
        return false;
    return allow_domains_has_tag(tag);
}

function dat_matcher_usable(value) {
    let parsed = parse_dat_matcher(value);
    if (parsed == null)
        return true;
    let code = trim(as_string(parsed.code));
    if (code == "")
        return false;
    let path = parsed.kind == "geosite" ? xray_geosite_dat() : resolve_asset_dat(parsed.file);
    let ok = false;
    if (path != "") {
        if (parsed.kind == "ext" && parsed.file == "allow-domains.dat")
            ok = itdog_ext_matcher_ok(value, path);
        else
            ok = dat_contains(path, code);
    }
    if (!ok && !dropped_matcher_log[value]) {
        dropped_matcher_log[value] = true;
        log_message("skipping Xray matcher not present in dat: " + value, "warn");
    }
    return ok;
}

function community_ext_candidates(name) {
    name = trim(as_string(name));
    let tags = [];
    if (name == "")
        return tags;
    let special = GEOSITE_TAGS[name];
    if (special != null)
        push(tags, as_string(special));
    let site = ITDOG_SITE_CODE[name];
    if (site != null)
        push(tags, as_string(site));
    if (ITDOG_GEOSITE_ATTR[name] == true)
        push(tags, "russia-inside@" + replace(name, "_", "-"));
    return tags;
}

function community_ext_tag(name) {
    let tags = community_ext_candidates(name);
    return length(tags) > 0 ? tags[0] : "";
}

function resolve_community_ext_tag(name) {
    for (let tag in community_ext_candidates(name))
        if (allow_domains_has_tag(tag))
            return tag;
    return "";
}

function community_lst_relpath(name) {
    name = trim(as_string(name));
    let rel = LST_PATHS[name];
    return rel == null ? "" : as_string(rel);
}

function community_lst_url(name) {
    let rel = community_lst_relpath(name);
    return rel == "" ? "" : ITDOG_RAW_BASE + "/" + rel;
}

function community_lst_path(name) {
    let rel = community_lst_relpath(name);
    if (rel == "")
        return "";
    let slash = rindex(rel, "/");
    let basename = slash >= 0 ? substr(rel, slash + 1) : rel;
    return cache_dir() + "/" + basename;
}

function native_xray_list_name(name) {
    name = trim(as_string(name));
    return name == "ads_hagezi_pro" || name == "supercell" || name == "github";
}

function supercell_json_path() {
    return cache_dir() + "/supercell.json";
}

function github_list_path() {
    return cache_dir() + "/github.list";
}

function community_has_subnets(name) {
    return SUBNET_SERVICES[trim(as_string(name))] == true;
}

function subnet_relpaths(name) {
    name = trim(as_string(name));
    if (!community_has_subnets(name))
        return [];
    let rels = [ "Subnets/IPv4/" + name + ".lst" ];
    if (name != "roblox")
        push(rels, "Subnets/IPv6/" + name + ".lst");
    return rels;
}

function subnet_cache_path(rel) {
    rel = trim(as_string(rel));
    if (rel == "")
        return "";
    return cache_dir() + "/" + rel;
}

function subnet_rel_from_url(url) {
    url = as_string(url);
    let needle = "/Subnets/";
    let at = index(url, needle);
    if (at < 0)
        return "";
    return substr(url, at + 1);
}

function remember_subnet_file(service, url, src_path) {
    src_path = as_string(src_path);
    if (src_path == "" || file_size(src_path) == 0)
        return false;
    let rel = subnet_rel_from_url(url);
    if (rel == "" && community_has_subnets(service))
        rel = "Subnets/IPv4/" + trim(as_string(service)) + ".lst";
    let dest = subnet_cache_path(rel);
    if (dest == "")
        return false;
    let parent = "";
    let slash = rindex(dest, "/");
    if (slash > 0)
        parent = substr(dest, 0, slash);
    if (parent != "" && !ensure_dir(parent))
        return false;
    let data = fs.readfile(src_path);
    if (data == null)
        return false;
    return fs.writefile(dest, data) != null;
}

function v2fly_geosite_tag(name) {
    name = trim(as_string(name));
    let tag = V2FLY_GEOSITE[name];
    return tag == null ? "" : as_string(tag);
}

function empty_matchers() {
    return { domains: [], ips: [], ok: false };
}

function push_unique(result, value, seen) {
    value = trim(as_string(value));
    if (value == "")
        return;
    if (type(seen) == "object") {
        if (seen[value])
            return;
        seen[value] = true;
        push(result, value);
        return;
    }
    for (let existing in result) {
        if (as_string(existing) == value)
            return;
    }
    push(result, value);
}

function looks_like_cidr(value) {
    value = trim(as_string(value));
    if (match(value, /^[0-9]{1,3}(\.[0-9]{1,3}){3}\/[0-9]{1,2}$/) != null)
        return true;
    if (index(value, ":") >= 0 && index(value, "/") >= 0)
        return true;
    return false;
}

function looks_like_ip(value) {
    value = trim(as_string(value));
    if (match(value, /^[0-9]{1,3}(\.[0-9]{1,3}){3}$/) != null)
        return true;
    return false;
}

function normalize_domain_line(value) {
    value = trim(as_string(value));
    if (value == "" || substr(value, 0, 1) == "#" || substr(value, 0, 1) == "!")
        return "";
    if (substr(value, 0, 2) == "||") {
        value = substr(value, 2);
        let cut = index(value, "^");
        if (cut >= 0)
            value = substr(value, 0, cut);
        value = trim(value);
    }
    if (substr(value, 0, 2) == "*.")
        value = substr(value, 2);
    let comma = index(value, ",");
    if (comma > 0) {
        let kind = lc(substr(value, 0, comma));
        let rest = trim(substr(value, comma + 1));
        let extra = index(rest, ",");
        if (extra >= 0)
            rest = trim(substr(rest, 0, extra));
        if (kind == "domain-suffix" || kind == "host-suffix" ||
            kind == "domain" || kind == "host" ||
            kind == "domain-keyword" || kind == "ip-cidr" || kind == "ip-cidr6")
            value = rest;
    }
    return value;
}

function parse_list_text(text) {
    let domains = [];
    let ips = [];
    let seen_domains = {};
    let seen_ips = {};
    for (let line in split(as_string(text), "\n")) {
        line = normalize_domain_line(line);
        if (line == "")
            continue;
        if (looks_like_cidr(line) || looks_like_ip(line))
            push_unique(ips, line, seen_ips);
        else
            push_unique(domains, line, seen_domains);
    }
    return { domains, ips };
}

function lst_to_matchers(path) {
    let data = fs.readfile(as_string(path));
    if (data == null)
        return empty_matchers();
    let parsed = parse_list_text(data);
    if (length(parsed.domains) + length(parsed.ips) == 0)
        return empty_matchers();
    if (length(parsed.domains) + length(parsed.ips) > MAX_INLINE_MATCHERS) {
        log_message("truncating oversized list for Xray (" +
            as_string(length(parsed.domains) + length(parsed.ips)) + " entries): " + path, "info");
        let domains = [];
        let ips = [];
        for (let value in parsed.domains) {
            if (length(domains) + length(ips) >= MAX_INLINE_MATCHERS)
                break;
            push(domains, value);
        }
        for (let value in parsed.ips) {
            if (length(domains) + length(ips) >= MAX_INLINE_MATCHERS)
                break;
            push(ips, value);
        }
        parsed.domains = domains;
        parsed.ips = ips;
    }
    let domains = [];
    for (let value in parsed.domains) {
        if (index(value, "full:") == 0 || index(value, "domain:") == 0 ||
            index(value, "keyword:") == 0 || index(value, "regexp:") == 0 ||
            index(value, "geosite:") == 0 || index(value, "ext:") == 0)
            push(domains, value);
        else
            push(domains, "domain:" + value);
    }
    return { domains, ips: parsed.ips, ok: true };
}

function json_decode_text(text) {
    try {
        return json(as_string(text));
    }
    catch (e) {
        return null;
    }
}

function ingest_rule_object(rule, domains, ips, seen_domains, seen_ips) {
    rule = object_or_empty(rule);
    if (type(seen_domains) != "object")
        seen_domains = {};
    if (type(seen_ips) != "object")
        seen_ips = {};
    for (let value in array_or_empty(rule.domain))
        push_unique(domains, "full:" + value, seen_domains);
    for (let value in array_or_empty(rule.domain_suffix))
        push_unique(domains, value, seen_domains);
    for (let value in array_or_empty(rule.domain_keyword))
        push_unique(domains, "keyword:" + value, seen_domains);
    for (let value in array_or_empty(rule.domain_regex))
        push_unique(domains, "regexp:" + value, seen_domains);
    for (let value in array_or_empty(rule.ip_cidr))
        push_unique(ips, value, seen_ips);
}

function source_json_to_matchers(value) {
    let domains = [];
    let ips = [];
    let seen_domains = {};
    let seen_ips = {};
    value = object_or_empty(value);
    ingest_rule_object(value, domains, ips, seen_domains, seen_ips);
    for (let rule in array_or_empty(value.rules))
        ingest_rule_object(rule, domains, ips, seen_domains, seen_ips);
    if (length(domains) + length(ips) == 0)
        return empty_matchers();
    if (length(domains) + length(ips) > MAX_INLINE_MATCHERS)
        return empty_matchers();
    return { domains, ips, ok: true };
}

function decompile_cache_path(srs_path) {
    return cache_dir() + "/" + singbox_rulesets.hash12(srs_path) + ".xray.json";
}

function command_from_args(args) {
    let parts = [];
    for (let arg in args)
        push(parts, "'" + replace(as_string(arg), /'/g, "'\\''") + "'");
    return join(" ", parts);
}

function timeout_bin() {
    if (file_exists("/usr/bin/timeout"))
        return "/usr/bin/timeout";
    if (file_exists("/bin/timeout"))
        return "/bin/timeout";
    return "";
}

function decompile_srs(srs_path) {
    srs_path = as_string(srs_path);
    let size = file_size(srs_path);
    if (size == 0)
        return empty_matchers();
    if (size > MAX_DECOMPILE_BYTES) {
        log_message("skip Xray decompile of oversized ruleset (" + size + " bytes): " + srs_path, "info");
        return empty_matchers();
    }
    if (!file_exists(SING_BOX_BIN))
        return empty_matchers();
    if (!ensure_dir(cache_dir()))
        return empty_matchers();

    let cached = decompile_cache_path(srs_path);
    if (file_size(cached) > 0 && file_mtime(cached) >= file_mtime(srs_path)) {
        let reused = json_decode_text(fs.readfile(cached));
        if (type(reused) == "object" && reused.ok)
            return {
                domains: array_or_empty(reused.domains),
                ips: array_or_empty(reused.ips),
                ok: true
            };
    }

    let tb = timeout_bin();
    if (tb == "" && size > 131072) {
        log_message("skip Xray decompile without timeout(1) for " + srs_path, "info");
        return empty_matchers();
    }

    let tmp = "/tmp/forkop-stage/" + singbox_rulesets.hash12(srs_path) + ".src." + as_string(clock()[0]);
    if (!ensure_dir("/tmp/forkop-stage"))
        return empty_matchers();
    let args = [ SING_BOX_BIN, "rule-set", "decompile", srs_path, "-o", tmp ];
    let command = command_from_args(args) + " >/dev/null 2>&1";
    if (tb != "")
        command = command_from_args([ tb, as_string(DECOMPILE_TIMEOUT_SECONDS) ]) + " " + command;

    log_message("decompile ruleset for Xray: " + srs_path, "debug");
    let status = system(command);
    let parsed = json_decode_text(fs.readfile(tmp));
    try { fs.unlink(tmp); } catch (e) { }
    if (status != 0)
        return empty_matchers();
    let matchers = source_json_to_matchers(parsed);
    if (matchers.ok)
        fs.writefile(cached, sprintf("%J\n", matchers));
    return matchers;
}

function copy_dat_to_asset_dirs(src) {
    if (file_size(src) == 0)
        return false;
    ensure_dir("/usr/share/xray");
    ensure_dir("/etc/xray");
    if (src != xray_constants.ALLOW_DOMAINS_DAT)
        system("cp -f '" + replace(src, /'/g, "'\\''") + "' '" + xray_constants.ALLOW_DOMAINS_DAT + "' >/dev/null 2>&1");
    system("cp -f '" + replace(xray_constants.ALLOW_DOMAINS_DAT, /'/g, "'\\''") + "' '" +
        xray_constants.ALLOW_DOMAINS_DAT_ETC + "' >/dev/null 2>&1");
    persist_dat_to_flash(xray_constants.ALLOW_DOMAINS_DAT, "allow-domains.dat");
    return allow_domains_dat_present();
}

function copy_adlist_to_asset_dirs(src) {
    if (file_size(src) == 0 || !looks_like_adlist_dat(src))
        return false;
    ensure_dir("/usr/share/xray");
    ensure_dir("/etc/xray");
    if (src != ADLIST_DAT)
        copy_file(src, ADLIST_DAT);
    copy_file(ADLIST_DAT, ADLIST_DAT_ETC);
    persist_dat_to_flash(ADLIST_DAT, "adlist.dat");
    return adlist_dat_path() != "";
}

function fetch_url(url, path, proxy_address, force) {
    url = trim(as_string(url));
    path = as_string(path);
    if (url == "" || path == "")
        return false;
    let parent = "";
    let slash = rindex(path, "/");
    if (slash > 0)
        parent = substr(path, 0, slash);
    if (parent != "" && !ensure_dir(parent))
        return false;
    if (!force && file_size(path) > 0)
        return true;
    return list_cache.download_to_file(url, path, proxy_address);
}

function needs_v2fly_geosite(names) {
    for (let name in array_or_empty(names))
        if (v2fly_geosite_tag(name) != "")
            return true;
    return false;
}

function fetch_v2fly_geosite(proxy_address, force) {
    let dest = xray_constants.XRAY_LOCATION_ASSET + "/geosite.dat";
    if (!force && looks_like_v2fly_dat(dest))
        return true;
    let tmp = download_scratch("v2fly-geosite.dat");
    if (tmp == "")
        return looks_like_v2fly_dat(dest);
    let urls = [ V2FLY_GEOSITE_DAT_URL, LOYALSOLDIER_GEOSITE_DAT_URL ];
    for (let url in urls) {
        log_message(
            "fetching v2fly geosite.dat" +
            (as_string(proxy_address) != "" ? " via " + as_string(proxy_address) : " directly"),
            "info"
        );
        try { fs.unlink(tmp); } catch (e) { }
        if (!fetch_url(url, tmp, proxy_address, true))
            continue;
        if (looks_like_itdog_dat(tmp) && !looks_like_v2fly_dat(tmp)) {
            salvage_itdog_dat(tmp);
            continue;
        }
        if (looks_like_v2fly_dat(tmp) && copy_file(tmp, dest) && looks_like_v2fly_dat(dest)) {
            persist_dat_to_flash(dest, "geosite.dat");
            forget_v2fly_scratch();
            log_message("staged v2fly geosite.dat for Xray (" + as_string(file_size(dest)) + " bytes)", "info");
            return true;
        }
    }
    if (!looks_like_v2fly_dat(dest))
        log_message("v2fly geosite.dat is missing; github waits for list-update", "info");
    return looks_like_v2fly_dat(dest);
}

function fetch_adlist_dat(proxy_address, force) {
    if (!force && adlist_dat_path() != "")
        return true;
    let tmp = download_scratch("adlist.download");
    if (tmp == "")
        return adlist_dat_path() != "";
    log_message(
        "fetching adlist.dat" +
        (as_string(proxy_address) != "" ? " via " + as_string(proxy_address) : " directly"),
        "info"
    );
    try { fs.unlink(tmp); } catch (e) { }
    if (!fetch_url(ADLIST_DAT_URL, tmp, proxy_address, true)) {
        if (adlist_dat_path() == "")
            log_message("adlist.dat is missing; ads_hagezi_pro waits for list-update", "info");
        return adlist_dat_path() != "";
    }
    if (!looks_like_adlist_dat(tmp)) {
        log_message("downloaded adlist.dat is not a hagezi dat; keeping the last copy", "warn");
        try { fs.unlink(tmp); } catch (e2) { }
        return adlist_dat_path() != "";
    }
    if (copy_adlist_to_asset_dirs(tmp)) {
        try { fs.unlink(tmp); } catch (e3) { }
        try { fs.unlink(tmp + ".gz"); } catch (e4) { }
        try { fs.unlink(tmp + ".gz.size"); } catch (e5) { }
        log_message("staged adlist.dat for Xray (" + as_string(file_size(ADLIST_DAT)) + " bytes)", "info");
        return true;
    }
    return adlist_dat_path() != "";
}

function fetch_url_quick(url, path) {
    url = trim(as_string(url));
    path = as_string(path);
    if (url == "" || path == "")
        return false;
    if (file_size(path) > 0)
        return true;
    let parent = "";
    let slash = rindex(path, "/");
    if (slash > 0)
        parent = substr(path, 0, slash);
    if (parent != "" && !ensure_dir(parent))
        return false;
    if (!ensure_dir("/tmp/forkop-stage"))
        return false;
    let name = slash >= 0 ? substr(path, slash + 1) : "fetch";
    let tmp = "/tmp/forkop-stage/" + name + ".quick." + as_string(clock()[0]);
    log_message("quick-fetch " + url + " (" + QUICK_FETCH_SECONDS + "s)", "info");
    let status = system(
        command_from_args([
            "curl", "-sS", "-L", "--fail", "--retry", "0",
            "--max-time", as_string(QUICK_FETCH_SECONDS),
            "-o", tmp, "--url", url
        ]) + " >/dev/null 2>&1"
    );
    if (status == 0 && file_size(tmp) > 0) {
        if (system("mv -f " + shell_quote(tmp) + " " + shell_quote(path)) != 0) {
            try { fs.unlink(tmp); } catch (e) { }
            return false;
        }
        return file_size(path) > 0;
    }
    try { fs.unlink(tmp); } catch (e2) { }
    return false;
}

function cached_srs_path(url) {
    let path = list_cache.usable_local_path(url);
    if (path != "")
        return path;
    return list_cache.cache_path_for_url(url);
}

function list_option_values(section, key) {
    let result = [];
    let value = object_or_empty(section)[key];
    if (type(value) == "array") {
        for (let item in value)
            push_unique(result, item);
        return result;
    }
    value = trim(as_string(value));
    if (value == "")
        return result;
    for (let item in split(value, /[ \t\r\n]+/))
        push_unique(result, item);
    return result;
}

function lst_nftset_hosts(name) {
    let path = community_lst_path(name);
    if (file_size(path) == 0)
        return [];
    let data = fs.readfile(path);
    if (data == null)
        return [];
    return parse_list_text(data).domains;
}

function community_subnet_ips(name) {
    let ips = [];
    let seen = {};
    for (let rel in subnet_relpaths(name)) {
        let path = subnet_cache_path(rel);
        if (file_size(path) == 0)
            continue;
        let data = fs.readfile(path);
        if (data == null)
            continue;
        for (let ip in array_or_empty(parse_list_text(data).ips))
            push_unique(ips, ip, seen);
    }
    return ips;
}

function community_matchers(name) {
    name = trim(as_string(name));
    if (name == "")
        return empty_matchers();

    let domains = [];
    let ips = community_subnet_ips(name);
    let seen_domains = {};
    let seen_ips = {};
    for (let ip in ips)
        seen_ips[ip] = true;

    let ext = resolve_community_ext_tag(name);
    if (ext != "") {
        let matcher = "ext:allow-domains.dat:" + ext;
        if (dat_matcher_usable(matcher))
            push_unique(domains, matcher, seen_domains);
    }

    if (length(domains) == 0) {
        let lst_path = community_lst_path(name);
        if (file_size(lst_path) > 0) {
            let from_lst = lst_to_matchers(lst_path);
            if (from_lst.ok) {
                for (let value in array_or_empty(from_lst.domains))
                    push_unique(domains, value, seen_domains);
                for (let ip in array_or_empty(from_lst.ips))
                    push_unique(ips, ip, seen_ips);
            }
        }
    }

    if (length(domains) == 0 && name == "ads_hagezi_pro" && adlist_dat_path() != "")
        push_unique(domains, "ext:adlist.dat:" + ADLIST_CODE, seen_domains);

    if (length(domains) == 0 && name == "supercell") {
        let json_path = supercell_json_path();
        if (file_size(json_path) > 0) {
            let from_json = source_json_to_matchers(json_decode_text(fs.readfile(json_path)));
            if (from_json.ok) {
                for (let value in array_or_empty(from_json.domains))
                    push_unique(domains, value, seen_domains);
                for (let ip in array_or_empty(from_json.ips))
                    push_unique(ips, ip, seen_ips);
            }
        }
    }

    if (length(domains) == 0) {
        let v2 = v2fly_geosite_tag(name);
        if (v2 != "") {
            let matcher = "geosite:" + v2;
            if (dat_matcher_usable(matcher))
                push_unique(domains, matcher, seen_domains);
        }
    }

    if (length(domains) == 0 && name == "github") {
        let list_path = github_list_path();
        if (file_size(list_path) > 0) {
            let from_lst = lst_to_matchers(list_path);
            if (from_lst.ok) {
                for (let value in array_or_empty(from_lst.domains))
                    push_unique(domains, value, seen_domains);
                for (let ip in array_or_empty(from_lst.ips))
                    push_unique(ips, ip, seen_ips);
            }
        }
    }

    if (length(domains) == 0 && !native_xray_list_name(name)) {
        let srs_url = singbox_rulesets.community_url(name);
        let srs_path = cached_srs_path(srs_url);
        if (file_size(srs_path) > 0) {
            let from_srs = decompile_srs(srs_path);
            if (from_srs.ok) {
                for (let value in array_or_empty(from_srs.domains))
                    push_unique(domains, value, seen_domains);
                for (let ip in array_or_empty(from_srs.ips))
                    push_unique(ips, ip, seen_ips);
            }
        }
    }

    if (length(domains) > 0 || length(ips) > 0)
        return { domains, ips, ok: true };
    return empty_matchers();
}

function list_file_matchers(reference) {
    reference = trim(as_string(reference));
    if (reference == "")
        return empty_matchers();
    let path = reference;
    if (substr(reference, 0, 7) == "http://" || substr(reference, 0, 8) == "https://") {
        path = cached_srs_path(reference);
    }
    if (file_size(path) == 0)
        return empty_matchers();
    let ext = singbox_rulesets.file_extension(path);
    if (ext == "srs")
        return decompile_srs(path);
    if (ext == "json")
        return source_json_to_matchers(json_decode_text(fs.readfile(path)));
    return lst_to_matchers(path);
}

function plain_list_parsed(reference) {
    let converted = list_file_matchers(reference);
    if (type(converted) != "object" || converted.ok != true)
        return { domains: [], ips: [] };
    return {
        domains: array_or_empty(converted.domains),
        ips: array_or_empty(converted.ips)
    };
}

function ruleset_matchers(reference) {
    reference = trim(as_string(reference));
    if (reference == "")
        return empty_matchers();
    if (substr(reference, 0, 1) == "/")
        return list_file_matchers(reference);

    let cached = cached_srs_path(reference);
    if (file_size(cached) == 0)
        return empty_matchers();

    let ext = singbox_rulesets.file_extension(reference);
    if (ext == "json") {
        let parsed = json_decode_text(fs.readfile(cached));
        return source_json_to_matchers(parsed);
    }
    if (ext == "lst" || ext == "txt" || ext == "list")
        return lst_to_matchers(cached);
    return decompile_srs(cached);
}

function needed_from_sections(sections) {
    let names = [];
    let seen = {};
    for (let section in array_or_empty(sections)) {
        if (as_string(object_or_empty(section).enabled) == "0")
            continue;
        for (let name in connections.community_lists(section)) {
            name = trim(as_string(name));
            if (name == "" || seen[name])
                continue;
            seen[name] = true;
            push(names, name);
        }
    }
    return names;
}

function needed_references(sections) {
    let refs = [];
    let seen = {};
    let add = function(value) {
        value = trim(as_string(value));
        if (value == "" || seen[value])
            return;
        seen[value] = true;
        push(refs, value);
    };
    for (let section in array_or_empty(sections)) {
        if (as_string(object_or_empty(section).enabled) == "0")
            continue;
        for (let value in connections.rule_sets(section))
            add(value);
        for (let value in connections.rule_sets_with_subnets(section))
            add(value);
        for (let value in list_option_values(section, "domain_ip_lists"))
            add(value);
    }
    return refs;
}

function uci_sections() {
    return uci_core.section_objects(CONFIG_NAME, "section");
}

function assets_present_for_uci() {
    if (!engine.is_xray_primary())
        return true;
    restore_flash_dat();
    let names = needed_from_sections(uci_sections());
    let need_itdog = false;
    let need_v2fly = false;
    let need_adlist = false;
    for (let name in names) {
        if (community_ext_tag(name) != "")
            need_itdog = true;
        if (v2fly_geosite_tag(name) != "")
            need_v2fly = true;
        if (name == "ads_hagezi_pro")
            need_adlist = true;
    }
    if (need_itdog && !allow_domains_dat_present())
        return false;
    if (need_v2fly && !v2fly_geosite_present())
        return false;
    if (need_adlist && adlist_dat_path() == "")
        return false;
    return true;
}

function ensure_reference(reference, proxy_address, force) {
    reference = trim(as_string(reference));
    if (reference == "" || substr(reference, 0, 1) == "/")
        return file_size(reference) > 0;
    let path = list_cache.cache_path_for_url(reference);
    if ((force || file_size(path) == 0) && !fetch_url(reference, path, proxy_address, force))
        return file_size(path) > 0;
    let ext = singbox_rulesets.file_extension(reference);
    if (ext == "srs" || ext == "")
        decompile_srs(path);
    return file_size(path) > 0;
}

function ensure_from_uci(settings, proxy_address, force) {
    if (!engine.is_xray_primary())
        return true;
    force = force === true;
    let allow_network = force;
    stage_geosite_dat();
    let sections = uci_sections();
    let names = needed_from_sections(sections);
    let refs = needed_references(sections);
    if (length(names) == 0 && length(refs) == 0)
        return true;

    if (as_string(proxy_address) == "")
        proxy_address = list_cache.lists_proxy_address(settings);

    let need_dat = false;
    for (let name in names) {
        if (community_ext_tag(name) != "")
            need_dat = true;
    }

    log_message(
        "Xray plane: " + (allow_network ? "updating" : "staging") + " " +
        length(names) + " community list(s) and " +
        length(refs) + " ruleset(s)" + (allow_network ? " (network allowed)" : " from cache"),
        "info"
    );

    let ok = true;
    if (need_dat && (force || !allow_domains_dat_present())) {
        if (allow_network) {
            log_message(
                "fetching allow-domains.dat" +
                (as_string(proxy_address) != "" ? " via " + as_string(proxy_address) : " directly"),
                "info"
            );
            if (!fetch_url(xray_constants.ALLOW_DOMAINS_DAT_URL, xray_constants.ALLOW_DOMAINS_DAT, proxy_address, force) &&
                !allow_domains_dat_present())
                ok = false;
            if (allow_domains_dat_present() && !looks_like_itdog_dat(xray_constants.ALLOW_DOMAINS_DAT))
                purge_unusable_allow_domains_dat();
            if (looks_like_itdog_dat(xray_constants.ALLOW_DOMAINS_DAT))
                log_message(
                    "using itdog allow-domains.dat (" +
                    as_string(file_size(xray_constants.ALLOW_DOMAINS_DAT)) + " bytes)",
                    "info"
                );
        }
        if (allow_domains_dat_present())
            copy_dat_to_asset_dirs(xray_constants.ALLOW_DOMAINS_DAT);
        else
            log_message("allow-domains.dat is missing; itdog domain lists wait for list-update", "info");
    }
    else if (need_dat && allow_domains_dat_present()) {
        copy_dat_to_asset_dirs(xray_constants.ALLOW_DOMAINS_DAT);
    }

    if (needs_v2fly_geosite(names)) {
        if (allow_network)
            fetch_v2fly_geosite(proxy_address, force);
        else if (!looks_like_v2fly_dat(xray_constants.XRAY_LOCATION_ASSET + "/geosite.dat"))
            log_message("v2fly geosite.dat is missing; github waits for list-update", "info");
    }

    let need_adlist = false;
    for (let name in names) {
        if (name == "ads_hagezi_pro")
            need_adlist = true;
    }
    if (need_adlist) {
        if (allow_network)
            fetch_adlist_dat(proxy_address, force);
        else if (adlist_dat_path() == "")
            log_message("adlist.dat is missing; ads_hagezi_pro waits for list-update", "info");
        else
            copy_adlist_to_asset_dirs(adlist_dat_path());
    }

    for (let name in names) {
        if (allow_network) {
            for (let rel in subnet_relpaths(name)) {
                let url = ITDOG_RAW_BASE + "/" + rel;
                let path = subnet_cache_path(rel);
                if (!fetch_url(url, path, proxy_address, force) && file_size(path) == 0)
                    ok = false;
            }
            if (community_lst_url(name) != "") {
                let lst_url = community_lst_url(name);
                if (!fetch_url(lst_url, community_lst_path(name), proxy_address, force) &&
                    file_size(community_lst_path(name)) == 0)
                    ok = false;
            }
            if (name == "supercell") {
                if (!fetch_url(SUPERCELL_JSON_URL, supercell_json_path(), proxy_address, force) &&
                    file_size(supercell_json_path()) == 0)
                    ok = false;
            }
            if (name == "github") {
                fetch_url(GITHUB_LIST_URL, github_list_path(), proxy_address, force);
            }
            if (!native_xray_list_name(name) &&
                (community_ext_tag(name) == "" || !allow_domains_dat_present())) {
                let srs_url = singbox_rulesets.community_url(name);
                if (srs_url != "")
                    fetch_url(srs_url, cached_srs_path(srs_url), proxy_address, force);
            }
        }
        if (!community_matchers(name).ok && community_ext_tag(name) == "")
            ok = false;
    }

    for (let reference in refs) {
        if (allow_network) {
            if (!ensure_reference(reference, proxy_address, force))
                ok = false;
        }
        else if (substr(trim(as_string(reference)), 0, 1) == "/") {
            if (file_size(reference) == 0)
                ok = false;
        }
        else {
            let converted = ruleset_matchers(reference);
            if (!converted.ok)
                log_message("ruleset not converted at start, sidecar will handle it: " + reference, "debug");
        }
    }

    return true;
}

return {
    community_ext_tag,
    community_lst_url,
    community_lst_path,
    lst_nftset_hosts,
    community_matchers,
    ruleset_matchers,
    list_file_matchers,
    plain_list_parsed,
    lst_to_matchers,
    decompile_srs,
    ensure_from_uci,
    remember_subnet_file,
    stage_geosite_dat,
    restore_flash_dat,
    assets_present_for_uci,
    geosite_has_tag,
    allow_domains_has_tag,
    dat_matcher_usable,
    needed_references,
    allow_domains_dat_present,
    v2fly_geosite_present,
    MAX_INLINE_MATCHERS,
    MAX_DECOMPILE_BYTES,
    DECOMPILE_TIMEOUT_SECONDS
};
