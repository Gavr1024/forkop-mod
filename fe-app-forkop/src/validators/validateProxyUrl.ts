import { ValidationResult } from './types';
import { validateShadowsocksUrl } from './validateShadowsocksUrl';
import { validateVlessUrl } from './validateVlessUrl';
import { validateVmessUrl } from './validateVmessUrl';
import { validateTrojanUrl } from './validateTrojanUrl';
import { validateSocksUrl } from './validateSocksUrl';
import { validateHysteria2Url } from './validateHysteriaUrl';

// TODO refactor current validation and add tests
export function validateProxyUrl(url: string | string[] | null | undefined): ValidationResult {
  if (url == null || url === '') {
    return { valid: true, message: 'Valid' };
  }

  if (Array.isArray(url)) {
    for (const item of url) {
      const result = validateProxyUrl(item);
      if (!result.valid) {
        return result;
      }
    }
    return { valid: true, message: 'Valid' };
  }

  const trimmedUrl = `${url}`.trim();

  if (trimmedUrl.startsWith('ss://')) {
    return validateShadowsocksUrl(trimmedUrl);
  }

  if (trimmedUrl.startsWith('vless://')) {
    return validateVlessUrl(trimmedUrl);
  }

  if (trimmedUrl.startsWith('vmess://')) {
    return validateVmessUrl(trimmedUrl);
  }

  if (trimmedUrl.startsWith('trojan://')) {
    return validateTrojanUrl(trimmedUrl);
  }

  if (/^socks(4|4a|5):\/\//.test(trimmedUrl)) {
    return validateSocksUrl(trimmedUrl);
  }

  if (
    trimmedUrl.startsWith('hysteria2://') ||
    trimmedUrl.startsWith('hy2://')
  ) {
    return validateHysteria2Url(trimmedUrl);
  }

  return {
    valid: false,
    message: _(
      'URL must start with vless://, vmess://, ss://, trojan://, socks4://, socks4a://, socks5://, hysteria2://, or hy2://',
    ),
  };
}
