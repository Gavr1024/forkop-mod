#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/forkop/files/usr/lib"
GEN="$LIB/xray/generator.uc"
NFT="$LIB/nft/apply.uc"
WORK_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

grep -Fq 'rule_sets_with_subnets' "$GEN" ||
  fail "Xray must keep a ruleset when Include IP addresses and subnets is on"
awk '
  /^function nft_populate_runtime_set_for_section\(/ { grab = 1 }
  grab { print }
  grab && /^}$/ { exit }
' "$NFT" | grep -Fq 'nft_restore_ruleset_subnets' ||
  fail "Save & Apply must load custom ruleset subnets into nftables"
awk '
  /^function emit_matcher_plans\(/ { grab = 1 }
  grab { print }
  grab && /^}$/ { exit }
' "$GEN" | grep -Fq 'plane_fallback_tag' ||
  fail "an excluded device must skip only this section, not every later section"

cat >"$WORK_DIR/listed.json" <<'JSON'
{
  "version": 3,
  "rules": [
    { "domain_suffix": [ "listed.example" ], "ip_cidr": [ "203.0.113.50/32" ] }
  ]
}
JSON

cat >"$WORK_DIR/state" <<EOF
forkop.settings=settings
forkop.settings.routing_engine=xray
forkop.skip=section
forkop.skip.enabled=1
forkop.skip.action=bypass
forkop.skip.domain=forkop-a.invalid
forkop.skip.excluded_source_ips=192.168.1.10
forkop.take=section
forkop.take.enabled=1
forkop.take.action=connection
forkop.take.proxy_core=xray
forkop.take.domain=forkop-b.invalid
forkop.take.selector_proxy_links=vless://00000000-0000-4000-8000-000000000001@203.0.113.8:443?encryption=none&security=tls&sni=alpha.example&type=tcp#take
forkop.only=section
forkop.only.enabled=1
forkop.only.action=bypass
forkop.only.domain=forkop-c.invalid
forkop.only.source_ip_cidr=192.168.1.20
forkop.full=section
forkop.full.enabled=1
forkop.full.action=bypass
forkop.full.domain=forkop-d.invalid
forkop.full.fully_routed_ips=192.168.1.30
forkop.full.excluded_source_ips=192.168.1.30
forkop.lists=section
forkop.lists.enabled=1
forkop.lists.action=bypass
forkop.lists.rule_set_with_subnets=$WORK_DIR/listed.json
forkop.wide=section
forkop.wide.enabled=1
forkop.wide.action=bypass
forkop.wide.domain=forkop-e.invalid
forkop.wide.source_ip_cidr=192.168.1.0/24
forkop.hole=section
forkop.hole.enabled=1
forkop.hole.action=block
forkop.hole.fully_routed_ips=192.168.50.0/24
forkop.hole.excluded_source_ips=192.168.50.10
forkop.keep=section
forkop.keep.enabled=1
forkop.keep.action=bypass
forkop.keep.fully_routed_ips=192.168.50.10
forkop.plain=section
forkop.plain.enabled=1
forkop.plain.action=bypass
forkop.plain.fully_routed_ips=10.9.0.0/16
forkop.aside=section
forkop.aside.enabled=1
forkop.aside.action=bypass
forkop.aside.fully_routed_ips=10.8.0.0/16
forkop.aside.excluded_source_ips=192.168.9.9
forkop.covered=section
forkop.covered.enabled=1
forkop.covered.action=block
forkop.covered.fully_routed_ips=192.168.70.5
forkop.covered.excluded_source_ips=192.168.70.0/24
forkop.v6hole=section
forkop.v6hole.enabled=1
forkop.v6hole.action=block
forkop.v6hole.fully_routed_ips=2001:db8:50::/126
forkop.v6hole.excluded_source_ips=2001:db8:50::1
forkop.lan=section
forkop.lan.enabled=1
forkop.lan.action=block
forkop.lan.fully_routed_ips=192.168.0.0/16 203.0.113.9
forkop.lan.excluded_source_ips=192.168.0.10 192.168.40.20 192.168.200.30
forkop.above=section
forkop.above.enabled=1
forkop.above.action=block
forkop.above.fully_routed_ips=192.168.88.10
forkop.below=section
forkop.below.enabled=1
forkop.below.action=bypass
forkop.below.domain=forkop-below.invalid
forkop.higher=section
forkop.higher.enabled=1
forkop.higher.action=bypass
forkop.higher.domain=forkop-higher.invalid
forkop.lowerfull=section
forkop.lowerfull.enabled=1
forkop.lowerfull.action=block
forkop.lowerfull.fully_routed_ips=192.168.88.20
forkop.jumpfrom=section
forkop.jumpfrom.enabled=1
forkop.jumpfrom.action=bypass
forkop.jumpfrom.domain=forkop-jump.invalid
forkop.jumpfrom.excluded_source_ips=192.168.77.5
forkop.jumpwall=section
forkop.jumpwall.enabled=1
forkop.jumpwall.action=block
forkop.jumpwall.fully_routed_ips=192.168.77.5
forkop.jumpto=section
forkop.jumpto.enabled=1
forkop.jumpto.action=bypass
forkop.jumpto.domain=forkop-jumpto.invalid
EOF

