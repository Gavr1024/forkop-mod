import { onMount, preserveScrollForPage } from '../../../helpers';
import { FORKOP_ACTION_PROVIDERS_AVAILABILITY_EVENT } from '../../../constants';
import { normalizeCompiledVersion } from '../../../helpers/normalizeCompiledVersion';
import { showToast } from '../../../helpers/showToast';
import {
  renderDownloadIcon24,
  renderRotateCcwIcon24,
  renderSearchIcon24,
  renderXIcon24,
} from '../../../icons';
import { renderButton } from '../../../partials';
import { getComponentActionKey } from '../../helpers/getComponentActionKey';
import type { UpdatesActionKey } from '../../helpers/getComponentActionKey';
import { isTransientRpcError } from '../../helpers/isTransientRpcError';
import { isActiveLuciTab } from '../../helpers/isActiveLuciTab';
import { shouldShowLoadingForRestoredAction } from '../../helpers/restoredActionLoading';
import {
  formatSingBoxVersion,
  normalizeSingBoxVariantFields,
} from '../../helpers/singBoxVariant';
import {
  hasLocalMutatingServiceActionLoading,
  isServiceTransitionStatus,
} from '../diagnostic/serviceTransition';
import { shouldApplyCompletedComponentActionResult } from './componentActionCompletion';
import {
  shouldPreserveCompletedCheckResultOnNextMount,
  shouldExposeCheckResults,
  shouldRefreshComponentStateBeforeRender,
  shouldResetCheckResultsOnMount,
} from './checkResultLifecycle';
import { ForkopShellMethods } from '../../methods';
import {
  logger,
  markUiActionOwned,
  setLocalComponentAction,
  shouldNotifyOwnedUiAction,
  store,
  StoreType,
} from '../../services';
import { ensureSystemInfo } from '../../services/systemInfo.service';
import {
  getCachedRuntimeUiState,
  refreshRuntimeUiState,
  subscribeRuntimeUiState,
} from '../../services/runtimeUiState.service';
import { Forkop } from '../../types';

type UpdateStatus = StoreType['updatesChecks'][Forkop.ComponentName]['status'];

interface ComponentActionButton {
  key: UpdatesActionKey;
  text: string;
  icon: () => SVGSVGElement;
  component: Forkop.ComponentName;
  action: Forkop.ComponentAction;
}

interface ComponentCard {
  component: Forkop.ComponentName;
  column: 0 | 1;
  title: string;
  version: string;
  latestVersion?: string;
  releaseUrl?: string;
  actions: ComponentActionButton[];
}

let updatesLifecycleRegistered = false;
let updatesControllerInitialized = false;
let updatesMounted = false;
let updatesMountId = 0;
let pageUnloading = false;
let preserveCheckResultsOnNextMount = false;
let componentUpdateCheckCacheResolved = false;
let componentUpdateCheckCacheSnapshot: Forkop.ComponentUpdateCheckCache | null =
  null;
let componentUpdateCheckCachePromise: Promise<Forkop.ComponentUpdateCheckCache> | null =
  null;
let componentActionStateUnsubscribe: (() => void) | null = null;
const SING_BOX_EXTENDED_FALLBACK_VERSIONS = [
  '1.14.0-extended-2.7.1',
  '1.14.0-extended-2.7.0',
  '1.13.18-extended-2.6.5',
  '1.13.18-extended-2.6.4',
  '1.13.18-extended-2.6.3',
  '1.13.16-extended-2.6.2',
  '1.13.16-extended-2.6.1',
  '1.13.16-extended-2.6.0',
  '1.13.14-extended-2.5.3',
  '1.13.14-extended-2.5.2',
  '1.13.14-extended-2.5.1',
  '1.13.14-extended-2.5.0',
  '1.13.12-extended-2.4.1',
  '1.13.12-extended-2.4.0',
];
const XRAY_FALLBACK_VERSIONS = [
  '26.3.27',
  '26.3.16',
  '26.2.6',
  '25.12.8',
  '25.10.15',
  '25.9.11',
  '25.8.3',
  '25.6.8',
  '25.4.30',
  '25.3.6',
];
let singBoxAvailableVersions: string[] = [...SING_BOX_EXTENDED_FALLBACK_VERSIONS];
let singBoxVersionsLoading = false;
let singBoxSelectedVersion = '';
let xrayAvailableVersions: string[] = [...XRAY_FALLBACK_VERSIONS];
let xrayPrereleaseVersions: string[] = [];
let xrayVersionsLoading = false;
let xraySelectedVersion = '';
let xrayIncludePrerelease = false;
let coreVersionsLoading = false;
let componentActionStateRefreshPromise: Promise<void> | null = null;
const followedComponentJobs = new Set<string>();
const handledComponentJobs = new Set<string>();

if (typeof window !== 'undefined') {
  window.addEventListener('pagehide', () => {
    pageUnloading = true;
  });
  window.addEventListener('pageshow', () => {
    pageUnloading = false;
  });
}

function isNotInstalled(version: string | undefined) {
  return !version || version === 'not installed';
}

function shouldShowInstallAfterCheck(component: Forkop.ComponentName) {
  const status = getVisibleCheckResult(component)?.status;

  return status === 'outdated' || status === 'dev';
}

function getVisibleCheckResult(component: Forkop.ComponentName) {
  if (
    !shouldExposeCheckResults({
      mounted: updatesMounted,
      cacheResolved: componentUpdateCheckCacheResolved,
    })
  ) {
    return null;
  }

  return store.get().updatesChecks[component];
}

function getLatestVersion(component: Forkop.ComponentName) {
  const checkResult = getVisibleCheckResult(component);

  if (!checkResult || !shouldShowInstallAfterCheck(component)) {
    return undefined;
  }

  return checkResult.latest_version || undefined;
}

function getGitHubReleaseUrl(component: Forkop.ComponentName) {
  const checkResult = getVisibleCheckResult(component);

  if (
    !checkResult ||
    !shouldShowInstallAfterCheck(component) ||
    !checkResult.release_url
  ) {
    return undefined;
  }

  return checkResult.release_url;
}

function isAnyActionLoading() {
  return Object.values(store.get().updatesActions).some((item) => item.loading);
}

function isServiceRuntimeActionLoading() {
  const state = store.get();

  return (
    hasLocalMutatingServiceActionLoading(state.diagnosticsActions) ||
    isServiceTransitionStatus(state.servicesInfoWidget.data.forkopStatus)
  );
}

function isSystemInfoLoading() {
  const systemInfo = store.get().diagnosticsSystemInfo;

  return systemInfo.loading || !systemInfo.loaded;
}

function setActionLoading(
  action: UpdatesActionKey,
  loading: boolean,
  local = false,
) {
  if (local || !loading) {
    setLocalComponentAction(action, loading && local);
  }

  const updatesActions = store.get().updatesActions;

  store.set({
    updatesActions: {
      ...updatesActions,
      [action]: { loading },
    },
  });
}

function beginComponentAction(button: ComponentActionButton) {
  if (isAnyActionLoading()) {
    return false;
  }

  setActionLoading(button.key, true, true);
  return true;
}

