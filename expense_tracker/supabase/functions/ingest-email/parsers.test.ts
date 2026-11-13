// Run with: node --test supabase/functions/ingest-email/parsers.test.ts   (Node 23.6+)
import { test } from "node:test";
import assert from "node:assert/strict";
import { parseBankEmail, type EmailInput, type ParsedTxn } from "./parsers.ts";

const RECEIVED = "2026-11-12T05:00:00.000Z"; // 12 Nov 2026, 10:30 IST

function mail(from: string, subject: string, body: string, date = RECEIVED): EmailInput {
  return { id: "m1", from, subject, body, date };
}

function ok(email: EmailInput): ParsedTxn {
  const r = parseBankEmail(email);
  assert.equal(r.ok, true, `expected a transaction, got ${JSON.stringify(r)}`);
  return (r as { ok: true; txn: ParsedTxn }).txn;
}

function rejected(email: EmailInput) {
  const r = parseBankEmail(email);
  assert.equal(r.ok, false, `expected rejection, got ${JSON.stringify(r)}`);
}

// ---------------------------------------------------------------- HDFC
test("HDFC UPI debit", () => {
  const t = ok(mail(
    "HDFC Bank InstaAlerts <alerts@hdfcbank.net>",
    "❗ You have done a UPI txn. Check details!",
    "Dear Customer, Rs.250.00 has been debited from account **4321 to VPA swiggy.stores@axb SWIGGY LIMITED on 12-11-26. Your UPI transaction reference number is 431612345678. If you did not authorize this transaction, please report it immediately.",
  ));
  assert.equal(t.amount, 250);
  assert.equal(t.direction, "debit");
  assert.equal(t.merchant, "Swiggy Limited");
  assert.equal(t.bank, "HDFC");
  assert.equal(t.accountLast4, "4321");
  assert.equal(t.method, "upi");
  assert.equal(t.accountKind, "bank");
  assert.equal(t.isTransfer, false);
});

test("HDFC UPI credit", () => {
  const t = ok(mail(
    "alerts@hdfcbank.bank.in",
    "You have received money",
    "Dear Customer, Rs. 5,000.00 is successfully credited to your account **4321 by VPA rahul.k@okaxis RAHUL KUMAR on 11-11-26. Your UPI transaction reference number is 431598765432. Thank you for banking with us.",
  ));
  assert.equal(t.amount, 5000);
  assert.equal(t.direction, "credit");
  assert.equal(t.merchant, "Rahul Kumar");
  assert.equal(t.txnAt, "2026-11-11T06:30:00.000Z"); // 11 Nov noon IST
});

test("HDFC credit card spend (new format)", () => {
  const t = ok(mail(
    "HDFC Bank InstaAlerts <alerts@hdfcbank.net>",
    "Debit Alert: Your HDFC Bank Credit Card",
    "Dear Card Member, Rs.1,249.00 is debited from your HDFC Bank Credit Card ending 9876 towards AMAZON PAY INDIA on 12 Nov, 2026 at 09:41:07. Available limit: Rs 1,20,000.00.",
  ));
  assert.equal(t.amount, 1249);
  assert.equal(t.direction, "debit");
  assert.equal(t.merchant, "Amazon Pay India");
  assert.equal(t.accountLast4, "9876");
  assert.equal(t.method, "card");
  assert.equal(t.accountKind, "card");
  assert.equal(t.txnAt, "2026-11-12T04:11:07.000Z");
});

test("HDFC credit card spend (old format)", () => {
  const t = ok(mail(
    "alerts@hdfcbank.net",
    "Alert : Update on your HDFC Bank Credit Card",
    "Thank you for using your HDFC Bank Credit Card ending 9876 for Rs 640.50 at ZOMATO on 10-11-2026 21:15:02. Authorization code:- 012345",
  ));
  assert.equal(t.amount, 640.5);
  assert.equal(t.direction, "debit");
  assert.equal(t.merchant, "Zomato");
  assert.equal(t.txnAt, "2026-11-10T15:45:02.000Z");
});

