"use strict";
"require baseclass";
"require form";
"require ui";
"require uci";
"require fs";
"require view.forkop.main as main";

let localListsBusy = false;

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
  const buttonLabel = localListsBusy
    ? _("Downloading lists…")
    : _("Download lists now");

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
      #cbi-forkop-dashboard-_local_lists > .cbi-value-field {
        margin-left: 0;
        width: 100%;
      }
    </style>
    <div class="fkp_dashboard-page__local-lists__header">
      <h4>${escapeHtml(_("Local list cache"))}</h4>
      <button
        id="forkop-local-lists-download"
        type="button"
        class="btn cbi-button cbi-button-action"
        ${enabled && !localListsBusy ? "" : "disabled"}
      >${escapeHtml(buttonLabel)}</button>
    </div>
    <p>${escapeHtml(
      enabled
        ? _("Selected lists stored on flash and used when the online repository is unavailable.")
        : _("Enable “Save selected lists locally” in settings to keep backups on flash."),
    )}</p>
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
  localListsBusy = false;
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
          localListsBusy = false;
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
        localListsBusy = false;
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

function downloadLocalListsNow(currentPayload) {
  if (localListsBusy) {
    return;
  }

  localListsBusy = true;
  mountLocalLists(currentPayload || { enabled: true, items: [] });

  fs.exec("/usr/bin/forkop", ["list_cache_persist"])
    .then(() => {
      pollListDownload(Date.now(), 0);
    })
    .catch(() => {
      localListsBusy = false;
      notify(_("Failed to download lists"), "error");
      refreshLocalListsView();
    });
}

function createDashboardContent(section) {
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