function setCheckResult(
  component: Forkop.ComponentName,
  status: UpdateStatus,
  latestVersion: string,
  releaseUrl: string = '',
) {
  const updatesChecks = store.get().updatesChecks;

  store.set({
    updatesChecks: {
      ...updatesChecks,
      [component]: {
        status,
        latest_version: latestVersion,
        release_url: releaseUrl,
      },
    },
  });
}

function resetCheckResult(component: Forkop.ComponentName) {
  setCheckResult(component, null, '');
}

function applyCachedCheckResults(results: Forkop.ComponentActionResult[]) {
  results.forEach((result) => {
    const status = result.status || null;

    if (Array.isArray(result.available_versions) && result.component === 'sing_box') {
      singBoxAvailableVersions = result.available_versions.filter(Boolean);
      if (
        singBoxSelectedVersion &&
        !singBoxAvailableVersions.includes(singBoxSelectedVersion)
      ) {
        singBoxSelectedVersion = '';
      }
    }

    if (Array.isArray(result.available_versions) && result.component === 'xray') {
      xrayAvailableVersions = result.available_versions.filter(Boolean);
      xrayPrereleaseVersions = Array.isArray(result.prerelease_versions)
        ? result.prerelease_versions.filter(Boolean)
        : [];
      if (
        xraySelectedVersion &&
        !visibleXrayVersionTags().includes(xraySelectedVersion)
      ) {
        xraySelectedVersion = '';
      }
    }

    if (status === 'latest' || status === 'outdated' || status === 'dev') {
      setCheckResult(
        result.component,
        status,
        result.latest_version || '',
        result.release_url || '',
      );
    }
  });
}

function loadComponentUpdateCheckCache({ force = false } = {}) {
  if (!force && componentUpdateCheckCacheSnapshot) {
    return Promise.resolve(componentUpdateCheckCacheSnapshot);
  }

  if (componentUpdateCheckCachePromise) {
    return componentUpdateCheckCachePromise;
  }

  const promise = ForkopShellMethods.componentUpdateCheckCache()
    .then((response) =>
      response.success
        ? response.data
        : ({
            enabled: false,
            results: [],
          } satisfies Forkop.ComponentUpdateCheckCache),
    )
    .then((cache) => {
      componentUpdateCheckCacheSnapshot = cache;
      return cache;
    })
    .finally(() => {
      if (componentUpdateCheckCachePromise === promise) {
        componentUpdateCheckCachePromise = null;
      }
    });

  componentUpdateCheckCachePromise = promise;
  return promise;
}

function getErrorMessage(error: unknown, fallback: string) {
  return error instanceof Error && error.message ? error.message : fallback;
}

async function ackComponentActionJob(jobId: string) {
  try {
    const response = await ForkopShellMethods.uiActionAck('component', jobId);

    if (!response.success) {
      logger.debug('[UPDATES]', 'component action ack failed', response.error);
    }
  } catch (error) {
    logger.debug('[UPDATES]', 'component action ack failed', error);
  }
}

function getExpectedLatestVersionForAction(button: ComponentActionButton) {
  if (button.component !== 'forkop' || button.action !== 'install') {
    return undefined;
  }

  return (
    store.get().updatesChecks[button.component].latest_version || undefined
  );
}

function getCheckToastMessage(status: UpdateStatus) {
  if (status === 'outdated') {
    return _('Update is available');
  }

  if (status === 'dev') {
    return _('Installed version is newer than release');
  }

  return _('Latest version is installed');
}

async function refreshSystemInfoAfterMutation() {
  await ensureSystemInfo({ force: true, silent: true });
}

function notifyActionProvidersAvailabilityChanged(
  systemInfo: StoreType['diagnosticsSystemInfo'],
) {
  if (typeof window === 'undefined' || typeof CustomEvent === 'undefined') {
    return;
  }

  window.dispatchEvent(
    new CustomEvent(FORKOP_ACTION_PROVIDERS_AVAILABILITY_EVENT, {
      detail: {
        zapretInstalled: Boolean(systemInfo.zapret_installed),
        zapret2Installed: Boolean(systemInfo.zapret2_installed),
        byedpiInstalled: Boolean(systemInfo.byedpi_installed),
      },
    }),
  );
}

function reloadPageAfterForkopUpdate() {
  window.setTimeout(() => {
    window.location.reload();
  }, 1200);
}

function patchSystemInfoAfterMutation(result: Forkop.ComponentActionResult) {
  const systemInfo = store.get().diagnosticsSystemInfo;
  const nextSystemInfo = { ...systemInfo, loading: false, loaded: true };
  const version =
    result.current_version || result.latest_version || _('unknown');

  if (result.component === 'forkop' && result.action === 'install') {
    nextSystemInfo.forkop_version = version;
  }

  if (result.component === 'sing_box') {
    nextSystemInfo.sing_box_version = version;

    if (result.action === 'install_extended') {
      nextSystemInfo.sing_box_extended = 1;
      nextSystemInfo.sing_box_tiny = 0;
      nextSystemInfo.sing_box_compressed = 0;
      nextSystemInfo.sing_box_tailscale = 1;
    }

    if (result.action === 'install_extended_compressed') {
      nextSystemInfo.sing_box_extended = 1;
      nextSystemInfo.sing_box_tiny = 0;
      nextSystemInfo.sing_box_compressed = 1;
      nextSystemInfo.sing_box_tailscale = 1;
    }

    if (result.action === 'install_stable') {
      nextSystemInfo.sing_box_extended = 0;
      nextSystemInfo.sing_box_tiny = 0;
      nextSystemInfo.sing_box_compressed = 0;
      nextSystemInfo.sing_box_tailscale = 1;
    }

    if (result.action === 'install_tiny') {
      nextSystemInfo.sing_box_extended = 0;
      nextSystemInfo.sing_box_tiny = 1;
      nextSystemInfo.sing_box_compressed = 0;
      nextSystemInfo.sing_box_tailscale = 0;
    }
  }

  if (result.component === 'zapret') {
    nextSystemInfo.providerInfoLoaded = true;

    if (result.action === 'remove') {
      nextSystemInfo.zapret_installed = 0;
      nextSystemInfo.zapret_version = 'not installed';
    } else {
      nextSystemInfo.zapret_installed = 1;
      nextSystemInfo.zapret_version = version;
    }
  }

  if (result.component === 'zapret2') {
    nextSystemInfo.providerInfoLoaded = true;

    if (result.action === 'remove') {
      nextSystemInfo.zapret2_installed = 0;
      nextSystemInfo.zapret2_version = 'not installed';
    } else {
      nextSystemInfo.zapret2_installed = 1;
      nextSystemInfo.zapret2_version = version;
    }
  }

  if (result.component === 'byedpi') {
    nextSystemInfo.providerInfoLoaded = true;

    if (result.action === 'remove') {
      nextSystemInfo.byedpi_installed = 0;
      nextSystemInfo.byedpi_version = 'not installed';
    } else {
      nextSystemInfo.byedpi_installed = 1;
      nextSystemInfo.byedpi_version = version;
    }
  }

  if (result.component === 'xray') {
    nextSystemInfo.providerInfoLoaded = true;

    if (result.action === 'remove') {
      nextSystemInfo.xray_installed = 0;
      nextSystemInfo.xray_version = 'not installed';
    } else {
      nextSystemInfo.xray_installed = 1;
      nextSystemInfo.xray_version = version;
    }
  }

  const normalizedSystemInfo = normalizeSingBoxVariantFields(nextSystemInfo);

  store.set({
    diagnosticsSystemInfo: normalizedSystemInfo,
  });

  if (
    result.component === 'zapret' ||
    result.component === 'zapret2' ||
    result.component === 'byedpi' ||
    result.component === 'xray'
  ) {
    notifyActionProvidersAvailabilityChanged(normalizedSystemInfo);
  }
}

