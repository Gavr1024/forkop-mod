"use strict";
"require view";
"require form";
"require baseclass";
"require uci";
"require ui";
"require fs";
"require dom";
"require view.forkop.main as main";

// Global settings
"require view.forkop.settings as settings";

// Sections
"require view.forkop.section as section";

// Server
"require view.forkop.server as server";

// Dashboard
"require view.forkop.dashboard as dashboard";

// Monitoring
"require view.forkop.monitoring as monitoring";

// Diagnostic
"require view.forkop.diagnostic as diagnostic";

// ByeDPI strategy check
"require view.forkop.byedpi_strategy as byedpiStrategy";

// Updates
"require view.forkop.updates as updates";

// Config slots
"require view.forkop.slots as slots";

const UCI_PACKAGE = main.FORKOP_UCI_PACKAGE;

const sectionListWarnings = {};
let sectionListWarningRequest = null;

function listWarningText(entry) {
  if (!entry) {
    return "";
  }
  const missing = Array.isArray(entry.missing)
    ? entry.missing.filter((name) => name)
    : [];
  const empty = Array.isArray(entry.empty)
    ? entry.empty.filter((name) => name)
    : [];
  const parts = [];
  if (missing.length) {
    parts.push(_("List has not downloaded: %s").format(missing.join(", ")));
  }
  if (empty.length) {
    parts.push(_("List file is empty: %s").format(empty.join(", ")));
  }
  return parts.join(". ");
}

function speedLimitNumber(section_id, key) {
  const raw = `${uci.get(UCI_PACKAGE, section_id, key) || ""}`.trim();
  if (!/^[0-9]+$/.test(raw)) {
    return 0;
  }
  const value = Number(raw);
  if (value < 1 || value > 10000) {
    return 0;
  }
  return value;
}

function sectionSpeedText(section_id) {
  const action = `${uci.get(UCI_PACKAGE, section_id, "action") || ""}`;
  if (
    ![
      "connection",
      "proxy",
      "outbound",
      "vpn",
      "zapret",
      "zapret2",
      "byedpi",
    ].includes(action)
  ) {
    return "";
  }
  const downOwn = speedLimitNumber(section_id, "speed_limit_down_mbit");
  const upOwn = speedLimitNumber(section_id, "speed_limit_up_mbit");
  let down = downOwn;
  let up = upOwn;
  if (!downOwn && !upOwn) {
    const legacy = speedLimitNumber(section_id, "speed_limit_mbit");
    if (!legacy) {
      return "";
    }
    down = legacy;
    up = legacy;
  }
  const none = _("no limit");
  const unit = _("Mbit/s");
  const downText = down ? down + " " + unit : none;
  const upText = up ? up + " " + unit : none;
  return _("Limit: download %s, upload %s").format(downText, upText);
}

function rememberSectionListWarnings(payload) {
  Object.keys(sectionListWarnings).forEach((key) => {
    delete sectionListWarnings[key];
  });
  const rows =
    payload && Array.isArray(payload.section_warnings)
      ? payload.section_warnings
      : [];
  rows.forEach((row) => {
    if (row && row.section) {
      sectionListWarnings[row.section] = row;
    }
  });
}

function applySectionListWarnings(root) {
  const scope =
    root && typeof root.querySelectorAll === "function" ? root : document;
  scope.querySelectorAll("tr[data-section-id]").forEach((row) => {
    const sectionId = row.getAttribute("data-section-id");
    const cell = row.querySelector("td.cbi-section-table-titles");
    if (!cell || !sectionId) {
      return;
    }
    cell.querySelectorAll(".fkp-section-speed, .fkp-section-list-warn").forEach((node) => {
      node.remove();
    });
    const speed = sectionSpeedText(sectionId);
    if (speed) {
      cell.appendChild(
        E(
          "div",
          {
            class: "fkp-section-speed",
            style:
              "display:block;margin-top:0.15rem;font-size:0.85em;font-weight:400;white-space:normal;opacity:0.85;",
          },
          speed,
        ),
      );
    }
    const text = listWarningText(sectionListWarnings[sectionId]);
    cell.appendChild(
      E(
        "div",
        {
          class: "fkp-section-list-warn",
          "data-fkp-list-warn": sectionId,
          style: `display:${text ? "block" : "none"};margin-top:0.15rem;color:#8a6d1d;font-size:0.85em;font-weight:400;white-space:normal;`,
        },
        text,
      ),
    );
  });
}

