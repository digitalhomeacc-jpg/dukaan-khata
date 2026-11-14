// Bank statement reader (HDFC layout, plus a generic one): spreadsheet rows → transactions.
// Pure TypeScript: used by the import-statement Edge Function and unit-tested with Node.

import { cleanMerchant, type Method, vpaTail } from "../ingest-email/parsers.ts";

export interface StatementTxn {
  /** YYYY-MM-DD */
  date: string;
  /** Order within the statement, keeps same-day rows in sequence. */
  seq: number;
  narration: string;
  ref: string | null;
  /** 12-digit UPI/IMPS reference, used to match the bank's email for the same payment. */
  rrn: string | null;
  amount: number;
  direction: "debit" | "credit";
  closingBalance: number | null;
  merchant: string | null;
  /** Payee's UPI ID, shortened like vpaTail(). */
  vpa: string | null;
  method: Method;
  /** ATM cash: a move from the bank account into Cash. */
  atm: boolean;
}

export interface Statement {
  bank: string | null;
  accountLast4: string | null;
  from: string | null;
  to: string | null;
  openingBalance: number | null;
  closingBalance: number | null;
  txns: StatementTxn[];
}

const STATEMENT_MONTHS: Record<string, string> = {
  jan: "01", feb: "02", mar: "03", apr: "04", may: "05", jun: "06",
  jul: "07", aug: "08", sep: "09", oct: "10", nov: "11", dec: "12",
};