function liveSelectedSingBoxVersion() {
  const select = document.querySelector(
    '.fkp_singbox-version-select',
  ) as HTMLSelectElement | null;
  const fromSelect = normalizeExtendedVersionTag(select?.value || '');
  if (fromSelect) {
    singBoxSelectedVersion = fromSelect;
    return fromSelect;
  }
  return normalizeExtendedVersionTag(singBoxSelectedVersion);
}

function liveSelectedXrayVersion() {
  const select = document.querySelector(
    '.fkp_xray-version-select',
  ) as HTMLSelectElement | null;
  const fromSelect = normalizeXrayVersionTag(select?.value || '', true);
  if (fromSelect) {
    xraySelectedVersion = fromSelect;
    return fromSelect;
  }
  return normalizeXrayVersionTag(xraySelectedVersion, true);
}

function currentXrayVersionInstallAction(tag: string) {
  const normalized = normalizeXrayVersionTag(tag);
  return normalized ? (`install@${normalized}` as Forkop.ComponentAction) : 'install';
}

function currentSingBoxVersionInstallAction(tag: string) {
  const systemInfo = normalizeSingBoxVariantFields(
    store.get().diagnosticsSystemInfo,
  );
  const normalized = `${tag || ''}`.trim();
  if (!normalized) {
    return systemInfo.sing_box_compressed
      ? 'install_extended_compressed'
      : 'install_extended';
  }
  if (systemInfo.sing_box_compressed) {
    return `install_extended_compressed@${normalized}`;
  }
  return `install_extended@${normalized}`;
}

function tagHasOpenwrtPackageBuild(tag: string) {
  const match = tag.match(/extended-([0-9]+)\.([0-9]+)/i);
  if (!match) {
    return false;
  }
  const major = Number(match[1]);
  const minor = Number(match[2]);
  return major > 2 || (major === 2 && minor >= 4);
}

function normalizeExtendedVersionTag(value: unknown) {
  let tag = `${value || ''}`.trim();
  if (!tag) {
    return '';
  }
  if (tag[0] === 'v' || tag[0] === 'V') {
    tag = tag.slice(1);
  }
  const lowered = tag.toLowerCase();
  if (
    lowered === 'version' ||
    lowered.includes('alpha') ||
    lowered.includes('beta') ||
    lowered.includes('rc') ||
    !lowered.includes('extended') ||
    !tagHasOpenwrtPackageBuild(tag)
  ) {
    return '';
  }
  return tag;
}

function mergeSingBoxVersions(values: unknown[]) {
  const seen = new Set<string>();
  const result: string[] = [];
  values.forEach((value) => {
    const tag = normalizeExtendedVersionTag(value);
    if (!tag || seen.has(tag)) {
      return;
    }
    seen.add(tag);
    result.push(tag);
  });
  return result;
}

function normalizeXrayVersionTag(value: unknown, allowPrerelease = false) {
  let tag = `${value || ''}`.trim();
  if (!tag) {
    return '';
  }
  if (tag[0] === 'v' || tag[0] === 'V') {
    tag = tag.slice(1);
  }
  const lowered = tag.toLowerCase();
  if (lowered === 'version' || !/^\d+\.\d+\.\d+/.test(tag)) {
    return '';
  }
  if (
    !allowPrerelease &&
    (lowered.includes('alpha') ||
      lowered.includes('beta') ||
      lowered.includes('rc'))
  ) {
    return '';
  }
  return tag;
}

function isXrayPrereleaseTag(tag: string) {
  const lowered = tag.toLowerCase();
  return (
    lowered.includes('alpha') ||
    lowered.includes('beta') ||
    lowered.includes('rc') ||
    xrayPrereleaseVersions.includes(tag)
  );
}

function mergeXrayVersions(values: unknown[], allowPrerelease = false) {
  const seen = new Set<string>();
  const result: string[] = [];
  values.forEach((value) => {
    const tag = normalizeXrayVersionTag(value, allowPrerelease);
    if (!tag || seen.has(tag)) {
      return;
    }
    seen.add(tag);
    result.push(tag);
  });
  return result;
}

function visibleXrayVersionTags() {
  const currentVersion = normalizeXrayVersionTag(
    store.get().diagnosticsSystemInfo.xray_version,
    true,
  );
  const ordered = mergeXrayVersions(
    [...xrayAvailableVersions, ...XRAY_FALLBACK_VERSIONS, currentVersion],
    true,
  );
  if (xrayIncludePrerelease) {
    return ordered;
  }
  return ordered.filter(
    (tag) => tag === currentVersion || !isXrayPrereleaseTag(tag),
  );
}

async function fetchSingBoxVersionsFromGitHub() {
  const response = await fetch(
    'https://api.github.com/repos/shtorm-7/sing-box-extended/tags?per_page=30',
    { headers: { Accept: 'application/vnd.github+json' } },
  );
  if (!response.ok) {
    throw new Error(`github tags http ${response.status}`);
  }
  const data = await response.json();
  if (!Array.isArray(data)) {
    throw new Error('github tags invalid');
  }
  return mergeSingBoxVersions(data.map((item) => item && item.name));
}

async function loadSingBoxVersionsFromRouter() {
  const startResponse = await ForkopShellMethods.componentActionStart(
    'sing_box',
    'list_versions',
  );
  if (!startResponse.success || !startResponse.data.job_id) {
    return [];
  }

  const response = await ForkopShellMethods.waitComponentActionJob(
    startResponse.data.job_id,
    'sing_box',
    'list_versions',
  );
  if (!response.success || !Array.isArray(response.data.available_versions)) {
    return [];
  }
  return mergeSingBoxVersions(response.data.available_versions);
}

function xrayVersionOptionLabel(version: string, currentVersion: string) {
  const marks = [];
  if (version === currentVersion) {
    marks.push(_('current'));
  }
  if (isXrayPrereleaseTag(version)) {
    marks.push(_('pre-release'));
  }
  return marks.length ? `${version} (${marks.join(', ')})` : version;
}

function syncXrayVersionSelect() {
  const select = document.querySelector(
    '.fkp_xray-version-select',
  ) as HTMLSelectElement | null;
  if (!select) {
    return;
  }
  const currentVersion = normalizeXrayVersionTag(
    store.get().diagnosticsSystemInfo.xray_version,
    true,
  );
  const options = visibleXrayVersionTags();
  const selected =
    xraySelectedVersion && options.includes(xraySelectedVersion)
      ? xraySelectedVersion
      : options.includes(currentVersion)
        ? currentVersion
        : options[0] || '';
  xraySelectedVersion = selected;
  select.replaceChildren(
    ...options.map((version) =>
      E(
        'option',
        {
          value: version,
          selected: version === selected ? 'selected' : null,
        },
        xrayVersionOptionLabel(version, currentVersion),
      ),
    ),
  );
  select.value = selected;
}

