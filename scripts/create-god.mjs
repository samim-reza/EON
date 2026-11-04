// Creates the one-and-only God account (email pre-confirmed) with a strong random password.
// The database trigger binds God to this account automatically.
// Usage: GOD_EMAIL=you@example.com node --env-file=<env file> scripts/create-god.mjs <output-file-for-password>
import { createClient } from "@supabase/supabase-js";
import { randomBytes } from "node:crypto";
import { writeFileSync } from "node:fs";

const GOD_EMAIL = process.env.GOD_EMAIL?.trim().toLowerCase();
if (!GOD_EMAIL) throw new Error("set GOD_EMAIL (it must hash to app.god_email_sha256() in the database)");
const out = process.argv[2];
if (!out) {
  console.error("usage: create-god.mjs <password-output-file>");
  process.exit(2);
}
const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
const key = process.env.SUPABASE_SECRET_KEY;
if (!url || !key) throw new Error("missing NEXT_PUBLIC_SUPABASE_URL / SUPABASE_SECRET_KEY");

const supabase = createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } });
// 24 random bytes → 32 base64url chars (letters + digits guaranteed with the suffix)
const password = randomBytes(24).toString("base64url") + "a1";
const { data, error } = await supabase.auth.admin.createUser({
  email: GOD_EMAIL,
  password,
  email_confirm: true,
  user_metadata: { username: "creator" },
});
if (error) {
  console.error("createUser failed:", error.message);
  process.exit(1);
}
writeFileSync(out, `GOD_EMAIL=${GOD_EMAIL}\nGOD_PASSWORD=${password}\n`, { mode: 0o600 });
console.log(`God account created (${data.user.id}); password written to ${out}`);
