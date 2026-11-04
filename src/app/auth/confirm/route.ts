import { NextResponse, type NextRequest } from "next/server";
import { createUserClient } from "@/lib/supabase/server";

/** Target of the email confirmation link. Accepts both link styles Supabase can send. */
export async function GET(request: NextRequest) {
  const { searchParams } = request.nextUrl;
  const code = searchParams.get("code");
  const tokenHash = searchParams.get("token_hash");
  const type = searchParams.get("type");
  const supabase = await createUserClient();

  let signedIn = false;
  if (code) {
    signedIn = !(await supabase.auth.exchangeCodeForSession(code)).error;
  } else if (tokenHash && (type === "email" || type === "signup")) {
    signedIn = !(await supabase.auth.verifyOtp({ type: "email", token_hash: tokenHash })).error;
  }
  // Opened on another device, the code exchange fails but the email is already confirmed.
  return NextResponse.redirect(new URL(signedIn ? "/me" : "/login?confirmed=1", request.url), { status: 303 });
}