async function fetchXrayVersionsFromGitHub() {
  const response = await fetch(
    'https://api.github.com/repos/XTLS/Xray-core/releases?per_page=30',
    { headers: { Accept: 'application/vnd.github+json' } },
  );
  if (!response.ok) {
    throw new Error(`github xray releases http ${response.status}`);
  }
  const data = await response.json();
  if (!Array.isArray(data)) {
    throw new Error('github xray releases invalid');
  }
  const ordered: string[] = [];
  const prerelease: string[] = [];
  const seen = new Set<string>();
  data.forEach((item) => {
    if (!item || typeof item !== 'object' || item.draft === true) {
      return;
    }
    const tag = normalizeXrayVersionTag(item.tag_name, true);
    if (!tag || seen.has(tag)) {
      return;
    }
    seen.add(tag);
    if (item.prerelease === true || /alpha|beta|rc/i.test(tag)) {
      prerelease.push(tag);
    }
    ordered.push(tag);
  });
  return {
    ordered: mergeXrayVersions(ordered, true),
    prerelease: mergeXrayVersions(prerelease, true),
  };
}

async function loadXrayVersionsFromRouter() {
  const startResponse = await ForkopShellMethods.componentActionStart(
    'xray',
    'list_versions',
  );
  if (!startResponse.success || !startResponse.data.job_id) {
    return { ordered: [] as string[], prerelease: [] as string[] };
  }

  const response = await ForkopShellMethods.waitComponentActionJob(
    startResponse.data.job_id,
    'xray',
    'list_versions',
  );
  if (!response.success || !Array.isArray(response.data.available_versions)) {
    return { ordered: [] as string[], prerelease: [] as string[] };
  }
  return {
    ordered: mergeXrayVersions(response.data.available_versions, true),
    prerelease: mergeXrayVersions(response.data.prerelease_versions || [], true),
  };
}

async function loadCoreVersionLists() {
  if (coreVersionsLoading) {
    return;
  }

  if (!singBoxAvailableVersions.length) {
    singBoxAvailableVersions = [...SING_BOX_EXTENDED_FALLBACK_VERSIONS];
  }
  if (!xrayAvailableVersions.length) {
    xrayAvailableVersions = [...XRAY_FALLBACK_VERSIONS];
  }
  coreVersionsLoading = true;
  singBoxVersionsLoading = true;
  xrayVersionsLoading = true;
  renderUpdatesComponents();

  try {
    const [githubSingBox, githubXray] = await Promise.all([
      fetchSingBoxVersionsFromGitHub().catch((error) => {
        logger.debug('[UPDATES]', 'load sing-box versions from GitHub failed', error);
        return [] as string[];
      }),
      fetchXrayVersionsFromGitHub().catch((error) => {
        logger.debug('[UPDATES]', 'load xray versions from GitHub failed', error);
        return { ordered: [] as string[], prerelease: [] as string[] };
      }),
    ]);

    if (githubSingBox.length) {
      singBoxAvailableVersions = githubSingBox;
    }
    if (githubXray.ordered.length || githubXray.prerelease.length) {
      xrayAvailableVersions = githubXray.ordered;
      xrayPrereleaseVersions = githubXray.prerelease;
    }
    singBoxVersionsLoading = !githubSingBox.length;
    xrayVersionsLoading = !(githubXray.ordered.length || githubXray.prerelease.length);
    renderUpdatesComponents();

    if (!githubSingBox.length) {
      try {
        const routerVersions = await loadSingBoxVersionsFromRouter();
        if (routerVersions.length) {
          singBoxAvailableVersions = routerVersions;
        }
      } catch (error) {
        logger.debug('[UPDATES]', 'load sing-box versions from router failed', error);
      }
    }

    if (!githubXray.ordered.length && !githubXray.prerelease.length) {
      try {
        const routerVersions = await loadXrayVersionsFromRouter();
        if (routerVersions.ordered.length || routerVersions.prerelease.length) {
          xrayAvailableVersions = routerVersions.ordered;
          xrayPrereleaseVersions = routerVersions.prerelease;
        }
      } catch (error) {
        logger.debug('[UPDATES]', 'load xray versions from router failed', error);
      }
    }
  } finally {
    coreVersionsLoading = false;
    singBoxVersionsLoading = false;
    xrayVersionsLoading = false;
    renderUpdatesComponents();
  }
}

async function applyCompletedComponentAction({
  key,
  result,
  notify,
}: {
  key: UpdatesActionKey;
  result: Forkop.ComponentActionResult;
  notify: boolean;
}) {
  if (result.action === 'list_versions') {
    setActionLoading(key, false);
    if (Array.isArray(result.available_versions)) {
      const versions = result.available_versions.filter(Boolean);
      if (result.component === 'xray') {
        xrayAvailableVersions = mergeXrayVersions(versions, true);
        xrayPrereleaseVersions = mergeXrayVersions(
          result.prerelease_versions || [],
          true,
        );
        if (
          xraySelectedVersion &&
          !visibleXrayVersionTags().includes(xraySelectedVersion)
        ) {
          xraySelectedVersion = '';
        }
      } else if (result.component === 'sing_box') {
        singBoxAvailableVersions = mergeSingBoxVersions(versions);
        if (
          singBoxSelectedVersion &&
          !singBoxAvailableVersions.includes(singBoxSelectedVersion)
        ) {
          singBoxSelectedVersion = '';
        }
      }
    }
    renderUpdatesComponents();
    return;
  }

  if (result.action === 'check_update') {
    setActionLoading(key, false);

    if (!shouldApplyCompletedComponentActionResult(result, notify)) {
      return;
    }

    if (
      shouldPreserveCompletedCheckResultOnNextMount({
        action: result.action,
        mounted: updatesMounted,
      })
    ) {
      preserveCheckResultsOnNextMount = true;
    }

    const status = result.status || null;

    if (status === 'latest' || status === 'outdated' || status === 'dev') {
      setCheckResult(
        result.component,
        status,
        result.latest_version || '',
        result.release_url || '',
      );
    }

    if (notify) {
      showToast(getCheckToastMessage(status), 'success');
    }
    return;
  }

  if (
    result.action === 'install' ||
    result.action.startsWith('install_') ||
    result.action.startsWith('install@')
  ) {
    setCheckResult(result.component, 'latest', result.latest_version || '');
  } else {
    resetCheckResult(result.component);
  }

  patchSystemInfoAfterMutation(result);
  setActionLoading(key, false);

  if (result.component === 'forkop' && result.action === 'install') {
    if (notify && result.message) {
      showToast(result.message, 'success', 1200);
    }

    if (notify) {
      reloadPageAfterForkopUpdate();
    }
    return;
  }

  if (notify && result.message) {
    showToast(result.message, 'success');
  }

  void refreshSystemInfoAfterMutation();
}

