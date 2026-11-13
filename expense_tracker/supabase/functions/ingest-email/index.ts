// Receives bank alert emails from each user's Google Apps Script, turns them
// into transactions and stores them for the user who owns the ingest token.
//
//   GET  → which senders / words the script should search Gmail for
//   POST → { messages: [...] } → transactions
//
// Deploy:  supabase functions deploy ingest-email --no-verify-jwt
// (The script authenticates with the per-user `x-ingest-token` header instead of a JWT.)

import { createClient } from "jsr:@supabase/supabase-js@2";
import {
  BANK_SENDERS,
  type EmailInput,
  isLenderSender,
  LENDER_SENDERS,
  looksTransactional,
  merchantKey,
  type ParsedTxn,
  parseBankEmail,
  SEARCH_KEYWORDS,
} from "./parsers.ts";

const MAX_MESSAGES = 100;
const MAX_BODY = 8000;
const KEEP_BODY = 4000;

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
  if (req.method !== "POST" && req.method !== "GET") return json(405, { error: "GET or POST only" });

  const token = req.headers.get("x-ingest-token")?.trim();
  if (!token || !/^[0-9a-f]{48}$/.test(token)) return json(401, { error: "missing or malformed token" });

  const { data: profile, error: profileError } = await supabase
    .from("profiles").select("id").eq("ingest_token", token).maybeSingle();
  if (profileError) return json(500, { error: profileError.message });
  if (!profile) return json(401, { error: "unknown token – copy the script again from the app" });
  const userId: string = profile.id;

  if (req.method === "GET") {
    const senders = [...new Set([...BANK_SENDERS, ...LENDER_SENDERS])];
    return json(200, { ok: true, senders, keywords: SEARCH_KEYWORDS });
  }

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

  const accounts = await loadAccounts(userId);
  const cashId = accounts.find((a) => a.kind === "cash")?.id ?? null;

  // Rows already stored for these emails: re-read them unless the user edited them.
  const ids = messages.map((m) => m.id);
  const { data: existingRows } = ids.length
    ? await supabase.from("transactions").select("id, email_id, edited, category_id")
      .eq("user_id", userId).in("email_id", ids)
    : { data: [] };
  const existing = new Map((existingRows ?? []).map((r) => [r.email_id as string, r]));

  const inserts = [];
  const updates: Array<{ id: string; row: Record<string, unknown> }> = [];
  const unparsed = [];
  for (const m of messages) {
    const email: EmailInput = {
      id: m.id,
      from: String(m.from ?? ""),
      subject: String(m.subject ?? ""),
      date: String(m.date ?? new Date().toISOString()),
      body: m.body.slice(0, MAX_BODY),
    };
    const lender = isLenderSender(email.from);
    const result = parseBankEmail(email);
    if (result.ok) {
      const t = result.txn;
      const accountId = await accountFor(userId, accounts, t);
      // ATM cash: money moves from the bank account into Cash; it is not spending.
      const atm = t.method === "atm" && t.direction === "debit";
      const row = {
        amount: t.amount,
        direction: t.direction,
        merchant: t.merchant,
        bank: t.bank,
        account_last4: t.accountLast4,
        method: t.method,
        txn_at: t.txnAt,
        account_id: accountId,
        counter_account_id: atm ? cashId : null,
        excluded: t.isTransfer || atm,
        needs_review: !t.merchant,
        email_subject: email.subject.slice(0, 200),
        email_body: email.body.slice(0, KEEP_BODY),
        email_from: email.from.slice(0, 200),
        email_received_at: email.date,
      };
      const rule = ruleFor.get(merchantKey(t.merchant)) ?? null;
      const old = existing.get(email.id);
      if (!old) {
        inserts.push({ ...row, user_id: userId, source: "email", email_id: email.id, category_id: rule });
      } else if (!old.edited) {
        updates.push({ id: old.id as string, row: { ...row, category_id: old.category_id ?? rule } });
      }
    }
    if (lender || (!result.ok && (result.reason === "unreadable" || looksTransactional(`${email.subject} ${email.body}`)))) {
      unparsed.push({
        user_id: userId,
        email_id: email.id,
        from_addr: email.from.slice(0, 200),
        subject: email.subject.slice(0, 200),
        body: email.body.slice(0, lender ? KEEP_BODY : 2000),
        received_at: email.date,
        kind: lender ? "lender" : "unreadable",
      });
    }
  }

  let added = 0;
  if (inserts.length) {
    const { data, error } = await supabase.from("transactions")
      .upsert(inserts, { onConflict: "user_id,email_id", ignoreDuplicates: true })
      .select("id");
    if (error) return json(500, { error: error.message });
    added = data?.length ?? 0;
  }
  let updated = 0;
  for (const u of updates) {
    const { error } = await supabase.from("transactions").update(u.row).eq("id", u.id).eq("edited", false);
    if (!error) updated++;
  }
  if (unparsed.length) {
    await supabase.from("unparsed_emails")
      .upsert(unparsed, { onConflict: "user_id,email_id", ignoreDuplicates: true });
  }
  await supabase.from("profiles").update({ last_sync_at: new Date().toISOString() }).eq("id", userId);

  return json(200, {
    ok: true,
    received: messages.length,
    parsed: inserts.length + updates.length,
    added,
    updated,
    unreadable: unparsed.filter((u) => u.kind === "unreadable").length,
    lender: unparsed.filter((u) => u.kind === "lender").length,
  });
});

type Account = { id: string; name: string; kind: string; bank: string | null; last4: string | null };

async function loadAccounts(userId: string): Promise<Account[]> {
  const { data } = await supabase.from("accounts")
    .select("id, name, kind, bank, last4").eq("user_id", userId);
  return (data ?? []) as Account[];
}

/** The user's account for this bank + last 4 digits, created on first sight. */
async function accountFor(userId: string, accounts: Account[], t: ParsedTxn): Promise<string | null> {
  if (!t.bank) return null;
  if (!t.accountLast4) {
    const same = accounts.filter((a) => a.bank === t.bank && a.kind === t.accountKind);
    return same.length === 1 ? same[0].id : null;
  }
  const found = accounts.find((a) => a.bank === t.bank && a.last4 === t.accountLast4);
  if (found) return found.id;

  const name = `${t.bank} ${t.accountKind === "card" ? "Card" : "A/c"} ••${t.accountLast4}`.slice(0, 40);
  const { data } = await supabase.from("accounts")
    .upsert({ user_id: userId, name, kind: t.accountKind, bank: t.bank, last4: t.accountLast4 },
      { onConflict: "user_id,name" })
    .select("id, name, kind, bank, last4").single();
  if (!data) return null;
  accounts.push(data as Account);
  return (data as Account).id;
}
