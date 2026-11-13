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
  isReviewSender,
  LENDER_SENDERS,
  LOAN_HISTORY_SEARCH,
  type LenderEvent,
  type LenderKey,
  lenderOf,
  parseLenderEmail,
  looksTransactional,
  merchantKey,
  type ParsedTxn,
  defaultCategoryName,
  findPayeeVpa,
  parseBalanceEmail,
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
    return json(200, { ok: true, senders, keywords: SEARCH_KEYWORDS, loanSearch: LOAN_HISTORY_SEARCH });
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
  const { data: cats } = await supabase.from("categories").select("id, name").eq("user_id", userId);
  const categoryNamed = new Map((cats ?? []).map((c) => [c.name as string, c.id as string]));
  /** The user's rule for this payee, else a default for well-known names (Zomato → Food & Dining). */
  const categoryFor = (merchant: string | null, details?: string): string | null =>
    ruleFor.get(merchantKey(merchant)) ?? categoryNamed.get(defaultCategoryName(merchant, details) ?? "") ?? null;

  const accounts = await loadAccounts(userId);
  const cashId = accounts.find((a) => a.kind === "cash")?.id ?? null;

  // Rows already stored for these emails: re-read them unless the user edited them.
  const ids = messages.map((m) => m.id);
  const { data: existingRows } = ids.length
    ? await supabase.from("transactions").select("id, email_id, edited, category_id")
      .eq("user_id", userId).in("email_id", ids)
    : { data: [] };
  const existing = new Map((existingRows ?? []).map((r) => [r.email_id as string, r]));
  // Emails already attached to a statement entry.
  const { data: attachedRows } = ids.length
    ? await supabase.from("transactions").select("email_ref").eq("user_id", userId).in("email_ref", ids)
    : { data: [] };
  const attached = new Set((attachedRows ?? []).map((r) => r.email_ref as string));
  // Statement entries an old email may describe (resyncing far back): same account, amount and direction,
  // within a day. Loaded lazily, once per batch.
  let stmtRows: Array<{ id: string; account_id: string | null; amount: number; direction: string; txn_at: string; payee_vpa: string | null; merchant: string | null }> | null = null;
  const usedStmt = new Set<string>();
  const istDay = (iso: string) => new Date(new Date(iso).getTime() + 330 * 60_000).toISOString().slice(0, 10);
  const statementTwin = async (accountId: string | null, amount: number, direction: string, at: string) => {
    if (!accountId) return null;
    if (stmtRows === null) {
      const dates = messages.map((m) => new Date(String(m.date ?? "")).getTime()).filter((n) => !Number.isNaN(n));
      if (!dates.length) return null;
      const from = new Date(Math.min(...dates) - 3 * 86_400_000).toISOString();
      const to = new Date(Math.max(...dates) + 2 * 86_400_000).toISOString();
      const { data } = await supabase.from("transactions")
        .select("id, account_id, amount, direction, txn_at, payee_vpa, merchant")
        .eq("user_id", userId).eq("source", "statement").is("email_ref", null)
        .gte("txn_at", from).lte("txn_at", to).limit(5000);
      stmtRows = (data ?? []) as typeof stmtRows;
    }
    const day = new Date(`${istDay(at)}T12:00:00Z`).getTime();
    const near = stmtRows!.filter((r) => !usedStmt.has(r.id) && r.account_id === accountId && Number(r.amount) === amount &&
      r.direction === direction && Math.abs(new Date(`${istDay(r.txn_at)}T12:00:00Z`).getTime() - day) <= 86_400_000);
    const best = near.find((r) => istDay(r.txn_at) === istDay(at)) ?? near[0] ?? null;
    if (best) usedStmt.add(best.id);
    return best;
  };
  let attachedNow = 0;

  const lenderEvents: Array<{ email: EmailInput; ev: LenderEvent }> = [];
  const readings: Array<Record<string, unknown>> = [];
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
    if (lender) {
      const ev = parseLenderEmail(email);
      if (ev === "ignore") continue;
      if (ev) {
        lenderEvents.push({ email, ev });
        continue;
      }
    }
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
        payee_vpa: findPayeeVpa(`${email.subject} ${email.body}`),
      };
      if (t.balanceAfter != null && accountId) {
        readings.push({ user_id: userId, account_id: accountId, balance: t.balanceAfter, as_of: t.txnAt, email_id: email.id });
      }
      const rule = categoryFor(t.merchant, (`${email.subject} ${email.body}`.match(/VPA:?\s*\S+@[\w.\-]+/i) ?? [""])[0]);
      const old = existing.get(email.id);
      if (!old && attached.has(email.id)) continue;
      const twin = old ? null : await statementTwin(accountId, t.amount, t.direction, t.txnAt);
      if (twin) {
        // Already in the app from a statement: add the email's details to it instead of a second entry.
        await supabase.from("transactions").update({
          email_ref: email.id,
          email_subject: row.email_subject, email_body: row.email_body, email_from: row.email_from,
          email_received_at: row.email_received_at,
          payee_vpa: twin.payee_vpa ?? row.payee_vpa,
          ...(twin.merchant ? {} : { merchant: row.merchant }),
        }).eq("id", twin.id);
        attachedNow++;
        continue;
      }
      if (!old) {
        inserts.push({ ...row, user_id: userId, source: "email", email_id: email.id, category_id: rule });
      } else if (!old.edited) {
        updates.push({ id: old.id as string, row: { ...row, category_id: old.category_id ?? rule } });
      }
    }
    if (!result.ok) {
      // Daily balance / low-balance emails: a balance reading for that account.
      const b = parseBalanceEmail(email);
      const acc = b && b.bank && b.accountLast4
        ? accounts.find((a) => a.bank === b.bank && a.last4 === b.accountLast4)
        : undefined;
      if (b && acc) {
        readings.push({ user_id: userId, account_id: acc.id, balance: b.balance, as_of: b.asOf, email_id: email.id });
        continue;
      }
    }
    const review = isReviewSender(email.from);
    if ((lender && !result.ok) || review || (!result.ok && (result.reason === "unreadable" || looksTransactional(`${email.subject} ${email.body}`)))) {
      unparsed.push({
        user_id: userId,
        email_id: email.id,
        from_addr: email.from.slice(0, 200),
        subject: email.subject.slice(0, 200),
        body: email.body.slice(0, lender || review ? KEEP_BODY : 2000),
        received_at: email.date,
        kind: lender ? "lender" : review ? "review" : "unreadable",
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
  if (readings.length) {
    await supabase.from("balance_readings").upsert(readings, { onConflict: "user_id,email_id", ignoreDuplicates: true });
  }

  let loanEvents = 0;
  for (const { email, ev } of lenderEvents) {
    const loan = await ensureLoan(userId, lenderOf(email.from), accounts);
    if (!loan) continue;
    if (ev.kind === "due") {
      if (ev.dueDate && (!loan.next_due_date || ev.dueDate >= loan.next_due_date)) {
        await supabase.from("loans").update({ next_due_amount: ev.amount, next_due_date: ev.dueDate }).eq("id", loan.id);
        loan.next_due_date = ev.dueDate;
      }
      loanEvents++;
      continue;
    }
    let txnId: string | null = null;
    if (ev.kind === "spend") {
      // A purchase paid by the loan is real spending, from the loan's own account.
      const { data: t } = await supabase.from("transactions").upsert({
        user_id: userId, source: "email", email_id: email.id,
        amount: ev.amount, direction: "debit", merchant: ev.merchant, method: "other",
        txn_at: ev.at, account_id: loan.account_id, loan_id: loan.id, loan_role: "spend",
        category_id: categoryFor(ev.merchant),
        email_subject: email.subject.slice(0, 200), email_body: email.body.slice(0, KEEP_BODY),
        email_from: email.from.slice(0, 200), email_received_at: email.date,
      }, { onConflict: "user_id,email_id" }).select("id").maybeSingle();
      txnId = (t?.id as string | undefined) ?? null;
    }
    const { data: e } = await supabase.from("loan_events").upsert({
      user_id: userId, loan_id: loan.id, kind: ev.kind, amount: ev.amount, event_at: ev.at,
      email_id: email.id, txn_id: txnId, note: ev.merchant ?? email.subject.slice(0, 120),
    }, { onConflict: "user_id,email_id", ignoreDuplicates: true }).select("id");
    loanEvents += e?.length ?? 0;
  }
  await supabase.rpc("link_loan_transactions", { p_user: userId });
  await supabase.rpc("apply_payee_names", { p_user: userId });
  await supabase.rpc("fix_vpa_names", { p_user: userId });
  await supabase.rpc("apply_vpa_rules", { p_user: userId });
  await supabase.rpc("apply_people", { p_user: userId });
  await supabase.rpc("link_wallet_topups", { p_user: userId });
  await supabase.rpc("link_self_transfers", { p_user: userId });

  if (unparsed.length) {
    await supabase.from("unparsed_emails")
      .upsert(unparsed, { onConflict: "user_id,email_id", ignoreDuplicates: true });
  }
  await supabase.from("profiles").update({ last_sync_at: new Date().toISOString() }).eq("id", userId);

  return json(200, {
    ok: true,
    received: messages.length,
    parsed: inserts.length + updates.length + attachedNow,
    added,
    matchedStatement: attachedNow,
    updated,
    unreadable: unparsed.filter((u) => u.kind === "unreadable").length,
    lender: unparsed.filter((u) => u.kind === "lender").length + lenderEvents.length,
    loanEvents,
    balances: readings.length,
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
    if (same.length === 1) return same[0].id;
    if (t.accountKind !== "wallet" || same.length > 1) return null;
    // A wallet has no account number: one per provider, e.g. "Amazon Pay balance".
    const { data } = await supabase.from("accounts")
      .upsert({ user_id: userId, name: `${t.bank} balance`, kind: "wallet", bank: t.bank }, { onConflict: "user_id,name" })
      .select("id, name, kind, bank, last4").single();
    if (!data) return null;
    accounts.push(data as Account);
    return (data as Account).id;
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

type Loan = { id: string; account_id: string | null; next_due_date: string | null };

const KNOWN_LENDERS: Record<Exclude<LenderKey, "other">, { name: string; kind: string; aliases: string[] }> = {
  slice: { name: "Slice borrow", kind: "credit_line", aliases: ["slice", "slice borrow", "slice small finance bank"] },
  kreditbee: { name: "KreditBee", kind: "emi", aliases: ["kreditbee", "krazybee", "krazybee services", "kbmas"] },
  fibe: { name: "Fibe", kind: "emi", aliases: ["fibe", "earlysalary", "social worth technologies", "fibe.cf."] },
};

/** The user's loan for this lender, made the first time one of its emails arrives. */
async function ensureLoan(userId: string, key: LenderKey, accounts: Account[]): Promise<Loan | null> {
  if (key === "other") return null;
  const def = KNOWN_LENDERS[key];
  const { data: found } = await supabase.from("loans").select("id, account_id, next_due_date")
    .eq("user_id", userId).eq("lender", key).eq("closed", false).order("created_at").limit(1).maybeSingle();
  if (found) return found as Loan;

  let accountId: string | null = null;
  if (def.kind === "credit_line") {
    const { data: acc } = await supabase.from("accounts")
      .upsert({ user_id: userId, name: def.name, kind: "card" }, { onConflict: "user_id,name" })
      .select("id, name, kind, bank, last4").single();
    if (acc) {
      accountId = acc.id as string;
      accounts.push(acc as Account);
    }
  }
  const { data } = await supabase.from("loans").upsert({
    user_id: userId, lender: key, name: def.name, kind: def.kind, aliases: def.aliases, account_id: accountId,
  }, { onConflict: "user_id,name" }).select("id, account_id, next_due_date").single();
  return (data as Loan | null) ?? null;
}