async function completeComponentActionJob(
  key: UpdatesActionKey,
  jobId: string,
  response: Forkop.MethodResponse<Forkop.ComponentActionResult>,
) {
  if (pageUnloading) {
    setActionLoading(key, false);
    return;
  }

  const alreadyHandled = handledComponentJobs.has(jobId);

  if (alreadyHandled) {
    setActionLoading(key, false);
    return;
  }

  const shouldNotify = shouldNotifyOwnedUiAction('component', jobId);

  if (!response.success || response.data.success === false) {
    const message = response.success
      ? response.data.message || _('Failed to execute')
      : response.error || _('Failed to execute');

    if (isTransientRpcError(message)) {
      setActionLoading(key, false);
      void refreshComponentActionState();
      return;
    }

    handledComponentJobs.add(jobId);
    setActionLoading(key, false);
    if (shouldNotify) {
      showToast(message, 'error');
    }
    await ackComponentActionJob(jobId);
    return;
  }

  handledComponentJobs.add(jobId);
  await ackComponentActionJob(jobId);
  await applyCompletedComponentAction({
    key,
    result: response.data,
    notify: shouldNotify,
  });
}

async function followComponentActionState(state: Forkop.ComponentActionResult) {
  const jobId = state.job_id;
  const key = getComponentActionKey(state.component, state.action);

  if (!jobId || !key || followedComponentJobs.has(jobId)) {
    return;
  }

  if (!state.running && handledComponentJobs.has(jobId)) {
    return;
  }

  followedComponentJobs.add(jobId);
  if (shouldShowLoadingForRestoredAction(state)) {
    setActionLoading(key, true);
  }

  try {
    const response = state.running
      ? await ForkopShellMethods.waitComponentActionJob(
          jobId,
          state.component,
          state.action,
          state.latest_version || undefined,
        )
      : ({
          success: true,
          data: state,
        } as Forkop.MethodSuccessResponse<Forkop.ComponentActionResult>);

    await completeComponentActionJob(key, jobId, response);
  } catch (error) {
    logger.error('[UPDATES]', 'followComponentActionState failed', error);
    if (!pageUnloading) {
      const message = getErrorMessage(error, _('Failed to execute'));

      setActionLoading(key, false);
      if (!isTransientRpcError(message)) {
        showToast(message, 'error');
      }
    }
  } finally {
    followedComponentJobs.delete(jobId);
  }
}

async function followAlreadyRunningComponentAction(
  button: ComponentActionButton,
) {
  const uiState = await refreshRuntimeUiState({ force: true });

  if (!uiState) {
    return false;
  }

  const state = uiState.actions.component.find(
    (item) =>
      item.running &&
      item.component === button.component &&
      item.action === button.action,
  );

  if (!state) {
    return false;
  }

  if (state.job_id) {
    markUiActionOwned('component', state.job_id);
  }
  await followComponentActionState(state);
  return true;
}

function isComponentActionAlreadyRunningError(message: string | undefined) {
  return Boolean(
    message && message.includes('Another component action is already running'),
  );
}

function handleComponentUiState(uiState: Forkop.UiState) {
  for (const state of uiState.actions.component || []) {
    void followComponentActionState(state);
  }
}

async function refreshComponentActionState() {
  if (componentActionStateRefreshPromise) {
    return componentActionStateRefreshPromise;
  }

  componentActionStateRefreshPromise = (async () => {
    if (!updatesMounted) {
      return;
    }

    const state = await refreshRuntimeUiState({ force: true });

    if (!state) {
      return;
    }

    handleComponentUiState(state);
  })().finally(() => {
    componentActionStateRefreshPromise = null;
  });

  return componentActionStateRefreshPromise;
}

function startComponentActionStateWatcher() {
  if (componentActionStateUnsubscribe) {
    return;
  }

  componentActionStateUnsubscribe = subscribeRuntimeUiState((uiState) => {
    if (updatesMounted) {
      handleComponentUiState(uiState);
    }
  });
}

function stopComponentActionStateWatcher() {
  if (!componentActionStateUnsubscribe) {
    return;
  }

  componentActionStateUnsubscribe();
  componentActionStateUnsubscribe = null;
}

async function handleComponentAction(button: ComponentActionButton) {
  if (!beginComponentAction(button)) {
    return;
  }

  let jobId = '';
  let ownsJobFollow = false;

  try {
    const startResponse = await ForkopShellMethods.componentActionStart(
      button.component,
      button.action,
    );

    if (!startResponse.success) {
      if (isComponentActionAlreadyRunningError(startResponse.error)) {
        setActionLoading(button.key, false);
        if (!(await followAlreadyRunningComponentAction(button))) {
          await refreshComponentActionState();
        }
        return;
      }

      if (isTransientRpcError(startResponse.error)) {
        if (!(await followAlreadyRunningComponentAction(button))) {
          setActionLoading(button.key, false);
          await refreshComponentActionState();
        }
        return;
      }

      throw new Error(startResponse.error);
    }

    jobId = startResponse.data.job_id;
    markUiActionOwned('component', jobId);
    if (followedComponentJobs.has(jobId)) {
      return;
    }

    followedComponentJobs.add(jobId);
    ownsJobFollow = true;

    const response = await ForkopShellMethods.waitComponentActionJob(
      jobId,
      button.component,
      button.action,
      getExpectedLatestVersionForAction(button),
    );

    await completeComponentActionJob(button.key, jobId, response);
  } catch (error) {
    logger.error('[UPDATES]', 'handleComponentAction failed', error);
    if (!pageUnloading) {
      const message = getErrorMessage(error, _('Failed to execute'));

      setActionLoading(button.key, false);
      if (!isTransientRpcError(message)) {
        showToast(message, 'error');
      }
      void refreshComponentActionState();
    }
  } finally {
    if (ownsJobFollow) {
      followedComponentJobs.delete(jobId);
    }
  }
}

function getCheckAction(
  component: Forkop.ComponentName,
  key: UpdatesActionKey,
): ComponentActionButton {
  return {
    key,
    text: _('Check update'),
    icon: renderSearchIcon24,
    component,
    action: 'check_update',
  };
}

function getInstallAction(
  component: Forkop.ComponentName,
  key: UpdatesActionKey,
  installed: boolean,
): ComponentActionButton {
  return {
    key,
    text: installed ? _('Update') : _('Install'),
    icon: installed ? renderRotateCcwIcon24 : renderDownloadIcon24,
    component,
    action: 'install',
  };
}

function getInstalledUpdateActions(
  component: Forkop.ComponentName,
  checkKey: UpdatesActionKey,
  installKey: UpdatesActionKey,
  installed = true,
) {
  if (!installed) {
    return [];
  }

  const actions = [getCheckAction(component, checkKey)];
  if (shouldShowInstallAfterCheck(component)) {
    actions.push(getInstallAction(component, installKey, true));
  }
  return actions;
}