function loadSectionListWarnings() {
  if (sectionListWarningRequest) {
    return sectionListWarningRequest;
  }
  sectionListWarningRequest = fs
    .exec("/usr/bin/forkop", ["list_cache_status"])
    .then((result) => {
      const stdout = result && result.stdout ? String(result.stdout) : "";
      try {
        rememberSectionListWarnings(JSON.parse(stdout));
      } catch (_error) {
        rememberSectionListWarnings(null);
      }
      applySectionListWarnings(document);
    })
    .catch(() => {
      rememberSectionListWarnings(null);
    });
  return sectionListWarningRequest;
}

function renderSectionAdd(sectionRef, extra_class) {
  const el = form.GridSection.prototype.renderSectionAdd.apply(sectionRef, [
    extra_class,
  ]);
  const nameEl = el.querySelector(".cbi-section-create-name");

  ui.addValidator(
    nameEl,
    "uciname",
    true,
    (value) => {
      const button = el.querySelector(".cbi-section-create > .cbi-button-add");
      const uciconfig = sectionRef.uciconfig || sectionRef.map.config;

      if (!value) {
        button.disabled = true;
        return true;
      }

      if (uci.get(uciconfig, value)) {
        button.disabled = true;
        return _("Expecting: %s").format(_("unique UCI identifier"));
      }

      button.disabled = null;
      return true;
    },
    "blur",
    "keyup",
  );

  return el;
}

function getRuleEditButtonText() {
  const label = _("Edit rule action");

  return label === "Edit rule action" ? "Edit" : label;
}

function configureGridSection(sectionRef, type, title, addTitle) {
  sectionRef.anonymous = false;
  sectionRef.addremove = true;
  sectionRef.sortable = true;
  sectionRef.rowcolors = true;
  sectionRef.nodescriptions = true;
  sectionRef.modaltitle = function (section_id) {
    const label = uci.get(UCI_PACKAGE, section_id, "label");
    return section_id ? `${title}: ${label || section_id}` : addTitle;
  };
  sectionRef.sectiontitle = function (section_id) {
    return uci.get(UCI_PACKAGE, section_id, "label") || section_id;
  };
  sectionRef.renderSectionAdd = function (extra_class) {
    return renderSectionAdd(sectionRef, extra_class);
  };

  if (type === "section") {
    sectionRef.renderRowActions = function (section_id) {
      const td = form.TableSection.prototype.renderRowActions.call(
        this,
        section_id,
        getRuleEditButtonText(),
      );
      const actions = td.querySelector("div") || td;
      const copyLabel = "Копировать";
      const button = E(
        "button",
        {
          class: "btn cbi-button cbi-button-action",
          title: _(
            "Make a second section with the same lists, DNS and devices",
          ),
          click: ui.createHandlerFn(
            this,
            function (id, ev) {
              if (ev && typeof ev.preventDefault === "function") {
                ev.preventDefault();
              }
              section.cloneRoutingSection(id);
              return this.map && typeof this.map.reset === "function"
                ? this.map.reset()
                : null;
            },
            section_id,
          ),
          disabled: this.map.readonly || null,
        },
        copyLabel,
      );
      const removeButton = actions.querySelector(".cbi-button-remove");
      if (removeButton) {
        actions.insertBefore(button, removeButton);
      } else {
        actions.appendChild(button);
      }
      return td;
    };
    const previousRender = sectionRef.render;
    sectionRef.render = function () {
      const rendered = previousRender.apply(this, arguments);
      return Promise.resolve(rendered).then((node) => {
        applySectionListWarnings(node);
        return loadSectionListWarnings().then(() => {
          applySectionListWarnings(node);
          return node;
        });
      });
    };
    loadSectionListWarnings();
  }
}