/** "01/08/26", "01-08-2026", "01 Aug 2026", "2026-08-01" → "2026-08-01". */
export function statementDate(v: string): string | null {
  const s = v.trim();
  let m = s.match(/^(\d{1,2})[\/\-.](\d{1,2})[\/\-.](\d{2}|\d{4})$/);
  if (m) {
    const y = m[3].length === 2 ? `20${m[3]}` : m[3];
    return `${y}-${m[2].padStart(2, "0")}-${m[1].padStart(2, "0")}`;
  }
  m = s.match(/^(\d{1,2})[\s\-]([A-Za-z]{3})[a-z]*[\s\-,]+'?(\d{2}|\d{4})$/);
  if (m && STATEMENT_MONTHS[m[2].toLowerCase()]) {
    const y = m[3].length === 2 ? `20${m[3]}` : m[3];
    return `${y}-${STATEMENT_MONTHS[m[2].toLowerCase()]}-${m[1].padStart(2, "0")}`;
  }
  m = s.match(/^(\d{4})-(\d{2})-(\d{2})/);
  return m ? `${m[1]}-${m[2]}-${m[3]}` : null;
}

function amount(v: string | undefined): number | null {
  if (v == null) return null;
  const s = String(v).replace(/[,₹\s]|INR|Rs\.?/gi, "").replace(/(Cr|Dr)$/i, "");
  if (!s || s === "-") return null;
  const n = Number(s);
  return Number.isFinite(n) ? n : null;
}

/** Payee and method from a narration such as "UPI-SHRESTH SHARMA-96…@MBK-PPIW0881822-657901454191-UPI". */
export function readNarration(n: string): { merchant: string | null; method: Method; rrn: string | null; atm: boolean } {
  const s = n.replace(/\s+/g, " ").trim();
  const rrn = s.match(/\b(\d{12})\b/)?.[1] ?? null;
  if (/INSTAALERTCHG|SMS\s*ALERT|ALERT\s*CHG/i.test(s)) return { merchant: "Bank alert charges", method: "other", rrn, atm: false };
  if (/^(UPIRET|REV-UPI|UPI\s*REV)/i.test(s)) return { merchant: "UPI refund", method: "upi", rrn, atm: false };
  if (/stipend/i.test(s)) return { merchant: "Stipend", method: "netbanking", rrn, atm: false };
  // Slice: "BW…" is a slice borrow order paid into the account; "Repayment" pays it back.
  if (/^BW[0-9a-z]*\b/i.test(s)) return { merchant: "Slice borrow", method: "other", rrn, atm: false };
  if (/^repayment\b/i.test(s)) return { merchant: "Slice borrow repayment", method: "other", rrn, atm: false };
  // Slice / other banks: "UPI Debit-NAME-VPA-…", "UPI Credit-NAME-VPA-…", "IMPS Credit-NAME-…"
  let w = s.match(/^UPI\s+(?:Debit|Credit|Dr|Cr)\s*-\s*([^-]+?)\s*-\s*([^\s]*@[^-\s]+)?/i);
  if (w) return { merchant: cleanMerchant(w[1]), method: "upi", rrn, atm: false };
  w = s.match(/^IMPS\s+(?:Debit|Credit|Dr|Cr)\s*-\s*([^-]+)/i);
  if (w) return { merchant: cleanMerchant(w[1]), method: "netbanking", rrn, atm: false };
  // Name first, then the UPI ID (which may itself contain a dash: "7822965946-2@ybl").
  let m = s.match(/^UPI[-\/]([^-]+?)-([^\s]*@[^-\s]+)(?:-|$)/i);
  if (m) return { merchant: cleanMerchant(m[1]), method: "upi", rrn, atm: false };
  m = s.match(/^UPI[-\/]([^-]+)-/i);
  if (m) return { merchant: cleanMerchant(m[1]), method: "upi", rrn, atm: false };
  // ATM fees and charges are money the bank kept, not cash in your hand.
  if (/\bATM\b.*\b(FEE|FEES|CHG|CHGS|CHARGES?)\b|\b(FEE|CHG|CHARGES?)\b.*\bATM\b/i.test(s)) {
    return { merchant: "ATM fees", method: "other", rrn, atm: false };
  }
  if (/^(ATW|NWD|EAW|ATM)[-\s]/i.test(s) || /\bATM\s*(WDL|CASH)/i.test(s)) {
    return { merchant: "ATM cash", method: "atm", rrn, atm: true };
  }
  m = s.match(/^NEFT\s*(?:DR|CR)?-[^-]*-([^-]+)-/i) ?? s.match(/^RTGS\s*(?:DR|CR)?-[^-]*-([^-]+)-/i);
  if (m) return { merchant: cleanMerchant(m[1]), method: "netbanking", rrn, atm: false };
  m = s.match(/^IMPS-\d+-([^-]+)-/i);
  if (m) return { merchant: cleanMerchant(m[1]), method: "netbanking", rrn, atm: false };
  m = s.match(/^ACH\s*[DC]?-?\s*([^-]+)-/i);
  if (m) return { merchant: cleanMerchant(m[1].replace(/^\s*-\s*/, "")), method: "netbanking", rrn, atm: false };
  m = s.match(/^(?:POS|ME DC SI|PCD)\s+\S*\s+(.+?)(?:\s{2,}|$)/i);
  if (m) return { merchant: cleanMerchant(m[1]), method: "card", rrn, atm: false };
  if (/interest/i.test(s)) return { merchant: "Bank interest", method: "other", rrn, atm: false };
  return { merchant: cleanMerchant(s.slice(0, 40)), method: "other", rrn, atm: false };
}

const COLS = {
  date: /^(txn\s*|transaction\s*)?date$/i,
  narration: /narration|description|particulars|remarks|details/i,
  ref: /ref|chq|cheque/i,
  debit: /withdrawal|debit|dr\b/i,
  credit: /deposit|credit|cr\b/i,
  balance: /balance/i,
};

/** Reads statement rows (each row an array of cell texts). */
export function readStatement(rows: string[][]): Statement {
  const headerRow = rows.findIndex((r) =>
    r.some((c) => COLS.narration.test(c)) && r.some((c) => COLS.balance.test(c)) && r.some((c) => COLS.date.test(c.trim()))
  );
  // Bank and account come from the top of the statement, never from transaction lines
  // (a payment to someone at HDFC must not make a Slice statement "HDFC").
  const text = rows.slice(0, headerRow > 0 ? headerRow : 40).map((r) => r.join(" ")).join("\n");
  // Slice is run by North East Small Finance Bank (IFSC NESF…).
  const bank = /\bslice\b|NESF0/i.test(text) ? "Slice" : /hdfc/i.test(text) ? "HDFC" : /icici/i.test(text) ? "ICICI"
    : /state bank|sbi/i.test(text) ? "SBI" : /axis/i.test(text) ? "Axis" : /federal/i.test(text) ? "Federal" : null;
  const acc = text.match(/(?:account|a\/c)\s*(?:no|number)\.?\s*:?\s*[x*]*(\d{4,})/i);
  const period = text.match(/from\s*:?\s*(\d{1,2}\/\d{1,2}\/\d{2,4})\s*to\s*:?\s*(\d{1,2}\/\d{1,2}\/\d{2,4})/i);

  const headerAt = headerRow;
  const st: Statement = {
    bank,
    accountLast4: acc ? acc[1].slice(-4) : null,
    from: period ? statementDate(period[1]) : null,
    to: period ? statementDate(period[2]) : null,
    openingBalance: null,
    closingBalance: null,
    txns: [],
  };
  if (headerAt < 0) return st;
  const h = rows[headerAt].map((c) => String(c).trim());
  const col = (re: RegExp, not?: RegExp) => h.findIndex((c) => re.test(c) && !(not?.test(c)));
  const cDate = h.findIndex((c) => COLS.date.test(c));
  const cNar = col(COLS.narration);
  const cRef = col(COLS.ref, COLS.narration);
  const cDr = col(COLS.debit, COLS.balance);
  const cCr = col(COLS.credit, COLS.balance);
  const cBal = col(COLS.balance);

  let seq = 0;
  for (const r of rows.slice(headerAt + 1)) {
    const date = statementDate(String(r[cDate] ?? ""));
    if (!date) continue;
    const dr = amount(r[cDr]), cr = amount(r[cCr]);
    const value = dr && dr > 0 ? dr : cr && cr > 0 ? cr : null;
    if (value == null) continue;
    const narration = String(r[cNar] ?? "").trim();
    const info = readNarration(narration);
    const ref = cRef >= 0 ? String(r[cRef] ?? "").trim() || null : null;
    st.txns.push({
      date,
      seq: seq++,
      narration,
      ref,
      rrn: info.rrn ?? (ref?.match(/(\d{12})$/)?.[1] ?? null),
      amount: Math.round(value * 100) / 100,
      direction: dr && dr > 0 ? "debit" : "credit",
      closingBalance: cBal >= 0 ? amount(r[cBal]) : null,
      merchant: info.merchant,
      vpa: vpaTail(narration.match(/^UPI(?:\s+(?:Debit|Credit|Dr|Cr))?\s*[-\/][^-]+?-([^\s]*@[^-\s]+)/i)?.[1]),
      method: info.method,
      atm: info.atm && !!(dr && dr > 0),
    });
  }

  // Summary block ("Opening Balance | Debits | Credits | Closing Bal") if present.
  const sumAt = rows.findIndex((r) => r.some((c) => /^opening balance$/i.test(String(c).trim())));
  if (sumAt >= 0 && rows[sumAt + 1]) {
    const hdr = rows[sumAt].map((c) => String(c).trim().toLowerCase());
    const vals = rows[sumAt + 1];
    st.openingBalance = amount(vals[hdr.indexOf("opening balance")]);
    const ci = hdr.findIndex((c) => c.startsWith("closing"));
    st.closingBalance = ci >= 0 ? amount(vals[ci]) : null;
  }
  const first = st.txns[0];
  if (st.openingBalance == null && first?.closingBalance != null) {
    st.openingBalance = Math.round((first.closingBalance + (first.direction === "debit" ? first.amount : -first.amount)) * 100) / 100;
  }
  if (st.closingBalance == null) st.closingBalance = st.txns.at(-1)?.closingBalance ?? null;
  st.from ??= first?.date ?? null;
  st.to ??= st.txns.at(-1)?.date ?? null;
  return st;
}

/**
 * Federal Bank PDF statement, from its text lines (columns separated by two or more spaces):
 *   "17-NOV-2025  17-NOV-2025  UPI IN/114289461244/tiwari.rnst-  TFR  S71689235  616.00  876.43  Cr"
 *   "2@okhdfcbank/0000"                                  ← the particulars carry on
 * In or out is read from how the balance moved, and every line must agree with it (and the grand total),
 * otherwise [problems] says where and nothing should be imported.
 */
export function readFederalLines(lines: string[]): Statement & { problems: string[] } {
  const text = lines.slice(0, 40).join("\n");
  const acc = text.match(/Account Number\s*:\s*(\d{4,})/i);
  const period = text.match(/period\s+(\d{4}-\d{2}-\d{2})\s+to\s+(\d{4}-\d{2}-\d{2})/i);
  const st: Statement & { problems: string[] } = {
    bank: "Federal",
    accountLast4: acc ? acc[1].slice(-4) : null,
    from: period?.[1] ?? null,
    to: period?.[2] ?? null,
    openingBalance: null,
    closingBalance: null,
    txns: [],
    problems: [],
  };
  const money = (v: string) => Number(v.replace(/,/g, ""));
  const signed = (v: string, side: string) => (/dr/i.test(side) ? -1 : 1) * money(v);
  const round = (v: number) => Math.round(v * 100) / 100;
  const noise = /Federal Bank Ltd|^Ph:|Page \d+ of \d+|^Abbreviations|GRAND TOTAL|END OF STATEMENT|^DISCLAIMER|^Tran\b|^Type\b|^Date\s+Value Date/i;
  const entry = /^(\d{2}-[A-Z]{3}-\d{4})\s{2,}\d{2}-[A-Z]{3}-\d{4}\s{2,}(.*)$/i;
  let balance: number | null = null;
  let open: { cols: string[]; extra: string[] } | null = null;
  let seq = 0;
  let totals: [number, number] | null = null;

  const finish = () => {
    if (!open) return;
    const { cols, extra } = open;
    open = null;
    // [date, value date, ...particulars, type, tran id, (cheque), amount, balance, Cr/Dr]
    const side = cols.at(-1)!, bal = cols.at(-2)!, amt = cols.at(-3)!;
    const typeAt = cols.slice(0, -3).findLastIndex((c, i) => i >= 3 && /^[A-Z]{2,6}$/.test(c));
    let particulars = cols.slice(2, typeAt > 2 ? typeAt : cols.length - 5).join(" ");
    for (const e of extra) {
      // Federal wraps by width: in the middle of an ID (joined as is), or between words of a name.
      particulars += /[A-Z]$/.test(particulars) && /^[A-Z]/.test(e) ? ` ${e}` : e;
    }
    const date = statementDate(cols[0]);
    if (!date || !/^(cr|dr)$/i.test(side) || !/^[\d,]+\.\d{2}$/.test(amt) || !/^[\d,]+\.\d{2}$/.test(bal)) {
      st.problems.push(`Could not read the line: ${cols.join(" | ")}`);
      return;
    }
    const value = money(amt), after = signed(bal, side);
    let direction: "debit" | "credit";
    if (balance == null) {
      st.problems.push("No opening balance before the first entry.");
      direction = "debit";
    } else {
      const moved = round(after - balance);
      if (Math.abs(Math.abs(moved) - value) > 0.005) {
        st.problems.push(`${cols[0]} ₹${amt}: the balance moved by ₹${Math.abs(moved).toFixed(2)}, not ₹${amt}.`);
      }
      direction = moved < 0 ? "debit" : "credit";
    }
    balance = after;
    const info = readFederalNarration(particulars);
    st.txns.push({
      date,
      seq: seq++,
      narration: particulars,
      ref: cols[typeAt + 1] ?? null,
      rrn: info.rrn,
      amount: round(value),
      direction,
      closingBalance: after,
      merchant: info.merchant,
      vpa: vpaTail(info.vpa),
      method: info.method,
      atm: info.atm && direction === "debit",
    });
  };

  for (const raw of lines) {
    const line = raw.trim();
    if (!line) continue;
    const ob = line.match(/^Opening Balance\s+([\d,]+\.\d{2})\s+(Cr|Dr)$/i);
    if (ob) {
      balance = st.openingBalance = signed(ob[1], ob[2]);
      continue;
    }
    const gt = line.match(/GRAND TOTAL\s+([\d,]+\.\d{2})\s+([\d,]+\.\d{2})/i);
    if (gt) totals = [money(gt[1]), money(gt[2])];
    if (entry.test(line)) {
      finish();
      open = { cols: line.split(/\s{2,}/), extra: [] };
      continue;
    }
    if (noise.test(line) || /\s{2,}/.test(line)) {
      finish();
      continue;
    }
    if (open) (open as { extra: string[] }).extra.push(line);
  }
  finish();

  // Your own UPI IDs (the statement's email or mobile number): money between your own accounts, under your name.
  const holder = text.match(/^Name\s*:\s*(.+?)(?:\s{2,}|$)/im)?.[1]?.trim();
  const email = text.match(/Email ID\s*:\s*([^\s@]+)@/i)?.[1]?.toLowerCase();
  const mobile = text.match(/Mobile Number\s*:\s*(?:91)?(\d{10})\b/i)?.[1];
  if (holder) {
    const name = holder.toLowerCase().replace(/\b[a-z]/g, (c) => c.toUpperCase());
    for (const t of st.txns) {
      const id = (t.narration.match(/([a-z0-9.\-_]+)@[a-z0-9]+/i)?.[1] ?? "").toLowerCase();
      if (id && ((email && id.startsWith(email)) || (mobile && id.includes(mobile)))) t.merchant = name;
      if (/^FT IMPS/i.test(t.narration) && t.merchant?.toLowerCase() === holder.toLowerCase()) t.merchant = name;
    }
  }

  st.closingBalance = balance;
  if (st.openingBalance == null) st.problems.push("The opening balance was not found.");
  if (!st.txns.length) st.problems.push("No entries were found.");
  if (totals) {
    const out = round(st.txns.filter((t) => t.direction === "debit").reduce((v, t) => v + t.amount, 0));
    const into = round(st.txns.filter((t) => t.direction === "credit").reduce((v, t) => v + t.amount, 0));
    if (Math.abs(out - totals[0]) > 0.005 || Math.abs(into - totals[1]) > 0.005) {
      st.problems.push(`Read ₹${out.toFixed(2)} out and ₹${into.toFixed(2)} in; the bank's total says ₹${totals[0].toFixed(2)} and ₹${totals[1].toFixed(2)}.`);
    }
  } else {
    st.problems.push("The GRAND TOTAL line was not found, so the statement may be cut short.");
  }
  st.from ??= st.txns[0]?.date ?? null;
  st.to ??= st.txns.at(-1)?.date ?? null;
  return st;
}

const BRANDS: [RegExp, string][] = [
  [/^borrowrepayments@slc/i, "Slice borrow repayment"],
  [/^amazonpaylater/i, "Amazon Pay Later repayment"],
  [/^amazon/i, "Amazon"],
  [/^netflix/i, "Netflix"],
  [/^youtube/i, "YouTube"],
  [/^spotify/i, "Spotify"],
  [/^nykaa/i, "Nykaa"],
  [/^swiggy/i, "Swiggy"],
  [/^zomato/i, "Zomato"],
  [/^(blinkit|grofers)/i, "Blinkit"],
  [/^zepto/i, "Zepto"],
  [/^irctc/i, "IRCTC"],
  [/^uber/i, "Uber"],
  [/^(olacabs|ola\b)/i, "Ola"],
  [/^(jio|myjio)/i, "Jio"],
  [/^airtel/i, "Airtel"],
];

/**
 * A payee name from a UPI ID alone (Federal Bank statements have no names): brands by name, shop QR codes as
 * "PhonePe shop ••8806" (each shop stays apart), people as their first name ("siddhant0723@slc" → "Siddhant"),
 * which the app then widens to the full name it knows for that UPI ID.
 */
export function federalPayee(id: string): string {
  const v = id.trim();
  if (!v) return "UPI payment";
  for (const [re, name] of BRANDS) if (re.test(v)) return name;
  const local = v.split("@")[0];
  const tail = (x: string) => `••${x.replace(/[^a-z0-9]/gi, "").slice(-4)}`;
  if (/^q\d+$/i.test(local) && /@ybl$/i.test(v)) return `PhonePe shop ${tail(local)}`;
  if (/^paytm(qr|\.s)/i.test(local)) return `Paytm shop ${tail(local)}`;
  if (/^bharatpe/i.test(local)) return `BharatPe shop ${tail(local)}`;
  if (/^gpay-\d+/i.test(local) || /@okbiz/i.test(v)) return `GPay shop ${tail(local)}`;
  if (/^vyapar\./i.test(local)) return `Vyapar shop ${tail(local)}`;
  if (/^\d{10,}$/.test(local) || !v.includes("@")) return v;
  const words = local
    .replace(/^(paytm|gpay|phonepe)[.\-]/i, "")
    .replace(/-\d+$/, "")
    .split(/[._\-]+/)
    .map((w) => w.replace(/\d+/g, ""))
    .filter((w) => w.length >= 2);
  if (!words.length) return v;
  return words.map((w) => w[0].toUpperCase() + w.slice(1).toLowerCase()).join(" ");
}

/**
 * Federal Bank particulars: "UPIOUT/<ref>/<upi id>/<note>/<code>", "UPI IN/<ref>/<upi id>/…",
 * "FT IMPS/IFI/<ref>/<name>/…", "NFT/<name>/…", "SBINT:…" (interest).
 */
export function readFederalNarration(n: string): { merchant: string | null; method: Method; rrn: string | null; atm: boolean; vpa: string | null } {
  const s = n.replace(/\s+/g, " ").trim();
  const rrn = s.match(/\b(\d{12})\b/)?.[1] ?? null;
  const vpa = s.match(/([a-z0-9.\-_]+@[a-z0-9]+)/i)?.[1] ?? null;
  if (/^SBINT/i.test(s)) return { merchant: "Bank interest", method: "other", rrn, atm: false, vpa: null };
  if (/^UPI\s*(OUT|IN)\b/i.test(s)) {
    const id = vpa ?? s.split("/")[2]?.trim() ?? "";
    return { merchant: federalPayee(id), method: "upi", rrn, atm: false, vpa };
  }
  const imps = s.match(/^FT\s+IMPS\/IF[IO]\/\d+\/([^\/]+)/i);
  if (imps) {
    return { merchant: cleanMerchant(imps[1].replace(/\s+(DIS|DISB|PV)$/i, "")), method: "netbanking", rrn, atm: false, vpa: null };
  }
  const neft = s.match(/^NFT\/([^\/]+)/i);
  if (neft) return { merchant: cleanMerchant(neft[1]), method: "netbanking", rrn, atm: false, vpa: null };
  const r = readNarration(s);
  return { ...r, vpa };
}

/** An entry the app already has on the account (from an email, a statement or by hand). */
export interface ExistingRow {
  id: string;
  amount: number | string;
  direction: string;
  txn_at: string;
  email_body: string | null;
  email_id: string | null;
  merchant?: string | null;
  source?: string;
}

const stmtDay = (iso: string) => new Date(new Date(iso).getTime() + 330 * 60_000).toISOString().slice(0, 10);

/**
 * Matches statement lines to what the app has. A line is "already there" only if an unused entry of the same
 * amount and direction exists on the same day (an email: within a day); the same reference can repeat across
 * refunds, so it only breaks ties. Returns the new lines, and the app's entries within the statement's days
 * that the bank does not have.
 */
export function planImport(txns: StatementTxn[], existing: ExistingRow[], last4: string, periodFrom: string, periodTo: string) {
  const used = new Set<string>();
  const occurrence = new Map<string, number>();
  const keyOf = (t: StatementTxn) => {
    const base = `stmt2:${last4}:${t.date}:${t.rrn ?? "-"}:${t.direction}:${t.amount}`;
    const n = (occurrence.get(base) ?? 0) + 1;
    occurrence.set(base, n);
    return n === 1 ? base : `${base}#${n}`;
  };
  const dayDiff = (a: string, b: string) =>
    Math.abs(new Date(`${a}T12:00:00Z`).getTime() - new Date(`${b}T12:00:00Z`).getTime()) / 86_400_000;
  const fresh: Array<StatementTxn & { key: string }> = [];
  let already = 0, fromEmails = 0;
  for (const t of txns) {
    const key = keyOf(t);
    const candidates = existing.filter((e) =>
      !used.has(e.id) && Number(e.amount) === t.amount && e.direction === t.direction &&
      (e.email_id?.startsWith("stmt") ? stmtDay(e.txn_at) === t.date : dayDiff(stmtDay(e.txn_at), t.date) <= 1));
    const byRef = t.rrn ? candidates.find((e) => e.email_body?.includes(t.rrn!) || e.email_id?.includes(t.rrn!)) : undefined;
    const sameDay = candidates.find((e) => stmtDay(e.txn_at) === t.date);
    const match = byRef ?? sameDay ?? candidates[0];
    if (match) {
      used.add(match.id);
      if (match.email_id?.startsWith("stmt")) already++; else fromEmails++;
      continue;
    }
    fresh.push({ ...t, key });
  }
  const extras = existing.filter((e) => !used.has(e.id) && stmtDay(e.txn_at) >= periodFrom && stmtDay(e.txn_at) <= periodTo);
  return { fresh, already, fromEmails, extras };
}
