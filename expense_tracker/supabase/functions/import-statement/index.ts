// Imports a bank statement (HDFC .xls, or .xlsx / .csv in a similar layout) for the signed-in user.
//
//   POST { file: <base64>, fileName, accountId?, dryRun, setOpening }
//   dryRun → what would happen; otherwise imports new rows, skipping ones already
//   in the app from bank emails (matched by UPI reference, else amount + day).
//
// Deploy: supabase functions deploy import-statement   (JWT verification on: the user's login)

import { createClient } from "jsr:@supabase/supabase-js@2";
import * as XLSX from "npm:xlsx@0.18.5";
import { defaultCategoryName, merchantKey } from "../ingest-email/parsers.ts";
import { readStatement, type StatementTxn } from "./statement.ts";

const supabase = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
  auth: { persistSession: false },
});

const CORS = {
  "access-control-allow-origin": "*",
  "access-control-allow-headers": "authorization, apikey, content-type, x-client-info",
  "access-control-allow-methods": "POST, OPTIONS",
};

function json(status: number, body: unknown) {
  return new Response(JSON.stringify(body), { status, headers: { ...CORS, "content-type": "application/json" } });
}

const IST_OFFSET = "+05:30";
const dayOf = (iso: string) => new Date(new Date(iso).getTime() + 330 * 60_000).toISOString().slice(0, 10);
const shift = (date: string, days: number) => new Date(new Date(`${date}T12:00:00Z`).getTime() + days * 86_400_000).toISOString().slice(0, 10);

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json(405, { error: "POST only" });

  const jwt = req.headers.get("authorization")?.replace(/^Bearer\s+/i, "");
  const { data: auth } = jwt ? await supabase.auth.getUser(jwt) : { data: { user: null } };
  const user = auth?.user;
  if (!user) return json(401, { error: "Please sign in again." });

  let body: { file?: string; fileName?: string; accountId?: string; dryRun?: boolean; setOpening?: boolean };
  try {
    body = await req.json();
  } catch {
    return json(400, { error: "body must be JSON" });
  }
  if (!body.file) return json(400, { error: "No file." });

  let rows: string[][];
  let kind = "unknown";
  try {
    const bytes = Uint8Array.from(atob(body.file), (c) => c.charCodeAt(0));
    const head = new TextDecoder().decode(bytes.slice(0, 64)).trimStart().toLowerCase();
    kind = head.startsWith("%pdf") ? "pdf" : bytes[0] === 0x50 && bytes[1] === 0x4b ? "xlsx"
      : bytes[0] === 0xd0 && bytes[1] === 0xcf ? "xls" : head.startsWith("<") ? "html" : "text";
    if (kind === "pdf") {
      return json(400, { error: "This is a PDF. In NetBanking choose the format XLS or Delimited, then download again." });
    }
    const wb = XLSX.read(bytes, { type: "array" });
    const sheet = wb.Sheets[wb.SheetNames[0]];
    rows = (XLSX.utils.sheet_to_json(sheet, { header: 1, raw: false, defval: "" }) as unknown[][])
      .map((r) => r.map((c) => String(c ?? "")));
  } catch (e) {
    return json(400, { error: `Could not open the file: ${e}` });
  }
  const st = readStatement(rows);
  if (!st.txns.length) {
    // Say what was in the file, so a new layout can be added.
    const sample = rows.filter((r) => r.some((c) => c.trim())).slice(0, 25)
      .map((r) => r.filter((c) => c.trim()).map((c) => c.trim().slice(0, 18)).slice(0, 7).join(" | "))
      .filter((l) => /date|narration|description|particular|withdraw|deposit|debit|credit|balance/i.test(l)).slice(0, 2);
    return json(400, {
      error: `No transactions found in this ${kind.toUpperCase()} file (${rows.length} rows${body.fileName ? `, ${body.fileName}` : ""}). ` +
        (sample.length ? `Column row seen: ${sample[0]}. ` : "No column titles like Date / Narration / Balance were found. ") +
        "Send a screenshot of this message so the layout can be added.",
    });
  }

  // Which account: the one picked in the app, else the statement's bank + last 4 digits.
  type Acc = { id: string; name: string; bank: string | null; last4: string | null; opening_date: string | null };
  let account: Acc | null = null;
  if (body.accountId) {
    const { data } = await supabase.from("accounts").select("id, name, bank, last4, opening_date")
      .eq("id", body.accountId).eq("user_id", user.id).maybeSingle();
    account = data as Acc | null;
  }
  if (!account && st.bank && st.accountLast4) {
    const { data } = await supabase.from("accounts").select("id, name, bank, last4, opening_date")
      .eq("user_id", user.id).eq("bank", st.bank).eq("last4", st.accountLast4).maybeSingle();
    account = data as Acc | null;
  }
  const accountName = account?.name ?? `${st.bank ?? "Bank"} A/c ••${st.accountLast4 ?? "????"}`;
  const last4 = account?.last4 ?? st.accountLast4 ?? "acct";

  // What the app already has for this account in the statement's period.
  const from = shift(st.from ?? st.txns[0].date, -2), to = shift(st.to ?? st.txns.at(-1)!.date, 2);
  const { data: existingRows } = account
    ? await supabase.from("transactions").select("id, amount, direction, txn_at, email_body, email_id")
      .eq("user_id", user.id).eq("account_id", account.id)
      .gte("txn_at", `${from}T00:00:00${IST_OFFSET}`).lte("txn_at", `${to}T23:59:59${IST_OFFSET}`)
    : { data: [] };
  const existing = (existingRows ?? []) as Array<{ id: string; amount: number; direction: string; txn_at: string; email_body: string | null; email_id: string | null }>;
  // Each statement line is "already there" only if an unused entry of the same day, amount and
  // direction exists (bank emails may be a day off). The same refund reference can repeat across
  // several refunds, so a reference is only a tie-breaker, never enough on its own.
  const used = new Set<string>();
  const occurrence = new Map<string, number>();
  const keyOf = (t: StatementTxn) => {
    const base = `stmt2:${last4}:${t.date}:${t.rrn ?? "-"}:${t.direction}:${t.amount}`;
    const n = (occurrence.get(base) ?? 0) + 1;
    occurrence.set(base, n);
    return n === 1 ? base : `${base}#${n}`;
  };
  const dayDiff = (a: string, b: string) => Math.abs(new Date(`${a}T12:00:00Z`).getTime() - new Date(`${b}T12:00:00Z`).getTime()) / 86_400_000;
  const fresh: Array<StatementTxn & { key: string }> = [];
  let already = 0, fromEmails = 0;
  for (const t of st.txns) {
    const key = keyOf(t);
    const candidates = existing.filter((e) =>
      !used.has(e.id) && Number(e.amount) === t.amount && e.direction === t.direction &&
      (e.email_id?.startsWith("stmt") ? dayOf(e.txn_at) === t.date : dayDiff(dayOf(e.txn_at), t.date) <= 1));
    const byRef = t.rrn ? candidates.find((e) => e.email_body?.includes(t.rrn!) || e.email_id?.includes(t.rrn!)) : undefined;
    const sameDay = candidates.find((e) => dayOf(e.txn_at) === t.date);
    const match = byRef ?? sameDay ?? candidates[0];
    if (match) {
      used.add(match.id);
      if (match.email_id?.startsWith("stmt")) already++; else fromEmails++;
      continue;
    }
    fresh.push({ ...t, key });
  }

  const summary = {
    ok: true,
    account: accountName,
    bank: st.bank,
    from: st.from,
    to: st.to,
    openingBalance: st.openingBalance,
    closingBalance: st.closingBalance,
    rows: st.txns.length,
    debits: st.txns.filter((t) => t.direction === "debit").length,
    credits: st.txns.filter((t) => t.direction === "credit").length,
    alreadyFromEmails: fromEmails,
    alreadyImported: already,
    new: fresh.length,
  };
  if (body.dryRun) return json(200, summary);

  // Create the account if the app has not seen it yet.
  if (!account) {
    const { data } = await supabase.from("accounts").upsert(
      { user_id: user.id, name: accountName, kind: "bank", bank: st.bank, last4: st.accountLast4 },
      { onConflict: "user_id,name" },
    ).select("id, name, bank, last4, opening_date").single();
    account = data as Acc;
  }

  // Categories: the user's own rules (friends included), else defaults for well-known payees.
  const [{ data: rules }, { data: cats }, { data: cash }, { data: known }] = await Promise.all([
    supabase.from("merchant_rules").select("merchant_key, category_id").eq("user_id", user.id),
    supabase.from("categories").select("id, name").eq("user_id", user.id),
    supabase.from("accounts").select("id").eq("user_id", user.id).eq("kind", "cash").limit(1).maybeSingle(),
    supabase.from("transactions").select("merchant").eq("user_id", user.id).not("merchant", "is", null).limit(5000),
  ]);
  const ruleFor = new Map((rules ?? []).map((r) => [r.merchant_key as string, r.category_id as string]));
  const catNamed = new Map((cats ?? []).map((c) => [c.name as string, c.id as string]));
  // Statement names are cut at ~20 letters ("Shreyash Sandeep Shi"): use the full name from emails.
  const fullNames = [...new Set((known ?? []).map((k) => k.merchant as string))];
  const fullName = (m: string | null): string | null => {
    if (!m || m.length < 12) return m;
    const k = merchantKey(m);
    const hits = fullNames.filter((n) => merchantKey(n).startsWith(k) && n.length > m.length);
    return hits.length === 1 ? hits[0] : m;
  };

  const rowsToInsert = fresh.map((t) => {
    const merchant = fullName(t.merchant);
    const category = ruleFor.get(merchantKey(merchant)) ?? catNamed.get(defaultCategoryName(merchant, t.narration) ?? "") ?? null;
    const at = new Date(new Date(`${t.date}T06:00:00${IST_OFFSET}`).getTime() + t.seq * 1000).toISOString();
    return {
      user_id: user.id, source: "statement", email_id: t.key, account_id: account!.id,
      amount: t.amount, direction: t.direction, merchant, method: t.method, txn_at: at, payee_vpa: t.vpa,
      bank: st.bank, account_last4: st.accountLast4, category_id: category,
      excluded: t.atm, counter_account_id: t.atm ? (cash?.id ?? null) : null,
      needs_review: !merchant, note: t.narration.slice(0, 200),
    };
  });
  let added = 0;
  for (let i = 0; i < rowsToInsert.length; i += 200) {
    const { data, error } = await supabase.from("transactions")
      .upsert(rowsToInsert.slice(i, i + 200), { onConflict: "user_id,email_id", ignoreDuplicates: true }).select("id");
    if (error) return json(500, { error: error.message });
    added += data?.length ?? 0;
  }

  // The bank's closing balance at the end of each day.
  const lastOfDay = new Map<string, number>();
  for (const t of st.txns) if (t.closingBalance != null) lastOfDay.set(t.date, t.closingBalance);
  const readings = [...lastOfDay].map(([date, balance]) => ({
    user_id: user.id, account_id: account!.id, balance, as_of: new Date(`${date}T23:59:00${IST_OFFSET}`).toISOString(),
    email_id: `stmtbal:${last4}:${date}`,
  }));
  if (readings.length) {
    await supabase.from("balance_readings").upsert(readings, { onConflict: "user_id,email_id", ignoreDuplicates: true });
  }

  // Only ever move the starting point earlier: a later file must not hide older months.
  if (body.setOpening && st.openingBalance != null && st.from && (!account!.opening_date || st.from < account!.opening_date)) {
    await supabase.from("accounts").update({ opening_balance: st.openingBalance, opening_date: st.from }).eq("id", account!.id);
  }
  await supabase.rpc("link_loan_transactions", { p_user: user.id });
  await supabase.rpc("apply_payee_names", { p_user: user.id });
  await supabase.rpc("apply_people", { p_user: user.id });
  await supabase.rpc("link_wallet_topups", { p_user: user.id });
  await supabase.rpc("link_self_transfers", { p_user: user.id });

  return json(200, { ...summary, added, account: account!.name, balanceCheck: await checkDays(user.id, account!.id, lastOfDay) });
});

