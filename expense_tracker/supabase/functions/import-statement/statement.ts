// Bank statement reader (HDFC layout, plus a generic one): spreadsheet rows → transactions.
// Pure TypeScript: used by the import-statement Edge Function and unit-tested with Node.

import { cleanMerchant, type Method } from "../ingest-email/parsers.ts";

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
  m = s.match(/^(\d{1,2})[\s\-]([A-Za-z]{3})[a-z]*[\s\-,]+(\d{2}|\d{4})$/);
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
  let m = s.match(/^UPI[-\/](.+?)-([^-\s]*@[^-\s]+)(?:-|$)/i);
  if (m) return { merchant: cleanMerchant(m[1]), method: "upi", rrn, atm: false };
  m = s.match(/^UPI[-\/]([^-]+)-/i);
  if (m) return { merchant: cleanMerchant(m[1]), method: "upi", rrn, atm: false };
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
  narration: /narration|description|particulars|remarks/i,
  ref: /ref|chq|cheque/i,
  debit: /withdrawal|debit|dr\b/i,
  credit: /deposit|credit|cr\b/i,
  balance: /balance/i,
};

/** Reads statement rows (each row an array of cell texts). */
export function readStatement(rows: string[][]): Statement {
  const text = rows.slice(0, 40).map((r) => r.join(" ")).join("\n");
  const bank = /hdfc/i.test(text) ? "HDFC" : /icici/i.test(text) ? "ICICI" : /state bank|sbi/i.test(text) ? "SBI" : /axis/i.test(text) ? "Axis" : null;
  const acc = text.match(/account\s*(?:no|number)\.?\s*:?\s*[x*]*(\d{4,})/i);
  const period = text.match(/from\s*:?\s*(\d{1,2}\/\d{1,2}\/\d{2,4})\s*to\s*:?\s*(\d{1,2}\/\d{1,2}\/\d{2,4})/i);

  const headerAt = rows.findIndex((r) =>
    r.some((c) => COLS.narration.test(c)) && r.some((c) => COLS.balance.test(c)) && r.some((c) => COLS.date.test(c.trim()))
  );
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
