// Receives bank alert emails from each user's Google Apps Script, turns them
// into transactions and stores them for the user who owns the ingest token.
//
// Deploy:  supabase functions deploy ingest-email --no-verify-jwt
// (The script authenticates with the per-user `x-ingest-token` header instead of a JWT.)

import { createClient } from "jsr:@supabase/supabase-js@2";
import { looksTransactional, merchantKey, parseBankEmail, type EmailInput } from "./parsers.ts";

const MAX_MESSAGES = 100;
const MAX_BODY = 8000;

const supabase = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  { auth: { persistSession: false } },
);

function json(status: number, body: unknown) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json(405, { error: "POST only" });

  const token = req.headers.get("x-ingest-token")?.trim();
  if (!token || !/^[0-9a-f]{48}$/.test(token)) return json(401, { error: "missing or malformed token" });

  const { data: profile, error: profileError } = await supabase
    .from("profiles").select("id").eq("ingest_token", token).maybeSingle();
  if (profileError) return json(500, { error: profileError.message });
  if (!profile) return json(401, { error: "unknown token – copy the script again from the app" });
  const userId: string = profile.id;

  let payload: { messages?: EmailInput[] };
  try {
    payload = await req.json();
  } catch {
    return json(400, { error: "body must be JSON" });
  }
  const messages = (payload.messages ?? []).slice(0, MAX_MESSAGES).filter((m) =>
    m && typeof m.id === "string" && typeof m.body === "string"
  );

  const { data: rules } = await supabase
    .from("merchant_rules").select("merchant_key, category_id").eq("user_id", userId);
  const ruleFor = new Map((rules ?? []).map((r) => [r.merchant_key as string, r.category_id as string]));

  const rows = [];
  const unparsed = [];
  for (const m of messages) {
    const email: EmailInput = {
      id: m.id,
      from: String(m.from ?? ""),
      subject: String(m.subject ?? ""),
      date: String(m.date ?? new Date().toISOString()),
      body: m.body.slice(0, MAX_BODY),
    };
    const result = parseBankEmail(email);
    if (result.ok) {
      const t = result.txn;
      rows.push({
        user_id: userId,
        amount: t.amount,
        direction: t.direction,
        merchant: t.merchant,
        bank: t.bank,
        account_last4: t.accountLast4,
        method: t.method,
        txn_at: t.txnAt,
        category_id: ruleFor.get(merchantKey(t.merchant)) ?? null,
        source: "email",
        email_id: email.id,
        email_subject: email.subject.slice(0, 200),
        excluded: t.isTransfer,
        needs_review: !t.merchant,
      });
    } else if (result.reason === "unreadable" || looksTransactional(`${email.subject} ${email.body}`)) {
      unparsed.push({
        user_id: userId,
        email_id: email.id,
        from_addr: email.from.slice(0, 200),
        subject: email.subject.slice(0, 200),
        body: email.body.slice(0, 2000),
        received_at: email.date,
      });
    }
  }

  let added = 0;
  if (rows.length) {
    const { data, error } = await supabase.from("transactions")
      .upsert(rows, { onConflict: "user_id,email_id", ignoreDuplicates: true })
      .select("id");
    if (error) return json(500, { error: error.message });
    added = data?.length ?? 0;
  }
  if (unparsed.length) {
    await supabase.from("unparsed_emails")
      .upsert(unparsed, { onConflict: "user_id,email_id", ignoreDuplicates: true });
  }
  await supabase.from("profiles").update({ last_sync_at: new Date().toISOString() }).eq("id", userId);

  return json(200, {
    ok: true,
    received: messages.length,
    parsed: rows.length,
    added,
    unreadable: unparsed.length,
  });
});
