import { insertIf } from '../../../../helpers';
import { DIAGNOSTICS_CHECKS_MAP } from './contstants';
import { ForkopShellMethods, RemoteFakeIPMethods } from '../../../methods';
import type { IDiagnosticsChecksItem } from '../../../services';
import { updateCheckStore } from './updateCheckStore';
import { getMeta } from '../helpers/getMeta';

export async function runFakeIPCheck() {
  const { order, title, code } = DIAGNOSTICS_CHECKS_MAP.FAKEIP;

  updateCheckStore({
    order,
    code,
    title,
    description: _('Checking, please wait'),
    state: 'loading',
    items: [],
  });

  const routerFakeIPResponse = await ForkopShellMethods.checkFakeIP();
  const xrayFakeDNS =
    routerFakeIPResponse.success &&
    `${routerFakeIPResponse.data.engine || ''}`.toLowerCase() === 'xray';
  const checkFakeIPResponse = xrayFakeDNS
    ? {
        success: true as const,
        data: { fakeip: true, IP: routerFakeIPResponse.data.IP },
        message: '',
      }
    : await RemoteFakeIPMethods.getFakeIpCheck();
  const checkIPResponse = xrayFakeDNS
    ? { success: false as const, data: { IP: '' }, message: '' }
    : await RemoteFakeIPMethods.getIpCheck();
  const browserFakeIPCheckUnavailable = !checkFakeIPResponse.success;
  const browserFakeIPCheckMessage = checkFakeIPResponse.success
    ? ''
    : checkFakeIPResponse.message;

  const checks = {
    singBoxFakeIP:
      routerFakeIPResponse.success && routerFakeIPResponse.data.fakeip,
    browserFakeIP:
      checkFakeIPResponse.success && checkFakeIPResponse.data.fakeip,
    canComparePublicIP: checkFakeIPResponse.success && checkIPResponse.success,
    differentIP:
      checkFakeIPResponse.success &&
      checkIPResponse.success &&
      checkFakeIPResponse.data.IP !== checkIPResponse.data.IP,
  };

  const fakeIPWorks = xrayFakeDNS
    ? checks.singBoxFakeIP
    : checks.singBoxFakeIP && checks.browserFakeIP;
  const { state, description } = fakeIPWorks
    ? xrayFakeDNS
      ? { state: 'success' as const, description: _('Checks passed') }
      : checks.differentIP
        ? { state: 'success' as const, description: _('Checks passed') }
        : {
            state: 'warning' as const,
            description: _('FakeIP works; public IP comparison is inconclusive'),
          }
    : browserFakeIPCheckUnavailable && checks.singBoxFakeIP
      ? {
          state: 'warning' as const,
          description: _('Browser FakeIP check could not be completed'),
        }
      : getMeta({
          allGood: false,
          atLeastOneGood: checks.singBoxFakeIP || checks.browserFakeIP,
        });

  updateCheckStore({
    order,
    code,
    title,
    description,
    state,
    items: [
      {
        state: checks.singBoxFakeIP ? 'success' : 'error',
        key: checks.singBoxFakeIP
          ? xrayFakeDNS
            ? _('Xray FakeDNS works')
            : _('Sing-box FakeIP DNS works')
          : xrayFakeDNS
            ? _('Xray FakeDNS does not work')
            : _('Sing-box FakeIP DNS does not work'),
        value: routerFakeIPResponse.success ? routerFakeIPResponse.data.IP : '',
      },
      {
        state: xrayFakeDNS
          ? 'success'
          : browserFakeIPCheckUnavailable
            ? 'warning'
            : checks.browserFakeIP
              ? 'success'
              : 'error',
        key: xrayFakeDNS
          ? _('Browser FakeIP check skipped for Xray')
          : browserFakeIPCheckUnavailable
            ? _('Browser FakeIP check could not be completed')
            : checks.browserFakeIP
              ? _('Browser is using FakeIP correctly')
              : _('Browser is not using FakeIP'),
        value: browserFakeIPCheckMessage,
      },
      ...insertIf<IDiagnosticsChecksItem>(
        !xrayFakeDNS && checks.browserFakeIP,
        [
          {
            state: checks.differentIP ? 'success' : 'warning',
            key: !checks.canComparePublicIP
              ? _('Could not compare FakeIP and control public IPs')
              : checks.differentIP
                ? _('FakeIP and control checks use different public IPs')
                : _('FakeIP and control checks use the same public IP'),
            value: '',
          },
        ],
      ),
    ],
  });
}