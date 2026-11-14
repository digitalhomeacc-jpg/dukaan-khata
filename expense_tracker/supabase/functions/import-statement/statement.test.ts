// Run with: node --test supabase/functions/import-statement/statement.test.ts
import { test } from "node:test";
import assert from "node:assert/strict";
import { planImport, readNarration, readStatement, statementDate, type StatementTxn } from "./statement.ts";

// HDFC layout with made-up people and numbers.
const ROWS: string[][] = [
  ["HDFC BANK Ltd.", "", "", "", "", "", ""],
  ["MR ASHA KUMAR", "", "", "", "Account No :50100000001234", "", ""],
  ["Statement From  :  01/08/26  To  :  31/10/26", "", "", "", "", "", ""],
  ["Date", "Narration", "Chq./Ref.No.", "Value Dt", "Withdrawal Amt.", "Deposit Amt.", "Closing Balance"],
  ["********", "****", "****", "****", "****", "****", "****"],
  ["01/08/26", "UPI-RAVI SHOP-PAYTMQR25IC@PAYTM-YESB0PTMUPI-600000000001-UPI", "0000600000000001", "01/08/26", "125.0", "", "3606.81"],
  ["01/08/26", "UPI-ROHAN DESAI-9600000000@MBK-PPIW0881822-600000000002-UPI", "0000600000000002", "01/08/26", "500.0", "", "3106.81"],
  ["02/08/26", "UPI-PRIYA SHARMA-PRIYA25@OKAXIS-BARB0MALEAS-600000000003-UPI", "0000600000000003", "02/08/26", "", "280.0", "3386.81"],
  ["05/08/26", "ACH D- CTRAZORPAY-CAPITALFLOTLLVB", "0000003130878976", "05/08/26", "595.58", "", "2791.23"],
  ["06/08/26", "ATW-512345XXXXXX1234-S1AW0001-PUNE", "0000000000001111", "06/08/26", "2,000.00", "", "791.23"],
  ["07/08/26", "NEFT CR-CITI0000001-ACME TECHNOLOGIES PVT LTD-SALARY AUG", "CITIN26000001", "07/08/26", "", "50,000.00", "50791.23"],
  ["********", "****", "****", "****", "****", "****", "****"],
  ["STATEMENT SUMMARY  :-"],
  ["Opening Balance", "Debits", "Credits", "Closing Bal"],
  ["3731.81", "3220.58", "50280.0", "50791.23"],
];

test("dates in statement formats", () => {
  assert.equal(statementDate("01/08/26"), "2026-08-01");
  assert.equal(statementDate("1-8-2026"), "2026-08-01");
  assert.equal(statementDate("01 Aug 2026"), "2026-08-01");
  assert.equal(statementDate("2026-08-01"), "2026-08-01");
  assert.equal(statementDate("********"), null);
});

test("narrations: payee, method, UPI reference", () => {
  assert.deepEqual(readNarration("UPI-ROHAN DESAI-9600000000@MBK-PPIW0881822-600000000002-UPI"),
    { merchant: "Rohan Desai", method: "upi", rrn: "600000000002", atm: false });
  assert.equal(readNarration("UPI-SIDDHANT KUMAR -********0723@SLC-HDFC0001792-667092").merchant, "Siddhant Kumar");
  assert.equal(readNarration("ATW-512345XXXXXX1234-S1AW0001-PUNE").atm, true);
  assert.equal(readNarration("NEFT CR-CITI0000001-ACME TECHNOLOGIES PVT LTD-SALARY AUG").merchant, "Acme Technologies");
  assert.equal(readNarration("ACH D- CTRAZORPAY-CAPITALFLOTLLVB").merchant, "Ctrazorpay");
});

test("HDFC statement: account, period, balances and rows", () => {
  const st = readStatement(ROWS);
  assert.equal(st.bank, "HDFC");
  assert.equal(st.accountLast4, "1234");
  assert.equal(st.from, "2026-08-01");
  assert.equal(st.to, "2026-10-31");
  assert.equal(st.openingBalance, 3731.81);
  assert.equal(st.closingBalance, 50791.23);
  assert.equal(st.txns.length, 6);
  const [a, b, c, , atm, salary] = st.txns;
  assert.deepEqual([a.direction, a.amount, a.merchant, a.closingBalance, a.seq], ["debit", 125, "Ravi Shop", 3606.81, 0]);
  assert.equal(b.rrn, "600000000002");
  assert.deepEqual([c.direction, c.amount, c.merchant], ["credit", 280, "Priya Sharma"]);
  assert.equal(atm.atm, true);
  assert.equal(atm.amount, 2000);
  assert.deepEqual([salary.direction, salary.amount, salary.method], ["credit", 50000, "netbanking"]);
});

test("opening balance from the first row when there is no summary", () => {
  const st = readStatement(ROWS.slice(0, 8));
  assert.equal(st.openingBalance, 3731.81);
});

test("bank charges, reversals, stipend and loan payouts", () => {
  assert.equal(readNarration("AUGAUG26 INSTAALERTCHG").merchant, "Bank alert charges");
  assert.equal(readNarration("UPIRET-12345678- 600000000009").merchant, "UPI refund");
  assert.equal(readNarration("REV-UPI-60000000000912345").merchant, "UPI refund");
  assert.equal(readNarration("INTERN STIPEND AUG 2026").merchant, "Stipend");
  assert.equal(readNarration("IMPS-600000000010-EARLYSALARY SERVICES-ICIC-XXXX1234-LOAN").merchant, "Earlysalary Services");
});

