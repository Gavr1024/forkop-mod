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
  if (status === "missing") {
    return _("Not downloaded yet");
  }
  return _("Disabled");
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

  const rows = items
    .map((item) => {
      const name = escapeHtml(item.name || item.id || "");
      return `<tr>
        <td>${name}</td>
        <td>${escapeHtml(item.kind || "")}</td>
        <td>${escapeHtml(formatBytes(item.size))}</td>
        <td>${escapeHtml(formatTime(item.mtime))}</td>
        <td>${escapeHtml(statusLabel(item.status))}</td>
      </tr>`;
    })
    .join("");

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