mkdir -p /var/run/forkop /etc/xray /tmp/forkop
FORKOP_UCI_STATE_FILE="$WORK_DIR/state" \
  ucode -L "$LIB" "$GEN" generate-config "$WORK_DIR/xray.json" "$WORK_DIR/ports.json" \
  >"$WORK_DIR/stdout" 2>"$WORK_DIR/stderr" || {
    cat "$WORK_DIR/stderr" >&2
    fail "xray generate-config failed"
  }

node - "$WORK_DIR/xray.json" <<'JS'
const fs = require("fs");
const config = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const rules = (config.routing && config.routing.rules) || [];
const text = (value) => JSON.stringify(value || []);
const hit = (pred) => rules.find(pred);

const later = hit((rule) =>
  text(rule.domain).includes("forkop-b.invalid") &&
  text(rule.source).includes("192.168.1.10") &&
  rule.outboundTag && rule.outboundTag !== "direct"
);
if (!later)
  throw new Error("excluded device must reach the later section for its own domains");

const skipped = hit((rule) =>
  text(rule.domain).includes("forkop-a.invalid") &&
  text(rule.source).includes("192.168.1.10")
);
if (skipped)
  throw new Error("excluded device must fall through to the full route, not a special domain rule");

const open = hit((rule) =>
  text(rule.domain).includes("forkop-a.invalid") && rule.source == null
);
if (!open)
  throw new Error("other devices must still match the section");

const filtered = rules.filter((rule) => text(rule.domain).includes("forkop-c.invalid"));
if (filtered.length !== 1 || !text(filtered[0].source).includes("192.168.1.20"))
  throw new Error("device filter must be the source of the Xray rule");

const full = hit((rule) =>
  rule.domain == null && rule.ip == null &&
  rule.outboundTag === "direct" &&
  text(rule.source).includes("192.168.1.30")
);
if (full)
  throw new Error("an excluded address must not stay in full routing for the same section");

const listedDomain = hit((rule) => text(rule.domain).includes("listed.example") && rule.source == null);
const listedIp = hit((rule) => text(rule.ip).includes("203.0.113.50") && rule.source == null);
if (!listedDomain || !listedIp)
  throw new Error("Include IP addresses and subnets must keep both domains and IPs");

const wrong = hit((rule) =>
  text(rule.domain).includes("forkop-c.invalid") &&
  text(rule.source).includes("192.168.1.10")
);
if (wrong)
  throw new Error("excluded device must not be copied onto a later section that does not allow it");

const inside = hit((rule) =>
  text(rule.domain).includes("forkop-e.invalid") &&
  text(rule.source).includes("192.168.1.10")
);
if (!inside)
  throw new Error("excluded device inside a later subnet filter must reach that section");

const hole = hit((rule) =>
  rule.outboundTag === "block" && text(rule.source).includes("192.168.50.128/25")
);
const holePieces = [
  "192.168.50.0/29",
  "192.168.50.8/31",
  "192.168.50.11",
  "192.168.50.12/30",
  "192.168.50.16/28",
  "192.168.50.32/27",
  "192.168.50.64/26",
  "192.168.50.128/25",
];
if (!hole || text(hole.source).includes("192.168.50.0/24") || text(hole.source).includes("192.168.50.10"))
  throw new Error("a fully routed network must be split around an excluded address inside it");
for (const piece of holePieces) {
  if (!text(hole.source).includes(piece))
    throw new Error("split fully routed network is missing " + piece);
}
if (hole.source.length !== holePieces.length)
  throw new Error("split fully routed network has extra pieces");

const kept = hit((rule) =>
  rule.outboundTag === "direct" && text(rule.source).includes("192.168.50.10")
);
if (!kept)
  throw new Error("excluded address inside a network must still reach a later full route");

const plain = hit((rule) => text(rule.source) === JSON.stringify(["10.9.0.0/16"]));
if (!plain)
  throw new Error("a fully routed network without exclusions must stay one piece");

const aside = hit((rule) => text(rule.source) === JSON.stringify(["10.8.0.0/16"]));
if (!aside)
  throw new Error("an exclusion outside the network must not split it");