function getOptionalComponentActions({
  component,
  installed,
  checkKey,
  installKey,
  removeKey,
}: {
  component: 'zapret' | 'zapret2' | 'byedpi' | 'xray';
  installed: boolean;
  checkKey: UpdatesActionKey;
  installKey: UpdatesActionKey;
  removeKey: UpdatesActionKey;
}) {
  if (!installed) {
    return [getInstallAction(component, installKey, false)];
  }

  return [
    ...getInstalledUpdateActions(component, checkKey, installKey),
    {
      key: removeKey,
      text: _('Remove'),
      icon: renderXIcon24,
      component,
      action: 'remove' as const,
    },
  ];
}

function getComponentCards(): ComponentCard[] {
  const systemInfo = normalizeSingBoxVariantFields(
    store.get().diagnosticsSystemInfo,
  );
  const systemInfoLoading = isSystemInfoLoading();
  const zapretInstalled = Boolean(systemInfo.zapret_installed);
  const zapret2Installed = Boolean(systemInfo.zapret2_installed);
  const byedpiInstalled = Boolean(systemInfo.byedpi_installed);
  const xrayInstalled = Boolean(systemInfo.xray_installed);
  const singBoxInstalled = !isNotInstalled(systemInfo.sing_box_version);
  const singBoxStable =
    singBoxInstalled &&
    !systemInfo.sing_box_extended &&
    !systemInfo.sing_box_tiny;
  const singBoxExtended =
    Boolean(systemInfo.sing_box_extended) && !systemInfo.sing_box_compressed;
  const singBoxExtendedCompressed =
    Boolean(systemInfo.sing_box_extended) &&
    Boolean(systemInfo.sing_box_compressed);
  const singBoxTiny = Boolean(systemInfo.sing_box_tiny);

  const forkopActions = getInstalledUpdateActions(
    'forkop',
    'forkopCheck',
    'forkopInstall',
  );
  const singBoxActions = getInstalledUpdateActions(
    'sing_box',
    'singBoxCheck',
    'singBoxInstall',
    singBoxInstalled,
  );

  // Add Sing-box variant actions (only show names, no 'Install' prefix)
  if (!singBoxStable) {
    singBoxActions.push({
      key: 'singBoxInstallStable',
      text: 'Stable',
      icon: renderDownloadIcon24,
      component: 'sing_box',
      action: 'install_stable',
    });
  }
  if (!singBoxTiny) {
    singBoxActions.push({
      key: 'singBoxInstallTiny',
      text: 'Tiny',
      icon: renderDownloadIcon24,
      component: 'sing_box',
      action: 'install_tiny',
    });
  }
  if (!singBoxExtended) {
    singBoxActions.push({
      key: 'singBoxInstallExtended',
      text: 'Extended',
      icon: renderDownloadIcon24,
      component: 'sing_box',
      action: 'install_extended',
    });
  }
  if (!singBoxExtendedCompressed) {
    singBoxActions.push({
      key: 'singBoxInstallExtendedCompressed',
      text: 'Extended compressed',
      icon: renderDownloadIcon24,
      component: 'sing_box',
      action: 'install_extended_compressed',
    });
  }

  const zapretActions = getOptionalComponentActions({
    component: 'zapret',
    installed: zapretInstalled,
    checkKey: 'zapretCheck',
    installKey: 'zapretInstall',
    removeKey: 'zapretRemove',
  });
  const zapret2Actions = getOptionalComponentActions({
    component: 'zapret2',
    installed: zapret2Installed,
    checkKey: 'zapret2Check',
    installKey: 'zapret2Install',
    removeKey: 'zapret2Remove',
  });
  const byedpiActions = getOptionalComponentActions({
    component: 'byedpi',
    installed: byedpiInstalled,
    checkKey: 'byedpiCheck',
    installKey: 'byedpiInstall',
    removeKey: 'byedpiRemove',
  });
  const xrayActions = getOptionalComponentActions({
    component: 'xray',
    installed: xrayInstalled,
    checkKey: 'xrayCheck',
    installKey: 'xrayInstall',
    removeKey: 'xrayRemove',
  });

  return [
    {
      component: 'forkop',
      column: 0,
      title: 'Forkop-Mod',
      version: systemInfoLoading
        ? _('Loading...')
        : normalizeCompiledVersion(systemInfo.forkop_version),
      latestVersion: getLatestVersion('forkop'),
      releaseUrl: getGitHubReleaseUrl('forkop'),
      actions: forkopActions,
    },
    {
      component: 'sing_box',
      column: 0,
      title: 'Sing-box',
      version: systemInfoLoading
        ? _('Loading...')
        : formatSingBoxVersion(systemInfo),
      latestVersion: getLatestVersion('sing_box'),
      releaseUrl: getGitHubReleaseUrl('sing_box'),
      actions: singBoxActions,
    },
    {
      component: 'zapret',
      column: 1,
      title: 'Zapret',
      version: systemInfoLoading
        ? _('Loading...')
        : zapretInstalled
          ? systemInfo.zapret_version
          : _('Not installed'),
      latestVersion: getLatestVersion('zapret'),
      releaseUrl: getGitHubReleaseUrl('zapret'),
      actions: zapretActions,
    },
    {
      component: 'zapret2',
      column: 1,
      title: 'Zapret2',
      version: systemInfoLoading
        ? _('Loading...')
        : zapret2Installed
          ? systemInfo.zapret2_version
          : _('Not installed'),
      latestVersion: getLatestVersion('zapret2'),
      releaseUrl: getGitHubReleaseUrl('zapret2'),
      actions: zapret2Actions,
    },
    {
      component: 'byedpi',
      column: 1,
      title: 'ByeDPI',
      version: systemInfoLoading
        ? _('Loading...')
        : byedpiInstalled
          ? systemInfo.byedpi_version
          : _('Not installed'),
      latestVersion: getLatestVersion('byedpi'),
      releaseUrl: getGitHubReleaseUrl('byedpi'),
      actions: byedpiActions,
    },
    {
      component: 'xray',
      column: 1,
      title: 'Xray',
      version: systemInfoLoading
        ? _('Loading...')
        : xrayInstalled
          ? systemInfo.xray_version
          : _('Not installed'),
      latestVersion: getLatestVersion('xray'),
      releaseUrl: getGitHubReleaseUrl('xray'),
      actions: xrayActions,
    },
  ];
}

