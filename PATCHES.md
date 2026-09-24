# Forkop-Mod 1.0.6 patch set

Based on upstream https://github.com/ushan0v/forkop main (1.0.5).

## What is in this tree

### sing-box 1.14
- Removed `dns.independent_cache`.
- Bypass DNS uses `evaluate` + `match_response` instead of legacy `ip_cidr`.
- Remote rule-sets use `http_clients` / `http_client.detour` instead of `download_detour`.

### Device exclusions (`forkop-exclusions-fix-5`)
- Settings list `routing_excluded_ips`: full Forkop bypass (nft early return + real DNS + safety route).
- Section list `excluded_source_ips`: invert source match for that section only.
- DNS for excluded devices goes to **bootstrap DNS**, not dnsmasq. dnsmasq is pointed at FakeIP (`127.0.0.42`), so answering via dnsmasq gave FakeIP and then skipped TPROXY — apps like ivi.ru failed as if they were proxied.
- If that bootstrap query is itself FakeIP-poisoned (Router 1 WAN sits behind another Forkop on Router 2), UDP/53 answers are `198.18.0.0/15`. Those addresses are then forwarded without TPROXY → Chrome `ERR_FAILED` / `ERR_SSL_VERSION_OR_CIPHER_MISMATCH`. YouTube apps keep working because they use their own DoH/IPs.
- Nested FakeIP is dropped (`match_response` invert 198.18/fc00). Fallback is **DoT :853** then **DoH :443** to the configured bootstrap host (`bypass-out`), which the upstream Forkop cannot poison.
- Hostname/IP in the list expands to **all** v4 and v6 addresses of that device (DHCP leases + odhcpd hosts). LuCI save does the same from host hints.
- Marker string in generator: `forkop-exclusions-fix-5`.

### Hostname crash fix (`forkop-exclusions-fix-3`)
LuCI often stores a DHCP name (`motorola-edge-60-fusion`) instead of an IP.
Old ucode then threw `Type error: left-hand side is not a function`.

Now:
- IP/CIDR is validated locally (no `!obj.method()` / `|| fn()`).
- Hostnames are resolved from `/tmp/dhcp.leases`, `/var/dhcp.leases`, `/tmp/hosts/odhcpd`, `/etc/hosts`.
- Unresolvable names are skipped; generation does not abort.
- Marker string in generator: `forkop-exclusions-fix-5`.

### rpcd ACL
Duplicate `/var/run/forkop/*` grants as `/tmp/run/forkop/*` for rpcd-mod-file 2026.07.19.

### Local list cache
- Settings flag `persist_lists_locally` (default on) stores selected community lists, rule-sets and Xray DAT in `/etc/forkop/list-cache`. Next to it, `update_interval` is 3h / 6h / 12h / 1d / 3d / 7d. When persist is on, start reuses the cache until that interval elapses (and still downloads if DAT is missing). When it is off, start fetches lists every time, as before.
- Cached files are used as `type: local` backups when the online repository is unavailable.
- If `download_lists_via_proxy` is enabled, the selected section/mixed inbound is brought up before the download.
- Dashboard shows cached lists, sizes, mtime, and status.

### Dual-core Xray (`xray-dual-core`)
Forkop can run **sing-box and Xray at the same time** without two TPROXY/FakeIP stacks.