const covered = hit((rule) => text(rule.source).includes("192.168.70.5"));
if (covered)
  throw new Error("an address covered by a wider exclusion must leave full routing");

const v6 = hit((rule) =>
  rule.outboundTag === "block" && text(rule.source).includes("2001:db8:50:0:0:0:0:2/127")
);
if (!v6 || text(v6.source).includes("2001:db8:50::/126") || !text(v6.source).includes("2001:db8:50:0:0:0:0:0"))
  throw new Error("an IPv6 network must be split around an excluded address inside it");

function ipv4num(ip) {
  return ip.split(".").reduce((acc, part) => ((acc << 8) + Number(part)) >>> 0, 0) >>> 0;
}
function cidrCovers(cidr, ip) {
  const [host, bitsRaw] = String(cidr).split("/");
  const bits = bitsRaw == null ? 32 : Number(bitsRaw);
  if (!Number.isFinite(bits) || bits < 0 || bits > 32)
    return false;
  if (bits === 0)
    return true;
  const shift = 32 - bits;
  return (ipv4num(host) >>> shift) === (ipv4num(ip) >>> shift);
}
const lan = hit((rule) => Array.isArray(rule.source) && rule.source.includes("203.0.113.9"));
const lanHoles = ["192.168.0.10", "192.168.40.20", "192.168.200.30"];
if (!lan || lan.source.includes("192.168.0.0/16") || lan.source.length < 2 || lan.source.length > 512)
  throw new Error("several exclusions inside one wide network must split that network");
for (const ip of lanHoles) {
  if (lan.source.some((item) => cidrCovers(item, ip)))
    throw new Error("excluded address " + ip + " is still inside the split network");
}

function ruleIndex(pred) {
  return rules.findIndex(pred);
}
const aboveCatch = ruleIndex((rule) =>
  rule.outboundTag === "block" &&
  rule.ip == null &&
  Array.isArray(rule.source) &&
  rule.source.includes("192.168.88.10")
);
const aboveFake = ruleIndex((rule) =>
  rule.outboundTag === "block" &&
  text(rule.ip).includes("198.18.0.0/15") &&
  text(rule.source).includes("192.168.88.10")
);
const belowDomain = ruleIndex((rule) => text(rule.domain).includes("forkop-below.invalid") && rule.source == null);
if (aboveFake < 0 || aboveCatch < 0 || belowDomain < 0 || aboveFake > aboveCatch || aboveCatch > belowDomain)
  throw new Error("a higher full route must take the device before a lower section domain " + aboveFake + " " + aboveCatch + " " + belowDomain);
if (rules[belowDomain].source != null)
  throw new Error("other devices must still match the lower section");

const higherDomain = ruleIndex((rule) => text(rule.domain).includes("forkop-higher.invalid") && rule.source == null);
const lowerCatch = ruleIndex((rule) =>
  rule.outboundTag === "block" &&
  rule.ip == null &&
  Array.isArray(rule.source) &&
  rule.source.includes("192.168.88.20")
);
if (higherDomain < 0 || lowerCatch < 0 || higherDomain > lowerCatch)
  throw new Error("a higher section domain must beat a lower full route");

const takeDomain = ruleIndex((rule) => text(rule.domain).includes("forkop-b.invalid") && rule.source == null);
if (takeDomain < 0 || aboveCatch < 0 || takeDomain > aboveCatch)
  throw new Error("a higher proxy section must be checked before a lower full route");

const jumped = hit((rule) =>
  text(rule.domain).includes("forkop-jumpto.invalid") &&
  text(rule.source).includes("192.168.77.5")
);
if (jumped)
  throw new Error("an exclusion must not skip a full route to a section below it");
const jumpCatch = ruleIndex((rule) =>
  rule.outboundTag === "block" &&
  rule.ip == null &&
  Array.isArray(rule.source) &&
  rule.source.includes("192.168.77.5")
);
const jumpDomain = ruleIndex((rule) => text(rule.domain).includes("forkop-jumpto.invalid") && rule.source == null);
if (jumpCatch < 0 || jumpDomain < 0 || jumpCatch > jumpDomain)
  throw new Error("a full route must take the excluded device before the section below");
const jumpDirect = hit((rule) =>
  text(rule.domain).includes("forkop-jump.invalid") &&
  text(rule.source).includes("192.168.77.5")
);
if (jumpDirect)
  throw new Error("excluded device must not be forced direct when a lower full route owns it");

const stolen = hit((rule) =>
  text(rule.domain).includes("forkop-below.invalid") &&
  text(rule.source).includes("192.168.1.10")
);
if (stolen)
  throw new Error("a copied domain must not skip a network full route that still contains the device");

console.log("xray device filter checks passed");
JS