const EntryPoint = {
  async render() {
    main.injectGlobalStyles();
    const uiCapabilities = {
      loaded: false,
      singBoxExtended: false,
      singBoxTiny: false,
      singBoxTailscale: true,
      singBoxOpenConnect: false,
      singBoxVersion: "",
      zapretInstalled: false,
      zapret2Installed: false,
      byedpiInstalled: false,
      xrayInstalled: false,
      serverInboundsEnabledCount: -1,
    };
    let uiCapabilitiesPromise = null;
    let serverSectionRef = null;

    const applyUiCapabilities = function () {
      if (serverSectionRef) {
        server.applyServerCapabilities(serverSectionRef, uiCapabilities);
      }

      if (typeof window !== "undefined") {
        window.dispatchEvent(
          new CustomEvent(main.FORKOP_ACTION_PROVIDERS_AVAILABILITY_EVENT, {
            detail: {
              zapretInstalled: uiCapabilities.zapretInstalled,
              zapret2Installed: uiCapabilities.zapret2Installed,
              byedpiInstalled: uiCapabilities.byedpiInstalled,
              xrayInstalled: uiCapabilities.xrayInstalled,
              singBoxOpenConnect: uiCapabilities.singBoxOpenConnect,
              singBoxVersion: uiCapabilities.singBoxVersion,
            },
          }),
        );
      }

      if (main.store && typeof main.store.set === "function") {
        const currentSystemInfo = main.store.get().diagnosticsSystemInfo;
        main.store.set({
          diagnosticsSystemInfo: {
            ...currentSystemInfo,
            providerInfoLoaded: true,
            sing_box_extended: uiCapabilities.singBoxExtended ? 1 : 0,
            sing_box_tiny: uiCapabilities.singBoxTiny ? 1 : 0,
            sing_box_tailscale: uiCapabilities.singBoxTailscale ? 1 : 0,
            zapret_installed: uiCapabilities.zapretInstalled ? 1 : 0,
            zapret2_installed: uiCapabilities.zapret2Installed ? 1 : 0,
            byedpi_installed: uiCapabilities.byedpiInstalled ? 1 : 0,
            xray_installed: uiCapabilities.xrayInstalled ? 1 : 0,
            server_inbounds_enabled_count:
              uiCapabilities.serverInboundsEnabledCount,
            zapret_version: uiCapabilities.zapretInstalled
              ? currentSystemInfo.zapret_version
              : "not installed",
            zapret2_version: uiCapabilities.zapret2Installed
              ? currentSystemInfo.zapret2_version
              : "not installed",
            byedpi_version: uiCapabilities.byedpiInstalled
              ? currentSystemInfo.byedpi_version
              : "not installed",
            xray_version: uiCapabilities.xrayInstalled
              ? currentSystemInfo.xray_version
              : "not installed",
          },
        });
      }
    };

    const updateUiCapabilities = function (data) {
      uiCapabilities.loaded = true;
      uiCapabilities.singBoxExtended = Boolean(
        Number(data?.sing_box_extended) === 1,
      );
      uiCapabilities.singBoxTiny = Boolean(Number(data?.sing_box_tiny) === 1);
      uiCapabilities.singBoxTailscale =
        typeof data?.sing_box_tailscale === "undefined"
          ? true
          : Boolean(Number(data.sing_box_tailscale) === 1);
      uiCapabilities.zapretInstalled = Boolean(
        Number(data?.zapret_installed) === 1,
      );
      uiCapabilities.zapret2Installed = Boolean(
        Number(data?.zapret2_installed) === 1,
      );
      uiCapabilities.byedpiInstalled = Boolean(
        Number(data?.byedpi_installed) === 1,
      );
      uiCapabilities.xrayInstalled = Boolean(
        Number(data?.xray_installed) === 1,
      );
      uiCapabilities.singBoxOpenConnect = Boolean(
        Number(data?.sing_box_openconnect) === 1,
      );
      uiCapabilities.singBoxVersion = `${data?.sing_box_version || ""}`.trim();
      const serverInboundsEnabledCount =
        typeof data?.server_inbounds_enabled_count !== "undefined"
          ? Number(data.server_inbounds_enabled_count)
          : -1;
      uiCapabilities.serverInboundsEnabledCount = Number.isFinite(
        serverInboundsEnabledCount,
      )
        ? serverInboundsEnabledCount
        : -1;

      applyUiCapabilities();

      return uiCapabilities;
    };

    const applyUiState = function (data) {
      const result = updateUiCapabilities(data?.capabilities || data || {});

      if (typeof main.applyUiStateToStore === "function" && data?.service) {
        main.applyUiStateToStore(data);
      } else if (
        main.store &&
        typeof main.store.set === "function" &&
        data?.service
      ) {
        main.store.set({
          servicesInfoWidget: {
            loading: false,
            failed: false,
            data: {
              singbox: Number(data.service.sing_box?.running) || 0,
              forkopRunning: Number(data.service.forkop?.running) || 0,
              forkopEnabled: Number(data.service.forkop?.enabled) || 0,
              forkopStatus: data.service.forkop?.status || "",
            },
          },
        });
      }

      return result;
    };

    const loadFallbackUiCapabilities = function () {
      return Promise.allSettled([
        main.ForkopShellMethods.getServerCapabilities(),
        main.ForkopShellMethods.checkZapretRuntime(),
        main.ForkopShellMethods.checkZapret2Runtime(),
        main.ForkopShellMethods.checkByedpiRuntime(),
        main.ForkopShellMethods.checkInboundsConfig(),
      ]).then(
        ([
          serverCapabilitiesResult,
          zapretRuntimeResult,
          zapret2RuntimeResult,
          byedpiRuntimeResult,
          inboundsConfigResult,
        ]) => {
          const serverCapabilities =
            serverCapabilitiesResult.status === "fulfilled"
              ? serverCapabilitiesResult.value
              : null;
          const zapretRuntime =
            zapretRuntimeResult.status === "fulfilled"
              ? zapretRuntimeResult.value
              : null;
          const zapret2Runtime =
            zapret2RuntimeResult.status === "fulfilled"
              ? zapret2RuntimeResult.value
              : null;
          const byedpiRuntime =
            byedpiRuntimeResult.status === "fulfilled"
              ? byedpiRuntimeResult.value
              : null;
          const inboundsConfig =
            inboundsConfigResult.status === "fulfilled"
              ? inboundsConfigResult.value
              : null;

          return updateUiCapabilities({
            sing_box_extended:
              serverCapabilities?.success &&
              Number(serverCapabilities.data?.sing_box_extended) === 1
                ? 1
                : 0,
            sing_box_tiny:
              serverCapabilities?.success &&
              Number(serverCapabilities.data?.sing_box_tiny) === 1
                ? 1
                : 0,
            sing_box_tailscale:
              !serverCapabilities?.success ||
              typeof serverCapabilities.data?.sing_box_tailscale ===
                "undefined" ||
              Number(serverCapabilities.data?.sing_box_tailscale) === 1
                ? 1
                : 0,
            zapret_installed:
              zapretRuntime?.success &&
              Number(zapretRuntime.data?.zapret_installed) === 1
                ? 1
                : 0,
            zapret2_installed:
              zapret2Runtime?.success &&
              Number(zapret2Runtime.data?.zapret2_installed) === 1
                ? 1
                : 0,
            byedpi_installed:
              byedpiRuntime?.success &&
              Number(byedpiRuntime.data?.byedpi_installed) === 1
                ? 1
                : 0,
            server_inbounds_enabled_count:
              inboundsConfig?.success &&
              typeof inboundsConfig.data?.enabled_count !== "undefined"
                ? inboundsConfig.data.enabled_count
                : -1,
          });
        },
      );
    };

    const loadUiCapabilities = function () {
      if (uiCapabilities.loaded) {
        return Promise.resolve(uiCapabilities);
      }

      if (uiCapabilitiesPromise) {
        return uiCapabilitiesPromise;
      }

      uiCapabilitiesPromise = main.ForkopShellMethods.getUiCapabilities()
        .then((response) => {
          if (!response?.success) {
            throw new Error("UI capabilities request failed");
          }

          return updateUiCapabilities(response.data);
        })
        .catch((error) => {
          console.warn("Failed to load Forkop UI capabilities", error);
          return main.ForkopShellMethods.getUiState()
            .then((response) => {
              if (!response?.success) {
                throw new Error("UI state request failed");
              }

              return applyUiState(response.data);
            })
            .catch((fallbackError) => {
              console.warn("Failed to load Forkop UI state", fallbackError);
              return loadFallbackUiCapabilities();
            });
        })
        .finally(() => {
          uiCapabilitiesPromise = null;
        });

      return uiCapabilitiesPromise;
    };
    const forkopMap = new form.Map(
      UCI_PACKAGE,
      _("Forkop Settings"),
      _("Configuration for Forkop service"),
    );
    forkopMap.tabbed = true;
    const originalHandleSaveApply = forkopMap.handleSaveApply;
    forkopMap.handleSaveApply = function (ev, mode) {
      const refreshUiState = function () {
        main.ForkopShellMethods.getUiState()
          .then((response) => {
            if (
              response?.success &&
              typeof main.applyUiStateToStore === "function"
            ) {
              main.applyUiStateToStore(response.data);
            }
          })
          .catch(() => null);
      };

      if (main.store && typeof main.store.set === "function") {
        const servicesInfoWidget = main.store.get().servicesInfoWidget;
        main.store.set({
          servicesInfoWidget: {
            ...servicesInfoWidget,
            data: {
              ...servicesInfoWidget.data,
              forkopStatus: "reloading",
            },
          },
        });
      }

      return Promise.resolve(originalHandleSaveApply.call(this, ev, mode))
        .then((result) => {
          window.setTimeout(refreshUiState, 250);

          return result;
        })
        .catch((error) => {
          refreshUiState();

          throw error;
        });
    };

    const rulesSection = forkopMap.section(
      form.GridSection,
      "section",
      _("Sections"),
      _("Drag rows to change priority. The rule at the top is checked first."),
    );
    configureGridSection(
      rulesSection,
      "section",
      _("Section"),
      _("Add a section"),
    );
    section.configureSectionSection(rulesSection, {
      loadActionProvidersAvailability: loadUiCapabilities,
    });
    section.createSectionContent(rulesSection);

    const serverSection = forkopMap.section(
      form.GridSection,
      "server",
      _("Servers"),
      _("Accept external proxy connections and route them with the selected routing engine."),
    );
    configureGridSection(
      serverSection,
      "server",
      _("Server"),
      _("Add a server inbound"),
    );
    serverSectionRef = serverSection;
    server.configureServerSection(serverSection, {
      loadCapabilities: loadUiCapabilities,
    });
    server.createServerContent(serverSection, uiCapabilities);

    const settingsSection = forkopMap.section(
      form.TypedSection,
      "settings",
      _("Settings"),
    );
    settingsSection.anonymous = true;
    settingsSection.addremove = false;
    settingsSection.cfgsections = function () {
      return ["settings"];
    };
    settings.createSettingsContent(settingsSection, uiCapabilities);

    const slotsSection = forkopMap.section(
      form.TypedSection,
      "slots",
      _("Config slots"),
    );
    slotsSection.anonymous = true;
    slotsSection.addremove = false;
    slotsSection.cfgsections = function () {
      return ["slots"];
    };
    slots.createSlotsContent(slotsSection);

    const diagnosticSection = forkopMap.section(
      form.TypedSection,
      "diagnostic",
      _("Diagnostics"),
    );
    diagnosticSection.anonymous = true;
    diagnosticSection.addremove = false;
    diagnosticSection.cfgsections = function () {
      return ["diagnostic"];
    };
    diagnostic.createDiagnosticContent(diagnosticSection);

    const byedpiStrategySection = forkopMap.section(
      form.TypedSection,
      "byedpi_strategy",
      _("ByeDPI"),
    );
    byedpiStrategySection.anonymous = true;
    byedpiStrategySection.addremove = false;
    byedpiStrategySection.cfgsections = function () {
      return ["byedpi_strategy"];
    };
    byedpiStrategy.createByedpiStrategyContent(byedpiStrategySection);

    const dashboardSection = forkopMap.section(
      form.TypedSection,
      "dashboard",
      _("Dashboard"),
    );
    dashboardSection.anonymous = true;
    dashboardSection.addremove = false;
    dashboardSection.cfgsections = function () {
      return ["dashboard"];
    };
    dashboard.createDashboardContent(dashboardSection);

    const monitoringSection = forkopMap.section(
      form.TypedSection,
      "monitoring",
      _("Monitoring"),
    );
    monitoringSection.anonymous = true;
    monitoringSection.addremove = false;
    monitoringSection.cfgsections = function () {
      return ["monitoring"];
    };
    monitoring.createMonitoringContent(monitoringSection);

    const updatesSection = forkopMap.section(
      form.TypedSection,
      "updates",
      _("Components"),
    );
    updatesSection.anonymous = true;
    updatesSection.addremove = false;
    updatesSection.cfgsections = function () {
      return ["updates"];
    };
    updates.createUpdatesContent(updatesSection);

    let syncingRoutingTabs = false;

    function syncByedpiStrategyTab() {
      const visible = uiCapabilities.byedpiInstalled === true;
      const tabs = document.querySelectorAll(
        '.cbi-tabmenu [data-tab="byedpi_strategy"]',
      );

      tabs.forEach((tab) => {
        tab.style.display = visible ? "" : "none";
      });

      if (visible) {
        return;
      }

      const active = document.querySelector(
        '.cbi-tabmenu [data-tab="byedpi_strategy"]',
      );

      if (!active || active.classList.contains("cbi-tab-disabled")) {
        return;
      }

      const fallback =
        document.querySelector('.cbi-tabmenu [data-tab="section"] a') ||
        document.querySelector(".cbi-tabmenu a");

      if (fallback && typeof fallback.click === "function") {
        fallback.click();
      }
    }

    if (typeof window !== "undefined") {
      window.addEventListener(
        main.FORKOP_ACTION_PROVIDERS_AVAILABILITY_EVENT,
        (event) => {
          if (
            event &&
            event.detail &&
            typeof event.detail.byedpiInstalled !== "undefined"
          ) {
            uiCapabilities.byedpiInstalled = Boolean(event.detail.byedpiInstalled);
          }

          syncByedpiStrategyTab();
        },
      );
    }
    function refreshOpenModalMaps() {
      document.querySelectorAll("#modal_overlay .cbi-map").forEach((node) => {
        if (node.classList.contains("hidden")) {
          return;
        }

        const inst = dom.findClassInstance(node);
        if (
          !inst ||
          inst === forkopMap ||
          inst.forkopEngineRefresh ||
          typeof inst.checkDepends !== "function"
        ) {
          return;
        }

        inst.forkopEngineRefresh = true;
        try {
          inst.checkDepends();
        } catch (_error) {
          /* A stacked modal can render before its widgets are ready. */
        } finally {
          inst.forkopEngineRefresh = false;
        }
      });
    }

    function syncRoutingEngineTabs() {
      if (syncingRoutingTabs) {
        return;
      }

      syncingRoutingTabs = true;
      try {
        refreshOpenModalMaps();
        syncByedpiStrategyTab();
        if (serverSectionRef) {
          server.applyServerCapabilities(serverSectionRef, uiCapabilities);
        }
        server.syncServerVisibility();
      } finally {
        syncingRoutingTabs = false;
      }
    }

    const originalCheckDepends = forkopMap.checkDepends;
    forkopMap.checkDepends = function () {
      const result = originalCheckDepends.apply(this, arguments);
      syncRoutingEngineTabs();
      return result;
    };

    const originalRender = forkopMap.render;
    forkopMap.render = function () {
      return Promise.resolve(originalRender.apply(this, arguments)).then(
        (node) => {
          syncRoutingEngineTabs();
          syncByedpiStrategyTab();
          return node;
        },
      );
    };

    await loadUiCapabilities().catch(() => null);

    const rendered = await forkopMap.render();
    main.coreService({
      waitForLogWatcherStart: loadUiCapabilities,
      logWatcherStartDelayMs: 5000,
    });

    return rendered;
  },
};

return view.extend(EntryPoint);
