import "server-only";
import { seal, unseal, type Sealed } from "@/shared/seal";

const VERSION = 1;

/** The key-encryption key: 32 random bytes, base64, only in the app's environment. */
function kek(): Buffer | null {
  const raw = process.env.BYOK_KEK;
  if (!raw) return null;
  const key = Buffer.from(raw, "base64");
  return key.length === 32 ? key : null;
}

export const keysReady = () => kek() !== null;

export function sealKey(userId: string, key: string): Sealed {
  const k = kek();
  if (!k) throw new Error("keys are not configured");
  return seal(k, userId, key.trim(), VERSION);
}

export function openKey(userId: string, sealed: Sealed): string {
  const k = kek();
  if (!k) throw new Error("keys are not configured");
  return unseal(k, userId, sealed);
}