- Settings **Routing engine**: `sing-box` or `Xray`. Neither core is native or bundled. The package installs without them; install the chosen core from **Components**. The selected core owns **TPROXY :1602**, **FakeIP/FakeDNS** and **DNS on 127.0.0.42**. The other core, if installed, is a SOCKS sidecar for sections that pick it. Empty section `proxy_core` follows the routing plane.
- When the plane is sing-box: current behaviour (nft → sing-box tproxy; Xray sections via `127.0.0.1:10808+`).
- When the plane is Xray: nft still tproxies :1602, but Xray listens there (`dokodemo-door` + FakeDNS). sing-box drops tproxy/DNS inbounds and exposes mixed inbound `xray-plane-mixed-in` on `127.0.0.1:4536`. Unmatched tproxy traffic is SOCKS'd into that inbound; sing-box keeps FakeIP/route matching for its own sections.
- Section **Proxy core** still chooses which core dials the node. Help text follows the selected plane.
- Xray is always started when it is the routing plane, even with zero Xray sections.
- Lifecycle start order: sidecar first, then the plane (Xray-plane starts sing-box, then Xray).
- Fast Xray start with a warm cache **when `persist_lists_locally` is on**: boot runs `list-update-if-missing` (GitHub only if DAT is absent). Cron still uses `list_update_if_due`. DAT is copied to `/etc/forkop/list-cache/xray` and restored before generate. If UCI+DAT fingerprint matches the last stamp, generate and `xray -test` are skipped. After list-update, Xray reload and dnsmasq restart run only if `config.json` / nftset actually changed. With the flag off, start downloads and reloads as before.
- Validator refuses `routing_engine=xray` if `/usr/bin/xray` is missing.

QA (Xray as routing plane):
- `FREEDOM_TAG`/`BLACKHOLE_TAG` are defined (`direct`/`block`). Previously they were exported but undeclared, so `require("xray.constants")` could not load.
- TPROXY rules are applied **after** section outbounds exist and copy the SOCKS inbound's `outboundTag`/`balancerTag`. They no longer point at a synthetic `xray-<section>` tag that was never created.
- Domain matchers read `domain_suffix_text` / keyword / regex (LuCI fields), not only `domain`/`domain_suffix` lists.
- Unmatched TPROXY always falls through to the sing-box mixed inbound on `:4536` as a safety net. Community lists on the Xray plane are **converted**, not left on `.srs`:
  - itdoginfo country/service lists (`russia_inside`, `hdrezka`, `hodca`, …) → `ext:allow-domains.dat:<tag>` from the same repo’s `geosite.dat` release (RAW `.lst` if the dat is missing).
  - Known v2fly categories (`github`, …) → `geosite:<name>`.
  - Custom / hagezi / supercell `.srs` → `sing-box rule-set decompile` into Xray `full:` / `keyword:` / `regexp:` / CIDR matchers (capped; oversized lists stay on the sidecar).
  FakeDNS is then scoped to those matchers, so nft still intercepts without poisoning every domain.
