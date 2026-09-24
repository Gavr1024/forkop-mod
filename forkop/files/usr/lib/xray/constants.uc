#!/usr/bin/env ucode

const XRAY_BIN = "/usr/bin/xray";
const XRAY_CONFIG = "/etc/xray/config.json";
const XRAY_SERVICE_INIT = "/etc/init.d/xray";
const XRAY_MANAGED_SERVICE_MARKER = "Forkop managed xray service";
const XRAY_SOCKS_LISTEN = "127.0.0.1";
const XRAY_SOCKS_PORT_BASE = 10808;
const XRAY_CASCADE_PORT_BASE = 10908;
const XRAY_NODE_PORT_BASE = 11008;
const XRAY_STATE_DIR = "/var/run/forkop/xray";
const XRAY_PORTS_FILE = "/var/run/forkop/xray-ports.json";
const XRAY_NODES_FILE = "/var/run/forkop/xray-nodes.json";
const XRAY_LATENCY_FILE = "/var/run/forkop/xray-latency.json";
const XRAY_CASCADE_FILE = "/var/run/forkop/xray-cascade.json";
const XRAY_SELECTED_FILE = "/etc/forkop/xray-selected.json";
const XRAY_URLTEST_TAG = "__urltest__";
const XRAY_URLTEST_PID_FILE = "/var/run/forkop/xray-urltest.pid";
const XRAY_VERSION_STATE_FILE = "/etc/forkop/xray-version";
const XRAY_RELEASE_REPO = "XTLS/Xray-core";
const XRAY_REQUIRED_VERSION = "24.12.0";
const XRAY_ACCESS_LOG = "/tmp/xray-access.log";
const FREEDOM_TAG = "direct";
const BLACKHOLE_TAG = "block";
const OUTBOUND_MARK = 134217728;
const XRAY_TPROXY_TAG = "tproxy-in";
const XRAY_TPROXY6_TAG = "tproxy6-in";
const XRAY_TPROXY_PORT = 1602;
const XRAY_TPROXY_FAKEIP_TAG = "tproxy-fakeip-in";
const XRAY_TPROXY_FAKEIP6_TAG = "tproxy-fakeip6-in";
const XRAY_TPROXY_FAKEIP_PORT = 1605;
const XRAY_API_TAG = "api";
const XRAY_API_PORT = 10085;
const XRAY_DNS_INBOUND_TAG = "dns-in";
const XRAY_DNS_LISTEN = "127.0.0.42";
const XRAY_DNS_PORT = 53;
const XRAY_DNS_OUTBOUND_TAG = "dns-out";
const XRAY_DNS_REDIR_TAG = "dns-in-redir";
const XRAY_DNS_REDIR6_TAG = "dns-in-redir6";
const XRAY_DNS_REDIR_PORT = 1603;
const XRAY_REDIRECT_TAG = "redirect-in";
const XRAY_REDIRECT_LISTEN = "127.0.0.1";
const XRAY_REDIRECT_PORT = 1604;
const XRAY_DNS_REMOTE_TAG = "dns-remote";
const XRAY_DNS_BOOTSTRAP_TAG = "dns-bootstrap";
const SINGBOX_SIDECAR_TAG = "sing-box-sidecar";
const SINGBOX_SIDECAR_LISTEN = "127.0.0.1";
const SINGBOX_SIDECAR_PORT = 4536;
const SINGBOX_SIDECAR_INBOUND_TAG = "xray-plane-mixed-in";
const FAKEIP_INET4_RANGE = "198.18.0.0/15";
const FAKEIP_INET6_RANGE = "fc00::/18";
const XRAY_LOCATION_ASSET = "/usr/share/xray";
const ALLOW_DOMAINS_DAT = "/usr/share/xray/allow-domains.dat";
const ALLOW_DOMAINS_DAT_ETC = "/etc/xray/allow-domains.dat";
const ALLOW_DOMAINS_DAT_URL = "https://github.com/itdoginfo/allow-domains/releases/latest/download/geosite.dat";
const XRAY_LIST_CACHE_DIR = "/etc/forkop/list-cache/xray";
const XRAY_CONFIG_STAMP = "/etc/forkop/xray-config.stamp";
const XRAY_LAST_DIR = "/etc/forkop/xray-last";

function as_string(value) {
    return value == null ? "" : "" + value;
}

function inbound_tag(section_name) {
    return "socks-in-" + as_string(section_name);
}

function node_inbound_tag(section_name, index) {
    return "socks-in-" + as_string(section_name) + "-" + as_string(index);
}

function outbound_tag(section_name, index) {
    if (index == null || index == "")
        return "xray-" + as_string(section_name);
    return "xray-" + as_string(section_name) + "-" + as_string(index);
}

function balancer_tag(section_name) {
    return "balancer-" + as_string(section_name);
}

return {
    XRAY_BIN,
    XRAY_CONFIG,
    XRAY_SERVICE_INIT,
    XRAY_MANAGED_SERVICE_MARKER,
    XRAY_SOCKS_LISTEN,
    XRAY_SOCKS_PORT_BASE,
    XRAY_CASCADE_PORT_BASE,
    XRAY_NODE_PORT_BASE,
    XRAY_STATE_DIR,
    XRAY_PORTS_FILE,
    XRAY_NODES_FILE,
    XRAY_LATENCY_FILE,
    XRAY_CASCADE_FILE,
    XRAY_SELECTED_FILE,
    XRAY_URLTEST_TAG,
    XRAY_URLTEST_PID_FILE,
    XRAY_VERSION_STATE_FILE,
    XRAY_RELEASE_REPO,
    XRAY_REQUIRED_VERSION,
    TMP_XRAY_FOLDER,
    XRAY_ACCESS_LOG,
    OUTBOUND_MARK,
    FREEDOM_TAG,
    BLACKHOLE_TAG,
    XRAY_TPROXY_TAG,
    XRAY_TPROXY6_TAG,
    XRAY_TPROXY_PORT,
    XRAY_TPROXY_FAKEIP_TAG,
    XRAY_TPROXY_FAKEIP6_TAG,
    XRAY_TPROXY_FAKEIP_PORT,
    XRAY_API_TAG,
    XRAY_API_PORT,
    XRAY_DNS_INBOUND_TAG,
    XRAY_DNS_LISTEN,
    XRAY_DNS_PORT,
    XRAY_DNS_OUTBOUND_TAG,
    XRAY_DNS_REDIR_TAG,
    XRAY_DNS_REDIR6_TAG,
    XRAY_DNS_REDIR_PORT,
    XRAY_REDIRECT_TAG,
    XRAY_REDIRECT_LISTEN,
    XRAY_REDIRECT_PORT,
    XRAY_DNS_REMOTE_TAG,
    XRAY_DNS_BOOTSTRAP_TAG,
    SINGBOX_SIDECAR_TAG,
    SINGBOX_SIDECAR_LISTEN,
    SINGBOX_SIDECAR_PORT,
    SINGBOX_SIDECAR_INBOUND_TAG,
    FAKEIP_INET4_RANGE,
    FAKEIP_INET6_RANGE,
    XRAY_LOCATION_ASSET,
    ALLOW_DOMAINS_DAT,
    ALLOW_DOMAINS_DAT_ETC,
    ALLOW_DOMAINS_DAT_URL,
    XRAY_LIST_CACHE_DIR,
    XRAY_CONFIG_STAMP,
    XRAY_LAST_DIR,
    inbound_tag,
    node_inbound_tag,
    outbound_tag,
    balancer_tag
};
