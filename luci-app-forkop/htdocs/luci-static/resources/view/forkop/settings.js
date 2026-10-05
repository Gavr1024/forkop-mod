"use strict";
"require form";
"require uci";
"require baseclass";
"require tools.widgets as widgets";
"require view.forkop.main as main";
"require view.forkop.local_devices as localDevices";

const UCI_PACKAGE = main.FORKOP_UCI_PACKAGE;

function isSingBoxDuration(value) {
  return /^(?=.*[1-9])([0-9]+(?:\.[0-9]+)?(?:ns|us|ms|s|m|h|d))+$/.test(value);
}

function latencyTestUrlChoices() {
  return Array.isArray(main.LATENCY_TEST_URL_OPTIONS)
    ? main.LATENCY_TEST_URL_OPTIONS
    : [main.DEFAULT_LATENCY_TEST_URL || "https://www.gstatic.com/generate_204"];
}

function validateLatencyTestUrl(value) {
  const validation = main.validateUrl(`${value || ""}`.trim());
  return validation.valid ? true : validation.message;
}

function isDownloadSectionAction(action, capabilities) {
  switch (action) {
    case "connection":
    case "proxy":
    case "outbound":
    case "vpn":
      return true;
    case "zapret":
      return !capabilities?.loaded || Boolean(capabilities.zapretInstalled);
    case "zapret2":
      return !capabilities?.loaded || Boolean(capabilities.zapret2Installed);
    case "byedpi":
      return !capabilities?.loaded || Boolean(capabilities.byedpiInstalled);
    default:
      return false;
  }
}

function refreshDownloadSectionChoices(option, capabilities) {
  const sections = option.map?.data?.state?.values?.[UCI_PACKAGE] ?? {};

  option.keylist = [];
  option.vallist = [];

  for (const secName in sections) {
    const sec = sections[secName];
    if (
      sec[".type"] === "section" &&
      sec.enabled !== "0" &&
      isDownloadSectionAction(sec.action, capabilities)
    ) {
      option.value(secName, sec.label || secName);
    }
  }
}

function configureDownloadSectionOption(option, sectionOption, capabilities) {
  option.default = "";
  option.rmempty = false;
  option.cfgvalue = function (section_id) {
    return uci.get(UCI_PACKAGE, section_id, sectionOption) || "";
  };
  option.load = function (section_id) {
    refreshDownloadSectionChoices(this, capabilities);
    return this.cfgvalue(section_id);
  };
  option.write = function (section_id, value) {
    const normalized = value ? `${value}`.trim() : "";

    if (normalized) {
      uci.set(UCI_PACKAGE, section_id, sectionOption, normalized);
    } else {
      uci.unset(UCI_PACKAGE, section_id, sectionOption);
    }
  };
  option.remove = function (section_id) {
    uci.unset(UCI_PACKAGE, section_id, sectionOption);
  };
  option.validate = function (_section_id, value) {
    return value ? true : _("Select a section");
  };
}

function configureDownloadViaProxyFlag(option, sectionOption) {
  option.default = "0";
  option.rmempty = false;
  option.write = function (section_id, value) {
    const enabled = value === "1" || value === true;
    uci.set(UCI_PACKAGE, section_id, this.option, enabled ? "1" : "0");
    if (!enabled) {
      uci.unset(UCI_PACKAGE, section_id, sectionOption);
    }
  };
}

function optionListValues(option, section_id) {
  const formValue = option.formvalue(section_id);
  const value = formValue != null ? formValue : option.cfgvalue(section_id);
  return L.toArray(value)
    .map((item) => `${item || ""}`.trim())
    .filter(Boolean);
}

function configureDnsList(option, choices, defaultValue) {
  Object.entries(choices).forEach(([key, label]) => {
    option.value(key, _(label));
  });
  option.default = [defaultValue];
  option.rmempty = false;
  option.validate = function (_section_id, value) {
    const normalized = `${value || ""}`.trim();
    if (!normalized) {
      return optionListValues(option, _section_id).length > 0
        ? true
        : _("Add at least one DNS server");
    }
    const validation = main.validateDNS(normalized);
    return validation.valid ? true : validation.message;
  };
}

function dnsProtocolValue(dnsTypeOption, section_id) {
  const live = dnsTypeOption ? dnsTypeOption.formvalue(section_id) : null;
  if (live != null && `${live}` !== "") {
    return `${live}`;
  }
  return uci.get(UCI_PACKAGE, section_id, "dns_type") || "udp";
}

function dnsChoicesForProtocol(protocol) {
  if (protocol === "doq") {
    return main.DOQ_DNS_SERVER_OPTIONS;
  }
  if (protocol === "doh3") {
    return main.DOH3_DNS_SERVER_OPTIONS;
  }
  return main.DNS_SERVER_OPTIONS;
}

