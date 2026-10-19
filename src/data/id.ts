// id generation for UUIDv4 text primary keys (docs/decisions.md 2026-10-19, UUID ids).
// expo-crypto.randomUUID is the device path (Jest and Node fall through to Web Crypto).

type UuidSource = { randomUUID?: () => string };

type WebCryptoLike = {
  getRandomValues?: <T extends Uint8Array>(array: T) => T;
  randomUUID?: () => string;
};

declare const require: (id: string) => unknown;

function load_expo_crypto(): UuidSource | null {
  try {
    return require('expo-crypto') as UuidSource;
  } catch {
    // Not available outside the Expo runtime (for example plain Node test processes).
    return null;
  }
}

function global_crypto(): WebCryptoLike | undefined {
  return (globalThis as unknown as { crypto?: WebCryptoLike }).crypto;
}

function uuid_v4_fallback(): string {
  const bytes = new Uint8Array(16);
  const crypto_object = global_crypto();
  if (crypto_object?.getRandomValues) {
    crypto_object.getRandomValues(bytes);
  } else {
    for (let index = 0; index < bytes.length; index += 1) {
      bytes[index] = Math.floor(Math.random() * 256);
    }
  }
  bytes[6] = ((bytes[6] ?? 0) & 0x0f) | 0x40;
  bytes[8] = ((bytes[8] ?? 0) & 0x3f) | 0x80;
  const hex: string[] = [];
  for (const byte of bytes) {
    hex.push(byte.toString(16).padStart(2, '0'));
  }
  const text = hex.join('');
  return `${text.slice(0, 8)}-${text.slice(8, 12)}-${text.slice(12, 16)}-${text.slice(16, 20)}-${text.slice(20)}`;
}

// Returns a randomUUID string when the source actually produced one. In test harnesses
// (jest-expo) native module methods exist as stubs that return undefined, so every path is
// validated before use; a UUID generator must never hand back undefined.
function uuid_from(source: { randomUUID?: () => string } | undefined): string | null {
  if (!source || typeof source.randomUUID !== 'function') {
    return null;
  }
  const uuid = source.randomUUID();
  return typeof uuid === 'string' && uuid !== '' ? uuid : null;
}

export function generate_id(): string {
  const expo_uuid = uuid_from(load_expo_crypto() ?? undefined);
  if (expo_uuid !== null) {
    return expo_uuid;
  }
  const web_uuid = uuid_from(global_crypto());
  if (web_uuid !== null) {
    return web_uuid;
  }
  return uuid_v4_fallback();
}
