"use strict";
"require baseclass";
"require form";
"require fs";
"require uci";
"require ui";
"require view.forkop.main as main";

const UCI_PACKAGE = main.FORKOP_UCI_PACKAGE;
const AVAILABILITY_EVENT = "forkop:action-providers-availability";

let activeRoot = null;
let pollTimer = null;
let catalog = null;
let expanded = {};
let siteCache = {};
let siteLoads = {};
let lastState = null;

function callForkop(args) {
  return fs.exec("/usr/bin/forkop", args).then(
    (result) => {
      let data = null;

      try {
        data = JSON.parse(result.stdout || "");
      } catch (_error) {
        data = null;
      }

      return {
        code: result.code,
        data,
        stderr: result.stderr || "",
        stdout: result.stdout || "",
      };
    },
    (error) => ({
      code: 1,
      data: null,
      stderr: error && error.message ? error.message : "",
      stdout: "",
    }),
  );
}

function percent(item) {
  const total = Number(item && item.total) || 0;
  const success = Number(item && item.success) || 0;

  if (total <= 0) {
    return 0;
  }

  return Math.round((success * 100) / total);
}

function sortedStrategies(strategies) {
  return (strategies || [])
    .map((item, index) => ({ item, index }))
    .sort((left, right) => {
      const leftDone = left.item.completed ? 1 : 0;
      const rightDone = right.item.completed ? 1 : 0;

      if (leftDone !== rightDone) {
        return rightDone - leftDone;
      }

      const delta = percent(right.item) - percent(left.item);

      if (delta !== 0) {
        return delta;
      }

      return left.index - right.index;
    })
    .map((entry) => entry.item);
}

function byedpiSections() {
  return (uci.sections(UCI_PACKAGE, "section") || []).filter(
    (section) => section && section.action === "byedpi",
  );
}

function sectionLabel(section) {
  return section.label || section[".name"] || "";
}

function selectedLists(root) {
  return Array.from(
    root.querySelectorAll('input[data-list-id]:checked'),
  ).map((input) => input.getAttribute("data-list-id"));
}

function readSettings(root) {
  const numberValue = (name, fallback) => {
    const input = root.querySelector(`[data-field="${name}"]`);
    const value = input ? Number(input.value) : fallback;

    return Number.isFinite(value) ? value : fallback;
  };

  return {
    lists: selectedLists(root),
    domains: (root.querySelector('[data-field="domains"]') || {}).value || "",
    sni: ((root.querySelector('[data-field="sni"]') || {}).value || "").trim(),
    requests: numberValue("requests", 1),
    timeout: numberValue("timeout", 5),
    delay: numberValue("delay", 1),
    limit: numberValue("limit", 8),
    use_custom: Boolean(
      (root.querySelector('[data-field="use_custom"]') || {}).checked,
    ),
    commands: (root.querySelector('[data-field="commands"]') || {}).value || "",
  };
}