- sing-box still emits Xray SOCKS leaves when Xray is the plane (dashboard, `ip.podkop.fyi` probe, router-traffic redirect, conversion fallback).
- FakeDNS includes the IPv6 pool. Listen-port checks include `:1602` and `:53` even with zero Xray sections.
- Xray plane DNS follows Settings: `dns_type` becomes `https://` / `tls://` / UDP, all `dns_server` values are fallbacks. `ipv4_only`/`ipv6_only` map to DNS `UseIPv4`/`UseIPv6`. `prefer_ipv4`/`prefer_ipv6` keep DNS `UseIP` (both FakeDNS pools) and set outbound `sockopt.domainStrategy` to `UseIPv4v6` / `UseIPv6v4` — IPv4 (or IPv6) first, the other family only if the first has no addresses. Sidecar SOCKS stays AsIs. HTTPS/SVCB (types 64/65) are rejected on the dns outbound (`blockTypes` + `nonIPQuery: drop`), matching sing-box `query_type` reject at 127.0.0.42. FakeDNS `skipFallback` + `disableFallbackIfMatch` stop type-65 from hitting 8.8.8.8 if they reach the built-in DNS. dnsmasq `filter-rr=HTTPS/SVCB` is a LAN-side belt. Chrome canary `use-application-dns.net` is poisoned in both Xray hosts and dnsmasq. FakeDNS is scoped to converted lists; broad FakeDNS remains only if a list failed to convert.
- `wait-stable` requires the Xray process when it owns the plane, and only TPROXY IPv4 + DNS (IPv6 tproxy is optional). The sing-box DNS failover worker does not SIGHUP the sidecar's unused DNS.
- **Start hang fix:** choosing Xray as the plane used to block `/etc/init.d/forkop` inside `Preparing Xray` until LuCI `rpcd` timed out. Root cause: `ensure_from_uci` downloaded itdoginfo `geosite.dat` from GitHub (`curl --max-time 45 --retry 2` × 3) and then `sing-box rule-set decompile` of `russia-inside.srs` (tens of thousands of domains) on the router CPU. Start now converts from cache only, probes GitHub for at most 8s, never decompiles known itdoginfo lists (they use `ext:allow-domains.dat` or the sidecar), caps custom `.srs` decompile at 512 KiB / 8s, and bounds `xray run -test` at 20s. List-update still fetches `geosite.dat` in the background.
- **DNS_PROBE / no internet:** nft `redirect :1603` for `forkop_dns_sources` had no listener (Xray only bound 127.0.0.42:53). DNAT to loopback is dropped without `route_localnet`. Xray now also listens `0.0.0.0:1603` / `[::]:1603`.
- **generate-config `looks_like_itdog_dat` Type error:** it called `looks_like_v2fly_dat` defined below it. After list-update the dat is large enough to reach that call, so start died only once a dat existed. The v2fly check is inlined (no call). `community_matchers` is try/caught so generate still writes a config. A test forbids new forward refs.
- **Dashboard routing engine + traffic:** widgets show primary vs sidecar. When Xray owns TPROXY, Clash `/traffic` is the sidecar (near zero); the dashboard polls Xray Stats API (`api.listen` + inbound stats, nft counters as fallback). System info no longer repeats (основной)/(дополнительный). Xray pre-release checkbox uses the DOM `checked` property and does not remount the card on toggle.
- **Xray bypass/block:** TPROXY emits bypass → `direct` and block → `blackhole` from section domain/IP/source matchers, before connection sections. nft IP accept is not enough: dest may be FakeIP or a CDN address not yet in `forkop_rule_bypass_subnets` (overclockers.ru).
- **Xray FinalMask and direct fragment:** A connection section can split the TLS handshake toward its servers (`finalmask.tcp` fragment, tlshello). Settings can split TLS ClientHello on the direct `freedom` outbound and on interface bindings. Both are Xray-only; the UI says so. Hysteria2 keeps its own UDP mask. The proxy server does not need the same fragment settings. Connection rows no longer vanish after ESTABLISHED (conntrack dest becomes `:1602` / mark is stripped — keep TPROXY ports and access-log joins). Dashboard server pick writes `/etc/forkop/xray-selected.json`, patches routing, reloads Xray (Clash API does not control the plane). Hysteria2 share-links emit official Xray 26 `protocol: hysteria` + `hysteriaSettings.auth` / `udphop`. Salamander `obfs` is `finalmask.udp` (`type: salamander`). QUIC outbounds do not get TCP `domainStrategy`.
- **Xray native ByeDPI/DNS:** ByeDPI is an Xray SOCKS outbound to local `ciadpi` (`127.0.0.1:1080+`). DNS action sections become Xray DNS servers (`dns-action-<section>`). Zapret/Zapret2 use freedom + provider mark. If every Connection section is Xray and no inbound servers are enabled, the sing-box sidecar is not started **and the `sing-box` package is not required** — start no longer aborts with `Package 'sing-box' is not installed`. The reverse is also true: sing-box-only does not require Xray. Neither core is a package dependency; missing cores are installed from Components.
- **Xray-only stop/reload:** `/etc/init.d/sing-box stop` is skipped when the init script is missing, so stop/reload does not fail after the package is removed. Reload still regenerates Xray config without calling `sing-box reload`.
- **Xray-only nft start abort:** After FakeIP TPROXY and the dnsmasq nftset file were written, start returned non-zero with no Forkop fatal. Later nft steps no longer abort start; community-list sections create `forkop_rule_*_subnets`. Expanding 3018 dnsmasq nftset lines is a **separate child** (`nft-write-xray-nftset-conf`). After nft succeeded, start then died with `left-hand side is not a function`: `need_singbox_process()` was defined before `trim`/`module_output` (ucode binds names at definition time). It now calls `engine.need_singbox()`; `start_main` uses `engine.is_xray_primary()`.
- **Xray wait-stable after large dat:** `xray run -test` of a dat-backed config takes ~38s; the process then appears quickly but DNS `127.0.0.42:53` and TPROXY `:1602` bind later. wait-stable used to abort at 20s (`Routing plane did not reach a stable running state`) with no reason. Xray now waits 60s (`FORKOP_XRAY_START_VERIFY_TIMEOUT`), `start-runtime` waits for those two ports (not pid alone), and a failed wait logs which check failed (xray pid / DNS / TPROXY / nft).
- **Xray FakeIP destOverride:** `destOverride: ["fakedns+others"]` is ignored by Xray (access log keeps `198.18.x`, first outbound gets everything, remote dials FakeIP → timeout). TPROXY sniffing is `["fakedns","http","tls","quic"]`.
- **itdog lists B+D+E:** Start never waits on GitHub. itdog **domains** use cached `allow-domains.dat` (`ext:allow-domains.dat:<tag>`) only — no RAW `.lst` dump into config.json. itdog **subnets** (discord/telegram/…) stay RAW CIDRs in `/etc/forkop/list-cache/xray/Subnets/`. `geosite.dat` is fetched on list-update (via the download section) and Xray reloads.
- **Xray URLTest:** When the plane is Xray, URLTest auto-switch probes nodes through section SOCKS (`urltest-worker`) and does not use Clash/sing-box. Observatory `leastPing` still covers the first interval. Dashboard **Fastest** (`__urltest__`) restores auto; a pinned server stays manual. Sing-box primary is unchanged. The worker skips bypass/block/dns sections and reads `proxy_core` from the UCI object so BusyBox ucode does not throw `left-hand side is not a function` at `core:BYPASS`.
- **Xray router traffic:** nft OUTPUT DNAT `:1604` is accepted by Xray `dokodemo-door` (`redirect-in`) and routed to the selected section. Sing-box primary still owns `:1604`.
- **Xray fully_routed nft:** When the sidecar is skipped, start still runs `nft-populate-runtime-sets-from-uci` so `fully_routed_ips` (e.g. `192.168.0.0/16`) land in `forkop_rule_*_fully_sources`. Previously those sets stayed empty and only community whitelist IPs were intercepted.
- **Xray DNS/FakeIP like sing-box:** DNS-action (AdGuard) answers first with real IPs; those domains are not in FakeDNS. Connection-only domains still get FakeIP. TPROXY :1602 sniff is `fakedns,http,tls,quic` + `routeOnly`. Unmatched `198.18` blackholes before BLESS `fully_routed` sources.
- **Xray list sources:** ads_hagezi_pro → `adlist.dat`, supercell → `supercell.json`, github → v2fly `geosite:github` / `github.list`. `.srs` decompile is not used for these three when Xray is primary.
- **Xray diagnostics:** DNS/bootstrap checks use `127.0.0.42` (not sing-box health ports). Unused sidecar is not an error. Outbound ping goes through Xray SOCKS. FakeIP uses router FakeDNS; browser check is skipped. Sing-box primary diagnostics are unchanged.
- **Xray services widget / ping:** When no sing-box section exists, the dashboard shows sing-box as unused instead of “Running (sidecar)”, even if a leftover sing-box process is still up. Latency test probes Xray SOCKS and writes `/var/run/forkop/xray-latency.json` (group/proxy/list). Dashboard cards read those delays, not Clash history.
- **FakeIP blackhole:** missing `allow-domains.dat` used to make FakeDNS unrestricted. Russian sites (jeeping-max.ru) got 198.18.x, Xray could not match `russia_inside`, and the sidecar received FakeIPs it did not allocate — TCP timeout. FakeDNS is always scoped to converted matchers; unmapped lists use real DNS (direct) until list-update fetches the dat and reloads Xray. Sidecar sniffs `xray-plane-mixed-in`. IPv6 tproxy listens on `::`.


