"use strict";
"require baseclass";
"require form";
"require ui";
"require fs";

// forkop-slots-ax6000-2: Argon/AX6000-safe slot buttons (inline onclick + capture + confirm)

let slotsBusy = false;
let slotsSnapshot = null;
let lastActAt = 0;
let lastActKey = "";

function escapeHtml(value) {
  return String(value == null ? "" : value)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function formatBytes(size) {
  const value = Number(size);
  if (!Number.isFinite(value) || value <= 0) return "0 B";
  if (value < 1024) return `${value} B`;
  return `${(value / 1024).toFixed(1)} KiB`;
}

function formatTime(seconds) {
  const value = Number(seconds);
  if (!Number.isFinite(value) || value <= 0) return "—";
  try {
    return new Date(value * 1000).toLocaleString();
  } catch (_error) {
    return "—";
  }
}

function notify(message, type) {
  if (ui && typeof ui.addNotification === "function") {
    ui.addNotification(null, E("p", {}, message), type || "info");
  }
}

function parsePayload(result) {
  const stdout = result && result.stdout ? String(result.stdout) : "";
  try {
    return JSON.parse(stdout);
  } catch (_error) {
    return {
      enabled: false,
      host: "1.1.1.1",
      backup_host: "",
      interval: 30,
      fail_count: 2,
      scheduler: "worker",
      active: "",
      last_ok: false,
      last_check: 0,
      streak_ok: 0,
      streak_fail: 0,
      online: { saved: false, size: 0, mtime: 0 },
      offline: { saved: false, size: 0, mtime: 0 },
    };
  }
}

function slotButton(attrs, label, variant) {
  const extra = variant ? ` fkp-slots__btn--${variant}` : "";
  return `<button type="button" class="fkp-slots__btn${extra}" ${attrs} onclick="return window.__forkopSlotsAct(this)">${escapeHtml(label)}</button>`;
}

function slotCard(kind, item, active) {
  const saved = Boolean(item && item.saved);
  const isActive = active === kind;
  const title = kind === "online" ? _("When ping succeeds") : _("When ping fails");
  const hint =
    kind === "online"
      ? _("This profile is applied while at least one checked host answers.")
      : _("This profile is applied only when every checked host does not answer.");
  const saveBtn = slotButton(
    `data-slot-save="${kind}"${slotsBusy ? " disabled" : ""}`,
    _("Save current config"),
    "primary",
  );
  const applyBtn = slotButton(
    `data-slot-apply="${kind}"${slotsBusy || !saved ? " disabled" : ""}`,
    _("Apply now"),
    "ghost",
  );

  return `<article class="fkp-slots__card ${isActive ? "is-active" : ""} ${saved ? "is-saved" : ""}">
    <div class="fkp-slots__card-top">
      <div>
        <div class="fkp-slots__kicker">${escapeHtml(kind === "online" ? _("Online slot") : _("Offline slot"))}</div>
        <h3>${escapeHtml(title)}</h3>
      </div>
      <span class="fkp-slots__badge ${isActive ? "is-on" : ""}">${escapeHtml(isActive ? _("Slot is active") : _("Slot on standby"))}</span>
    </div>
    <p class="fkp-slots__hint">${escapeHtml(hint)}</p>
    <dl class="fkp-slots__meta">
      <div><dt>${escapeHtml(_("Status"))}</dt><dd>${escapeHtml(saved ? _("Saved") : _("Empty"))}</dd></div>
      <div><dt>${escapeHtml(_("Size"))}</dt><dd>${escapeHtml(formatBytes(item && item.size))}</dd></div>
      <div><dt>${escapeHtml(_("Updated"))}</dt><dd>${escapeHtml(formatTime(item && item.mtime))}</dd></div>
    </dl>
    <div class="fkp-slots__actions">${saveBtn}${applyBtn}</div>
  </article>`;
}

function hostProbeResult(payload, hostname) {
  const list = payload && Array.isArray(payload.hosts) ? payload.hosts : [];
  let item = null;
  for (let i = 0; i < list.length; i++) {
    if (list[i] && String(list[i].host) === String(hostname || "")) {
      item = list[i];
      break;
    }
  }
  if (!hostname) {
    return { text: "—", cls: "" };
  }
  if (!payload || !payload.last_check || !item) {
    return { text: _("No ping result yet"), cls: "" };
  }
  if (!item.ok) {
    return { text: _("Host is unreachable"), cls: "is-bad" };
  }
  if (item.ms) {
    return { text: `${item.ms} ${_("ms")}`, cls: "is-ok" };
  }
  return { text: _("Host is reachable"), cls: "is-ok" };
}

function renderHostField(id, field, label, value, placeholder, payload) {
  const result = hostProbeResult(payload, value);
  return `<div class="fkp-slots__field">
    <label for="${id}">${escapeHtml(label)}</label>
    <input id="${id}" data-slot-field="${field}" type="text" value="${escapeHtml(value)}" placeholder="${escapeHtml(placeholder)}">
    <span class="fkp-slots__rtt ${result.cls}">${escapeHtml(result.text)}</span>
  </div>`;
}

function renderSlots(payload) {
  payload = payload || {};
  const enabled = Boolean(payload.enabled);
  const host = payload.host || "1.1.1.1";
  const backupHost = payload.backup_host || "";
  const interval = Number(payload.interval) > 0 ? Number(payload.interval) : 30;
  const failCount = Number(payload.fail_count) > 0 ? Number(payload.fail_count) : 2;
  const scheduler = payload.scheduler === "cron" ? "cron" : "worker";
  const pingLabel = payload.last_check
    ? payload.last_ok
      ? _("At least one host is reachable")
      : _("All hosts are unreachable")
    : _("Not checked yet");

  return `<div class="fkp-slots">
    <style>
      .fkp-slots {
        --fkp-s-line: var(--border-color-medium, rgba(127,127,127,.22));
        --fkp-s-fill: var(--background-color-high, rgba(127,127,127,.04));
        --fkp-s-primary: var(--primary, #337ab7);
        --fkp-s-ok: #2e8b57;
        --fkp-s-bad: #c44747;
        margin: 0 0 8px;
        color: inherit;
      }
      .fkp-slots__lead {
        margin: 0 0 12px;
        font-size: 13px;
        line-height: 1.45;
        opacity: .78;
      }
      .fkp-slots__card,
      .fkp-slots__switch {
        border: 1px solid var(--fkp-s-line);
        border-radius: 8px;
        background: var(--fkp-s-fill);
      }
      .fkp-slots__grid {
        display: grid;
        grid-template-columns: repeat(2, minmax(0, 1fr));
        gap: 10px;
        margin-bottom: 10px;
      }
      .fkp-slots__card {
        padding: 12px 14px 13px;
        border-left: 3px solid transparent;
      }
      .fkp-slots__card.is-active {
        border-left-color: #337ab7;
        background: var(--fkp-s-fill);
      }
      .fkp-slots__card-top {
        display: flex;
        justify-content: space-between;
        align-items: flex-start;
        gap: 10px;
      }
      .fkp-slots__kicker {
        font-size: 10px;
        letter-spacing: .08em;
        text-transform: uppercase;
        opacity: .5;
        margin-bottom: 2px;
      }
      .fkp-slots__card h3,
      .fkp-slots__switch-head h3 {
        margin: 0;
        font-size: 15px;
        font-weight: 650;
        line-height: 1.3;
      }
      .fkp-slots__hint {
        margin: 6px 0 10px;
        font-size: 12px;
        line-height: 1.4;
        opacity: .7;
      }
      .fkp-slots__badge,
      .fkp-slots__ping {
        display: inline-flex;
        align-items: center;
        gap: 6px;
        flex: 0 0 auto;
        border-radius: 999px;
        padding: 2px 8px;
        font-size: 11px;
        line-height: 1.4;
        border: 1px solid var(--fkp-s-line);
        white-space: nowrap;
      }
      .fkp-slots__meta {
        display: grid;
        grid-template-columns: repeat(3, minmax(0, 1fr));
        gap: 8px;
        margin: 0 0 12px;
        padding: 8px 0;
        border-top: 1px solid var(--fkp-s-line);
        border-bottom: 1px solid var(--fkp-s-line);
      }
      .fkp-slots__meta dt {
        margin: 0;
        font-size: 11px;
        opacity: .55;
      }
      .fkp-slots__meta dd {
        margin: 2px 0 0;
        font-size: 13px;
        font-weight: 600;
      }
      .fkp-slots__actions {
        display: flex;
        flex-wrap: wrap;
        gap: 8px;
        align-items: center;
        position: relative;
        z-index: 2;
      }
      .fkp-slots__actions .fkp-slots__btn,
      .fkp-slots button.fkp-slots__btn,
      button.fkp-slots__btn {
        display: inline-block !important;
        box-sizing: border-box !important;
        position: relative !important;
        z-index: 5 !important;
        width: auto !important;
        min-width: 7.5em !important;
        max-width: 100% !important;
        height: 32px !important;
        min-height: 32px !important;
        margin: 0 !important;
        padding: 0 12px !important;
        border-radius: 4px !important;
        border-style: solid !important;
        border-width: 1px !important;
        font-size: 12px !important;
        font-weight: 600 !important;
        line-height: 30px !important;
        letter-spacing: 0 !important;
        white-space: nowrap !important;
        text-align: center !important;
        text-decoration: none !important;
        text-indent: 0 !important;
        text-shadow: none !important;
        background-image: none !important;
        box-shadow: none !important;
        appearance: none !important;
        -webkit-appearance: none !important;
        cursor: pointer !important;
        pointer-events: auto !important;
        touch-action: manipulation;
        opacity: 1;
        color: inherit;
        vertical-align: middle;
      }
      .fkp-slots button.fkp-slots__btn--primary {
        background: #337ab7 !important;
        border-color: #337ab7 !important;
        color: #fff !important;
        -webkit-text-fill-color: #fff !important;
      }
      .fkp-slots button.fkp-slots__btn--save {
        background: #2e8b57 !important;
        border-color: #2e8b57 !important;
        color: #fff !important;
        -webkit-text-fill-color: #fff !important;
      }
      .fkp-slots button.fkp-slots__btn--ghost {
        background: #fff !important;
        border-color: #888 !important;
        color: #333 !important;
        -webkit-text-fill-color: #333 !important;
      }
      .fkp-slots button.fkp-slots__btn:disabled {
        opacity: .42 !important;
        cursor: not-allowed !important;
        pointer-events: none !important;
      }
      .fkp-slots__switch { padding: 12px 14px 14px; }
      .fkp-slots__switch-head {
        display: flex;
        justify-content: space-between;
        align-items: center;
        gap: 12px;
        margin-bottom: 12px;
      }
      .fkp-slots__dot {
        width: 8px;
        height: 8px;
        border-radius: 50%;
        background: #8a8a8a;
        display: inline-block;
      }
      .fkp-slots__dot.is-ok { background: var(--fkp-s-ok); }
      .fkp-slots__dot.is-bad { background: var(--fkp-s-bad); }
      .fkp-slots__form {
        display: grid;
        grid-template-columns: minmax(0, 1.3fr) minmax(0, 1.3fr) 88px 108px auto;
        gap: 10px 12px;
        align-items: start;
      }
      .fkp-slots__field > label {
        display: block;
        font-size: 12px;
        opacity: .7;
        margin: 0 0 4px;
      }
      .fkp-slots input[type="text"],
      .fkp-slots input[type="number"] {
        display: block;
        width: 100%;
        box-sizing: border-box;
        height: 32px;
        min-height: 32px;
        padding: 4px 8px;
        text-align: left;
      }
      .fkp-slots__rtt {
        display: block;
        margin-top: 4px;
        min-height: 16px;
        font-size: 11px;
        font-weight: 600;
        opacity: .75;
      }
      .fkp-slots__rtt.is-ok { color: var(--fkp-s-ok); opacity: 1; }
      .fkp-slots__rtt.is-bad { color: var(--fkp-s-bad); opacity: 1; }
      .fkp-slots label.fkp-slots__check {
        display: flex;
        align-items: center;
        gap: 8px;
        font-size: 13px;
        font-weight: 600;
        margin: 22px 0 0;
        white-space: nowrap;
        opacity: 1;
      }
      .fkp-slots__check input { margin: 0; }
      .fkp-slots__radios {
        display: flex;
        flex-wrap: wrap;
        gap: 8px 18px;
        margin: 4px 0 0;
      }
      .fkp-slots__radios .fkp-slots__check { margin: 0; }
      .fkp-slots__field--wide { grid-column: 1 / -1; }
      .fkp-slots__switch .fkp-slots__hint { margin: 10px 0; }
      @media (max-width: 960px) {
        .fkp-slots__grid,
        .fkp-slots__form,
        .fkp-slots__meta { grid-template-columns: 1fr; }
        .fkp-slots__switch-head,
        .fkp-slots__card-top { flex-wrap: wrap; }
        .fkp-slots__check { margin-top: 4px; }
      }
      #cbi-forkop-slots-_slots_panel > .cbi-value-title { display: none; }
      #cbi-forkop-slots-_slots_panel > .cbi-value-field { margin-left: 0; width: 100%; }
    </style>
    <p class="fkp-slots__lead">${escapeHtml(_("Save the current Forkop config into a slot. Auto-switch applies the online slot if any host answers and the offline slot only if every host is down."))}</p>
    <div class="fkp-slots__grid">
      ${slotCard("online", payload.online, payload.active)}
      ${slotCard("offline", payload.offline, payload.active)}
    </div>
    <section class="fkp-slots__switch">
      <div class="fkp-slots__switch-head">
        <div>
          <div class="fkp-slots__kicker">${escapeHtml(_("Automatic switch"))}</div>
          <h3>${escapeHtml(_("Switch by ping"))}</h3>
        </div>
        <span class="fkp-slots__ping ${payload.last_check ? (payload.last_ok ? "is-ok" : "") : ""}">
          <span class="fkp-slots__dot ${payload.last_check ? (payload.last_ok ? "is-ok" : "is-bad") : ""}"></span>
          ${escapeHtml(pingLabel)}
        </span>
      </div>
      <div class="fkp-slots__form">
        ${renderHostField("forkop-slots-host", "host", _("Primary host to ping"), host, "1.1.1.1", payload)}
        ${renderHostField("forkop-slots-host-backup", "host-backup", _("Backup host to ping"), backupHost, "8.8.8.8", payload)}
        <div class="fkp-slots__field">
          <label for="forkop-slots-interval">${escapeHtml(_("Interval, sec"))}</label>
          <input id="forkop-slots-interval" data-slot-field="interval" type="number" min="10" step="5" value="${escapeHtml(interval)}">
        </div>
        <div class="fkp-slots__field">
          <label for="forkop-slots-fails">${escapeHtml(_("Checks before switch"))}</label>
          <input id="forkop-slots-fails" data-slot-field="fails" type="number" min="1" max="10" value="${escapeHtml(failCount)}">
        </div>
        <label class="fkp-slots__check">
          <input id="forkop-slots-enabled" data-slot-field="enabled" type="checkbox" ${enabled ? "checked" : ""}>
          ${escapeHtml(_("Enable auto-switch"))}
        </label>
        <div class="fkp-slots__field fkp-slots__field--wide">
          <label>${escapeHtml(_("Ping scheduler"))}</label>
          <div class="fkp-slots__radios">
            <label class="fkp-slots__check">
              <input data-slot-field="scheduler" name="forkop-slots-scheduler" type="radio" value="worker" ${scheduler !== "cron" ? "checked" : ""}>
              ${escapeHtml(_("Built-in worker"))}
            </label>
            <label class="fkp-slots__check">
              <input data-slot-field="scheduler" name="forkop-slots-scheduler" type="radio" value="cron" ${scheduler === "cron" ? "checked" : ""}>
              ${escapeHtml(_("System cron"))}
            </label>
          </div>
          <p class="fkp-slots__hint">${escapeHtml(_("Worker runs only while Forkop is started and does not spam syslog. Cron keeps checking every minute even if Forkop is stopped; BusyBox logs each run as cron.err."))}</p>
        </div>
      </div>
      <p class="fkp-slots__hint">${escapeHtml(_("These switch settings are written into the live config and every saved slot at the same time."))}</p>
      <div class="fkp-slots__actions">
        ${slotButton(`data-slot-configure="1"${slotsBusy ? " disabled" : ""}`, _("Save switch settings"), "save")}
        ${slotButton(`data-slot-probe="1"${slotsBusy ? " disabled" : ""}`, _("Check ping now"), "ghost")}
      </div>
    </section>
  </div>`;
}

function confirmSlotSave(kind) {
  const slotName = kind === "online" ? _("Online slot") : _("Offline slot");
  const question = _("Overwrite this slot with the current Forkop config?");
  let ok = false;
  try {
    ok = window.confirm(question + "\n\n" + slotName);
  } catch (_error) {
    ok = true;
  }
  if (ok) runAction(["slot_save", kind], _("Config saved to slot"));
}

function scopedField(fromEl, name) {
  let scope = document;
  if (fromEl && typeof fromEl.closest === "function") {
    const root = fromEl.closest(".fkp-slots") || fromEl.closest(".fkp-slots-root");
    if (root) scope = root;
  }
  const named = scope.querySelector("[data-slot-field='" + name + "']");
  if (named) return named;
  return document.getElementById("forkop-slots-" + name);
}

function collectSwitchArgs(fromEl) {
  const host = scopedField(fromEl, "host");
  const backupHostField = scopedField(fromEl, "host-backup");
  const interval = scopedField(fromEl, "interval");
  const fails = scopedField(fromEl, "fails");
  const enabled = scopedField(fromEl, "enabled");
  let scheduler = "worker";
  let scope = document;
  if (fromEl && typeof fromEl.closest === "function") {
    const root = fromEl.closest(".fkp-slots") || fromEl.closest(".fkp-slots-root");
    if (root) scope = root;
  }
  const radios = scope.querySelectorAll("[data-slot-field='scheduler']");
  for (let i = 0; i < radios.length; i++) {
    if (radios[i].checked && radios[i].value) scheduler = radios[i].value;
  }
  if (scheduler !== "cron") scheduler = "worker";
  return [
    "slot_configure",
    "enabled=" + (enabled && enabled.checked ? "1" : "0"),
    "host=" + ((host && host.value) || "1.1.1.1"),
    "backup_host=" + ((backupHostField && backupHostField.value) || ""),
    "interval=" + ((interval && interval.value) || "30"),
    "fail_count=" + ((fails && fails.value) || "2"),
    "scheduler=" + scheduler,
  ];
}

function collectProbeArgs(fromEl) {
  const host = scopedField(fromEl, "host");
  const backupHostField = scopedField(fromEl, "host-backup");
  return [
    "slot_probe",
    "host=" + ((host && host.value) || ""),
    "backup_host=" + ((backupHostField && backupHostField.value) || ""),
  ];
}

function closestSlotControl(node) {
  let el = node;
  if (el && el.nodeType === 3) el = el.parentNode;
  while (el && el !== document && el !== document.body && el !== document.documentElement) {
    if (el.getAttribute && (
      el.hasAttribute("data-slot-save") ||
      el.hasAttribute("data-slot-apply") ||
      el.hasAttribute("data-slot-configure") ||
      el.hasAttribute("data-slot-probe")
    )) {
      return el;
    }
    el = el.parentNode;
  }
  return null;
}

function activateSlotControl(el) {
  if (!el) return false;
  if (el.disabled || (el.hasAttribute && el.hasAttribute("disabled"))) return false;
  const key = [
    el.getAttribute("data-slot-save") || "",
    el.getAttribute("data-slot-apply") || "",
    el.hasAttribute("data-slot-configure") ? "cfg" : "",
    el.hasAttribute("data-slot-probe") ? "probe" : "",
  ].join("|");
  const now = Date.now();
  if (key && key === lastActKey && now - lastActAt < 500) return false;
  lastActAt = now;
  lastActKey = key;
  if (el.hasAttribute("data-slot-save")) {
    confirmSlotSave(el.getAttribute("data-slot-save"));
    return true;
  }
  if (el.hasAttribute("data-slot-apply")) {
    runAction(["slot_apply", el.getAttribute("data-slot-apply")], _("Slot applied. Forkop is reloading in the background."));
    return true;
  }
  if (el.hasAttribute("data-slot-configure")) {
    runAction(collectSwitchArgs(el), _("Switch settings saved"));
    return true;
  }
  if (el.hasAttribute("data-slot-probe")) {
    runAction(collectProbeArgs(el), _("Ping check finished"));
    return true;
  }
  return false;
}

function handleSlotClick(ev) {
  const el = closestSlotControl(ev && ev.target);
  if (!el) return;
  if (ev.preventDefault) ev.preventDefault();
  if (ev.stopPropagation) ev.stopPropagation();
  if (ev.stopImmediatePropagation) ev.stopImmediatePropagation();
  activateSlotControl(el);
}

function ensureDelegated() {
  if (window.__forkopSlotsClickBound) return;
  window.__forkopSlotsClickBound = true;
  document.addEventListener("click", handleSlotClick, true);
}

window.__forkopSlotsAct = function (el) {
  activateSlotControl(el);
  return false;
};

function bindActions(_payload) {
  ensureDelegated();
}

function eachSlotsRoot(fn) {
  const nodes = document.querySelectorAll("#forkop-slots-root, .fkp-slots-root");
  for (let i = 0; i < nodes.length; i++) fn(nodes[i]);
}

function mount(payload) {
  slotsSnapshot = payload;
  const html = renderSlots(payload);
  let found = false;
  eachSlotsRoot(function (node) {
    found = true;
    node.innerHTML = html;
  });
  if (!found) return;
  bindActions(payload);
}

function refreshSlots() {
  return fs
    .exec("/usr/bin/forkop", ["slot_status"])
    .then(function (result) { mount(parsePayload(result)); })
    .catch(function () { mount(parsePayload(null)); });
}

function runAction(args, successMessage) {
  if (slotsBusy) return;
  slotsBusy = true;
  mount(slotsSnapshot || parsePayload(null));
  const finish = function () {
    slotsBusy = false;
    refreshSlots();
  };
  try {
    const req = fs.exec("/usr/bin/forkop", args);
    if (!req || typeof req.then !== "function") {
      notify(_("Slot action failed"), "error");
      finish();
      return;
    }
    req.then(
      function (result) {
        const code = result && typeof result.code === "number" ? result.code : 1;
        if (code === 0) notify(successMessage, "info");
        else {
          const detail = result && (result.stderr || result.stdout);
          notify(
            detail ? _("Slot action failed") + ": " + String(detail).replace(/\s+/g, " ").slice(0, 180) : _("Slot action failed"),
            "error"
          );
        }
        finish();
      },
      function () {
        notify(_("Slot action failed"), "error");
        finish();
      }
    );
  } catch (_error) {
    notify(_("Slot action failed"), "error");
    finish();
  }
}

function createSlotsContent(section) {
  const panel = section.option(form.DummyValue, "_slots_panel");
  panel.rawhtml = true;
  panel.cfgvalue = function () {
    ensureDelegated();
    window.setTimeout(function () { refreshSlots(); }, 0);
    window.setTimeout(function () { refreshSlots(); }, 300);
    window.setTimeout(function () { refreshSlots(); }, 1200);
    return `<div id="forkop-slots-root" class="fkp-slots-root">${renderSlots(parsePayload(null))}</div>`;
  };
}

ensureDelegated();

return baseclass.extend({
  createSlotsContent,
});
