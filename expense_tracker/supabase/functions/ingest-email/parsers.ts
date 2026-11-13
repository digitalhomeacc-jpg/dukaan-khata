// Bank alert email parser (HDFC, ICICI, SBI, Axis + a generic fallback).
//
// Pure TypeScript with no imports so it runs both in the Supabase Edge Function
// (Deno) and under `node --test` for the unit tests.

export type Direction = "debit" | "credit";
export type Method = "upi" | "card" | "netbanking" | "atm" | "other";

export interface EmailInput {
  id: string;
  from: string;
  subject: string;
  /** ISO timestamp the email was received. */
  date: string;
  /** Plain-text (or HTML) body. */
  body: string;
}

export interface ParsedTxn {
  amount: number;
  direction: Direction;
  merchant: string | null;
  bank: string | null;
  accountLast4: string | null;
  /** Credit card vs. bank account (debit cards and UPI belong to the bank account). */
  accountKind: "bank" | "card";
  method: Method;
  /** ISO timestamp of the transaction. */
  txnAt: string;
  /** Card bill payments, own-account transfers: kept but left out of totals. */
  isTransfer: boolean;
}

export type ParseResult =
  | { ok: true; txn: ParsedTxn }
  | { ok: false; reason: "not_transaction" | "unreadable" };

const BANKS: Array<[string, RegExp]> = [
  ["HDFC", /hdfc/i],
  ["ICICI", /icici/i],
  ["SBI", /\bsbi\b|sbicard|sbi\.co\.in|state bank/i],
  ["Axis", /axis ?bank|axisbank|axis\.bank/i],
  ["Kotak", /kotak/i],
];

const MONTHS: Record<string, number> = {
  jan: 1, feb: 2, mar: 3, apr: 4, may: 5, jun: 6,
  jul: 7, aug: 8, sep: 9, sept: 9, oct: 10, nov: 11, dec: 12,
};

const AMOUNT = String.raw`(?:rs\.?|inr|₹)\s*([0-9][0-9,]*(?:\.[0-9]{1,2})?)`;

const DEBIT_WORDS = [
  String.raw`debited`, String.raw`has a debit`, String.raw`\bdebit of`, String.raw`\bspent\b`,
  String.raw`used for`, String.raw`withdrawn`, String.raw`\bpaid\b`, String.raw`\bsent\b`,
  String.raw`debit (?:card )?transaction`, String.raw`thank you for using`, String.raw`for using your`, String.raw`purchase of`, String.raw`deducted`,
];
const CREDIT_WORDS = [
  String.raw`credited`, String.raw`has a credit`, String.raw`\bcredit of`, String.raw`received`,
  String.raw`deposited`, String.raw`refund(?:ed)?`, String.raw`reversed`, String.raw`cashback`,
];

