import "server-only";
import nodemailer, { type Transporter } from "nodemailer";
import type { Email } from "@/shared/emails";

let transport: Transporter | null = null;

export const mailReady = () => Boolean(process.env.SMTP_USER && process.env.SMTP_PASS && process.env.MAIL_FROM);

/** Sends through the same SMTP relay Supabase Auth uses. Throws on failure; the caller retries later. */
export async function sendMail(to: string, email: Email) {
  transport ??= nodemailer.createTransport({
    host: process.env.SMTP_HOST ?? "smtp-relay.brevo.com", port: 587, secure: false, requireTLS: true,
    auth: { user: process.env.SMTP_USER, pass: process.env.SMTP_PASS },
    connectionTimeout: 10_000, greetingTimeout: 10_000, socketTimeout: 15_000,
  });
  await transport.sendMail({ from: process.env.MAIL_FROM, to, subject: email.subject, text: email.text, html: email.html });
}
