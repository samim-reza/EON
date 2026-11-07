/**
 * Proof of work for sign-up. The browser must find a number that, hashed with a challenge from the
 * server, starts with enough zero bits: about 65,000 tries, a second or two of work in the
 * background while someone types. Nothing for a person, but real cost for a bot opening accounts
 * by the thousand. It needs no third-party service and tracks nobody.
 */
export const POW_BITS = 16;

export type PowChallenge = { salt: string; expires: number; bits: number; sig: string };

export function leadingZeroBits(bytes: Uint8Array) {
  let bits = 0;
  for (const byte of bytes) {
    if (byte === 0) {
      bits += 8;
      continue;
    }
    return bits + Math.clz32(byte) - 24;
  }
  return bits;
}

const encoder = new TextEncoder();

export async function powDigest(salt: string, nonce: number) {
  return new Uint8Array(await crypto.subtle.digest("SHA-256", encoder.encode(`${salt}:${nonce}`)));
}

/** Searches in batches, so the page stays responsive while it works. */
export async function solvePow(challenge: Pick<PowChallenge, "salt" | "bits">, batch = 512): Promise<number> {
  for (let start = 0; ; start += batch) {
    const digests = await Promise.all(Array.from({ length: batch }, (_, i) => powDigest(challenge.salt, start + i)));
    const hit = digests.findIndex((d) => leadingZeroBits(d) >= challenge.bits);
    if (hit >= 0) return start + hit;
  }
}
