import { DIAGNOSTICS_CHECKS_MAP } from './contstants';
import { ForkopShellMethods } from '../../../methods';
import { updateCheckStore } from './updateCheckStore';
import { getMeta } from '../helpers/getMeta';

export async function runSingBoxCheck() {
  const { order, title, code } = DIAGNOSTICS_CHECKS_MAP.SINGBOX;

  updateCheckStore({
    order,
    code,
    title,
    description: _('Checking, please wait'),
    state: 'loading',
    items: [],
  });

  const singBoxChecks = await ForkopShellMethods.checkSingBox();

  if (!singBoxChecks.success) {
    updateCheckStore({
      order,
      code,
      title,
      description: _('Cannot receive checks result'),
      state: 'error',
      items: [],
    });

    throw new Error('Sing-box checks failed');
  }

  const data = singBoxChecks.data;
  const sidecarRequired = data.sing_box_required !== 0;
  const processOk = sidecarRequired
    ? Boolean(data.sing_box_process_running)
    : true;
  const portsOk = sidecarRequired
    ? Boolean(data.sing_box_ports_listening)
    : true;

  const allGood =
    Boolean(data.sing_box_installed) &&
    Boolean(data.sing_box_version_ok) &&
    Boolean(data.sing_box_service_exist) &&
    Boolean(data.sing_box_autostart_disabled) &&
    processOk &&
    portsOk;

  const atLeastOneGood =
    Boolean(data.sing_box_installed) ||
    Boolean(data.sing_box_version_ok) ||
    Boolean(data.sing_box_service_exist) ||
    Boolean(data.sing_box_autostart_disabled) ||
    Boolean(data.sing_box_process_running) ||
    Boolean(data.sing_box_ports_listening) ||
    !sidecarRequired;

  const { state, description } = getMeta({ atLeastOneGood, allGood });

  updateCheckStore({
    order,
    code,
    title,
    description,
    state,
    items: [
      {
        state: data.sing_box_installed ? 'success' : 'error',
        key: _('Sing-box installed'),
        value: '',
      },
      {
        state: data.sing_box_version_ok ? 'success' : 'error',
        key: _('Sing-box version is compatible (newer than 1.12.4)'),
        value: '',
      },
      {
        state: data.sing_box_service_exist ? 'success' : 'error',
        key: _('Sing-box service exist'),
        value: '',
      },
      {
        state: data.sing_box_autostart_disabled ? 'success' : 'error',
        key: _('Sing-box autostart disabled'),
        value: '',
      },
      {
        state: sidecarRequired
          ? data.sing_box_process_running
            ? 'success'
            : 'error'
          : 'success',
        key: sidecarRequired
          ? _('Sing-box process running')
          : _('Sing-box sidecar not used'),
        value: '',
      },
      {
        state: sidecarRequired
          ? data.sing_box_ports_listening
            ? 'success'
            : 'error'
          : 'success',
        key: sidecarRequired
          ? _('Sing-box listening ports')
          : _('Sing-box ports not required'),
        value: '',
      },
    ],
  });

  if (!atLeastOneGood || (sidecarRequired && !data.sing_box_process_running)) {
    throw new Error('Sing-box checks failed');
  }
}