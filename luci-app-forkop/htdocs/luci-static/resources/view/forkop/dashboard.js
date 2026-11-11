"use strict";
"require baseclass";
"require form";
"require ui";
"require uci";
"require fs";
"require view.forkop.main as main";
"require view.forkop.local_devices as localDevices";

let localListsBusy = "";
let lookupDeviceNames = {};

function escapeHtml(value) {
  return String(value == null ? "" : value)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function formatBytes(size) {
  const value = Number(size);
  if (!Number.isFinite(value) || value <= 0) {
    return "0 B";
  }

  const units = ["B", "KiB", "MiB", "GiB"];
  let amount = value;
  let unit = 0;
  while (amount >= 1024 && unit < units.length - 1) {
    amount /= 1024;
    unit += 1;
  }

  return `${amount >= 10 || unit === 0 ? amount.toFixed(0) : amount.toFixed(1)} ${units[unit]}`;
}

function formatTime(seconds) {
  const value = Number(seconds);
  if (!Number.isFinite(value) || value <= 0) {
    return "—";
  }

  try {
    return new Date(value * 1000).toLocaleString();
  } catch (_error) {
    return "—";
  }
}

function statusLabel(status) {
  if (status === "cached") {
    return _("Local backup");
  }
  if (status === "ready") {
    return _("On the router");
  }
  if (status === "absent") {
    return _("File not found");
  }
  if (status === "missing") {
    return _("Not downloaded yet");
  }
  return _("Disabled");
}

function isBuiltinList(item) {
  if (!item) {
    return false;
  }
  if (item.builtin === false || item.local === true) {
    return false;
  }
  return item.builtin === true || item.kind === "community";
}

function parseStatusPayload(result) {
  const stdout = result && result.stdout ? String(result.stdout) : "";
  try {
    return JSON.parse(stdout);
  } catch (_error) {
    return { enabled: false, items: [] };
  }
}

function notify(message, type) {
  if (ui && typeof ui.addNotification === "function") {
    ui.addNotification(null, E("p", {}, message), type || "info");
  }
}

function renderLocalLists(payload) {
  const enabled = Boolean(payload && payload.enabled);
  const items = payload && Array.isArray(payload.items) ? payload.items : [];
  const downloadLabel = localListsBusy === "download"
    ? _("Downloading lists…")
    : _("Download lists now");
  const pruneLabel = localListsBusy === "prune"
    ? _("Removing unused lists…")
    : _("Delete unused");
  const unusedBytes = Number(payload && payload.unused_bytes);
  const canPrune = Number.isFinite(unusedBytes) && unusedBytes > 0 && !localListsBusy;

  const listRow = (item) => {
    const name = escapeHtml(item.name || item.id || "");
    const clickable =
      (item.status === "cached" || item.status === "ready") && item.id;
    const custom = !isBuiltinList(item);
    const tag = custom
      ? `<span class="fkp-list-custom-tag">${escapeHtml(_("Not a built-in list"))}</span>`
      : "";
    const nameCell = clickable
      ? `<button type="button" class="fkp-list-open" data-list-id="${escapeHtml(item.id)}" data-list-name="${name}" style="background:none;border:0;padding:0;color:var(--primary-color,#1a73e8);cursor:pointer;text-align:left;font:inherit;text-decoration:underline;">${name}</button>${tag}`
      : `${name}${tag}`;
    return `<tr>
        <td>${nameCell}</td>
        <td>${escapeHtml(custom ? _("Your lists") : _("Built-in lists"))}</td>
        <td>${escapeHtml(formatBytes(item.size))}</td>
        <td>${escapeHtml(formatTime(item.mtime))}</td>
        <td>${escapeHtml(statusLabel(item.status))}</td>
      </tr>`;
  };
  const groupRow = (label) =>
    `<tr class="fkp-list-group"><td colspan="5">${escapeHtml(label)}</td></tr>`;
  const builtin = items.filter((item) => isBuiltinList(item));
  const custom = items.filter((item) => !isBuiltinList(item));
  const rows = [
    builtin.length ? groupRow(_("Built-in lists")) + builtin.map(listRow).join("") : "",
    custom.length ? groupRow(_("Your lists")) + custom.map(listRow).join("") : "",
  ].join("");

  const empty = `<tr><td colspan="5">${escapeHtml(
    enabled
      ? _("No local lists saved yet")
      : _("Local list cache is disabled"),
  )}</td></tr>`;

  return `<div class="fkp_dashboard-page__local-lists">
    <style>
      .fkp_dashboard-page__local-lists {
        margin-top: 16px;
        padding: 12px 14px;
        border: 1px solid var(--border-color-high, #555);
        border-radius: 6px;
      }
      .fkp_dashboard-page__local-lists__header {
        display: flex;
        align-items: center;
        justify-content: space-between;
        gap: 12px;
        margin: 0 0 8px;
        flex-wrap: wrap;
      }
      .fkp_dashboard-page__local-lists h4 {
        margin: 0;
      }
      .fkp_dashboard-page__local-lists table {
        width: 100%;
        border-collapse: collapse;
      }
      .fkp_dashboard-page__local-lists th,
      .fkp_dashboard-page__local-lists td {
        text-align: left;
        padding: 6px 8px;
        border-bottom: 1px solid var(--border-color-low, #333);
        word-break: break-all;
      }
      .fkp-list-group td {
        font-weight: 600;
        background: var(--background-color-high, rgba(127, 127, 127, 0.12));
      }
      .fkp-list-custom-tag {
        display: inline-block;
        margin-left: 0.45rem;
        padding: 0 0.4rem;
        border: 1px solid #c4a35a;
        border-radius: 999px;
        color: #8a6d1d;
        font-size: 0.8em;
        white-space: nowrap;
        vertical-align: middle;
      }
      #cbi-forkop-dashboard-_local_lists > .cbi-value-title {
        display: none;
      }
      #cbi-forkop-dashboard-_local_lists > .cbi-value-field,
      #cbi-forkop-dashboard-_local_lists > div,
      #cbi-forkop-dashboard-_local_lists > output {
        margin-left: 0;
        width: 100%;
        min-width: 0;
        box-sizing: border-box;
      }
    </style>
    <div class="fkp_dashboard-page__local-lists__header">
      <h4>${escapeHtml(_("Local list cache"))}</h4>
      <div style="display:flex;gap:8px;flex-wrap:wrap;">
      <button
        id="forkop-local-lists-download"
        type="button"
        class="btn cbi-button cbi-button-action"
        ${enabled && !localListsBusy ? "" : "disabled"}
      >${escapeHtml(downloadLabel)}</button>
      <button
        id="forkop-local-lists-prune"
        type="button"
        class="btn cbi-button cbi-button-remove"
        ${canPrune ? "" : "disabled"}
      >${escapeHtml(pruneLabel)}</button>
      </div>
    </div>
    <p>${escapeHtml(
      enabled
        ? _("Selected lists stored on flash and used when the online repository is unavailable.")
        : _("Enable “Save selected lists locally” in settings to keep backups on flash."),
    )}</p>
    <p>${escapeHtml(_("Cache"))}: ${escapeHtml(formatBytes(payload && payload.cache_bytes))} · ${escapeHtml(_("Unused"))}: ${escapeHtml(formatBytes(payload && payload.unused_bytes))} · ${escapeHtml(_("Free on flash"))}: ${escapeHtml(formatBytes(payload && payload.flash_free))}</p>
    <table>
      <thead>
        <tr>
          <th>${escapeHtml(_("Name"))}</th>
          <th>${escapeHtml(_("Type"))}</th>
          <th>${escapeHtml(_("Size"))}</th>
          <th>${escapeHtml(_("Updated"))}</th>
          <th>${escapeHtml(_("Status"))}</th>
        </tr>
      </thead>
      <tbody>${rows || empty}</tbody>
    </table>
  </div>`;
}

function mountLocalLists(payload) {
  const node = document.getElementById("forkop-local-lists");
  if (!node) {
    return;
  }

  node.innerHTML = renderLocalLists(payload);
  node.onclick = (event) => {
    let element = event.target;
    while (element && element !== node) {
      if (element.getAttribute && element.getAttribute("data-list-id")) {
        openListPreview(
          element.getAttribute("data-list-id"),
          element.getAttribute("data-list-name") || "",
        );
        return;
      }
      element = element.parentNode;
    }
  };
  const button = document.getElementById("forkop-local-lists-download");
  if (!button) {
    return;
  }

  button.addEventListener("click", () => {
    downloadLocalListsNow(payload);
  });
  const pruneButton = document.getElementById("forkop-local-lists-prune");
  if (!pruneButton) {
    return;
  }
  pruneButton.addEventListener("click", () => {
    pruneUnusedLists(payload);
  });
}

function refreshLocalListsView() {
  return fs
    .exec("/usr/bin/forkop", ["list_cache_status"])
    .then((result) => {
      mountLocalLists(parseStatusPayload(result));
    })
    .catch(() => {
      mountLocalLists({ enabled: false, items: [] });
    });
}

function finishListDownload(payload) {
  localListsBusy = "";
  const outcome = payload && payload.outcome;
  if (outcome === "fail") {
    notify(
      _("Failed to download some lists. Existing local copies were kept."),
      "warning",
    );
  } else if (outcome === "ok") {
    notify(_("List download finished"), "info");
  } else {
    notify(_("Failed to download lists"), "error");
  }
  mountLocalLists(payload || { enabled: true, items: [] });
}

function pollListDownload(startedAt, failures) {
  fs.exec("/usr/bin/forkop", ["list_cache_status"])
    .then((result) => {
      const payload = parseStatusPayload(result);
      if (payload.running) {
        mountLocalLists(payload);
        if (Date.now() - startedAt > 15 * 60 * 1000) {
          localListsBusy = "";
          notify(_("Failed to download lists"), "error");
          mountLocalLists(payload);
          return;
        }
        window.setTimeout(() => pollListDownload(startedAt, 0), 2000);
        return;
      }
      finishListDownload(payload);
    })
    .catch(() => {
      const next = (failures || 0) + 1;
      if (next > 5) {
        localListsBusy = "";
        notify(_("Failed to download lists"), "error");
        refreshLocalListsView();
        return;
      }
      window.setTimeout(() => pollListDownload(startedAt, next), 2000);
    });
}

let listPreviewToken = "";
let listPreviewView = "domains";

function previewHasSubnets(payload) {
  return Boolean(payload && (payload.has_subnets === true || payload.has_subnets === 1 || payload.has_subnets === "1"));
}

function previewViewName(view) {
  return view === "subnets" ? "subnets" : "domains";
}

function closeListPreview() {
  const token = listPreviewToken;
  listPreviewToken = "";
  listPreviewView = "domains";
  if (ui && typeof ui.hideModal === "function") {
    ui.hideModal();
  }
  if (token) {
    fs.exec("/usr/bin/forkop", ["list_cache_show_close", token]).catch(() => {});
  }
}

function showListPreview(payload, fallbackName) {
  if (!payload || !payload.ok) {
    closeListPreview();
    const message =
      payload && payload.error === "missing"
        ? _("Not downloaded yet")
        : _("Could not read this list");
    notify(message, "warning");
    return;
  }

  listPreviewToken = `${payload.token || ""}`;
  const page = Number(payload.page || 1);
  const pages = Number(payload.pages || 1);
  const titleName = payload.name || fallbackName || "";
  const view = previewViewName(payload.view || listPreviewView);
  const hasSubnets = previewHasSubnets(payload);
  listPreviewView = view;
  if (ui && typeof ui.hideModal === "function") {
    ui.hideModal();
  }
  const modeButton = (label, mode) =>
    E(
      "button",
      {
        class: "btn",
        style:
          view === mode
            ? "font-weight:600;border-color:#3e8f46;color:#3e8f46;"
            : "",
        click: () => {
          if (view !== mode) {
            loadListPreviewPage(1, titleName, mode);
          }
        },
      },
      label,
    );
  const controls = [];
  if (pages > 1) {
    const openPage = (target) => {
      const next = Math.min(pages, Math.max(1, Math.floor(Number(target))));
      if (!Number.isFinite(next) || next === page) {
        return;
      }
      loadListPreviewPage(next, titleName, view);
    };
    const pageInput = E("input", {
      type: "number",
      min: "1",
      max: String(pages),
      value: String(page),
      "data-list-page": "1",
      style: "width:4.5rem;margin:0 0.35rem;vertical-align:middle;",
      keydown: (event) => {
        if (event.key === "Enter") {
          event.preventDefault();
          openPage(event.target.value);
        }
      },
      change: (event) => openPage(event.target.value),
    });
    controls.push(
      E(
        "button",
        {
          class: "btn",
          disabled: page <= 1 ? "disabled" : void 0,
          click: () => loadListPreviewPage(page - 1, titleName, view),
        },
        _("Previous"),
      ),
      pageInput,
      E("span", { style: "margin:0 0.6rem;" }, `/ ${pages}`),
      E(
        "button",
        {
          class: "btn",
          style: "margin-right:0.6rem;",
          click: () => openPage(pageInput.value),
        },
        _("OK"),
      ),
      E(
        "button",
        {
          class: "btn",
          disabled: page >= pages ? "disabled" : void 0,
          click: () => loadListPreviewPage(page + 1, titleName, view),
        },
        _("Next"),
      ),
    );
  }
  controls.push(
    E(
      "button",
      {
        class: "btn",
        click: closeListPreview,
      },
      _("Close"),
    ),
  );
  const body = [
    E(
      "pre",
      {
        style:
          "max-height:60vh;overflow:auto;white-space:pre-wrap;word-break:break-word;margin:0;",
      },
      payload.text || "",
    ),
    E("div", { class: "right" }, controls),
  ];
  if (hasSubnets) {
    body.unshift(
      E(
        "div",
        { style: "display:flex;gap:0.4rem;margin:0 0 0.75rem;" },
        [modeButton(_("Domains"), "domains"), modeButton(_("Subnets"), "subnets")],
      ),
    );
  }
  ui.showModal(`${_("List contents")}: ${titleName}`, body);
}

function readListPreviewResult(result) {
  try {
    return JSON.parse(result && result.stdout ? result.stdout : "{}");
  } catch (_error) {
    return {};
  }
}

function loadListPreviewPage(page, name, view) {
  const token = listPreviewToken;
  const nextView = previewViewName(view || listPreviewView);
  if (!token || page < 1 || !ui || typeof ui.showModal !== "function") {
    return;
  }
  listPreviewView = nextView;
  if (typeof ui.hideModal === "function") {
    ui.hideModal();
  }
  ui.showModal(`${_("List contents")}: ${name || ""}`, [
    E("p", {}, _("Loading...")),
  ]);
  fs.exec("/usr/bin/forkop", [
    "list_cache_show_page",
    token,
    String(page),
    nextView,
  ])
    .then((result) => {
      showListPreview(readListPreviewResult(result), name);
    })
    .catch(() => {
      closeListPreview();
      notify(_("Could not read this list"), "error");
    });
}

function openListPreview(id, name) {
  if (!id || !ui || typeof ui.showModal !== "function") {
    return;
  }

  if (listPreviewToken) {
    fs.exec("/usr/bin/forkop", ["list_cache_show_close", listPreviewToken]).catch(() => {});
  }
  listPreviewToken = "";
  listPreviewView = "domains";
  ui.showModal(`${_("List contents")}: ${name || id}`, [
    E("p", {}, _("Loading...")),
  ]);

  fs.exec("/usr/bin/forkop", ["list_cache_show", id])
    .then((result) => {
      showListPreview(readListPreviewResult(result), name || id);
    })
    .catch(() => {
      closeListPreview();
      notify(_("Could not read this list"), "error");
    });
}

function pruneUnusedLists(currentPayload) {
  if (localListsBusy) {
    return;
  }

  localListsBusy = "prune";
  mountLocalLists(currentPayload || { enabled: true, items: [] });

  fs.exec("/usr/bin/forkop", ["list_cache_prune"])
    .then((result) => {
      localListsBusy = "";
      const payload = parseStatusPayload(result);
      if (payload && payload.ok === false) {
        notify(_("Could not remove unused lists"), "error");
      } else {
        notify(_("Unused lists removed"), "info");
      }
      refreshLocalListsView();
    })
    .catch(() => {
      localListsBusy = "";
      notify(_("Could not remove unused lists"), "error");
      refreshLocalListsView();
    });
}

function downloadLocalListsNow(currentPayload) {
  if (localListsBusy) {
    return;
  }

  localListsBusy = "download";
  mountLocalLists(currentPayload || { enabled: true, items: [] });

  fs.exec("/usr/bin/forkop", ["list_cache_persist"])
    .then(() => {
      pollListDownload(Date.now(), 0);
    })
    .catch(() => {
      localListsBusy = "";
      notify(_("Failed to download lists"), "error");
      refreshLocalListsView();
    });
}

function reasonText(kind, value) {
  if (kind === "domain") {
    return _("the exact domain");
  }
  if (kind === "suffix") {
    return _("the suffix %s").format(value);
  }
  if (kind === "keyword") {
    return _("the keyword %s").format(value);
  }
  if (kind === "regex") {
    return _("a regular expression");
  }
  if (kind === "community" || kind === "list") {
    return _("the list %s").format(value);
  }
  if (kind === "missing") {
    return _("the list %s is not downloaded").format(value);
  }
  if (kind === "large") {
    return _("the list %s is too large to check").format(value);
  }
  return value || "";
}

function actionText(action) {
  if (action === "bypass") {
    return _("directly");
  }
  if (action === "block") {
    return _("blocked");
  }
  if (action === "zapret" || action === "zapret2" || action === "byedpi") {
    return _("through bypass");
  }
  return _("through the proxy");
}

function dnsServerText(data) {
  const server = `${data.dns_server || ""}`.trim();
  const type = `${data.dns_type || "udp"}`.trim();
  if (!server) {
    return _("its DNS server");
  }
  if (type === "dot") {
    return `DoT ${server}`;
  }
  if (type === "doh") {
    return `DoH ${server}`;
  }
  if (type === "doh3") {
    return `DoH3 ${server}`;
  }
  if (type === "doq") {
    return `DoQ ${server}`;
  }
  return server;
}

function lookupDeviceLabel(value) {
  const raw = `${value || ""}`.trim();
  if (!raw) {
    return "";
  }
  const ip = raw.split("/")[0];
  const name = `${lookupDeviceNames[ip] || lookupDeviceNames[raw] || ""}`.trim();
  if (raw.indexOf("/") >= 0) {
    return name ? `${name} (${raw})` : raw;
  }
  return name || raw;
}

function forcedText(data) {
  const items = Array.isArray(data.forced) ? data.forced : [];
  if (!items.length) {
    return "";
  }
  return items
    .map((item) => {
      const devices = Array.isArray(item.devices) ? item.devices : [];
      const names = devices.map(lookupDeviceLabel).filter((name) => name);
      if (!names.length) {
        return "";
      }
      const where = actionText(item.action);
      if (names.length === 1 && `${devices[0] || ""}`.indexOf("/") >= 0) {
        return _("Subnet %s still goes to section %s, including this site, and is sent %s.").format(
          names[0],
          item.label,
          where,
        );
      }
      if (names.length === 1) {
        return _("Device %s still goes to section %s, including this site, and is sent %s.").format(
          names[0],
          item.label,
          where,
        );
      }
      return _("Devices %s still go to section %s, including this site, and are sent %s.").format(
        names.join(", "),
        item.label,
        where,
      );
    })
    .filter((line) => line)
    .join(" ");
}

function withForced(sentence, data) {
  const extra = forcedText(data);
  return extra ? `${sentence} ${extra}` : sentence;
}

function dnsDetourText(data) {
  if (!data.dns_detour) {
    return "";
  }
  return ` ${_("Queries to that server go through section %s.").format(data.dns_detour)}`;
}

function routeDnsText(data) {
  if (data.dns_mode !== "route") {
    return "";
  }
  let text = "";
  if (data.dns_source_limited) {
    text = _(
      "Devices selected in DNS section %s resolve the name with %s. Other devices use the usual DNS.",
    ).format(data.dns_label, dnsServerText(data));
  } else {
    text = _("The tunnel resolves the name with DNS section %s, server %s.").format(
      data.dns_label,
      dnsServerText(data),
    );
  }
  return ` ${text}${dnsDetourText(data)}`;
}

function lookupSentence(data) {
  if (!data || data.status === "bad") {
    return _("Enter a site, for example youtube.com");
  }
  if (data.device) {
    const who = lookupDeviceLabel(data.device);
    if (data.via === "full" && data.status === "match") {
      if (data.reason_kind === "temporary") {
        return _(
          "Device %s is sent through section %s for a limited time, including %s, and goes %s. The section settings stay unchanged.",
        ).format(who, data.label || data.section_id, data.domain, actionText(data.action));
      }
      let sentence = _(
        "Device %s goes to section %s, including %s, and is sent %s. This is full routing, so the site list does not matter.",
      ).format(who, data.label || data.section_id, data.domain, actionText(data.action));
      if (data.dns_label) {
        sentence +=
          " " +
          _("DNS section %s answers every name for this device with %s.").format(
            data.dns_label,
            dnsServerText(data),
          );
        sentence += dnsDetourText(data);
      }
      return sentence;
    }
    if (data.status === "dns" && data.dns_mode === "real") {
      const sentence =
        data.dns_via === "full"
          ? _(
              "For %s, DNS section %s answers every name, including %s, with a real address from %s. The connection bypasses the sections below.",
            ).format(who, data.dns_label || data.label, data.domain, dnsServerText(data))
          : _(
              "For %s, DNS section %s answers %s with a real address from %s. The connection bypasses the sections below.",
            ).format(who, data.dns_label || data.label, data.domain, dnsServerText(data));
      return sentence + dnsDetourText(data);
    }
    if (data.status === "none" && data.dns_mode === "route") {
      const sentence =
        data.dns_via === "full"
          ? _(
              "For %s, DNS section %s answers every name, including %s, with a stand-in address from %s. No section below takes the connection, so it goes directly.",
            ).format(who, data.dns_label, data.domain, dnsServerText(data))
          : _(
              "For %s, DNS section %s gives %s a stand-in address and resolves the name with %s. No section below takes the connection, so it goes directly.",
            ).format(who, data.dns_label, data.domain, dnsServerText(data));
      return sentence + dnsDetourText(data);
    }
    if (data.status === "none") {
      return _("For %s, no section takes %s. It goes outside the rules.").format(
        who,
        data.domain,
      );
    }
    if (data.status === "unknown") {
      return _(
        "For %s, section %s is higher than the others, but %s. Until that is fixed, the result is unknown.",
      ).format(
        who,
        data.label || data.section_id,
        reasonText(data.reason_kind, data.reason_value),
      );
    }
    let sentence = _(
      "For %s, section %s takes %s because of %s and sends it %s.",
    ).format(
      who,
      data.label || data.section_id,
      data.domain,
      reasonText(data.reason_kind, data.reason_value),
      actionText(data.action),
    );
    if (data.dns_via === "full" && data.dns_label) {
      sentence +=
        " " +
        _("DNS section %s answers every name for this device with %s.").format(
          data.dns_label,
          dnsServerText(data),
        );
      sentence += dnsDetourText(data);
    } else {
      sentence += routeDnsText(data);
    }
    return sentence;
  }
  if (data.status === "dns" && data.dns_mode === "real") {
    let sentence = _(
      "DNS section %s answers %s with a real address from %s. The connection bypasses the sections below.",
    ).format(data.dns_label || data.label, data.domain, dnsServerText(data));
    sentence += dnsDetourText(data);
    if (data.source_limited) {
      sentence += ` ${_("This match is only for devices selected in that section.")}`;
    }
    if (data.fallback_status === "match") {
      sentence +=
        " " +
        _("Other devices go to %s because of %s and are sent %s.").format(
          data.fallback_label,
          reasonText(data.fallback_reason_kind, data.fallback_reason_value),
          actionText(data.fallback_action),
        );
    }
    return withForced(sentence, data);
  }
  if (data.status === "none" && data.dns_mode === "route") {
    return withForced(
      _(
        "DNS section %s gives %s a stand-in address and resolves the name with %s. No section below takes the connection, so it goes directly.",
      ).format(data.dns_label, data.domain, dnsServerText(data)) + dnsDetourText(data),
      data,
    );
  }
  if (data.status === "none") {
    return withForced(
      _("No section takes %s. It goes outside the rules.").format(data.domain),
      data,
    );
  }
  if (data.status === "unknown") {
    return withForced(
      _(
        "Section %s is higher than the others, but %s. Until that is fixed, the result is unknown.",
      ).format(data.label || data.section_id, reasonText(data.reason_kind, data.reason_value)),
      data,
    );
  }
  let sentence = _("Section %s takes %s because of %s and sends it %s.").format(
    data.label || data.section_id,
    data.domain,
    reasonText(data.reason_kind, data.reason_value),
    actionText(data.action),
  );
  if (data.source_limited) {
    sentence += " " + _("This match is only for devices selected in that section.");
  }
  if (data.fallback_status === "match") {
    sentence +=
      " " +
      _("Other devices go to %s because of %s.").format(
        data.fallback_label,
        reasonText(data.fallback_reason_kind, data.fallback_reason_value),
      );
  }
  sentence += routeDnsText(data);
  return withForced(sentence, data);
}

function renderDomainLookup() {
  const result = E(
    "div",
    { id: "forkop-domain-lookup-result", style: "margin-top:0.6rem" },
    _("Enter a site, for example youtube.com"),
  );
  const input = E("input", {
    type: "text",
    class: "cbi-input-text",
    placeholder: "youtube.com",
    style: "max-width:16rem",
  });
  const device = new ui.Dropdown("", {}, {
    create: true,
    optional: true,
    placeholder: _("Any device"),
  });
  const deviceNode = device.render();
  deviceNode.style.display = "inline-block";
  deviceNode.style.minWidth = "14rem";
  deviceNode.style.verticalAlign = "middle";
  localDevices.loadLocalDeviceChoices().then((choices) => {
    const labels = deviceChoiceLabels(choices);
    if (typeof device.clearChoices === "function") {
      device.clearChoices();
    }
    device.addChoices(sortedDeviceIps(labels), labels);
    device.options.sort = sortedDeviceIps(labels);
  });
  const button = E(
    "button",
    {
      type: "button",
      class: "btn cbi-button cbi-button-action",
      click: (ev) => {
        ev.preventDefault();
        ev.stopPropagation();
        const domain = `${input.value || ""}`.trim();
        const selected = device.getValue();
        const raw = `${Array.isArray(selected) ? selected[0] || "" : selected || ""}`.trim();
        result.textContent = _("Checking…");
        localDevices
          .loadLocalDeviceChoices()
          .catch(() => ({}))
          .then((choices) => {
            lookupDeviceNames = choices || {};
            let ip = "";
            if (raw) {
              const ips = localDevices.resolveLocalDeviceListValues(raw);
              const targets = (Array.isArray(ips) ? ips : []).filter((item) =>
                main.validateIP(item).valid,
              );
              if (!targets.length) {
                result.textContent = _("No such device");
                return null;
              }
              ip = targets[0];
            }
            return fs.exec("/usr/bin/forkop", ["lookup_domain", domain, ip]);
          })
          .then((response) => {
            if (!response) {
              return;
            }
            const text = `${response && response.stdout ? response.stdout : ""}`.trim();
            if (!text) {
              result.textContent = _("Could not check this site");
              return;
            }
            try {
              result.textContent = lookupSentence(JSON.parse(text));
            } catch (_error) {
              result.textContent = _("Could not check this site");
            }
          })
          .catch(() => {
            result.textContent = _("Could not check this site");
          });
      },
    },
    _("Check"),
  );

  return E("div", { class: "cbi-section", id: "forkop-domain-lookup" }, [
    E("h3", {}, _("Where a site goes")),
    E(
      "div",
      { class: "cbi-section-descr" },
      _("Uses the saved sections, from top to bottom, and the lists already on the router."),
    ),
    E(
      "div",
      {
        style:
          "display:flex;flex-wrap:wrap;gap:0.5rem;align-items:center;margin-top:0.6rem",
      },
      [input, deviceNode, button],
    ),
    result,
  ]);
}

function pauseUntilText(until) {
  const value = Number(until);
  if (!Number.isFinite(value) || value <= 0) {
    return _("until you turn it off");
  }
  return _("until %s").format(new Date(value * 1000).toLocaleString());
}

function renderPauseRows(list, items) {
  while (list.firstChild) {
    list.removeChild(list.firstChild);
  }
  if (!items.length) {
    list.appendChild(E("div", {}, _("No device is paused.")));
    return;
  }
  items.forEach((item) => {
    const title = item.label ? `${item.label} · ${item.ip}` : item.ip;
    list.appendChild(
      E("div", { style: "margin-top:0.35rem" }, [
        E("span", {}, `${title} — ${pauseUntilText(item.until)} `),
        E(
          "button",
          {
            type: "button",
            class: "btn cbi-button",
            click: (ev) => {
              ev.preventDefault();
              ev.stopPropagation();
              fs.exec("/usr/bin/forkop", ["pause_device_clear", item.ip]).then(() =>
                refreshDevicePauses(list),
              );
            },
          },
          _("Resume"),
        ),
      ]),
    );
  });
}

function refreshDevicePauses(list) {
  fs.exec("/usr/bin/forkop", ["pause_device_list"])
    .then((response) => {
      const text = `${response && response.stdout ? response.stdout : ""}`.trim();
      const data = text ? JSON.parse(text) : { items: [] };
      renderPauseRows(list, Array.isArray(data.items) ? data.items : []);
    })
    .catch(() => {
      renderPauseRows(list, []);
    });
}

function deviceChoiceLabels(choices) {
  const labels = {};
  Object.keys(choices || {}).forEach((ip) => {
    const name = `${choices[ip] || ""}`.trim();
    labels[ip] = name || ip;
  });
  return labels;
}

function sortedDeviceIps(choices) {
  return Object.keys(choices || {}).sort((left, right) => {
    const byName = `${choices[left] || ""}`.localeCompare(`${choices[right] || ""}`);
    return byName || `${left}`.localeCompare(`${right}`);
  });
}

function renderDevicePause() {
  const list = E("div", { style: "margin-top:0.6rem" });
  const device = new ui.Dropdown("", {}, {
    create: true,
    optional: true,
    placeholder: _("Device name or IP"),
  });
  const deviceNode = device.render();
  deviceNode.style.display = "inline-block";
  deviceNode.style.minWidth = "16rem";
  deviceNode.style.verticalAlign = "middle";
  localDevices.loadLocalDeviceChoices().then((choices) => {
    const labels = deviceChoiceLabels(choices);
    if (typeof device.clearChoices === "function") {
      device.clearChoices();
    }
    device.addChoices(sortedDeviceIps(labels), labels);
    device.options.sort = sortedDeviceIps(labels);
  });
  const duration = E(
    "select",
    { class: "cbi-input-select", style: "max-width:14rem" },
    [
      E("option", { value: "5" }, _("5 minutes")),
      E("option", { value: "15" }, _("15 minutes")),
      E("option", { value: "30" }, _("30 minutes")),
      E("option", { value: "60", selected: true }, _("1 hour")),
      E("option", { value: "120" }, _("2 hours")),
      E("option", { value: "240" }, _("4 hours")),
      E("option", { value: "480" }, _("8 hours")),
      E("option", { value: "0" }, _("Until I turn it off")),
    ],
  );
  const note = E("div", { style: "margin-top:0.4rem" });
  const button = E(
    "button",
    {
      type: "button",
      class: "btn cbi-button cbi-button-action",
      click: (ev) => {
        ev.preventDefault();
        ev.stopPropagation();
        const selected = device.getValue();
        const raw = `${Array.isArray(selected) ? selected[0] || "" : selected || ""}`.trim();
        if (!raw) {
          note.textContent = _("Enter a device name or IP");
          return;
        }
        note.textContent = "";
        localDevices.loadLocalDeviceChoices().then((choices) => {
          const ips = localDevices.resolveLocalDeviceListValues(raw);
          const targets = (Array.isArray(ips) ? ips : []).filter((ip) =>
            main.validateIP(ip).valid,
          );
          if (!targets.length) {
            note.textContent = _("No such device");
            return;
          }
          const knownName = `${(choices || {})[targets[0]] || ""}`.trim();
          const label = knownName || (main.validateIP(raw).valid ? "" : raw);
          Promise.all(
            targets.map((ip) =>
              fs.exec("/usr/bin/forkop", [
                "pause_device_add",
                ip,
                duration.value || "60",
                label,
              ]),
            ),
          )
            .then((responses) => {
              const failed = responses.some((response) => Number(response && response.code) !== 0);
              note.textContent = failed ? _("Could not pause this device") : "";
              try {
                if (typeof device.setValues === "function") {
                  device.setValues("");
                }
              } catch (_error) {}
              refreshDevicePauses(list);
            })
            .catch(() => {
              note.textContent = _("Could not pause this device");
            });
        });
      },
    },
    _("Pause"),
  );
  window.setTimeout(() => refreshDevicePauses(list), 0);
  return E("div", { class: "cbi-section", id: "forkop-device-pause" }, [
    E("h3", {}, _("Pause a device")),
    E(
      "div",
      { class: "cbi-section-descr" },
      _("While paused, this device goes around the proxy. Its sections stay unchanged."),
    ),
    E(
      "div",
      {
        style:
          "display:flex;flex-wrap:wrap;gap:0.5rem;align-items:center;margin-top:0.6rem",
      },
      [deviceNode, duration, button],
    ),
    note,
    list,
  ]);
}

const ROUTING_ACTIONS = {
  connection: true,
  proxy: true,
  outbound: true,
  vpn: true,
  bypass: true,
  block: true,
  zapret: true,
  zapret2: true,
  byedpi: true,
};

function routingSectionChoices() {
  const choices = [];
  const packageName = main.FORKOP_UCI_PACKAGE || "forkop";
  (uci.sections(packageName, "section") || []).forEach((section) => {
    if (!section || section.enabled === "0" || !ROUTING_ACTIONS[section.action]) {
      return;
    }
    const id = `${section[".name"] || ""}`.trim();
    if (!id) {
      return;
    }
    choices.push({ id, label: `${section.label || ""}`.trim() || id });
  });
  choices.sort((left, right) => left.label.localeCompare(right.label) || left.id.localeCompare(right.id));
  return choices;
}

function renderDeviceRoute() {
  const list = E("div", { style: "margin-top:0.6rem" });
  const device = new ui.Dropdown("", {}, {
    create: true,
    optional: true,
    placeholder: _("Device name or IP"),
  });
  const deviceNode = device.render();
  deviceNode.style.display = "inline-block";
  deviceNode.style.minWidth = "14rem";
  deviceNode.style.verticalAlign = "middle";
  localDevices.loadLocalDeviceChoices().then((choices) => {
    const labels = deviceChoiceLabels(choices);
    if (typeof device.clearChoices === "function") {
      device.clearChoices();
    }
    device.addChoices(sortedDeviceIps(labels), labels);
    device.options.sort = sortedDeviceIps(labels);
  });
  const sectionSelect = E("select", { class: "cbi-input-select", style: "max-width:16rem" }, [
    E("option", { value: "" }, _("Section")),
  ]);
  routingSectionChoices().forEach((choice) => {
    sectionSelect.appendChild(E("option", { value: choice.id }, choice.label));
  });
  const duration = E(
    "select",
    { class: "cbi-input-select", style: "max-width:14rem" },
    [
      E("option", { value: "5" }, _("5 minutes")),
      E("option", { value: "15" }, _("15 minutes")),
      E("option", { value: "30" }, _("30 minutes")),
      E("option", { value: "60", selected: true }, _("1 hour")),
      E("option", { value: "120" }, _("2 hours")),
      E("option", { value: "240" }, _("4 hours")),
      E("option", { value: "480" }, _("8 hours")),
      E("option", { value: "0" }, _("Until I turn it off")),
    ],
  );
  const note = E("div", { style: "margin-top:0.4rem" });
  const button = E(
    "button",
    {
      type: "button",
      class: "btn cbi-button cbi-button-action",
      click: (ev) => {
        ev.preventDefault();
        ev.stopPropagation();
        const selected = device.getValue();
        const raw = `${Array.isArray(selected) ? selected[0] || "" : selected || ""}`.trim();
        const sectionId = `${sectionSelect.value || ""}`.trim();
        if (!raw) {
          note.textContent = _("Enter a device name or IP");
          return;
        }
        if (!sectionId) {
          note.textContent = _("Choose a section");
          return;
        }
        note.textContent = "";
        localDevices.loadLocalDeviceChoices().then((choices) => {
          const ips = localDevices.resolveLocalDeviceListValues(raw);
          const targets = (Array.isArray(ips) ? ips : []).filter((ip) =>
            main.validateIP(ip).valid,
          );
          if (!targets.length) {
            note.textContent = _("No such device");
            return;
          }
          const knownName = `${(choices || {})[targets[0]] || ""}`.trim();
          const label = knownName || (main.validateIP(raw).valid ? "" : raw);
          Promise.all(
            targets.map((ip) =>
              fs.exec("/usr/bin/forkop", [
                "route_device_add",
                ip,
                duration.value || "60",
                sectionId,
                label,
              ]),
            ),
          )
            .then((responses) => {
              let saved = false;
              let switched = true;
              responses.forEach((response) => {
                const text = `${response && response.stdout ? response.stdout : ""}`.trim();
                let data = null;
                try {
                  data = text ? JSON.parse(text) : null;
                } catch (_error) {
                  data = null;
                }
                if (data && data.ok === true) {
                  saved = true;
                  if (data.applied === false) {
                    switched = false;
                  }
                } else if (Number(response && response.code) === 0) {
                  saved = true;
                }
              });
              if (!saved) {
                note.textContent = _("Could not route this device");
              } else if (!switched) {
                note.textContent = _(
                  "The device is listed, but the tunnel was not switched, so a higher section can still take the traffic.",
                );
              } else {
                note.textContent = "";
              }
              try {
                if (typeof device.setValues === "function") {
                  device.setValues("");
                }
              } catch (_error) {}
              refreshDeviceRoutes(list);
            })
            .catch(() => {
              note.textContent = _("Could not route this device");
            });
        });
      },
    },
    _("Send"),
  );
  window.setTimeout(() => refreshDeviceRoutes(list), 0);
  return E("div", { class: "cbi-section", id: "forkop-device-route" }, [
    E("h3", {}, _("Temporary full routing")),
    E(
      "div",
      { class: "cbi-section-descr" },
      _(
        "For the chosen time, all traffic from this device goes through the selected section. The section settings stay unchanged.",
      ),
    ),
    E(
      "div",
      {
        style:
          "display:flex;flex-wrap:wrap;gap:0.5rem;align-items:center;margin-top:0.6rem",
      },
      [deviceNode, sectionSelect, duration, button],
    ),
    note,
    list,
  ]);
}

function renderRouteRows(list, items) {
  while (list.firstChild) {
    list.removeChild(list.firstChild);
  }
  if (!items.length) {
    list.appendChild(E("div", {}, _("No device is temporarily routed.")));
    return;
  }
  items.forEach((item) => {
    const title = item.label ? `${item.label} · ${item.ip}` : item.ip;
    const sectionName = item.section_label || item.section || "";
    list.appendChild(
      E("div", { style: "margin-top:0.35rem" }, [
        E("span", {}, `${title} — ${sectionName} — ${pauseUntilText(item.until)} `),
        E(
          "button",
          {
            type: "button",
            class: "btn cbi-button",
            click: (ev) => {
              ev.preventDefault();
              ev.stopPropagation();
              fs.exec("/usr/bin/forkop", ["route_device_clear", item.ip]).then(() =>
                refreshDeviceRoutes(list),
              );
            },
          },
          _("Stop"),
        ),
      ]),
    );
  });
}

function refreshDeviceRoutes(list) {
  fs.exec("/usr/bin/forkop", ["route_device_list"])
    .then((response) => {
      const text = `${response && response.stdout ? response.stdout : ""}`.trim();
      const data = text ? JSON.parse(text) : { items: [] };
      renderRouteRows(list, Array.isArray(data.items) ? data.items : []);
    })
    .catch(() => {
      renderRouteRows(list, []);
    });
}

function createDashboardContent(section) {
  const lookup = section.option(form.DummyValue, "_domain_lookup");
  lookup.rawhtml = true;
  lookup.cfgvalue = () => renderDomainLookup();

  const pause = section.option(form.DummyValue, "_device_pause");
  pause.rawhtml = true;
  pause.cfgvalue = () => renderDevicePause();

  const route = section.option(form.DummyValue, "_device_route");
  route.rawhtml = true;
  route.cfgvalue = () => renderDeviceRoute();

  const o = section.option(form.DummyValue, "_mount_node");
  o.rawhtml = true;
  o.cfgvalue = () => {
    main.DashboardTab.initController();
    return main.DashboardTab.render();
  };

  const localLists = section.option(form.DummyValue, "_local_lists");
  localLists.rawhtml = true;
  localLists.cfgvalue = () => {
    const persistEnabled =
      uci.get(main.FORKOP_UCI_PACKAGE || "forkop", "settings", "persist_lists_locally") ===
      "1";

    window.setTimeout(() => {
      refreshLocalListsView();
    }, 0);

    return `<div id="forkop-local-lists">${renderLocalLists({
      enabled: persistEnabled,
      items: [],
    })}</div>`;
  };
}

const EntryPoint = {
  createDashboardContent,
};

return baseclass.extend(EntryPoint);