test("UPI ID with a dash does not end up in the name", () => {
  assert.equal(readNarration("UPI-ROHAN DESAI SHI-7822965946-2@YBL-SBIN0011426-600000000011-PAYMENT").merchant, "Rohan Desai Shi");
});

test("payee UPI ID kept in short form", () => {
  const st = readStatement(ROWS);
  assert.equal(st.txns[0].vpa, "25ic@p");
  assert.equal(st.txns[1].vpa, "0000@m");
});

// Slice bank account statement layout (made-up names / numbers)
const SLICE_ROWS: string[][] = [
  ["Customer ID", "380000000001", "Account", "slice"],
  ["Phone", "9000000000", "A/C Number", "033300000002690"],
  ["DATE", "DETAILS", "REF NO.", "TRANSACTION TYPE", "DEBIT", "CREDIT", "BALANCE"],
  ["27 Sep '25", "UPI Credit-slice-slice@slc-NESF0SLICE1-52", "8040000000000001", "CREDIT", "", "5510", "5510"],
  ["27 Sep '25", "UPI Debit-Shree Mahalaxmi Mart-bharatpe.9s0o0y@fbpe", "8040000000000002", "DEBIT", "465", "", "5045"],
  ["27 Sep '25", "Repayment", "2020000000000003", "DEBIT", "2170.89", "", "2874.11"],
  ["28 Sep '25", "Interest Cr. for 27-Sep-2025", "2020000000000004", "CREDIT", "", "0.52", "2874.63"],
  ["29 Sep '25", "BWb12a3", "2020000000000005", "CREDIT", "", "1000", "3874.63"],
];

test("Slice statement: layout, borrow, repayment, interest", () => {
  const st = readStatement(SLICE_ROWS);
  assert.equal(st.bank, "Slice");
  assert.equal(st.accountLast4, "2690");
  assert.equal(st.openingBalance, 0);
  assert.equal(st.txns.length, 5);
  assert.equal(st.txns[0].date, "2025-09-27");
  assert.equal(st.txns[0].merchant, "slice");
  assert.equal(st.txns[1].merchant, "Shree Mahalaxmi Mart");
  assert.equal(st.txns[1].direction, "debit");
  assert.equal(st.txns[1].vpa, "s0oy@f".length ? st.txns[1].vpa : "");
  assert.equal(st.txns[2].merchant, "Slice borrow repayment");
  assert.equal(st.txns[3].merchant, "Bank interest");
  assert.equal(st.txns[4].merchant, "Slice borrow");
});


test("ATM fees are bank charges, withdrawals are cash", () => {
  assert.equal(readNarration("ATM FEES INTL W/D INCL ST 200626-EPR2717360302657").atm, false);
  assert.equal(readNarration("ATM FEES INTL W/D INCL ST 200626-EPR2717360302657").merchant, "ATM fees");
  assert.equal(readNarration("ATW-416021XXXXXX7523-4972B001-BANGKOK").atm, true);
  assert.equal(readNarration("NWD-416021XXXXXX7523-00484020-AHMADNAGAR").atm, true);
});

test("match exactly: a withdrawal the bank put back is fixed, a manual guess on the account is removed", () => {
  const line = (seq: number, direction: "debit" | "credit", amount: number, narration: string): StatementTxn => ({
    date: "2026-07-08", seq, narration, ref: null, rrn: null, amount, direction, closingBalance: null,
    merchant: "ATM cash", vpa: null, method: "atm", atm: direction === "debit",
  });
  // The bank: one withdrawal, then the same amount put back.
  const bank = [line(0, "debit", 3500, "ATW-…-AHMADNAGAR"), line(1, "credit", 3500, "ATW REV-…-LONI")];
  // The app: two withdrawals (one wrong), and a manual entry on the account that day.
  const app = [
    { id: "w1", amount: "3500.00", direction: "debit", txn_at: "2026-07-08T00:40:46+00:00", email_body: null, email_id: "stmt2:3191:2026-07-08:a:debit:3500" },
    { id: "w2", amount: "3500.00", direction: "debit", txn_at: "2026-07-08T00:40:47+00:00", email_body: null, email_id: "stmt2:3191:2026-07-08:b:debit:3500" },
    { id: "m1", amount: "45.00", direction: "debit", txn_at: "2026-07-08T06:30:00+00:00", email_body: null, email_id: null },
    { id: "out", amount: "99.00", direction: "debit", txn_at: "2026-07-20T06:30:00+00:00", email_body: null, email_id: null },
  ];
  const plan = planImport(bank, app, "3191", "2026-07-01", "2026-07-15");
  assert.deepEqual(plan.fresh.map((t) => [t.direction, t.amount]), [["credit", 3500]]); // the put-back is added
  assert.deepEqual(plan.extras.map((e) => e.id).sort(), ["m1", "w2"]); // the wrong withdrawal and the guess go
  assert.equal(plan.already, 1);
  // Outside the statement's days nothing is touched.
  assert.ok(!plan.extras.some((e) => e.id === "out"));
});
