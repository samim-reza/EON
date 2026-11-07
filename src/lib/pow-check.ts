import { createHash, createHmac, randomBytes, timingSafeEqual } from "node:crypto";
import { leadingZeroBits, POW_BITS, type PowChallenge } from "@/shared/pow";

const LIFETIME_MS = 30 * 60_000;

/** The challenge is signed and bound to the visitor's network, so a solution can't be shared around. */
function sign(key: string, salt: string, expires: number, bits: number, client: string) {
  return createHmac("sha256", key).update(`pow:${salt}.${expires}.${bits}.${client}`).digest("hex");
}

export function makeChallenge(key: string, client: string, now = Date.now()): PowChallenge {
  const salt = randomBytes(12).toString("hex");
  const expires = now + LIFETIME_MS;
  return { salt, expires, bits: POW_BITS, sig: sign(key, salt, expires, POW_BITS, client) };
}

export function checkSolution(key: string, client: string, fields: Record<string, unknown>, now = Date.now()): "ok" | "expired" | "invalid" {
  const salt = String(fields.pow_salt ?? "");
  const expires = Number(fields.pow_expires);
  const bits = Number(fields.pow_bits);
  const nonce = Number(fields.pow_nonce);
  const sig = String(fields.pow_sig ?? "");
  if (!/^[0-9a-f]{24}$/.test(salt) || !/^[0-9a-f]{64}$/.test(sig) || !Number.isSafeInteger(nonce) || nonce < 0 || bits < POW_BITS) return "invalid";
  const want = Buffer.from(sign(key, salt, expires, bits, client), "hex");
  if (!timingSafeEqual(want, Buffer.from(sig, "hex"))) return "invalid";
  if (expires < now) return "expired";
  const digest = createHash("sha256").update(`${salt}:${nonce}`).digest();
  return leadingZeroBits(digest) >= bits ? "ok" : "invalid";
}