/** Strip HTML, decode the common entities and collapse whitespace. */
export function normalize(text: string): string {
  return text
    .replace(/<(script|style)[\s\S]*?<\/\1>/gi, " ")
    .replace(/<br\s*\/?>|<\/(p|div|tr|td|li)>/gi, " ")
    .replace(/<[^>]+>/g, " ")
    .replace(/&nbsp;/gi, " ")
    .replace(/&amp;/gi, "&")
    .replace(/&#8377;|&#x20b9;/gi, "₹")
    .replace(/&[a-z]+;|&#\d+;/gi, " ")
    .replace(/\*\*/g, "XX") // HDFC writes "account **1234"
    .replace(/\s+/g, " ")
    .trim();
}

export function detectBank(from: string, text: string): string | null {
  for (const [name, re] of BANKS) if (re.test(from)) return name;
  for (const [name, re] of BANKS) if (re.test(text)) return name;
  return null;
}

function isNoise(text: string): boolean {
  const t = text.toLowerCase();
  if (/\botp\b|one time password|verification code/.test(t) && !/\bdebited\b|\bcredited\b/.test(t)) return true;
  if (/\b(declined|failed|unsuccessful|could not be processed)\b/.test(t)) return true;
  if (/minimum amount due|total amount due|statement (?:is|has been) generated|payment (?:is )?due/.test(t)) return true;
  if (/will be (?:debited|charged|deducted)|is scheduled|upcoming (?:debit|payment)|mandate (?:created|registered)/.test(t)) return true;
  return false;
}

/** Find the transaction amount, skipping balances and limits. */
function findAmount(text: string): { value: number; index: number } | null {
  const re = new RegExp(AMOUNT, "gi");
  let m: RegExpExecArray | null;
  while ((m = re.exec(text))) {
    const before = text.slice(Math.max(0, m.index - 30), m.index).toLowerCase();
    if (/(bal(ance)?|limit|avl|available|outstanding|due)[\s:.\-is]*$/.test(before)) continue;
    const value = Number(m[1].replace(/,/g, ""));
    if (value > 0 && Number.isFinite(value)) return { value, index: m.index };
  }
  return null;
}

/** Pick debit/credit from the keyword closest to the amount. */
function findDirection(text: string, amountIndex: number): Direction | null {
  const lower = text.toLowerCase();
  let best: { dir: Direction; dist: number } | null = null;
  const scan = (words: string[], dir: Direction) => {
    for (const w of words) {
      const re = new RegExp(w, "gi");
      let m: RegExpExecArray | null;
      while ((m = re.exec(lower))) {
        const dist = Math.abs(m.index - amountIndex);
        if (!best || dist < best.dist) best = { dir, dist };
      }
    }
  };
  scan(DEBIT_WORDS, "debit");
  scan(CREDIT_WORDS, "credit");
  return (best as { dir: Direction } | null)?.dir ?? null;
}

function findLast4(text: string): string | null {
  const patterns = [
    /(?:a\/c|account|acct|card)(?:\s*(?:no\.?|number|ending(?: with)?|ending in))?\s*[:\-]?\s*(?:[x*]+\s*)(\d{3,6})\b/i,
    /(?:card|a\/c|account)[^.]{0,30}?ending(?: with| in)?\s*[x*]*(\d{4})\b/i,
    /\b[x*]{2,}(\d{3,6})\b/i,
  ];
  for (const p of patterns) {
    const m = text.match(p);
    if (m) return m[1].slice(-4);
  }
  return null;
}

function cleanMerchant(raw: string | undefined | null): string | null {
  if (!raw) return null;
  let s = raw
    .replace(/\s+/g, " ")
    .replace(/^(?:vpa|upi|mr\.?|ms\.?|m\/s\.?)\s+/i, "")
    .replace(/[\s.,;:\-]+$/, "")
    .trim();
  if (s.length < 2) return null;
  if (/^\d+$/.test(s)) return null;
  if (/^(your|the|a|an|on|via|using|account|a\/c)$/i.test(s)) return null;
  if (s.length > 48) s = s.slice(0, 48).trim();
  return s;
}

/** "UPI/P2M/412345678901/SWIGGY LIMITED/..." → "SWIGGY LIMITED" */
function fromUpiPath(info: string): string | null {
  const parts = info.split(/[\/|]/).map((p) => p.trim()).filter(Boolean);
  const skip = /^(upi|p2m|p2a|imps|neft|rtgs|mmt|inb|ach|nach|pos|ecom|bil|dr|cr|onl|payment from phonepe|paytm|gpay|ybl|ibl|axl|okaxis|okhdfcbank|okicici|oksbi)$/i;
  const named = parts.filter((p) => !/^[0-9xX]+$/.test(p) && !skip.test(p) && !/@/.test(p) && !/^[A-Z]{4}0[A-Z0-9]{6}$/.test(p));
  return cleanMerchant(named[0] ?? parts.find((p) => /@/.test(p)) ?? null);
}

const STOP = String.raw`(?=\s+(?:on|dated|at|via|using|ref|reference|txn|transaction|from|for|with|avl|available|upi|\(|is\b|has\b|was\b)|[.,;]|\s*$)`;

function findMerchant(text: string, dir: Direction): string | null {
  const tries: Array<() => string | null> = [
    // "to VPA swiggy@icici SWIGGY on" / "by VPA x@okaxis JOHN DOE on"
    () => {
      const m = text.match(/(?:to|by|from)\s+vpa\s+(\S+@\S+?)\s+([A-Za-z][A-Za-z0-9 &.'\-]{1,40}?)\s+on\b/i);
      return m ? cleanMerchant(m[2]) ?? cleanMerchant(m[1]) : null;
    },
    () => {
      const m = text.match(/(?:to|by|from)\s+vpa\s+(\S+@[\w.]+)/i);
      return m ? cleanMerchant(m[1]) : null;
    },
    // "Info: UPI/P2M/123/SWIGGY." / "Info: AMAZON PAY."
    () => {
      const m = text.match(/info[:\s]+([^\s].*?)(?=\.\s|\.$| the available| avl| available|$)/i);
      if (!m) return null;
      return /[\/|]/.test(m[1]) ? fromUpiPath(m[1]) : cleanMerchant(m[1]);
    },
    // Axis: "UPI/P2M/412345/SWIGGY ..."
    () => {
      const m = text.match(/\b(?:UPI|IMPS|NEFT|RTGS)\/[^\s]*(?:\s+[A-Z][A-Z0-9&.]+\b(?![a-z]))*/);
      return m ? fromUpiPath(m[0]) : null;
    },
    () => {
      const m = text.match(new RegExp(String.raw`\b(?:at|towards)\s+([A-Za-z0-9][\w&.'*\- /]{1,48}?)` + STOP, "i"));
      return m ? cleanMerchant(m[1]) : null;
    },
    () => {
      const re = dir === "debit"
        ? String.raw`\b(?:transfer to|paid to|sent to|trf to|to)\s+([A-Za-z][\w&.' \-]{1,48}?)`
        : String.raw`\b(?:transfer from|received from|trf from|from|by)\s+([A-Za-z][\w&.' \-]{1,48}?)`;
      const m = text.match(new RegExp(re + STOP, "i"));
      const v = m ? cleanMerchant(m[1]) : null;
      if (v && /^(your|you|a\/c|account|ac|acct|the|hdfc|icici|sbi|axis)\b/i.test(v)) return null;
      return v;
    },
  ];
  for (const t of tries) {
    const v = t();
    if (v) return v;
  }
  return null;
}

function findMethod(text: string): Method {
  const t = text.toLowerCase();
  if (/\bupi\b|\bvpa\b/.test(t)) return "upi";
  if (/\batm\b|withdrawn|cash withdrawal/.test(t)) return "atm";
  if (/credit card|debit card|\bcard\b/.test(t)) return "card";
  if (/\bneft\b|\bimps\b|\brtgs\b|net ?banking|\bmmt\b/.test(t)) return "netbanking";
  return "other";
}

function isTransfer(text: string, dir: Direction): boolean {
  const t = text.toLowerCase();
  if (dir === "credit" && /(?:payment|amount)[\s\S]{0,60}?(?:received|credited)[\s\S]{0,60}?(?:credit card|card account)/.test(t)) return true;
  if (/towards (?:your )?(?:\w+ )?(?:bank )?credit card (?:bill|payment|outstanding)/.test(t)) return true;
  if (/\bself\b|own account|to your (?:own )?(?:a\/c|account)/.test(t)) return true;
  return false;
}

/** Offset of India Standard Time. Bank alerts are always in IST. */
const IST = "+05:30";

function pad(n: number) {
  return String(n).padStart(2, "0");
}

function year(y: string): number {
  const n = Number(y);
  return y.length <= 2 ? 2000 + n : n;
}

function ymd(y: number, mo: number, d: number): string | null {
  if (mo < 1 || mo > 12 || d < 1 || d > 31 || y < 2000 || y > 2100) return null;
  return `${y}-${pad(mo)}-${pad(d)}`;
}

/** Returns { date: "YYYY-MM-DD", time?: "HH:MM:SS" } for the first date in the text. */
export function findDate(text: string): { date: string; time: string | null } | null {
  const mon = String.raw`(jan|feb|mar|apr|may|jun|jul|aug|sept?|oct|nov|dec)[a-z]*`;
  const candidates: Array<{ index: number; date: string | null }> = [];
  const push = (re: RegExp, f: (m: RegExpMatchArray) => string | null) => {
    const m = text.match(re);
    if (m && m.index !== undefined) candidates.push({ index: m.index, date: f(m) });
  };
  push(/\b(\d{1,2})[-\/.](\d{1,2})[-\/.](\d{4}|\d{2})\b/, (m) => ymd(year(m[3]), +m[2], +m[1]));
  push(new RegExp(String.raw`\b(\d{1,2})[-\s]?` + mon + String.raw`[-\s,]*(\d{4}|\d{2})\b`, "i"), (m) =>
    ymd(year(m[3]), MONTHS[m[2].toLowerCase()], +m[1]));
  push(new RegExp(String.raw`\b` + mon + String.raw`\s+(\d{1,2}),?\s+(\d{4})\b`, "i"), (m) =>
    ymd(+m[3], MONTHS[m[1].toLowerCase()], +m[2]));
  push(/\b(\d{4})-(\d{2})-(\d{2})\b/, (m) => ymd(+m[1], +m[2], +m[3]));
  const valid = candidates.filter((c) => c.date).sort((a, b) => a.index - b.index);
  if (!valid.length) return null;
  const after = text.slice(valid[0].index, valid[0].index + 40);
  const tm = after.match(/\b(\d{1,2}):(\d{2})(?::(\d{2}))?\s*(am|pm)?/i);
  let time: string | null = null;
  if (tm) {
    let h = +tm[1];
    if (tm[4]) {
      const pm = tm[4].toLowerCase() === "pm";
      if (pm && h < 12) h += 12;
      if (!pm && h === 12) h = 0;
    }
    if (h < 24) time = `${pad(h)}:${tm[2]}:${tm[3] ?? "00"}`;
  }
  return { date: valid[0].date!, time };
}

function istDay(iso: string): string {
  const d = new Date(new Date(iso).getTime() + 330 * 60_000);
  return d.toISOString().slice(0, 10);
}

/** Choose the transaction time: the date written in the email, else when the email arrived. */
function resolveTime(text: string, emailDate: string): string {
  const received = new Date(emailDate);
  const fallback = isNaN(received.getTime()) ? new Date().toISOString() : received.toISOString();
  const found = findDate(text);
  if (!found) return fallback;
  if (!found.time && found.date === istDay(fallback)) return fallback;
  const iso = new Date(`${found.date}T${found.time ?? "12:00:00"}${IST}`);
  if (isNaN(iso.getTime())) return fallback;
  // A date far from the arrival time is probably a misread (dd/mm vs mm/dd).
  const days = Math.abs(iso.getTime() - new Date(fallback).getTime()) / 86_400_000;
  return days > 10 ? fallback : iso.toISOString();
}

export function parseBankEmail(email: EmailInput): ParseResult {
  const text = normalize(`${email.subject}. ${email.body}`);
  if (isNoise(text)) return { ok: false, reason: "not_transaction" };
  const amount = findAmount(text);
  if (!amount) return { ok: false, reason: looksTransactional(text) ? "unreadable" : "not_transaction" };
  const direction = findDirection(text, amount.index);
  if (!direction) return { ok: false, reason: looksTransactional(text) ? "unreadable" : "not_transaction" };
  return {
    ok: true,
    txn: {
      amount: Math.round(amount.value * 100) / 100,
      direction,
      merchant: findMerchant(text, direction),
      bank: detectBank(email.from, text),
      accountLast4: findLast4(text),
      accountKind: /credit card/i.test(text) ? "card" : "bank",
      method: findMethod(text),
      txnAt: resolveTime(text, email.date),
      isTransfer: isTransfer(text, direction),
    },
  };
}

/** True when an email mentions money moving, so it is worth showing as "couldn't read". */
export function looksTransactional(text: string): boolean {
  const t = normalize(text).toLowerCase();
  return new RegExp(AMOUNT, "i").test(t) && /debit|credit|spent|withdrawn|paid|received/.test(t) && !isNoise(t);
}

/** Lower-cased, space-collapsed key used to remember a category per merchant. */
export function merchantKey(merchant: string | null): string {
  return (merchant ?? "").toLowerCase().replace(/\s+/g, " ").trim();
}