function sanitizeDnsServers(protocol, values) {
  const list = L.toArray(values)
    .map((item) => `${item || ""}`.trim())
    .filter(Boolean);
  if (protocol !== "doq" && protocol !== "doh3") {
    return list;
  }
  const allowed = new Set(Object.keys(dnsChoicesForProtocol(protocol) || {}));
  const plain = new Set(Object.keys(main.DNS_SERVER_OPTIONS || {}));
  const rewrite =
    protocol === "doq"
      ? main.DOQ_DNS_SERVER_REWRITE || {}
      : main.DOH3_DNS_SERVER_REWRITE || {};
  const kept = [];
  const seen = new Set();
  list.forEach((value) => {
    const mapped = rewrite[value] || value;
    if (!allowed.has(mapped) && plain.has(value)) {
      return;
    }
    if (seen.has(mapped)) {
      return;
    }
    seen.add(mapped);
    kept.push(mapped);
  });
  if (kept.length > 0) {
    return kept;
  }
  return protocol === "doq" ? ["9.9.9.9"] : ["8.8.8.8"];
}

function replaceDnsServerChoices(option, protocol) {
  const choices = dnsChoicesForProtocol(protocol);
  option.keylist = [];
  option.vallist = [];
  Object.entries(choices).forEach(([key, label]) => {
    option.value(key, _(label));
  });
}

function configureDnsFailoverVisibility(option, dnsOption, bootstrapOption) {
  option.depends("dns_server", "__forkop_multiple_dns__");
  option.depends("bootstrap_dns_server", "__forkop_multiple_dns__");
  option.retain = true;
  option.checkDepends = function (section_id) {
    return (
      optionListValues(dnsOption, section_id).length > 1 ||
      optionListValues(bootstrapOption, section_id).length > 1
    );
  };
}

function configureDnsDuration(
  option,
  defaultValue,
  dnsOption,
  bootstrapOption,
) {
  option.default = defaultValue;
  option.rmempty = false;
  option.validate = function (_section_id, value) {
    const normalized = `${value || ""}`.trim();
    if (!normalized || !isSingBoxDuration(normalized)) {
      return _("Use sing-box duration format like 10s, 1m or 2m30s");
    }
    return true;
  };
  configureDnsFailoverVisibility(option, dnsOption, bootstrapOption);
}

let routingEngineOption = null;
let unsavedRoutingEngine = "";

function isXrayRoutingEngine(value) {
  const engine = `${value || ""}`.trim().toLowerCase();
  return engine === "xray" || engine === "xray-core";
}

function liveDropdownValue(id) {
  const node = document.getElementById(id);
  if (!node || typeof node.querySelector !== "function") {
    return "";
  }
  const selected = node.querySelector("li[selected]");
  const fromItem = selected ? selected.getAttribute("data-value") : "";
  if (fromItem) {
    return `${fromItem}`;
  }
  const hidden = node.querySelector('input[type="hidden"]');
  if (hidden && `${hidden.value || ""}` !== "") {
    return `${hidden.value}`;
  }
  const data = node.getAttribute ? node.getAttribute("data-value") : "";
  if (data) {
    return `${data}`;
  }
  return node.value ? `${node.value}` : "";
}

function currentRoutingEngine() {
  if (unsavedRoutingEngine) {
    return unsavedRoutingEngine;
  }

  const liveDom = liveDropdownValue(
    "cbid." + UCI_PACKAGE + ".settings.routing_engine",
  );
  if (liveDom) {
    return liveDom;
  }

  if (routingEngineOption) {
    try {
      const live = routingEngineOption.formvalue("settings");
      if (live != null && `${live}` !== "") {
        return `${live}`;
      }
    } catch (_error) {
      /* The widget is not rendered yet. */
    }
  }

  return uci.get(UCI_PACKAGE, "settings", "routing_engine") || "sing-box";
}

function dnsProtocolChoices(engine) {
  const xray = isXrayRoutingEngine(engine);
  const choices = [["doh", _("DNS over HTTPS (DoH)")]];
  if (!xray) {
    choices.push(["doh3", _("DNS over HTTP/3 (DoH3)")]);
  }
  choices.push(["doq", _("DNS over QUIC (DoQ)")]);
  if (!xray) {
    choices.push(["dot", _("DNS over TLS (DoT)")]);
  }
  choices.push(["udp", _("UDP (Unprotected DNS)")]);
  return choices;
}

function replaceListChoices(option, choices) {
  option.keylist = [];
  option.vallist = [];
  choices.forEach(([key, label]) => option.value(key, label));
}

let dnsTypeRefreshLock = false;

function displayedDnsProtocol(option, section_id, cfgvalue) {
  const raw =
    cfgvalue != null && `${cfgvalue}` !== ""
      ? `${cfgvalue}`.trim()
      : dnsProtocolValue(option, section_id);
  const xray = isXrayRoutingEngine(currentRoutingEngine());
  if (xray) {
    if (raw === "doh3") {
      option._forkopHeldDoh3 = true;
    }
    if (raw === "doh3" || (option._forkopHeldDoh3 && raw === "doh")) {
      return "doh";
    }
    option._forkopHeldDoh3 = false;
    return raw || "udp";
  }
  if (option._forkopHeldDoh3 && (raw === "doh" || raw === "doh3")) {
    option._forkopHeldDoh3 = false;
    return "doh3";
  }
  option._forkopHeldDoh3 = false;
  return raw || "udp";
}

