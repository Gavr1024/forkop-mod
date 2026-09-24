import { ValidationResult } from './types';

const SERVER_OUTBOUND_TYPES = new Set([
  'vless',
  'vmess',
  'trojan',
  'shadowsocks',
  'socks',
  'http',
  'hysteria2',
  'hysteria',
  'hy2',
]);

function invalid(message: string): ValidationResult {
  return { valid: false, message };
}

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return Boolean(value) && typeof value === 'object' && !Array.isArray(value);
}

function nonEmptyString(value: unknown): value is string {
  return typeof value === 'string' && value.trim().length > 0;
}

function asTrimmedString(value: unknown): string {
  return typeof value === 'string' ? value.trim() : '';
}

function validateServerPort(value: unknown): boolean {
  if (typeof value === 'number' && Number.isInteger(value)) {
    return value >= 1 && value <= 65535;
  }
  if (typeof value === 'string' && /^\d+$/.test(value.trim())) {
    const port = Number.parseInt(value.trim(), 10);
    return port >= 1 && port <= 65535;
  }
  return false;
}

function validateOutbounds(value: unknown): boolean {
  return (
    Array.isArray(value) &&
    value.length > 0 &&
    value.every((item) => nonEmptyString(item))
  );
}

function nestedSettings(value: Record<string, unknown>): Record<string, unknown> {
  return isPlainObject(value.settings) ? value.settings : {};
}

function outboundType(parsed: Record<string, unknown>): string {
  return asTrimmedString(parsed.type || parsed.protocol).toLowerCase();
}

function outboundTag(parsed: Record<string, unknown>): string {
  return asTrimmedString(parsed.tag);
}

function outboundServer(parsed: Record<string, unknown>): string {
  const settings = nestedSettings(parsed);
  return asTrimmedString(
    parsed.server || parsed.address || settings.address || settings.server,
  );
}

function outboundPort(parsed: Record<string, unknown>): unknown {
  const settings = nestedSettings(parsed);
  if (parsed.server_port !== undefined) {
    return parsed.server_port;
  }
  if (parsed.port !== undefined) {
    return parsed.port;
  }
  if (settings.port !== undefined) {
    return settings.port;
  }
  return settings.server_port;
}

function unwrapOutbound(parsed: unknown): unknown {
  if (!isPlainObject(parsed)) {
    return parsed;
  }
  if (outboundType(parsed) || outboundTag(parsed)) {
    return parsed;
  }
  const outbounds = parsed.outbounds;
  if (Array.isArray(outbounds) && outbounds.length > 0 && isPlainObject(outbounds[0])) {
    return outbounds[0];
  }
  return parsed;
}

function validateParsedOutbound(
  parsed: Record<string, unknown>,
  usedTags: string[],
): ValidationResult {
  const type = outboundType(parsed);
  if (!type) {
    return invalid(_('JSON outbound must contain a non-empty type field'));
  }

  const tag = outboundTag(parsed);
  if (!tag) {
    return invalid(_('JSON outbound must contain a non-empty tag field'));
  }
  if (usedTags.some((usedTag) => `${usedTag || ''}`.trim() === tag)) {
    return invalid(_('Duplicate JSON outbound tag'));
  }

  if (
    (type === 'selector' || type === 'urltest') &&
    !validateOutbounds(parsed.outbounds)
  ) {
    return invalid(
      _(
        'Selector and URLTest outbounds must contain a non-empty outbounds array',
      ),
    );
  }

  if (SERVER_OUTBOUND_TYPES.has(type)) {
    if (!outboundServer(parsed)) {
      return invalid(
        _('Server outbound must contain a non-empty server field'),
      );
    }
    if (!validateServerPort(outboundPort(parsed))) {
      return invalid(
        _('Server outbound must contain a numeric server_port from 1 to 65535'),
      );
    }
  } else if (
    parsed.server_port !== undefined &&
    !validateServerPort(parsed.server_port)
  ) {
    return invalid(_('server_port must be a number from 1 to 65535'));
  }

  if (
    parsed.outbounds !== undefined &&
    Array.isArray(parsed.outbounds) &&
    parsed.outbounds.every((item) => typeof item === 'string') &&
    !validateOutbounds(parsed.outbounds)
  ) {
    return invalid(_('outbounds must be a non-empty array of strings'));
  }

  if (parsed.detour !== undefined && !nonEmptyString(parsed.detour)) {
    return invalid(_('detour must be a non-empty string'));
  }

  return { valid: true, message: _('Valid') };
}

export function validateOutboundJson(
  value: unknown,
  usedTags: string[] = [],
): ValidationResult {
  if (Array.isArray(value)) {
    if (value.length === 0) {
      return invalid(_('JSON outbound cannot be empty'));
    }
    if (value.length === 1) {
      return validateOutboundJson(value[0], usedTags);
    }
    return invalid(_('JSON outbound must be a JSON object'));
  }

  if (isPlainObject(value)) {
    return validateParsedOutbound(unwrapOutbound(value) as Record<string, unknown>, usedTags);
  }

  const normalized = `${value ?? ''}`.trim();
  if (!normalized.length) {
    return invalid(_('JSON outbound cannot be empty'));
  }

  let parsed: unknown;
  try {
    parsed = JSON.parse(normalized);
  } catch {
    return { valid: false, message: _('Invalid JSON format') };
  }

  parsed = unwrapOutbound(parsed);
  if (!isPlainObject(parsed)) {
    return invalid(_('JSON outbound must be a JSON object'));
  }

  return validateParsedOutbound(parsed, usedTags);
}