function renderComponentCard(card: ComponentCard) {
  const updatesActions = store.get().updatesActions;
  const anyActionLoading = isAnyActionLoading();
  const serviceRuntimeActionLoading = isServiceRuntimeActionLoading();
  const systemInfoLoading = isSystemInfoLoading();

  // 1. Header (displays Title, Current Version, no badges)
  const headerChildren: Node[] = [
    E('b', { class: 'fkp_updates-page__component__title' }, card.title),
    E(
      'span',
      { class: 'fkp_updates-page__component__header-version' },
      card.version,
    ),
  ];
  const header = E(
    'div',
    { class: 'fkp_updates-page__component__header' },
    headerChildren,
  );

  // 2. Details (renders status messages for check results)
  const detailsChildren: Node[] = [];
  const checkResult = getVisibleCheckResult(card.component);

  if (checkResult && checkResult.status) {
    let labelText = '';
    const latestValueNodes: Node[] = [];

    if (checkResult.status === 'outdated') {
      labelText = _('Update is available:');
      const versionToShow =
        checkResult.latest_version || card.latestVersion || card.version;

      if (checkResult.release_url) {
        latestValueNodes.push(
          E(
            'a',
            {
              class: 'fkp_updates-page__component__release-version-link',
              href: checkResult.release_url,
              target: '_blank',
              rel: 'noopener noreferrer',
            },
            versionToShow || _('Open'),
          ),
        );
      } else if (versionToShow) {
        latestValueNodes.push(document.createTextNode(versionToShow));
      }
    } else if (checkResult.status === 'latest') {
      labelText = _('Latest version is installed');
    } else if (checkResult.status === 'dev') {
      labelText = `${_('Installed version is newer than release')}. ${_('Latest version:')}`;
      const versionToShow = checkResult.latest_version || card.latestVersion;

      if (checkResult.release_url) {
        latestValueNodes.push(
          E(
            'a',
            {
              class: 'fkp_updates-page__component__release-version-link',
              href: checkResult.release_url,
              target: '_blank',
              rel: 'noopener noreferrer',
            },
            versionToShow || _('Open'),
          ),
        );
      } else if (versionToShow) {
        latestValueNodes.push(document.createTextNode(versionToShow));
      }
    }

    if (labelText) {
      const rowChildren: Node[] = [
        E(
          'span',
          { class: 'fkp_updates-page__component__info-label' },
          labelText,
        ),
      ];
      if (latestValueNodes.length > 0) {
        rowChildren.push(
          E(
            'span',
            {
              class:
                'fkp_updates-page__component__info-value fkp_updates-page__component__info-value--latest',
            },
            latestValueNodes,
          ),
        );
      }

      detailsChildren.push(
        E(
          'div',
          { class: 'fkp_updates-page__component__info-row' },
          rowChildren,
        ),
      );
    }
  }

  const detailsContainer =
    detailsChildren.length > 0
      ? E(
          'div',
          { class: 'fkp_updates-page__component__details' },
          detailsChildren,
        )
      : null;

  // 3. Actions classification
  const primaryActions: ComponentActionButton[] = [];
  const dangerActions: ComponentActionButton[] = [];
  const variantActions: ComponentActionButton[] = [];

  card.actions.forEach((action) => {
    if (action.action === 'remove') {
      dangerActions.push(action);
    } else if (action.action.startsWith('install_')) {
      variantActions.push(action);
    } else {
      primaryActions.push(action);
    }
  });

  const actionElements: Node[] = [];

  // Render primary and danger buttons in a main row
  const primaryButtons = primaryActions.map((action) => {
    const loading = updatesActions[action.key].loading;
    const isUpdateOrInstall = action.action === 'install';

    return renderButton({
      classNames: isUpdateOrInstall ? ['cbi-button-save'] : [],
      text: action.text,
      icon: action.icon,
      loading,
      disabled:
        systemInfoLoading ||
        serviceRuntimeActionLoading ||
        (anyActionLoading && !loading),
      onClick: () => void handleComponentAction(action),
    });
  });

  const dangerButtons = dangerActions.map((action) => {
    const loading = updatesActions[action.key].loading;

    return renderButton({
      classNames: ['cbi-button-remove'],
      text: action.text,
      icon: action.icon,
      loading,
      disabled:
        systemInfoLoading ||
        serviceRuntimeActionLoading ||
        (anyActionLoading && !loading),
      onClick: () => void handleComponentAction(action),
    });
  });

  if (primaryButtons.length > 0 || dangerButtons.length > 0) {
    actionElements.push(
      E('div', { class: 'fkp_updates-page__component__actions-main' }, [
        ...primaryButtons,
        ...dangerButtons,
      ]),
    );
  }

  // Render variant buttons if any
  if (variantActions.length > 0) {
    const variantButtons = variantActions.map((action) => {
      const loading = updatesActions[action.key].loading;
      return renderButton({
        text: action.text,
        icon: action.icon,
        loading,
        disabled:
          systemInfoLoading ||
          serviceRuntimeActionLoading ||
          (anyActionLoading && !loading),
        onClick: () => void handleComponentAction(action),
      });
    });

    actionElements.push(
      E('div', { class: 'fkp_updates-page__component__variants' }, [
        E(
          'div',
          { class: 'fkp_updates-page__component__variants-title' },
          _('Install another build:'),
        ),
        E(
          'div',
          { class: 'fkp_updates-page__component__variants-buttons' },
          variantButtons,
        ),
      ]),
    );
  }

  if (card.component === 'sing_box') {
    const currentVersion = `${card.version || ''}`.trim();
    const options = mergeSingBoxVersions([
      ...singBoxAvailableVersions,
      ...SING_BOX_EXTENDED_FALLBACK_VERSIONS,
      currentVersion,
    ]);
    const selected =
      singBoxSelectedVersion && options.includes(singBoxSelectedVersion)
        ? singBoxSelectedVersion
        : options.includes(normalizeExtendedVersionTag(currentVersion))
          ? normalizeExtendedVersionTag(currentVersion)
          : options[0] || '';
    const installLoading =
      updatesActions.singBoxInstallExtended.loading ||
      updatesActions.singBoxInstallExtendedCompressed.loading;

    actionElements.push(
      E('div', { class: 'fkp_updates-page__component__versions' }, [
        E(
          'div',
          { class: 'fkp_updates-page__component__variants-title' },
          _('Install specific version:'),
        ),
        E('div', { class: 'fkp_updates-page__component__versions-row' }, [
          E(
            'select',
            {
              class: 'fkp_singbox-version-select',
              change: (event: Event) => {
                const target = event.target as HTMLSelectElement;
                singBoxSelectedVersion = target.value;
              },
            },
            options.map((version) =>
              E(
                'option',
                { value: version },
                version === currentVersion ||
                  version === normalizeExtendedVersionTag(currentVersion)
                  ? `${version} (${_('current')})`
                  : version,
              ),
            ),
          ),
          renderButton({
            classNames: ['cbi-button-save'],
            text: singBoxVersionsLoading
              ? _('Loading versions...')
              : _('Install selected'),
            icon: renderDownloadIcon24,
            loading: installLoading,
            disabled:
              systemInfoLoading ||
              serviceRuntimeActionLoading ||
              anyActionLoading ||
              singBoxVersionsLoading ||
              !selected,
            onClick: () => {
              const tag = liveSelectedSingBoxVersion();
              if (!tag) {
                return;
              }
              void handleComponentAction({
                key: store.get().diagnosticsSystemInfo.sing_box_compressed
                  ? 'singBoxInstallExtendedCompressed'
                  : 'singBoxInstallExtended',
                text: _('Install selected'),
                icon: renderDownloadIcon24,
                component: 'sing_box',
                action: currentSingBoxVersionInstallAction(
                  tag,
                ) as Forkop.ComponentAction,
              });
            },
          }),
        ]),
      ]),
    );
  }

  if (card.component === 'xray') {
    const currentVersion = normalizeXrayVersionTag(card.version, true);
    const options = visibleXrayVersionTags();
    const selected =
      xraySelectedVersion && options.includes(xraySelectedVersion)
        ? xraySelectedVersion
        : options.includes(currentVersion)
          ? currentVersion
          : options[0] || '';
    const installLoading = updatesActions.xrayInstall.loading;

    actionElements.push(
      E('div', { class: 'fkp_updates-page__component__versions' }, [
        E(
          'div',
          { class: 'fkp_updates-page__component__variants-title' },
          _('Install specific version:'),
        ),
        E('label', { class: 'fkp_updates-page__component__prerelease' }, [
          (() => {
            const checkbox = E('input', {
              type: 'checkbox',
              id: 'fkp-xray-prerelease',
              click: (event: Event) => event.stopPropagation(),
              change: (event: Event) => {
                event.stopPropagation();
                const target = event.target as HTMLInputElement;
                xrayIncludePrerelease = Boolean(target.checked);
                syncXrayVersionSelect();
              },
            }) as HTMLInputElement;
            checkbox.checked = xrayIncludePrerelease;
            checkbox.autocomplete = 'off';
            return checkbox;
          })(),
          _('Show pre-release versions'),
        ]),
        E('div', { class: 'fkp_updates-page__component__versions-row' }, [
          E(
            'select',
            {
              class: 'fkp_xray-version-select',
              change: (event: Event) => {
                const target = event.target as HTMLSelectElement;
                xraySelectedVersion = target.value;
              },
            },
            options.map((version) =>
              E(
                'option',
                {
                  value: version,
                  selected: version === selected ? 'selected' : null,
                },
                xrayVersionOptionLabel(version, currentVersion),
              ),
            ),
          ),
          renderButton({
            classNames: ['cbi-button-save'],
            text: xrayVersionsLoading
              ? _('Loading versions...')
              : _('Install selected'),
            icon: renderDownloadIcon24,
            loading: installLoading,
            disabled:
              systemInfoLoading ||
              serviceRuntimeActionLoading ||
              anyActionLoading ||
              xrayVersionsLoading ||
              !selected,
            onClick: () => {
              const tag = liveSelectedXrayVersion();
              if (!tag) {
                return;
              }
              void handleComponentAction({
                key: 'xrayInstall',
                text: _('Install selected'),
                icon: renderDownloadIcon24,
                component: 'xray',
                action: currentXrayVersionInstallAction(tag),
              });
            },
          }),
        ]),
      ]),
    );
  }

  const actionsContainer = E(
    'div',
    {
      class: [
        'fkp_updates-page__component__actions',
        detailsContainer
          ? 'fkp_updates-page__component__actions--with-details'
          : '',
      ]
        .filter(Boolean)
        .join(' '),
    },
    actionElements,
  );

  const cardChildren: Node[] = [header];
  if (detailsContainer) {
    cardChildren.push(detailsContainer);
  }
  cardChildren.push(actionsContainer);

  return E('div', { class: 'fkp_updates-page__component' }, cardChildren);
}