function normalizeSite(raw) {
  let value = String(raw || "").trim();

  if (!value || value.charAt(0) === "#") {
    return "";
  }

  if (/[\s"'`<>]/.test(value)) {
    return "";
  }

  if (value.indexOf("://") < 0) {
    value = `https://${value}`;
  }

  if (value.indexOf("https://") !== 0 && value.indexOf("http://") !== 0) {
    return "";
  }

  return value;
}

function collectSites(settings) {
  const seen = {};
  const sites = [];
  const lists = (catalog && catalog.lists) || [];
  let missing = false;

  (settings.lists || []).forEach((id) => {
    const list = lists.find((item) => item.id === id);
    const domains = list && Array.isArray(list.domains) ? list.domains : null;
    const count = list && list.count != null ? Number(list.count) : NaN;

    if (!domains || domains.length === 0 || (Number.isFinite(count) && domains.length !== count)) {
      missing = true;
      return;
    }

    domains.forEach((domain) => {
      const url = normalizeSite(domain);

      if (!url) {
        missing = true;
        return;
      }

      if (seen[url]) {
        return;
      }

      seen[url] = true;
      sites.push(url);
    });
  });

  String(settings.domains || "")
    .split(/\n/)
    .forEach((line) => {
      const url = normalizeSite(line);

      if (!url || seen[url]) {
        return;
      }

      seen[url] = true;
      sites.push(url);
    });

  return { sites, missing };
}

function listsKey(value) {
  return (Array.isArray(value) ? value : [])
    .map((item) => String(item))
    .sort()
    .join("\n");
}

function countSites(settings) {
  return collectSites(settings).sites.length;
}

function countCommands(settings) {
  if (!settings.use_custom) {
    return catalog && catalog.strategy_count ? catalog.strategy_count : 0;
  }

  return String(settings.commands || "")
    .split(/\n/)
    .filter((line) => line.trim() && line.trim().charAt(0) !== "#").length;
}

function failureText(message) {
  switch (message) {
    case "not_installed":
      return _("ciadpi is not installed");
    case "no_sites":
      return _("Select at least one domain");
    case "no_commands":
      return _("Custom strategy list is empty");
    case "already_running":
      return _("A strategy check is already running");
    case "bad_request":
      return _("Check the SNI and numeric settings");
    case "too_many":
      return _("Too many domains or strategies");
    case "sites_mismatch":
      return _("The domain list is incomplete. Reload the page and try again.");
    default:
      return _("Could not start the strategy check");
  }
}

function statusText(state) {
  const total = Number(state && state.total) || 0;
  const current = Number(state && state.current) || 0;

  if (state && state.running && current > 0) {
    return _("Strategy %d of %d").format(current, total);
  }

  if (state && (state.running || state.stopping)) {
    return _("Preparing…");
  }

  if (state && state.failed) {
    return _("ByeDPI check failed");
  }

  if (state && state.interrupted) {
    return _("Check was interrupted");
  }

  if (state && state.strategies && state.strategies.length) {
    return _("Check complete");
  }

  return "";
}

function injectStyles() {
  if (document.getElementById("fkp-byedpi-strategy-style")) {
    return;
  }

  const style = E("style", { id: "fkp-byedpi-strategy-style" });

  style.textContent = `
#cbi-${UCI_PACKAGE}-byedpi_strategy > h3 { display: none; }
.fkp-byedpi-strategy { display: flex; flex-direction: column; gap: 12px; width: 100%; }
.fkp-byedpi-strategy__card {
  border: 2px solid var(--background-color-low, lightgray);
  border-radius: 4px;
  padding: 12px;
  display: flex;
  flex-direction: column;
  gap: 10px;
}
.fkp-byedpi-strategy__title { font-size: 16px; font-weight: bold; }
.fkp-byedpi-strategy__note { color: var(--text-color-medium, #666); line-height: 1.45; }
.fkp-byedpi-strategy__grid {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(180px, 1fr));
  gap: 10px;
}
.fkp-byedpi-strategy label { display: flex; flex-direction: column; gap: 4px; font-weight: bold; }
.fkp-byedpi-strategy input[type="text"],
.fkp-byedpi-strategy input[type="number"],
.fkp-byedpi-strategy textarea,
.fkp-byedpi-strategy select { font-weight: normal; width: 100%; }
.fkp-byedpi-strategy textarea { min-height: 88px; }
.fkp-byedpi-strategy__lists { display: flex; flex-wrap: wrap; gap: 8px 14px; font-weight: normal; }
.fkp-byedpi-strategy__lists label { flex-direction: row; align-items: center; font-weight: normal; }
.fkp-byedpi-strategy__actions { display: flex; flex-wrap: wrap; gap: 8px; align-items: center; }
.fkp-byedpi-strategy__estimate { font-weight: normal; }
.fkp-byedpi-strategy__row {
  border-top: 1px solid var(--background-color-low, lightgray);
  padding-top: 8px;
  display: flex;
  flex-direction: column;
  gap: 6px;
}
.fkp-byedpi-strategy__row-head { display: flex; justify-content: space-between; gap: 8px; align-items: center; }
.fkp-byedpi-strategy__command { font-family: monospace; word-break: break-word; }
.fkp-byedpi-strategy__bar { height: 6px; border-radius: 99px; background: var(--background-color-low, #ddd); overflow: hidden; }
.fkp-byedpi-strategy__bar > span { display: block; height: 100%; background: var(--primary-color--hover, #2e7d32); }
.fkp-byedpi-strategy__sites { margin: 0; padding-left: 18px; }
.fkp-byedpi-strategy__hidden { display: none; }
`;
  document.head.appendChild(style);
}

function renderLists(lists) {
  const active = (catalog && catalog.defaults && catalog.defaults.active) || [];
  const box = E("div", { class: "fkp-byedpi-strategy__lists" });

  (lists || []).forEach((list) => {
    const input = E("input", {
      type: "checkbox",
      "data-list-id": list.id,
    });

    if (active.indexOf(list.id) >= 0) {
      input.checked = true;
    }

    box.appendChild(
      E("label", {}, [
        input,
        E(
          "span",
          {},
          `${list.name} (${list.count != null ? list.count : (list.domains || []).length})`,
        ),
      ]),
    );
  });

  return box;
}

function copyCommand(command, button) {
  const done = () => {
    const previous = button.textContent;

    button.textContent = _("Copied");
    window.setTimeout(() => {
      button.textContent = previous;
    }, 1200);
  };

  if (navigator.clipboard && navigator.clipboard.writeText) {
    navigator.clipboard.writeText(command).then(done, done);
    return;
  }

  done();
}

function applyCommand(root, command) {
  const select = root.querySelector('[data-field="section"]');
  const sectionId = select ? select.value : "";

  if (!sectionId) {
    ui.addNotification(
      null,
      E(
        "p",
        {},
        _(
          "No ByeDPI section yet. Create one on the Sections tab with action ByeDPI, then apply the strategy.",
        ),
      ),
    );
    return;
  }

  uci.set(UCI_PACKAGE, sectionId, "byedpi_cmd_opts", command);
  const section = byedpiSections().find((item) => item[".name"] === sectionId);

  ui.addNotification(
    null,
    E(
      "p",
      {},
      _("Strategy saved to “%s”. Press Save & Apply to start using it.").format(
        sectionLabel(section || { ".name": sectionId }),
      ),
    ),
  );
}

function resultNote(state, root) {
  const saved = state && state.settings ? Number(state.settings.sites) : NaN;

  if (!state || !Number.isFinite(saved) || saved < 0) {
    return "";
  }

  if ((!state.strategies || !state.strategies.length) && !(state.running || state.stopping)) {
    return "";
  }

  const settings = readSettings(root);
  const collected = collectSites(settings);
  const listsMatch =
    !Array.isArray(state.settings.lists) ||
    listsKey(state.settings.lists) === listsKey(settings.lists);

  if (!collected.missing && listsMatch && collected.sites.length === saved) {
    return _("Checked %d domains").format(saved);
  }

  return _("This is an old result, %d domains").format(saved);
}

function fillSiteList(list, sites) {
  list.innerHTML = "";
  (sites || []).forEach((site) => {
    list.appendChild(
      E("li", {}, `${site.site} — ${site.success}/${site.total}`),
    );
  });

  if (!list.childNodes.length) {
    list.appendChild(E("li", {}, _("Preparing…")));
  }
}

function loadSites(root, index) {
  const key = String(index);

  if (siteLoads[key]) {
    return;
  }

  siteLoads[key] = callForkop(["byedpi_strategy_sites", key]).then((result) => {
    siteLoads[key] = null;

    if (activeRoot !== root || !result.data || result.data.success === false) {
      return;
    }

    siteCache[key] = result.data.sites || [];
    const list = root.querySelector(`[data-sites="${key}"]`);

    if (!list || !expanded[key]) {
      return;
    }

    fillSiteList(list, siteCache[key]);
  });
}

function refreshOpenSites(root, state) {
  ((state && state.strategies) || []).forEach((strategy) => {
    if (strategy.index == null) {
      return;
    }

    const key = String(strategy.index);

    if (!expanded[key]) {
      return;
    }

    if (state.running || state.stopping || !siteCache[key]) {
      loadSites(root, strategy.index);
    }
  });
}

function renderResults(root, state) {
  const mount = root.querySelector("[data-results]");
  const select = root.querySelector('[data-field="section"]');
  const previousSection = select ? select.value : "";

  mount.innerHTML = "";
  const sections = byedpiSections();
  const options = [
    E("option", { value: "" }, _("Section")),
  ];

  sections.forEach((section) => {
    const id = section[".name"];
    const option = E("option", { value: id }, sectionLabel(section));

    if (id === previousSection) {
      option.selected = true;
    }

    options.push(option);
  });

  const sectionSelect = E(
    "select",
    { "data-field": "section", class: "cbi-input-select" },
    options,
  );

  mount.appendChild(
    E("div", { class: "fkp-byedpi-strategy__actions" }, [
      sectionSelect,
      E(
        "span",
        { class: "fkp-byedpi-strategy__note" },
        _(
          "Applying a strategy only fills the section field. Save & Apply reloads Forkop.",
        ),
      ),
    ]),
  );

  const strategies = sortedStrategies(state && state.strategies);
  const note = resultNote(state, root);

  if (note) {
    mount.appendChild(
      E("div", { class: "fkp-byedpi-strategy__note", "data-run-note": "1" }, note),
    );
  }

  if (!strategies.length) {
    return;
  }

  strategies.forEach((strategy) => {
    const value = percent(strategy);
    const key = strategy.index != null ? String(strategy.index) : "";
    const open = Boolean(key && expanded[key]);
    const cached = key ? siteCache[key] : null;
    const sites = E(
      "ul",
      {
        class: open
          ? "fkp-byedpi-strategy__sites"
          : "fkp-byedpi-strategy__sites fkp-byedpi-strategy__hidden",
        "data-sites": key,
      },
      open && cached
        ? cached.map((site) =>
            E("li", {}, `${site.site} — ${site.success}/${site.total}`),
          )
        : [],
    );

    if (open && !cached) {
      sites.appendChild(E("li", {}, _("Preparing…")));
    }

    const toggle = E(
      "button",
      {
        class: "cbi-button cbi-button-neutral",
        type: "button",
        click: () => {
          if (!key) {
            return;
          }

          expanded[key] = !expanded[key];
          sites.classList.toggle("fkp-byedpi-strategy__hidden", !expanded[key]);
          toggle.textContent = expanded[key] ? _("Hide details") : _("Details");

          if (expanded[key]) {
            loadSites(root, strategy.index);
          }
        },
      },
      open ? _("Hide details") : _("Details"),
    );
    const apply = E(
      "button",
      {
        class: "cbi-button cbi-button-action",
        type: "button",
        click: () => applyCommand(root, strategy.command || ""),
      },
      _("Apply"),
    );
    const copy = E(
      "button",
      {
        class: "cbi-button cbi-button-neutral",
        type: "button",
        click: (event) => copyCommand(strategy.command || "", event.currentTarget),
      },
      _("Copy"),
    );

    mount.appendChild(
      E("div", { class: "fkp-byedpi-strategy__row" }, [
        E("div", { class: "fkp-byedpi-strategy__row-head" }, [
          E("strong", {}, `${value}% · ${strategy.success || 0}/${strategy.total || 0}`),
          E("div", { class: "fkp-byedpi-strategy__actions" }, [
            key ? toggle : E("span"),
            copy,
            apply,
          ]),
        ]),
        E("div", { class: "fkp-byedpi-strategy__bar" }, [
          E("span", { style: `width:${value}%` }),
        ]),
        E("div", { class: "fkp-byedpi-strategy__command" }, strategy.command || ""),
        strategy.error === "ciadpi"
          ? E("div", { class: "fkp-byedpi-strategy__note" }, _("Failed to start ciadpi"))
          : E("span"),
        sites,
      ]),
    );
  });
}

function setBusy(root, busy) {
  const start = root.querySelector("[data-action='start']");
  const stop = root.querySelector("[data-action='stop']");

  if (start) {
    start.disabled = busy;
  }

  if (stop) {
    stop.disabled = !busy;
  }

  root.querySelectorAll("input, textarea, select").forEach((input) => {
    if (input.getAttribute("data-field") === "section") {
      return;
    }

    input.disabled = busy;
  });
}

function updateEstimate(root) {
  const settings = readSettings(root);
  const sites = countSites(settings);
  const commands = countCommands(settings);
  const requests = Math.max(1, settings.requests || 1);
  const node = root.querySelector("[data-estimate]");

  if (!node) {
    return;
  }

  node.textContent = _(
    "About %d requests across %d strategies. Each request can take up to %d s.",
  ).format(sites * commands * requests, commands, settings.timeout || 5);
}

function renderState(root, state) {
  lastState = state || {};
  const status = root.querySelector("[data-status]");
  const running = Boolean(state && (state.running || state.stopping));

  if (status) {
    status.textContent = statusText(state);
  }

  setBusy(root, running);
  renderResults(root, state || {});
  refreshOpenSites(root, state || {});

  if (running) {
    startPolling(root);
  } else if (pollTimer) {
    window.clearInterval(pollTimer);
    pollTimer = null;
  }
}

function refreshStatus(root) {
  return callForkop(["byedpi_strategy_status"]).then((result) => {
    if (activeRoot !== root) {
      return;
    }

    renderState(root, (result && result.data) || {});
  });
}

function startPolling(root) {
  if (pollTimer) {
    return;
  }

  pollTimer = window.setInterval(() => {
    if (activeRoot) {
      refreshStatus(activeRoot);
    }
  }, 1000);
}

function startTest(root) {
  const settings = readSettings(root);
  const collected = collectSites(settings);

  updateEstimate(root);

  if (collected.missing || collected.sites.length === 0) {
    const status = root.querySelector("[data-status]");

    if (status) {
      status.textContent = collected.missing
        ? _("The domain list is incomplete. Reload the page and try again.")
        : _("Select at least one domain");
    }

    return;
  }

  siteCache = {};
  siteLoads = {};
  expanded = {};
  setBusy(root, true);
  callForkop([
    "byedpi_strategy_start",
    JSON.stringify(Object.assign({}, settings, { expected: collected.sites.length })),
  ]).then((result) => {
    if (activeRoot !== root) {
      return;
    }

    const failed = !result.data || result.data.success === false;

    return refreshStatus(root).then(() => {
      if (activeRoot !== root) {
        return;
      }

      if (lastState && (lastState.running || lastState.stopping)) {
        return;
      }

      if (!failed) {
        return;
      }

      const status = root.querySelector("[data-status]");

      if (status) {
        status.textContent = failureText(result.data && result.data.message);
      }

      setBusy(root, false);
    });
  });
}

function stopTest(root) {
  const status = root.querySelector("[data-status]");

  if (status) {
    status.textContent = _("Stopping…");
  }

  callForkop(["byedpi_strategy_stop"]).then((result) => {
    if (activeRoot !== root) {
      return;
    }

    renderState(root, (result && result.data && result.data.state) || result.data || {});
  });
}

function renderPage() {
  injectStyles();
  const defaults = {
    sni: "google.com",
    requests: 1,
    timeout: 5,
    delay: 1,
    limit: 8,
  };
  const root = E("div", { class: "fkp-byedpi-strategy" }, [
    E("div", { class: "fkp-byedpi-strategy__card" }, [
      E("div", { class: "fkp-byedpi-strategy__title" }, _("Strategy check")),
      E(
        "div",
        { class: "fkp-byedpi-strategy__note" },
        _(
          "ByeDPI listens on the router and the check opens each site through its SOCKS proxy. Nothing is sent to a remote VPN server. A request counts as successful only when the reply body arrives in full, not merely when the site answers. The strategy with more successful requests is the more universal one. It is not necessarily the best strategy for every single site.",
        ),
      ),
      E(
        "div",
        { class: "fkp-byedpi-strategy__note" },
        _("Built-in list from ByeByeDPI"),
      ),
      E("div", { "data-lists": "1" }, E("div", { class: "fkp-byedpi-strategy__note" }, _("Preparing…"))),
      E("label", {}, [
        _("Extra domains"),
        E("textarea", {
          "data-field": "domains",
          class: "cbi-input-textarea",
          placeholder: "example.com",
        }),
        E(
          "span",
          { class: "fkp-byedpi-strategy__note" },
          _("One domain per line. https:// is added when the scheme is missing."),
        ),
      ]),
      E("div", { class: "fkp-byedpi-strategy__grid" }, [
        E("label", {}, [
          _("SNI"),
          E("input", {
            type: "text",
            "data-field": "sni",
            class: "cbi-input-text",
            value: defaults.sni,
          }),
        ]),
        E("label", {}, [
          _("Requests per site"),
          E("input", {
            type: "number",
            min: "1",
            max: "10",
            "data-field": "requests",
            class: "cbi-input-text",
            value: String(defaults.requests),
          }),
        ]),
        E("label", {}, [
          _("Timeout (seconds)"),
          E("input", {
            type: "number",
            min: "1",
            max: "30",
            "data-field": "timeout",
            class: "cbi-input-text",
            value: String(defaults.timeout),
          }),
        ]),
        E("label", {}, [
          _("Pause between strategies (seconds)"),
          E("input", {
            type: "number",
            min: "0",
            max: "15",
            "data-field": "delay",
            class: "cbi-input-text",
            value: String(defaults.delay),
          }),
        ]),
        E("label", {}, [
          _("Parallel requests"),
          E("input", {
            type: "number",
            min: "1",
            max: "20",
            "data-field": "limit",
            class: "cbi-input-text",
            value: String(defaults.limit),
          }),
          E(
            "span",
            { class: "fkp-byedpi-strategy__note" },
            _("ByeByeDPI uses 20. On a router, 4–8 is safer."),
          ),
        ]),
      ]),
      E("label", { class: "fkp-byedpi-strategy__lists" }, [
        E("input", { type: "checkbox", "data-field": "use_custom" }),
        E("span", {}, _("Use my strategies")),
      ]),
      E("label", {}, [
        _("One ciadpi strategy per line. Leave this off to test the built-in ByeByeDPI list."),
        E("textarea", {
          "data-field": "commands",
          class: "cbi-input-textarea",
          placeholder: "-d1 -s3+s -a1",
        }),
      ]),
      E("div", { class: "fkp-byedpi-strategy__actions" }, [
        E(
          "button",
          {
            class: "cbi-button cbi-button-apply",
            type: "button",
            "data-action": "start",
            click: () => startTest(root),
          },
          _("Start"),
        ),
        E(
          "button",
          {
            class: "cbi-button cbi-button-remove",
            type: "button",
            "data-action": "stop",
            disabled: "disabled",
            click: () => stopTest(root),
          },
          _("Stop"),
        ),
        E("strong", { "data-status": "1" }),
      ]),
      E("div", { class: "fkp-byedpi-strategy__estimate", "data-estimate": "1" }),
    ]),
    E("div", { class: "fkp-byedpi-strategy__card", "data-results": "1" }),
  ]);

  root.addEventListener("input", () => {
    updateEstimate(root);
    const note = root.querySelector("[data-run-note]");

    if (note && lastState) {
      note.textContent = resultNote(lastState, root);
    }
  });
  root.addEventListener("change", () => {
    updateEstimate(root);
    const note = root.querySelector("[data-run-note]");

    if (note && lastState) {
      note.textContent = resultNote(lastState, root);
    }
  });
  return root;
}

function loadCatalog(root) {
  return callForkop(["byedpi_strategy_catalog"]).then((result) => {
    if (activeRoot !== root) {
      return;
    }

    catalog = result.data && result.data.lists ? result.data : { lists: [], strategy_count: 0 };
    const mount = root.querySelector("[data-lists]");

    if (mount) {
      mount.innerHTML = "";
      mount.appendChild(renderLists(catalog.lists || []));
    }

    const defaults = (result.data && result.data.defaults) || {};

    ["sni", "requests", "timeout", "delay", "limit"].forEach((name) => {
      const input = root.querySelector(`[data-field="${name}"]`);

      if (input && defaults[name] != null && input.value === "") {
        input.value = String(defaults[name]);
      }
    });

    updateEstimate(root);
  });
}

function mount(root) {
  activeRoot = root;

  if (pollTimer) {
    window.clearInterval(pollTimer);
    pollTimer = null;
  }

  loadCatalog(root).then(() => refreshStatus(root));
}

function createByedpiStrategyContent(section) {
  const option = section.option(form.DummyValue, "_mount_node");

  option.rawhtml = true;
  option.cfgvalue = () => {
    const root = renderPage();

    window.setTimeout(() => mount(root), 0);
    return root;
  };
}

if (typeof window !== "undefined") {
  window.addEventListener(AVAILABILITY_EVENT, (event) => {
    const detail = event && event.detail;

    if (!detail || detail.byedpiInstalled !== false || !activeRoot) {
      return;
    }

    stopTest(activeRoot);
  });
}

return baseclass.extend({
  createByedpiStrategyContent,
});