test("HDFC HTML body", () => {
  const t = ok(mail(
    "alerts@hdfcbank.net",
    "Account update",
    "<html><body><p>Dear Customer,</p><p>Rs.&nbsp;1,000.00 has been debited from account **4321 to VPA blinkit@hdfcbank BLINKIT on 12-11-26.</p></body></html>",
  ));
  assert.equal(t.amount, 1000);
  assert.equal(t.merchant, "Blinkit");
});

test("Credit card bill payment is a transfer", () => {
  const t = ok(mail(
    "alerts@hdfcbank.net",
    "Payment received",
    "Dear Card Member, Payment of Rs 15,430.00 has been received towards your HDFC Bank Credit Card ending 9876 on 12-11-2026. Thank you.",
  ));
  assert.equal(t.direction, "credit");
  assert.equal(t.isTransfer, true);
});

// ---------------------------------------------------------------- ICICI
test("ICICI credit card", () => {
  const t = ok(mail(
    "ICICI Bank <credit_cards@icicibank.com>",
    "Transaction alert for your ICICI Bank Credit Card",
    "Dear Customer, Your ICICI Bank Credit Card XX5678 has been used for a transaction of INR 2,399.00 on Nov 11, 2026 at 18:22:10. Info: MYNTRA DESIGNS. The Available Credit Limit on your card is INR 85,000.00 and Total Credit Limit is INR 1,00,000.00.",
  ));
  assert.equal(t.amount, 2399);
  assert.equal(t.direction, "debit");
  assert.equal(t.merchant, "Myntra Designs");
  assert.equal(t.accountLast4, "5678");
  assert.equal(t.bank, "ICICI");
  assert.equal(t.txnAt, "2026-11-11T12:52:10.000Z");
});

test("ICICI account debit with UPI info", () => {
  const t = ok(mail(
    "customernotification@icicibank.com",
    "Transaction alert for your ICICI Bank Account",
    "Dear Customer, ICICI Bank Account XX123 has been debited with INR 180.00 on 12-Nov-26. Info: UPI/431612345678/UBER INDIA/uber@icici. The Available Balance is INR 45,210.33.",
  ));
  assert.equal(t.amount, 180);
  assert.equal(t.direction, "debit");
  assert.equal(t.merchant, "Uber India");
  assert.equal(t.accountLast4, "123");
});

test("ICICI salary credit", () => {
  const t = ok(mail(
    "alert@icicibank.com",
    "Credit alert",
    "Dear Customer, ICICI Bank Account XX123 is credited with INR 85,000.00 on 01-Nov-26. Info: NEFT-CITIN26305123456-ACME TECHNOLOGIES PVT LTD. The Available Balance is INR 1,30,210.33.",
  ));
  assert.equal(t.amount, 85000);
  assert.equal(t.direction, "credit");
  assert.ok(t.merchant?.includes("Acme Technologies"), t.merchant ?? "");
  assert.equal(t.method, "netbanking");
});

// ---------------------------------------------------------------- SBI
test("SBI debit by transfer", () => {
  const t = ok(mail(
    "cbssbi.cas@alerts.sbi.co.in",
    "Transaction Alert",
    "Dear Customer, Your A/C XXXXX6789 has a debit by transfer of Rs 499.00 on 12Nov26. Transfer to NETFLIX. Avl Bal Rs 22,341.10. -SBI",
  ));
  assert.equal(t.amount, 499);
  assert.equal(t.direction, "debit");
  assert.equal(t.merchant, "Netflix");
  assert.equal(t.accountLast4, "6789");
  assert.equal(t.bank, "SBI");
});

test("SBI UPI debit", () => {
  const t = ok(mail(
    "donotreply.sbiatm@alerts.sbi.co.in",
    "UPI transaction",
    "Dear UPI user A/C X6789 debited by 120.0 on date 12Nov26 trf to CHAI POINT Refno 431612345678. If not u? call 1800111109. Rs.120.00 -SBI",
  ));
  assert.equal(t.amount, 120);
  assert.equal(t.direction, "debit");
  assert.equal(t.merchant, "Chai Point");
});