function renderUpdatesComponents() {
  const container = document.getElementById('fkp_updates-components');

  if (!container) {
    return;
  }

  const columns = [[], []] as Node[][];
  getComponentCards().forEach((card) => {
    columns[card.column].push(renderComponentCard(card));
  });

  return preserveScrollForPage(() => {
    container.replaceChildren(
      E('div', { class: 'fkp_updates-page__components-column' }, columns[0]),
      E('div', { class: 'fkp_updates-page__components-column' }, columns[1]),
    );
  });
}

function onStoreUpdate(
  _next: StoreType,
  _prev: StoreType,
  diff: Partial<StoreType>,
) {
  if (
    diff.diagnosticsSystemInfo ||
    diff.updatesActions ||
    diff.updatesChecks ||
    diff.diagnosticsActions ||
    diff.servicesInfoWidget
  ) {
    renderUpdatesComponents();
  }
}

function applyComponentUpdateCheckCache(
  componentUpdateCheckCache: Forkop.ComponentUpdateCheckCache,
) {
  componentUpdateCheckCacheResolved = true;

  if (componentUpdateCheckCache.enabled) {
    store.reset(['updatesChecks']);
    applyCachedCheckResults(componentUpdateCheckCache.results);
  }

  if (
    shouldResetCheckResultsOnMount({
      anyActionLoading: isAnyActionLoading(),
      preserveCheckResultsOnNextMount,
      persistentCacheEnabled: componentUpdateCheckCache.enabled,
    })
  ) {
    store.reset(['updatesChecks']);
  }
}

async function onPageMount() {
  onPageUnmount();

  updatesMounted = true;
  updatesMountId += 1;
  const mountId = updatesMountId;
  const cachedRuntimeState = getCachedRuntimeUiState();
  const hasRuntimeSnapshot = Boolean(cachedRuntimeState);
  const needsFreshStateBeforeRender =
    shouldRefreshComponentStateBeforeRender(cachedRuntimeState);
  const runtimeStateRefreshPromise =
    !hasRuntimeSnapshot || needsFreshStateBeforeRender
      ? refreshRuntimeUiState({ force: true })
      : null;
  const prefetchedComponentUpdateCheckCache = componentUpdateCheckCacheSnapshot;

  if (prefetchedComponentUpdateCheckCache) {
    applyComponentUpdateCheckCache(prefetchedComponentUpdateCheckCache);
  }

  renderUpdatesComponents();

  const componentUpdateCheckCache = await loadComponentUpdateCheckCache({
    force: Boolean(prefetchedComponentUpdateCheckCache),
  });

  if (!updatesMounted || mountId !== updatesMountId) {
    return;
  }

  applyComponentUpdateCheckCache(componentUpdateCheckCache);
  preserveCheckResultsOnNextMount = false;
  renderUpdatesComponents();

  if (runtimeStateRefreshPromise) {
    await runtimeStateRefreshPromise;

    if (!updatesMounted || mountId !== updatesMountId) {
      return;
    }
  }

  store.subscribe(onStoreUpdate);
  startComponentActionStateWatcher();
  renderUpdatesComponents();
  void ensureSystemInfo();
  void loadCoreVersionLists();
  if (hasRuntimeSnapshot) {
    void refreshRuntimeUiState({ force: true });
  }
}

function onPageUnmount() {
  updatesMounted = false;
  updatesMountId += 1;
  stopComponentActionStateWatcher();
  store.unsubscribe(onStoreUpdate);
}

function registerLifecycleListeners() {
  if (updatesLifecycleRegistered) {
    return;
  }

  updatesLifecycleRegistered = true;

  store.subscribe((next, prev, diff) => {
    if (
      diff.tabService &&
      next.tabService.current !== prev.tabService.current
    ) {
      const isUpdatesVisible = next.tabService.current === 'updates';

      if (isUpdatesVisible) {
        return onPageMount();
      }

      if (updatesMounted) {
        return onPageUnmount();
      }
    }
  });
}

export async function initController(): Promise<void> {
  if (updatesControllerInitialized) {
    return;
  }

  updatesControllerInitialized = true;
  void loadComponentUpdateCheckCache();

  onMount('updates-status').then(() => {
    logger.debug('[UPDATES]', 'initController', 'onMount');
    registerLifecycleListeners();
    if (
      store.get().tabService.current === 'updates' ||
      isActiveLuciTab('updates')
    ) {
      onPageMount();
    }
  });
}