- Components tab: install / update / remove **Xray-core** from [XTLS/Xray-core](https://github.com/XTLS/Xray-core) (same job model as sing-box / ByeDPI). Binary lands at `/usr/bin/xray`, geo files at `/usr/share/xray` and `/etc/xray`. Autostart of the managed `/etc/init.d/xray` stays disabled — Forkop starts it.
- Components tab: install / update / remove **Xray-core** from [XTLS/Xray-core](https://github.com/XTLS/Xray-core) (same job model as sing-box / ByeDPI). Binary lands at `/usr/bin/xray`, geo files at `/usr/share/xray` and `/etc/xray`. Autostart of the managed `/etc/init.d/xray` stays disabled — Forkop starts it.
- Section setting **Proxy core**: `sing-box` (default) or `Xray`. Only connection/proxy/outbound/vpn sections have the selector.
- Share-links (`vless://`, `vmess://`, `trojan://`, `ss://`, `socks://`, `hy2://` / `hysteria2://`) and pasted JSON are converted to **Xray 26 simplified outbounds** (`settings.address/port/id`, `encryption: "none"`, `streamSettings.method` + `network`). Classic `vnext`/`servers` JSON is flattened. Hysteria2 is emitted as `protocol: hysteria` + `method/network: hysteria` with `hysteriaSettings.auth`. `type=raw` and `xtls-rprx-vision-udp443` parse. HTTP/h2 transport maps to xhttp (HTTP transport was removed in 26.x).
- Interface bindings on an Xray section become `freedom` outbounds with `sockopt.interface` + `domainStrategy: UseIP` (plus the outbound mark). A section that only binds an interface (no share-links) is valid and starts. Cascade (`outbound_detour`) from an Xray proxy section uses `sockopt.dialerProxy`: Xray→Xray chains natively to the target outbound tag (e.g. the interface freedom); Xray→sing-box hops through a dedicated SOCKS inbound on `10908+` whose route rule is inserted **before** domain/IP matchers. Interface/freedom leaves are not given `dialerProxy` (same as sing-box).
- Lifecycle: generate xray config **before** sing-box (so the port map exists), start xray **before** sing-box, stop xray **after** sing-box. If no section uses Xray, generation is skipped so a plain sing-box start is not blocked.
- System information always shows the Xray version. Diagnostics always run the Xray checks (installed, version ≥ 24.12.0, service, autostart disabled, process, listening ports, configured sections).
- Monitoring: **Core** column on Active/Closed, plus a **Cores** tab (domain → Xray or sing-box).
- Dashboard (информационная панель): Services widget shows Xray Running/Stopped/Not installed. System info counts outbounds per core (`sing-box N · Xray M`). Core badge is on the **section title only**, not on outbound cards. Multiple share-links in an Xray section appear as a Clash selector (one SOCKS inbound per node on `11008+`), so every outbound is visible and selectable like sing-box. Process status uses pidof/procd/ubus and the sidecar listen ports — `pgrep -x xray` alone was a false negative while traffic still went through the sidecar.
- Interface cards on an Xray section show the UCI interface name (`VNI`, `awg1`), not the generator tag (`VNI-iface-1`).
- URLTest / Priority on an Xray section is a Clash `urltest` / selector over the SOCKS leaves (iface Direct is excluded from the probe set). The dashboard can select the group the same way as sing-box.
- Xray URLTest worker (`runtime.uc urltest-worker`) no longer calls `xray_constants.inbound_tag()` / object shorthand `{ tag, delay }` (ucode `left-hand side is not a function`). Tag helpers are local, geodata is required only in `init_config`, catch logs the failing step (`Xray URLTest worker at probe:…`).
- Diagnostics: **Show Xray config** next to **Show sing-box config** (raw dump + Hide values). CLI: `forkop show_xray_config`.
- Components: Xray has the same **Install specific version** dropdown as sing-box. Version lists for sing-box and Xray are fetched from GitHub **in the browser in parallel** when the Updates tab opens, so they do not contend for the router component-action lock.
- Router `list_versions` / `check_update` no longer take the exclusive component lock. A section Save (Xray regen ~1 min) plus Updates GitHub fallback no longer logs `[error] Another component action is already running`. Install/remove still exclusive.

### Restart interfaces after start
Settings flag `restart_interfaces_after_start` plus a NetworkSelect list and delay (0–60 s). After a successful Forkop **start**, the selected UCI interfaces are bounced with `/sbin/ifup` in the background. Ping/DNS are not touched. Does not run on reload.

### Config slots UI
Slots tab: left-aligned LuCI layout (no duplicate heading), compact cards, native `<button type="button">` with visible labels (LuCI `.cbi-button` on `<button>` drew empty boxes).

AX6000 / Argon (`forkop-slots-ax6000-2`): clicks do not depend on theme JS. Buttons use inline `onclick` plus a document capture handler, `window.confirm` instead of `ui.showModal` (Argon often hides the LuCI modal), no `all: unset`, no `Promise.finally`. Copy `slots.js` and hard-refresh the browser.

Auto-switch ping scheduler: default **built-in worker** (no `cron.err` every minute, engine-agnostic). Optional **system cron** as before. Choice is on the Slots tab (`slots_probe_backend`). The worker is started in a subshell so Save switch settings does not wait on it.

New modules: `forkop/files/usr/lib/xray/{constants,outbound,generator,runtime}.uc`.

### Router traffic through a section (`router-traffic-section`)
Settings flag **Route the router's own traffic** plus a section selector. Off by default.

When both the flag and a section are set, Forkop intercepts **IPv4 TCP from the router itself** (apk, wget, LuCI outbound HTTP) and forces it through that section:

- sing-box `type: redirect` inbound on `127.0.0.1:1604` only. No `network` field (sing-box 1.14 `DisallowUnknownFields`). No second IPv6 inbound.
- Early route rule `inbound: redirect-in → <section>-out`, inserted after sniff/hijack-dns so domain lists cannot steal this traffic. Xray sections work because they already appear as SOCKS outbounds with that tag.
- nft `nat hook output` DNAT (`redirect to :1604`) is applied **after** sing-box is stable. Skips ICMP, DNS 53, NTP 123 (if excluded), `localv4`, and sockets with the outbound mark (proxy dials to the VPS).
- Dest-based OUTPUT TPROXY marks are skipped while this is on, so listed destinations are not blackholed into table `forkop`.
- Ping stays direct. IPv6 from the router is not intercepted.

Leftover `route_router_traffic=1` without a section (old checkbox) is treated as off and cleared by migration `router_traffic_section`.

Copy **settings.js, generator.uc, route.uc, constants.uc, nft/apply.uc, lifecycle.uc, state.uc, validator.uc** together and **restart Forkop**, not only Save. Copying nft/lifecycle without generator DNATs to a closed port.

Сборка ipk/apk — в `BUILD.md` (`./build.sh 1.0.6 ./dist`). Версия пакета 1.0.6.

## Manual copy onto an existing 1.0.5 install

```sh
cp forkop/files/usr/lib/singbox/generator.uc /usr/lib/forkop/singbox/generator.uc
cp forkop/files/usr/lib/singbox/dns.uc       /usr/lib/forkop/singbox/dns.uc
cp forkop/files/usr/lib/singbox/constants.uc /usr/lib/forkop/singbox/constants.uc
cp forkop/files/usr/lib/nft/apply.uc         /usr/lib/forkop/nft/apply.uc
cp forkop/files/usr/lib/singbox/runtime.uc   /usr/lib/forkop/singbox/runtime.uc
cp luci-app-forkop/htdocs/luci-static/resources/view/forkop/settings.js \
   /www/luci-static/resources/view/forkop/settings.js
cp luci-app-forkop/htdocs/luci-static/resources/view/forkop/section.js \
   /www/luci-static/resources/view/forkop/section.js
cp luci-app-forkop/htdocs/luci-static/resources/view/forkop/local_devices.js \
   /www/luci-static/resources/view/forkop/local_devices.js
cp luci-app-forkop/root/usr/share/rpcd/acl.d/luci-app-forkop.json \
   /usr/share/rpcd/acl.d/luci-app-forkop.json
chmod 0644 /usr/share/rpcd/acl.d/luci-app-forkop.json
/etc/init.d/rpcd restart
/etc/init.d/forkop restart
grep -n forkop-exclusions-fix-5 /usr/lib/forkop/singbox/generator.uc
```

The last grep must print a line. Empty output means the file was not replaced.

### Dual-core Xray files (share-link → Xray 26 JSON)

If Forkop is already installed, copy these and reload:

```sh
mkdir -p /usr/lib/forkop/xray
cp forkop/files/usr/lib/xray/constants.uc /usr/lib/forkop/xray/constants.uc
cp forkop/files/usr/lib/xray/outbound.uc /usr/lib/forkop/xray/outbound.uc
cp forkop/files/usr/lib/xray/generator.uc /usr/lib/forkop/xray/generator.uc
cp forkop/files/usr/lib/xray/runtime.uc /usr/lib/forkop/xray/runtime.uc
cp forkop/files/usr/lib/subscription/parser.uc /usr/lib/forkop/subscription/parser.uc
cp forkop/files/usr/lib/singbox/generator.uc /usr/lib/forkop/singbox/generator.uc
cp forkop/files/usr/lib/singbox/route.uc /usr/lib/forkop/singbox/route.uc
cp forkop/files/usr/lib/singbox/constants.uc /usr/lib/forkop/singbox/constants.uc
cp forkop/files/usr/lib/service/ui.uc /usr/lib/forkop/service/ui.uc
cp forkop/files/usr/lib/service/lifecycle.uc /usr/lib/forkop/service/lifecycle.uc
cp forkop/files/usr/lib/components/action.uc /usr/lib/forkop/components/action.uc
cp forkop/files/usr/lib/diagnostics/runtime.uc /usr/lib/forkop/diagnostics/runtime.uc
cp forkop/files/usr/lib/diagnostics/status.uc /usr/lib/forkop/diagnostics/status.uc
cp forkop/files/usr/lib/nft/apply.uc /usr/lib/forkop/nft/apply.uc
cp forkop/files/usr/lib/service/state.uc /usr/lib/forkop/service/state.uc
cp forkop/files/usr/lib/config/validator.uc /usr/lib/forkop/config/validator.uc
cp forkop/files/usr/lib/config/migration.uc /usr/lib/forkop/config/migration.uc
cp forkop/files/usr/lib/core/constants.uc /usr/lib/forkop/core/constants.uc
cp forkop/files/usr/bin/forkop /usr/bin/forkop
cp luci-app-forkop/htdocs/luci-static/resources/view/forkop/main.js \
   /www/luci-static/resources/view/forkop/main.js
cp luci-app-forkop/htdocs/luci-static/resources/view/forkop/settings.js \
   /www/luci-static/resources/view/forkop/settings.js
cp luci-app-forkop/htdocs/luci-static/resources/view/forkop/slots.js \
   /www/luci-static/resources/view/forkop/slots.js
cp luci-app-forkop/po/ru/forkop.po /usr/lib/lua/luci/i18n/forkop.ru.po 2>/dev/null || true
/etc/init.d/rpcd restart
/etc/init.d/forkop restart
```

## Config slots
- New LuCI tab saves `/etc/config/forkop` into online/offline slots.
- Auto-switch applies a slot after repeated ping success/failure.
- Ping checks run in a Forkop worker by default (`slots_probe_backend=worker`). System cron remains selectable on the Slots tab.
- Apply slot / save switch settings do not wait for Xray reload or the ping worker (LuCI `file.exec` would otherwise time out with "Slot action failed").
