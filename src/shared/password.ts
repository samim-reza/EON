import { z } from "zod";

/** The one set of password rules, used at sign-up and when choosing a new password. */
export const passwordSchema = z
  .string()
  .min(12, "Passwords need at least 12 characters.")
  .max(72, "Passwords can be at most 72 characters.")
  .regex(/[a-zA-Z]/, "Passwords need at least one letter.")
  .regex(/\d/, "Passwords need at least one digit.");

/** Shape of the one-time token in a password-reset link. */
export const resetTokenSchema = z.string().regex(/^[A-Za-z0-9_-]{16,128}$/);