test("SBI Card spend", () => {
  const t = ok(mail(
    "onlinesbicard@sbicard.com",
    "Transaction Alert from SBI Card",
    "Rs.3,450.00 spent on your SBI Credit Card ending 4455 at RELIANCE DIGITAL on 09/11/26. Trxn. not done by you? Report at https://sbicard.com/Dispute",
  ));
  assert.equal(t.amount, 3450);
  assert.equal(t.merchant, "Reliance Digital");
  assert.equal(t.accountLast4, "4455");
  assert.equal(t.txnAt, "2026-11-09T06:30:00.000Z");
});

test("SBI ATM withdrawal", () => {
  const t = ok(mail(
    "donotreply.sbiatm@alerts.sbi.co.in",
    "ATM withdrawal",
    "Dear Customer, Rs 2,000.00 withdrawn at SBI ATM S1BW000123 from A/c XX6789 on 12Nov26. Avl Bal Rs 20,341.10.",
  ));
  assert.equal(t.amount, 2000);
  assert.equal(t.direction, "debit");
  assert.equal(t.method, "atm");
});

// ---------------------------------------------------------------- Axis
test("Axis UPI debit", () => {
  const t = ok(mail(
    "alerts@axisbank.com",
    "Debit transaction alert for A/c no. XX2468",
    "Dear Customer, INR 349.00 debited A/c no. XX2468 12-11-26, 13:05:44 UPI/P2M/431612345678/DOMINOS PIZZA Not you? SMS BLOCKUPI Cust ID to 919951860002 Axis Bank",
  ));
  assert.equal(t.amount, 349);
  assert.equal(t.direction, "debit");
  assert.equal(t.merchant, "Dominos Pizza");
  assert.equal(t.accountLast4, "2468");
  assert.equal(t.bank, "Axis");
  assert.equal(t.txnAt, "2026-11-12T07:35:44.000Z");
});

test("Axis credit card spend", () => {
  const t = ok(mail(
    "alerts@axis.bank.in",
    "Transaction alert on Axis Bank Credit Card",
    "Transaction alert: INR 1,875.00 spent on Axis Bank Credit Card no. XX1357 at BOOKMYSHOW on 08-11-2026 20:10:05 IST. Available Limit: INR 54,000.00.",
  ));
  assert.equal(t.amount, 1875);
  assert.equal(t.merchant, "Bookmyshow");
  assert.equal(t.accountLast4, "1357");
});

test("Axis UPI credit", () => {
  const t = ok(mail(
    "alerts@axisbank.com",
    "Credit transaction alert",
    "Dear Customer, INR 1,200.00 credited to A/c no. XX2468 on 12-11-26 13:40:01 IST by UPI/P2A/431698765432/PRIYA SHARMA",
  ));
  assert.equal(t.direction, "credit");
  assert.equal(t.merchant, "Priya Sharma");
});

// ---------------------------------------------------------------- noise
test("OTP email is ignored", () => {
  rejected(mail("alerts@hdfcbank.net", "OTP", "Your OTP for transaction of Rs 500.00 at AMAZON is 123456. Do not share it with anyone."));
});

test("Declined transaction is ignored", () => {
  rejected(mail("alerts@axisbank.com", "Declined", "Your transaction of INR 999.00 at FLIPKART on Axis Bank Credit Card XX1357 was declined due to incorrect PIN."));
});

test("Statement / payment due is ignored", () => {
  rejected(mail("credit_cards@icicibank.com", "Statement", "Your ICICI Bank Credit Card XX5678 statement has been generated. Total amount due: INR 12,000.00. Minimum amount due: INR 600.00."));
});

