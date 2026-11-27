#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNTIME="$ROOT_DIR/forkop/files/usr/lib/xray/runtime.uc"
MAIN_JS="$ROOT_DIR/luci-app-forkop/htdocs/luci-static/resources/view/forkop/main.js"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

extract_fn() {
  local file="$1"
  local name="$2"
  awk -v name="$name" '
    $0 ~ "^function " name "\\(" { grab = 1 }
    grab { print }
    grab && /^}$/ { exit }
  ' "$file"
}

extract_fn "$RUNTIME" "active_node_tag" | grep -F 'remembered_section_outbound' >/dev/null ||
  fail "least ping and least load must keep the last real server"
if extract_fn "$RUNTIME" "active_node_tag" | grep -F 'lowest_delay_tag' >/dev/null; then
  fail "least ping and least load must not fall back to the fastest server"
fi
extract_fn "$RUNTIME" "active_node_tag" | grep -F 'tag_is_stopped' >/dev/null ||
  fail "a stopped server must not stay selected"
extract_fn "$RUNTIME" "latest_detour_index" | grep -F 'is_node_probe_inbound' >/dev/null ||
  fail "server checks must not count as the last connection"
extract_fn "$RUNTIME" "clear_last_outbounds" | grep -F 'since:' >/dev/null ||
  fail "a new Xray start must ignore the old access log"
extract_fn "$RUNTIME" "start_runtime" | grep -F 'clear_last_outbounds' >/dev/null ||
  fail "a new Xray start must forget the previous server"
extract_fn "$RUNTIME" "access_log_read_command" | grep -F 'tail -c +' >/dev/null ||
  fail "only log lines after the restart mark may choose a server"
extract_fn "$RUNTIME" "access_line_route" | grep -F 'accepted' >/dev/null ||
  fail "access log parser must read accepted connections"
extract_fn "$MAIN_JS" "renderBalancerInfoModal" | grep -F 'Last connection' >/dev/null ||
  fail "least load details must call the row the last connection"
extract_fn "$MAIN_JS" "renderBalancerInfoModal" | grep -F 'Servers have not been checked yet' >/dev/null ||
  fail "an unchecked group must not say the servers were too slow"
extract_fn "$MAIN_JS" "leastLoadGroupCodes" | grep -F 'ranked.slice(0, expected)' >/dev/null ||
  fail "a zero max RTT must keep only the fastest servers"
extract_fn "$MAIN_JS" "buildBalancerInfo" | grep -F 'member.inGroup' >/dev/null ||
  fail "least load details must mark the current group"

parser="$(extract_fn "$RUNTIME" "access_token"; printf '\n'; extract_fn "$RUNTIME" "access_line_route"; printf '\n'; extract_fn "$RUNTIME" "access_line_outbound"; printf '\n'; extract_fn "$RUNTIME" "is_node_probe_inbound")"
ucode -e '
function as_string(value) { return value == null ? "" : "" + value; }
function trim(value) { return replace(as_string(value), /^[ \t\r\n]+|[ \t\r\n]+$/g, ""); }
'"$parser"'
let samples = [
  [ "from 192.168.1.5:41234 accepted tcp:example.com:443 [socks-in-EN -> node-a]", "node-a", "socks-in-EN" ],
  [ "from 192.168.1.5:41234 accepted tcp:example.com:443 [tproxy-in >> node-b]", "node-b", "tproxy-in" ],
  [ "from 192.168.1.5:1 accepted tcp:example.com:443 [tproxy-in ==> node-c]", "node-c", "tproxy-in" ],
  [ "from tcp:www.gstatic.com:443 accepted tcp:www.gstatic.com:443 [node-a]", "", "" ],
  [ "from tcp:www.gstatic.com:443 accepted tcp:www.gstatic.com:443 [-> node-a]", "", "" ],
  [ "from 10.0.0.2:1 accepted tcp:[2001:db8::1]:443 [tproxy-in -> node-d]", "node-d", "tproxy-in" ],
  [ "detour: node-e extra", "node-e", "" ],
  [ "from 1.1.1.1:2 accepted tcp:a:80 [in -> balancer-EN]", "", "in" ],
  [ "from 1.1.1.1:2 rejected tcp:a:80 [in -> node-f]", "", "" ],
  [ "from 127.0.0.1:9 accepted tcp:www.gstatic.com:443 [socks-in-EN-2 -> node-g]", "node-g", "socks-in-EN-2" ],
  [ "from 10.0.0.8:9 accepted tcp:a:443 [tproxy-in -> Netherlands 1]", "Netherlands 1", "tproxy-in" ]
];
for (let sample in samples) {
  let route = access_line_route(sample[0]);
  if (route.outbound != sample[1] || route.inbound != sample[2] || access_line_outbound(sample[0]) != sample[1]) {
    print("FAIL " + sample[1] + " got " + route.outbound + " inbound " + route.inbound + "\n");
    exit(1);
  }
}
if (!is_node_probe_inbound("socks-in-EN-2") || is_node_probe_inbound("socks-in-EN") || is_node_probe_inbound("tproxy-in")) {
  print("FAIL probe inbound\n");
  exit(1);
}
print("ok\n");
' || fail "access log outbound parser"

parser="$(extract_fn "$RUNTIME" "shell_quote"; printf '\n'; extract_fn "$RUNTIME" "access_log_read_command")"
ucode -e '
function as_string(value) { return value == null ? "" : "" + value; }
'"$parser"'
let whole = access_log_read_command("/tmp/xray-access.log", 0);
let fresh = access_log_read_command("/tmp/xray-access.log", 100);
if (index(whole, "tail -n 2000") < 0 || index(whole, "tail -c +") >= 0) {
  print("FAIL whole " + whole + "\n");
  exit(1);
}
if (index(fresh, "tail -c +101") < 0) {
  print("FAIL fresh " + fresh + "\n");
  exit(1);
}
print("ok\n");
' || fail "access log restart mark"

node --check "$MAIN_JS" || fail "dashboard script did not parse"
node -e '
const fs = require("fs");
const src = fs.readFileSync(process.argv[1], "utf8");
function extract(name) {
  const start = src.indexOf("function " + name + "(");
  if (start < 0) throw new Error("missing " + name);
  let depth = 0;
  let seen = false;
  for (let i = start; i < src.length; i++) {
    if (src[i] === "{") { depth++; seen = true; }
    else if (src[i] === "}") {
      depth--;
      if (seen && depth === 0) return src.slice(start, i + 1);
    }
  }
  throw new Error("unclosed " + name);
}
eval(extract("parseDurationMs") + "\n" + extract("leastLoadGroupCodes"));
const members = [
  { code: "slow", latency: 1500 },
  { code: "mid", latency: 400 },
  { code: "fast", latency: 80 },
  { code: "dead", latency: 0 }
];
const under = leastLoadGroupCodes(members, "1s", "1").join(",");
if (under !== "fast,mid") throw new Error("1s group " + under);
const zero = leastLoadGroupCodes(members, "0s", "1").join(",");
if (zero !== "fast") throw new Error("0s group " + zero);
const none = leastLoadGroupCodes([{ code: "a", latency: 0 }], "1s", "1").join(",");
if (none !== "") throw new Error("unchecked group " + none);
' "$MAIN_JS" || fail "least load group"
ucode -c "$RUNTIME" || fail "xray runtime did not compile"

printf 'xray balancer choice checks passed\n'
