/**
 * Sealing a player's AI key. AES-256-GCM with a key-encryption key that lives only in the app's
 * environment, never in the database, and with the owner's user id as additional data: a sealed
 * key copied onto another account will not open. Pure, so it can be tested without any secrets.
 */
import { createCipheriv, createDecipheriv, randomBytes } from "node:crypto";

export type Sealed = { ciphertext: string; iv: string; tag: string; version: number };

const aad = (userId: string, version: number) => Buffer.from(`${userId}|v${version}`);

export function seal(kek: Buffer, userId: string, plaintext: string, version = 1): Sealed {
  if (kek.length !== 32) throw new Error("the key-encryption key must be 32 bytes");
  const iv = randomBytes(12);
  const cipher = createCipheriv("aes-256-gcm", kek, iv);
  cipher.setAAD(aad(userId, version));
  const ciphertext = Buffer.concat([cipher.update(plaintext, "utf8"), cipher.final()]);
  return { ciphertext: ciphertext.toString("base64"), iv: iv.toString("base64"), tag: cipher.getAuthTag().toString("base64"), version };
}

/** Throws if anything was tampered with, or if it belongs to another account. */
export function unseal(kek: Buffer, userId: string, sealed: Sealed): string {
  const decipher = createDecipheriv("aes-256-gcm", kek, Buffer.from(sealed.iv, "base64"));
  decipher.setAAD(aad(userId, sealed.version));
  decipher.setAuthTag(Buffer.from(sealed.tag, "base64"));
  return Buffer.concat([decipher.update(Buffer.from(sealed.ciphertext, "base64")), decipher.final()]).toString("utf8");
}