/** The app's balance at the end of each statement day next to the bank's closing balance. */
async function checkDays(userId: string, accountId: string, bankByDay: Map<string, number>) {
  const { data: acc } = await supabase.from("accounts").select("opening_balance, opening_date").eq("id", accountId).single();
  const rows: Array<{ amount: number; direction: string; txn_at: string; account_id: string | null; counter_account_id: string | null; excluded: boolean }> = [];
  for (let from = 0; ; from += 1000) {
    const { data } = await supabase.from("transactions")
      .select("amount, direction, txn_at, account_id, counter_account_id, excluded")
      .eq("user_id", userId).or(`account_id.eq.${accountId},counter_account_id.eq.${accountId}`)
      .order("txn_at").range(from, from + 999);
    rows.push(...((data ?? []) as typeof rows));
    if (!data || data.length < 1000) break;
  }
  const openingDate = (acc?.opening_date as string | null) ?? null;
  const effects = rows
    .filter((t) => !openingDate || dayOf(t.txn_at) >= openingDate)
    .map((t) => {
      const signed = (t.direction === "debit" ? -1 : 1) * Number(t.amount);
      let e = 0;
      if (t.account_id === accountId) e += signed;
      if (t.excluded && t.counter_account_id === accountId) e -= signed;
      return { day: dayOf(t.txn_at), e };
    })
    .filter((x) => x.e !== 0);
  const days = [...bankByDay.keys()].sort();
  let i = 0, bal = Number(acc?.opening_balance ?? 0);
  const differences: Array<{ date: string; bank: number; app: number; difference: number }> = [];
  for (const d of days) {
    if (openingDate && d < openingDate) continue;
    while (i < effects.length && effects[i].day <= d) bal += effects[i++].e;
    const bank = bankByDay.get(d)!, app = Math.round(bal * 100) / 100;
    if (Math.abs(bank - app) >= 1) differences.push({ date: d, bank, app, difference: Math.round((bank - app) * 100) / 100 });
  }
  return { days: days.filter((d) => !openingDate || d >= openingDate).length, differences: differences.slice(0, 50), differentDays: differences.length };
}