function refreshDnsTypeField(option, section_id) {
  const field =
    document.querySelector(
      `#cbi-${UCI_PACKAGE}-${section_id}-dns_type .cbi-value-field`,
    ) ||
    document.querySelector(
      `#cbi-${UCI_PACKAGE}-settings-dns_type .cbi-value-field`,
    );
  if (!field || !option) {
    return;
  }
  dnsTypeRefreshLock = true;
  const rendered = option.renderWidget(
    section_id,
    null,
    option.formvalue(section_id),
  );
  Promise.resolve(rendered).then((node) => {
    if (node) {
      field.replaceChildren(node);
    }
    option.onchange(null, section_id, false);
    window.setTimeout(() => {
      dnsTypeRefreshLock = false;
    }, 50);
  });
}

function routingEngineMatches(engine, wanted) {
  const xray = isXrayRoutingEngine(engine);
  return wanted === "xray" ? xray : !xray;
}

function restrictRoutingEngine(option, engine) {
  if (!option || option.forkopEngineRestrict) {
    return option;
  }

  option.retain = true;
  option.forkopEngineRestrict = engine;
  const previous = option.checkDepends;
  option.checkDepends = function (section_id) {
    if (!routingEngineMatches(currentRoutingEngine(), engine)) {
      return false;
    }

    return typeof previous === "function"
      ? previous.call(this, section_id)
      : true;
  };
  return option;
}

function routingMap() {
  return routingEngineOption ? routingEngineOption.map : null;
}

function liveFormValue(name, sectionId) {
  const map = routingMap();
  if (!map || typeof map.lookupOption !== "function" || !sectionId) {
    return null;
  }

  const found = map.lookupOption(name, sectionId);
  if (!found || !found[0]) {
    return null;
  }

  try {
    const value = found[0].formvalue(found[1] || sectionId);
    return value == null ? "" : `${value}`.trim();
  } catch (_error) {
    return null;
  }
}