test("Upcoming mandate is ignored", () => {
  rejected(mail("alerts@hdfcbank.net", "Upcoming", "Rs 649.00 will be debited from your account **4321 towards NETFLIX on 15-11-26 as per your e-mandate."));
});

test("Promotional email is ignored", () => {
  rejected(mail("offers@hdfcbank.net", "Exclusive offer", "Get a personal loan at attractive rates. Apply now!"));
});

test("Implausible date falls back to email date", () => {
  const t = ok(mail("alerts@hdfcbank.net", "UPI", "Rs.10.00 has been debited from account **4321 to VPA a@b SHOP on 01-01-20."));
  assert.equal(t.txnAt, RECEIVED);
});

test("HDFC low balance warning is ignored", () => {
  rejected(mail("HDFC Bank InstaAlerts <alerts@hdfcbank.bank.in>", "View: Account update for your HDFC Bank A/c",
    "Dear Customer, Greetings from HDFC Bank! The balance in your account ending XX6516 has dropped below Rs. INR 5,000.00, which is the threshold set by you. Balance as of yesterday: Rs. INR 21.91 Please note that deposits or credits may take some time to reflect in your account."));
});

test("HDFC promotional mailer is ignored", () => {
  rejected(mail("HDFC Bank <information@mailers.hdfcbank.bank.in>", "Rs.2,000 voucher with your HDFC Bank Debit Card linked with A/c xx6516",
    "This Dhanteras, Get Rs.2,000 Voucher on single in-store transaction of Rs.1 Lakh & above on Jewellery using your HDFC Bank Debit Card. Offer valid from 31 st Oct 26"));
});

// HDFC's 2026 wording (names and numbers made up).
const HDFC_FOOTER = " If you did not authorize this transaction, please report it immediately at: a. When in India (Toll free): 1800 258 6161 c. Or SMS 'BLOCK UPI' to 7308080808. We're here to support you in every step of the way. Warm regards, HDFC Bank";

test("HDFC 2026 UPI debit: name in brackets, footer ignored", () => {
  const t = ok(mail("HDFC Bank InstaAlerts <alerts@hdfcbank.bank.in>", "❗  You have done a UPI txn. Check details!",
    "Dear Customer, Greetings from HDFC Bank! Rs.265.00 is debited from your account ending 3191 towards VPA ******6712@ybl (Hotel Sagar) on 12-11-26. UPI transaction reference no.: 800011112222." + HDFC_FOOTER));
  assert.equal(t.amount, 265);
  assert.equal(t.direction, "debit");
  assert.equal(t.merchant, "Hotel Sagar");
  assert.equal(t.accountLast4, "3191");
  assert.equal(t.method, "upi");
});

test("HDFC 2026 UPI debit to a person in capitals", () => {
  const t = ok(mail("alerts@hdfcbank.bank.in", "❗  You have done a UPI txn. Check details!",
    "Dear Customer, Rs.800.00 is debited from your account ending 6516 towards VPA ******4168@kotakbank (AMIT KUMAR SHAH) on 10-11-26. UPI transaction reference no.: 600000000001." + HDFC_FOOTER));
  assert.equal(t.merchant, "Amit Kumar Shah");
  assert.equal(t.accountLast4, "6516");
});

test("HDFC 2026 UPI credit: Sender line", () => {
  const t = ok(mail("HDFC Bank InstaAlerts <alerts@hdfcbank.bank.in>", "View: Account update for your HDFC Bank A/c",
    "Dear Customer, Greetings from HDFC Bank! We're writing to inform you that Rs.220.00 has been successfully credited to your HDFC Bank account ending in 3191. Transaction Details: a. Date: 12-11-26 b. Sender: ROHAN VIJAY DESAI (VPA: ************00-1@okicici) c. UPI Reference No.: 600000000002 Need Help? India (Toll-Free): 1800 258 6161 Thank you for banking with HDFC Bank. Warm Regards, HDFC Bank"));
  assert.equal(t.amount, 220);
  assert.equal(t.direction, "credit");
  assert.equal(t.merchant, "Rohan Vijay Desai");
  assert.equal(t.accountLast4, "3191");
});