function createSettingsContent(section, capabilities) {
  let o = section.option(
    form.ListValue,
    "routing_engine",
    _("Routing engine"),
    _(
      "Which core owns TPROXY, FakeIP and DNS. The other core stays available as a SOCKS sidecar for sections that select it. Neither core is bundled with Forkop; install the chosen core from Components.",
    ),
  );
  o.value("sing-box", "sing-box");
  o.value("xray", "Xray");
  o.default = "sing-box";
  o.rmempty = false;
  routingEngineOption = o;
  const renderRoutingEngine = o.render;
  o.render = function (option_index, section_id) {
    const settingsId = section_id != null ? section_id : option_index;
    return Promise.resolve(renderRoutingEngine.apply(this, arguments)).then(
      (node) => {
        if (node && node.addEventListener && !node.dataset.fkpDnsTypeEngine) {
          node.dataset.fkpDnsTypeEngine = "1";
          const refresh = (ev) => {
            const picked = ev && ev.detail && ev.detail.value;
            const engine =
              picked && typeof picked === "object" ? picked.value : picked;
            if (engine) {
              unsavedRoutingEngine = `${engine}`;
            }
            window.setTimeout(
              () => refreshDnsTypeField(dnsTypeOption, settingsId),
              0,
            );
          };
          node.addEventListener("widget-change", refresh);
          node.addEventListener("cbi-dropdown-change", refresh);
          node.addEventListener("change", refresh);
        }
        return node;
      },
    );
  };

  o = section.option(
    form.Flag,
    "xray_freedom_fragment",
    _("Fragment direct connections"),
    _(
      "Split the TLS handshake on direct Xray connections so filters do not see the site name in one packet.",
    ),
  );
  o.default = "0";
  o.rmempty = false;
  restrictRoutingEngine(o, "xray");

  o = section.option(
    form.Value,
    "xray_freedom_fragment_length",
    _("Fragment length"),
    _("Byte size of each piece, for example 100-200."),
  );
  o.default = "100-200";
  o.rmempty = false;
  o.depends("xray_freedom_fragment", "1");
  o.validate = function (_section_id, value) {
    return /^\d+(-\d+)?$/.test(`${value || ""}`.trim())
      ? true
      : _("Use a number or a range like 100-200");
  };
  restrictRoutingEngine(o, "xray");

  o = section.option(
    form.Value,
    "xray_freedom_fragment_interval",
    _("Fragment interval"),
    _("Pause between pieces, in milliseconds, for example 10-20."),
  );
  o.default = "10-20";
  o.rmempty = false;
  o.depends("xray_freedom_fragment", "1");
  o.validate = function (_section_id, value) {
    return /^\d+(-\d+)?$/.test(`${value || ""}`.trim())
      ? true
      : _("Use a number or a range like 10-20");
  };
  restrictRoutingEngine(o, "xray");

  o = section.option(
    form.ListValue,
    "xray_freedom_fragment_packets",
    _("FinalMask packets"),
    _(
      "tlshello splits the TLS handshake. 1-3 splits the first TCP writes.",
    ),
  );
  o.value("tlshello", _("TLS handshake"));
  o.value("1-3", _("First TCP writes (1-3)"));
  o.default = "tlshello";
  o.rmempty = false;
  o.depends("xray_freedom_fragment", "1");
  restrictRoutingEngine(o, "xray");

  o = section.option(
    form.Value,
    "xray_freedom_fragment_max_split",
    _("FinalMask max split"),
    _(
      "How many pieces one packet may be split into, for example 100-200. Use 0 for no limit.",
    ),
  );
  o.default = "100-200";
  o.rmempty = false;
  o.depends("xray_freedom_fragment", "1");
  o.validate = function (_section_id, value) {
    return /^\d+(-\d+)?$/.test(`${value || ""}`.trim())
      ? true
      : _("Use a number or a range like 100-200");
  };
  restrictRoutingEngine(o, "xray");

  o = section.option(
    form.Flag,
    "xray_freedom_fragment_noise",
    _("FinalMask noise"),
    _(
      "Send extra bytes before a direct connection. This is TCP noise on the direct outbound.",
    ),
  );
  o.default = "0";
  o.rmempty = false;
  o.depends("xray_freedom_fragment", "1");
  restrictRoutingEngine(o, "xray");

  o = section.option(
    form.ListValue,
    "xray_freedom_fragment_noise_type",
    _("Noise type"),
  );
  o.value("rand", _("Random bytes"));
  o.value("str", _("Text"));
  o.value("hex", _("Hex"));
  o.value("base64", _("Base64"));
  o.default = "rand";
  o.rmempty = false;
  o.depends({ xray_freedom_fragment: "1", xray_freedom_fragment_noise: "1" });
  restrictRoutingEngine(o, "xray");

  o = section.option(
    form.Value,
    "xray_freedom_fragment_noise_rand",
    _("Noise length"),
    _("Random byte length, for example 10-20."),
  );
  o.default = "10-20";
  o.rmempty = false;
  o.depends({
    xray_freedom_fragment: "1",
    xray_freedom_fragment_noise: "1",
    xray_freedom_fragment_noise_type: "rand",
  });
  o.validate = function (_section_id, value) {
    return /^\d+(-\d+)?$/.test(`${value || ""}`.trim())
      ? true
      : _("Use a number or a range like 10-20");
  };
  restrictRoutingEngine(o, "xray");

  o = section.option(
    form.Value,
    "xray_freedom_fragment_noise_packet",
    _("Noise packet"),
    _("Fixed noise data. Text, hex or base64, matching the type."),
  );
  o.depends({ xray_freedom_fragment: "1", xray_freedom_fragment_noise: "1", xray_freedom_fragment_noise_type: "str" });
  o.depends({ xray_freedom_fragment: "1", xray_freedom_fragment_noise: "1", xray_freedom_fragment_noise_type: "hex" });
  o.depends({ xray_freedom_fragment: "1", xray_freedom_fragment_noise: "1", xray_freedom_fragment_noise_type: "base64" });
  restrictRoutingEngine(o, "xray");

  o = section.option(
    form.Value,
    "xray_freedom_fragment_noise_delay",
    _("Noise delay"),
    _("Pause after the noise, in milliseconds, for example 10-16."),
  );
  o.default = "10-16";
  o.rmempty = false;
  o.depends({ xray_freedom_fragment: "1", xray_freedom_fragment_noise: "1" });
  o.validate = function (_section_id, value) {
    return /^\d+(-\d+)?$/.test(`${value || ""}`.trim())
      ? true
      : _("Use a number or a range like 10-20");
  };
  restrictRoutingEngine(o, "xray");

  o = section.option(
    form.ListValue,
    "dns_type",
    _("DNS Protocol Type"),
    _("Select DNS protocol to use"),
  );
  replaceListChoices(o, dnsProtocolChoices(currentRoutingEngine()));
  o.default = "udp";
  o.rmempty = false;
  const dnsTypeOption = o;
  const renderDnsTypeWidget = o.renderWidget;
  o.renderWidget = function (section_id, option_index, cfgvalue) {
    replaceListChoices(this, dnsProtocolChoices(currentRoutingEngine()));
    const selected = displayedDnsProtocol(this, section_id, cfgvalue);
    return renderDnsTypeWidget.call(this, section_id, option_index, selected);
  };

  const dnsOption = section.option(
    form.DynamicList,
    "dns_server",
    _("DNS Servers"),
    _(
      "Main DNS server. If multiple servers are selected, a timeout switches to a backup.",
    ),
  );
  configureDnsList(dnsOption, main.DNS_SERVER_OPTIONS, "77.88.8.8");
  const renderDnsServers = dnsOption.renderWidget;
  dnsOption.renderWidget = function (section_id, option_index, cfgvalue) {
    const protocol = dnsProtocolValue(dnsTypeOption, section_id);
    replaceDnsServerChoices(this, protocol);
    const selected = sanitizeDnsServers(
      protocol,
      cfgvalue != null ? cfgvalue : this.cfgvalue(section_id),
    );
    return renderDnsServers.call(this, section_id, option_index, selected);
  };
  dnsTypeOption.onchange = function (_event, section_id, fromUser) {
    if (fromUser) {
      this._forkopHeldDoh3 = false;
    }
    const field = document.querySelector(
      `#cbi-${UCI_PACKAGE}-${section_id}-dns_server .cbi-value-field`,
    );
    if (!field) {
      return;
    }
    const rendered = dnsOption.renderWidget(
      section_id,
      null,
      dnsOption.formvalue(section_id),
    );
    Promise.resolve(rendered).then((node) => {
      if (node) {
        field.replaceChildren(node);
      }
    });
  };
  const renderDnsType = dnsTypeOption.render;
  dnsTypeOption.render = function (option_index, section_id) {
    const settingsId = section_id != null ? section_id : option_index;
    return Promise.resolve(renderDnsType.apply(this, arguments)).then((node) => {
      if (node && node.addEventListener && !node.dataset.fkpDnsProtocol) {
        node.dataset.fkpDnsProtocol = "1";
        node.addEventListener("widget-change", () => {
          dnsTypeOption.onchange(null, settingsId, !dnsTypeRefreshLock);
        });
      }
      return node;
    });
  };

  o = section.option(form.DummyValue, "_xray_doq_direct", _("DoQ"));
  o.depends("dns_type", "doq");
  o.rawhtml = true;
  o.cfgvalue = function () {
    return (
      '<span style="color:#c62828">' +
      _(
        "DoQ does not go through a section. Xray dials it directly from the router.",
      ) +
      "</span>"
    );
  };
  o.write = function () {};
  o.remove = function () {};
  restrictRoutingEngine(o, "xray");

  o = section.option(
    form.Value,
    "dns_certificate_name",
    _("Certificate name"),
    _(
      "Name on the certificate when the server is a custom IP, for example dns.example.net. A hostname or a preset from the list does not need this.",
    ),
  );
  o.rmempty = true;
  o.depends("dns_type", "doq");
  o.depends("dns_type", "doh3");
  o.depends("dns_type", "doh");
  o.depends("dns_type", "dot");
  o.validate = function (_section_id, value) {
    const name = `${value || ""}`.trim();
    if (!name) {
      return true;
    }
    return main.validateDomain(name).valid
      ? true
      : _("Certificate name must be a domain, for example dns.example.net");
  };

  const bootstrapOption = section.option(
    form.DynamicList,
    "bootstrap_dns_server",
    _("Bootstrap DNS Servers"),
    _(
      "DNS server used to obtain IP addresses for upstream DNS and proxies. If multiple servers are selected, a timeout switches to a backup.",
    ),
  );
  configureDnsList(
    bootstrapOption,
    main.BOOTSTRAP_DNS_SERVER_OPTIONS,
    "77.88.8.8",
  );

  o = section.option(
    form.Value,
    "dns_check_interval",
    _("DNS Check Interval"),
    _("How often to check the active DNS servers."),
  );
  configureDnsDuration(o, "10s", dnsOption, bootstrapOption);
  restrictRoutingEngine(o, "sing-box");

  o = section.option(
    form.Value,
    "dns_recovery_check_interval",
    _("Higher-priority DNS Check"),
    _("How often to check whether a higher-priority DNS server has recovered."),
  );
  configureDnsDuration(o, "60s", dnsOption, bootstrapOption);
  restrictRoutingEngine(o, "sing-box");

  o = section.option(
    form.Value,
    "dns_check_timeout",
    _("DNS Unavailability Timeout"),
    _(
      "Maximum time to wait for example.com to resolve during a DNS health check.",
    ),
  );
  configureDnsDuration(o, "2s", dnsOption, bootstrapOption);
  restrictRoutingEngine(o, "sing-box");

  o = section.option(
    form.Value,
    "dns_rewrite_ttl",
    _("DNS Rewrite TTL"),
    _(
      "How long to keep cached real DNS answers, in seconds (default: 60). FakeIP stays in its own pool and is not stored in this cache. On sing-box this is also the TTL sent to clients.",
    ),
  );
  o.default = "60";
  o.rmempty = false;
  o.validate = function (section_id, value) {
    if (!value) {
      return _("TTL value cannot be empty");
    }

    const ttl = parseInt(value);
    if (isNaN(ttl) || ttl < 0) {
      return _("TTL must be a positive number");
    }

    return true;
  };

  o = section.option(form.ListValue, "dns_strategy", _("DNS Strategy"));
  o.value("prefer_ipv4", _("Prefer IPv4"));
  o.value("ipv4_only", _("IPv4 only"));
  o.value("prefer_ipv6", _("Prefer IPv6"));
  o.value("ipv6_only", _("IPv6 only"));
  o.default = "prefer_ipv4";
  o.rmempty = false;

  o = section.option(
    form.Flag,
    "dns_detour_enabled",
    _("DNS through proxy"),
    _("Route main DNS requests through the selected section."),
  );
  configureDownloadViaProxyFlag(o, "dns_detour_section");

  o = section.option(
    form.ListValue,
    "dns_detour_section",
    _("DNS requests through section"),
  );
  o.depends("dns_detour_enabled", "1");
  configureDownloadSectionOption(o, "dns_detour_section", capabilities);

  o = section.option(
    widgets.DeviceSelect,
    "source_network_interfaces",
    _("Source Network Interface"),
    _("Select the network interface from which the traffic will originate"),
  );
  o.default = "br-lan";
  o.noaliases = true;
  o.nobridges = false;
  o.noinactive = false;
  o.multiple = true;
  o.filter = function (section_id, value) {
    // Block specific interface names from being selectable
    const blocked = ["wan", "phy0-ap0", "phy1-ap0", "pppoe-wan"];
    if (blocked.includes(value)) {
      return false;
    }

    // Try to find the device object by its name
    const device = this.devices.find((dev) => dev.getName() === value);

    // If no device is found, allow the value
    if (!device) {
      return true;
    }

    // Check the type of the device
    const type = device.getType();

    // Consider any Wi-Fi / wireless / wlan device as invalid
    const isWireless =
      type === "wifi" || type === "wireless" || type.includes("wlan");

    // Allow only non-wireless devices
    return !isWireless;
  };

  o = section.option(
    form.DynamicList,
    "routing_excluded_ips",
    _("Completely excluded devices"),
    _(
      "Devices and subnets in this list are fully excluded from Forkop: no tproxy mark, no FakeIP DNS, traffic goes as if Forkop were stopped.",
    ),
  );
  o.placeholder = _("Device or IP");
  o.rmempty = true;
  o.validate = function (_section_id, value) {
    if (!value || value.length === 0) {
      return true;
    }

    const resolved = localDevices.resolveLocalDeviceListValue(value);
    const validation = main.validateSubnet(resolved);
    return validation.valid ? true : validation.message;
  };
  o.write = function (section_id, value) {
    const resolved = [];
    const seen = {};
    localDevices.normalizeOptionValues(value).forEach((item) => {
      localDevices.resolveLocalDeviceListValues(item).forEach((ip) => {
        if (!ip || seen[ip]) {
          return;
        }
        seen[ip] = true;
        resolved.push(ip);
      });
    });
    if (resolved.length) {
      uci.set(UCI_PACKAGE, section_id, "routing_excluded_ips", resolved);
    } else {
      uci.unset(UCI_PACKAGE, section_id, "routing_excluded_ips");
    }
  };
  o.renderWidget = function (section_id, _option_index, cfgvalue) {
    return localDevices.createLocalDeviceDynamicListWidget(
      this,
      section_id,
      cfgvalue,
    );
  };

  o = section.option(
    form.Flag,
    "route_router_traffic",
    _("Route the router's own traffic"),
    _(
      "Send IPv4 TCP from the router itself through the selected section. Ping, DNS and NTP stay direct. Apply and restart Forkop after changing this.",
    ),
  );
  configureDownloadViaProxyFlag(o, "route_router_traffic_section");

  o = section.option(
    form.ListValue,
    "route_router_traffic_section",
    _("Router traffic through"),
  );
  o.depends("route_router_traffic", "1");
  configureDownloadSectionOption(
    o,
    "route_router_traffic_section",
    capabilities,
  );

  o = section.option(
    form.Flag,
    "enable_output_network_interface",
    _("Enable Output Network Interface"),
    _("You can select Output Network Interface, by default autodetect"),
  );
  o.default = "0";
  o.rmempty = false;

  o = section.option(
    widgets.DeviceSelect,
    "output_network_interface",
    _("Output Network Interface"),
    _("Select the network interface to which the traffic will originate"),
  );
  o.noaliases = true;
  o.multiple = false;
  o.depends("enable_output_network_interface", "1");
  o.filter = function (section_id, value) {
    // Blocked interface names that should never be selectable
    const blockedInterfaces = ["br-lan"];

    // Reject immediately if the value matches any blocked interface
    if (blockedInterfaces.includes(value)) {
      return false;
    }

    // Reject lan*
    if (value.startsWith("lan")) {
      return false;
    }

    // Reject tun*, wg*, vpn*, awg*, oc*
    if (
      value.startsWith("tun") ||
      value.startsWith("wg") ||
      value.startsWith("vpn") ||
      value.startsWith("awg") ||
      value.startsWith("oc")
    ) {
      return false;
    }

    // Try to find the device object with the given name
    const device = this.devices.find((dev) => dev.getName() === value);

    // If no device is found, allow the value
    if (!device) {
      return true;
    }

    // Get the device type (e.g., "wifi", "ethernet", etc.)
    const type = device.getType();

    // Reject wireless-related devices
    const isWireless =
      type === "wifi" || type === "wireless" || type.includes("wlan");

    return !isWireless;
  };

  o = section.option(
    form.Flag,
    "restart_interfaces_after_start",
    _("Restart interfaces after start"),
    _(
      "Bring selected network interfaces down and up after Forkop starts. Use this if routing appears only after a WAN/LAN bounce.",
    ),
  );
  configureDownloadViaProxyFlag(o, "restart_interfaces");

  o = section.option(
    widgets.NetworkSelect,
    "restart_interfaces",
    _("Interfaces to restart"),
  );
  o.depends("restart_interfaces_after_start", "1");
  o.multiple = true;
  o.rmempty = false;
  o.filter = function (_section_id, value) {
    if (["loopback", "lo"].includes(value)) {
      return false;
    }
    if (value.startsWith("@")) {
      return false;
    }
    return true;
  };

  o = section.option(
    form.ListValue,
    "restart_interfaces_delay",
    _("Restart delay"),
    _(
      "Seconds to wait after a successful start before restarting the selected interfaces.",
    ),
  );
  o.depends("restart_interfaces_after_start", "1");
  o.default = "5";
  o.rmempty = false;
  o.value("0", _("Immediately"));
  o.value("3", _("3 seconds"));
  o.value("5", _("5 seconds"));
  o.value("10", _("10 seconds"));
  o.value("15", _("15 seconds"));
  o.value("30", _("30 seconds"));
  o.value("60", _("60 seconds"));

  o = section.option(
    form.Flag,
    "enable_badwan_interface_monitoring",
    _("Interface Monitoring"),
    _("Interface monitoring for Bad WAN"),
  );
  o.default = "0";
  o.rmempty = false;

  o = section.option(
    widgets.NetworkSelect,
    "badwan_monitored_interfaces",
    _("Monitored Interfaces"),
    _("Select the WAN interfaces to be monitored"),
  );
  o.depends("enable_badwan_interface_monitoring", "1");
  o.multiple = true;
  o.filter = function (section_id, value) {
    // Reject if the value is in the blocked list ['lan', 'loopback']
    if (["lan", "loopback"].includes(value)) {
      return false;
    }

    // Reject if the value starts with '@' (means it's an alias/reference)
    if (value.startsWith("@")) {
      return false;
    }

    // Otherwise allow it
    return true;
  };

  o = section.option(
    form.Value,
    "badwan_reload_delay",
    _("Interface Monitoring Delay"),
    _("Delay in milliseconds before reloading Forkop after interface UP"),
  );
  o.depends("enable_badwan_interface_monitoring", "1");
  o.default = "2000";
  o.rmempty = false;
  o.validate = function (section_id, value) {
    if (!value) {
      return _("Delay value cannot be empty");
    }
    return true;
  };

  o = section.option(
    form.Flag,
    "enable_yacd",
    _("Enable YACD"),
    `<a href="${main.getClashUIUrl()}" target="_blank">${main.getClashUIUrl()}</a>`,
  );
  o.default = "0";
  o.rmempty = false;
  restrictRoutingEngine(o, "sing-box");

  o = section.option(
    form.Flag,
    "enable_yacd_wan_access",
    _("Enable YACD WAN Access"),
    _(
      "Allows access to YACD from the WAN. Make sure to open the appropriate port in your firewall.",
    ),
  );
  o.depends("enable_yacd", "1");
  o.default = "0";
  o.rmempty = false;
  restrictRoutingEngine(o, "sing-box");

  o = section.option(
    form.Value,
    "yacd_secret_key",
    _("YACD Secret Key"),
    _(
      "Secret key for authenticating remote access to YACD when WAN access is enabled.",
    ),
  );
  o.depends("enable_yacd_wan_access", "1");
  o.rmempty = false;
  restrictRoutingEngine(o, "sing-box");

  o = section.option(
    form.Flag,
    "disable_quic",
    _("Disable QUIC"),
    _(
      "Disable the QUIC protocol to improve compatibility or fix issues with video streaming",
    ),
  );
  o.default = "0";
  o.rmempty = false;

  o = section.option(
    form.Flag,
    "component_update_check_enabled",
    _("Automatic component update checks"),
    _("Automatically check installed components for new versions"),
  );
  o.default = "0";
  o.rmempty = false;

  o = section.option(
    form.Value,
    "component_update_check_interval",
    _("Component update check interval"),
    _("Use sing-box duration format like 1d, 12h or 30m"),
  );
  o.depends("component_update_check_enabled", "1");
  o.placeholder = "1d";
  o.default = "1d";
  o.rmempty = false;
  o.cfgvalue = function (section_id) {
    return (
      uci.get(UCI_PACKAGE, section_id, "component_update_check_interval") ||
      "1d"
    );
  };
  o.write = function (section_id, value) {
    const normalized = value ? `${value}`.trim() : "";
    uci.set(
      UCI_PACKAGE,
      section_id,
      "component_update_check_interval",
      normalized.length ? normalized : "1d",
    );
  };
  o.validate = function (_section_id, value) {
    const normalized = value ? `${value}`.trim() : "";

    if (normalized.length && isSingBoxDuration(normalized)) {
      return true;
    }

    return _("Use sing-box duration format like 1d, 12h or 30m");
  };

  o = section.option(
    form.Value,
    "latency_test_url",
    _("Latency test URL"),
    _(
      "Default address for checking server availability and latency. URLTest uses its own address.",
    ),
  );
  latencyTestUrlChoices().forEach((value) => o.value(value));
  o.default =
    main.DEFAULT_LATENCY_TEST_URL || "https://www.gstatic.com/generate_204";
  o.rmempty = false;
  o.validate = function (_section_id, value) {
    return validateLatencyTestUrl(value);
  };

  o = section.option(
    form.Flag,
    "list_update_enabled",
    _("Enable list updates"),
    _("Enable automatic updates for remote lists and rule sets"),
  );
  o.default = "1";
  o.rmempty = false;

  o = section.option(
    form.Flag,
    "persist_lists_locally",
    _("Save selected lists locally"),
    _(
      "When enabled, selected lists and Xray DAT stay on flash. Start reuses that cache until the interval below elapses. When disabled, lists are fetched on every start, as before. If download through a section is enabled, that section is started first.",
    ),
  );
  o.default = "1";
  o.rmempty = false;

  o = section.option(
    form.ListValue,
    "update_interval",
    _("List update interval"),
    _(
      "How often to fetch new lists. If lists are already downloaded, start does not hit GitHub until this interval has passed. Never turns off automatic updates; the dashboard button still downloads them.",
    ),
  );
  o.value("3h", _("Every 3 hours"));
  o.value("6h", _("Every 6 hours"));
  o.value("12h", _("Every 12 hours"));
  o.value("1d", _("Every day"));
  o.value("3d", _("Every 3 days"));
  o.value("7d", _("Every 7 days"));
  o.value("never", _("Never"));
  o.default = "1d";
  o.rmempty = false;
  o.cfgvalue = function (section_id) {
    const allowed = ["3h", "6h", "12h", "1d", "3d", "7d", "never"];
    const current = uci.get(UCI_PACKAGE, section_id, "update_interval") || "1d";
    return allowed.indexOf(current) >= 0 ? current : "1d";
  };

  o = section.option(
    form.Flag,
    "download_lists_via_proxy",
    _("Download lists through a section"),
    _("Download remote lists and rule sets via the selected section"),
  );
  configureDownloadViaProxyFlag(o, "download_lists_via_proxy_section");

  o = section.option(
    form.ListValue,
    "download_lists_via_proxy_section",
    _("Download lists through"),
  );
  o.depends("download_lists_via_proxy", "1");
  configureDownloadSectionOption(
    o,
    "download_lists_via_proxy_section",
    capabilities,
  );

  o = section.option(
    form.Flag,
    "download_components_via_proxy",
    _("Download components through a section"),
    _("Download component packages via the selected section"),
  );
  configureDownloadViaProxyFlag(o, "download_components_via_proxy_section");

  o = section.option(
    form.ListValue,
    "download_components_via_proxy_section",
    _("Download components through"),
  );
  o.depends("download_components_via_proxy", "1");
  configureDownloadSectionOption(
    o,
    "download_components_via_proxy_section",
    capabilities,
  );

  o = section.option(
    form.Flag,
    "dont_touch_dhcp",
    _("Dont Touch My DHCP!"),
    _("Forkop will not modify your DHCP configuration"),
  );
  o.default = "0";
  o.rmempty = false;

  o = section.option(
    form.ListValue,
    "config_path",
    _("Config File Path"),
    _(
      "Select path for sing-box config file. Change this ONLY if you know what you are doing.",
    ),
  );
  o.value("/etc/sing-box/config.json", "Flash (/etc/sing-box/config.json)");
  o.value("/tmp/sing-box/config.json", "RAM (/tmp/sing-box/config.json)");
  o.default = "/etc/sing-box/config.json";
  o.rmempty = false;
  restrictRoutingEngine(o, "sing-box");

  o = section.option(
    form.Value,
    "cache_path",
    _("Cache File Path"),
    _(
      "Select or enter path for sing-box cache file. Change this ONLY if you know what you are doing.",
    ),
  );
  o.value("/tmp/sing-box/cache.db", "RAM (/tmp/sing-box/cache.db)");
  o.value(
    "/usr/share/sing-box/cache.db",
    "Flash (/usr/share/sing-box/cache.db)",
  );
  o.default = "/tmp/sing-box/cache.db";
  o.rmempty = false;
  o.validate = function (section_id, value) {
    if (!value) {
      return _("Cache file path cannot be empty");
    }

    if (!value.startsWith("/")) {
      return _("Path must be absolute (start with /)");
    }

    if (!value.endsWith("cache.db")) {
      return _("Path must end with cache.db");
    }

    const parts = value.split("/").filter(Boolean);
    if (parts.length < 2) {
      return _("Path must contain at least one directory (like /tmp/cache.db)");
    }

    return true;
  };
  restrictRoutingEngine(o, "sing-box");

  o = section.option(
    form.ListValue,
    "log_level",
    _("Log Level"),
    _("Log level for sing-box and Xray"),
  );
  o.value("trace", "Trace");
  o.value("debug", "Debug");
  o.value("info", "Info");
  o.value("warn", "Warn");
  o.value("error", "Error");
  o.value("fatal", "Fatal");
  o.value("panic", "Panic");
  o.default = "warn";
  o.rmempty = false;

  o = section.option(
    form.Flag,
    "exclude_ntp",
    _("Exclude NTP"),
    _(
      "Exclude NTP protocol traffic from the tunnel to prevent it from being routed through the proxy or VPN",
    ),
  );
  o.default = "0";
  o.rmempty = false;

  o = section.option(
    form.Flag,
    "exclude_bittorrent",
    _("Exclude BitTorrent"),
    _(
      "Send BitTorrent and DHT traffic directly, bypassing Forkop. Trackers over HTTP/HTTPS may still follow section rules.",
    ),
  );
  o.default = "0";
  o.rmempty = false;
}

const EntryPoint = {
  createSettingsContent,
  restrictRoutingEngine,
  currentRoutingEngine,
  isXrayRoutingEngine,
  liveFormValue,
};

return baseclass.extend(EntryPoint);