test("payee is never taken from the footer", () => {
  const t = ok(mail("alerts@hdfcbank.bank.in", "UPI", "Rs.50.00 is debited from your account ending 3191 on 12-11-26." + HDFC_FOOTER));
  assert.equal(t.merchant, null);
});

// ---------------------------------------------------------------- Slice (made-up names / numbers)
import { parseLenderEmail, type LenderEvent } from "./parsers.ts";

const SLICE = "slice <noreply@slice.bank.in>";
function lender(subject: string, body: string): LenderEvent | "ignore" | null {
  return parseLenderEmail(mail(SLICE, subject, body));
}

test("amount with an invisible joiner is read whole", () => {
  const t = ok(mail(SLICE, "Received ₹1,\u200c500", "Hi Asha, You have received ₹1,\u200c500 in your slice bank a/c xx2690. Aval. Bal. Rs. 1,631.30! Transaction Date 18-Oct-26 Sender Name slice Ref No. 600000000003 Reach out to our customer support team at 08000000000 or drop us an email"));
  assert.equal(t.amount, 1500);
  assert.equal(t.direction, "credit");
  assert.equal(t.merchant, "slice");
  assert.equal(t.accountLast4, "2690");
  assert.equal(t.bank, "Slice");
});

test("Slice account UPI payment: 'To NAME RRN'", () => {
  const t = ok(mail(SLICE, "₹300 debited from your slice account", "Hi Asha, ₹300 debited from your slice bank account xx2690 via UPI. Transaction date 18-Oct-26 To HP Petrol Pump Loni RRN 600000000004 Best, Team slice"));
  assert.equal(t.amount, 300);
  assert.equal(t.direction, "debit");
  assert.equal(t.merchant, "HP Petrol Pump Loni");
});

test("slice borrow cash to bank is a borrow", () => {
  const e = lender("Borrow order confirmed!", "Hi Asha, You have transferred *₹590* to your bank account via *slice borrow.* Order ID: BW0000001");
  assert.deepEqual(e && e !== "ignore" && [e.kind, e.amount], ["borrow", 590]);
});

test("slice borrow purchase is a spend with the shop", () => {
  const e = lender("Transaction completed using slice borrow 🎉", "Hi Asha, You have paid *₹136* to Aayush medical and general store using *slice borrow.* Order ID: CL0000001");
  assert.ok(e && e !== "ignore");
  assert.equal(e.kind, "spend");
  assert.equal(e.amount, 136);
  assert.equal(e.merchant, "Aayush medical and general store");
});

test("repayment and due reminder", () => {
  const r = lender("Repayment successful!", "Hi Asha, Your repayment of ₹506.54 was successful. Transaction ID : RID-1");
  assert.deepEqual(r && r !== "ignore" && [r.kind, r.amount], ["repay", 506.54]);
  const d = lender("Payment reminder", "Hello Asha, As a friendly reminder, your payment of ₹506.54 is due today. Repaying on time helps maintain a healthy credit score.");
  assert.ok(d && d !== "ignore");
  assert.equal(d.kind, "due");
  assert.equal(d.amount, 506.54);
  assert.equal(d.dueDate, "2026-11-12");
});

test("failed repayment, OTP and offers are ignored", () => {
  assert.equal(lender("Repayment failed", "Hi Asha, Your repayment of ₹28,\u200c921.90 has failed."), "ignore");
  assert.equal(lender("Your slice email OTP is 8111", "Your OTP is 8111"), "ignore");
  assert.equal(parseLenderEmail(mail("Fibe <notification@info.fibe.in>", "Pay with FibePay and win every week!", "Win exciting prizes")), "ignore");
});

test("Slice bank account alerts go to the normal reader", () => {
  assert.equal(lender("₹300 debited from your slice account", "₹300 debited from your slice bank account xx2690 via UPI."), null);
});
