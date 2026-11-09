# दुकान खाता · Dukaan Khata

Accounting + khata + stock app for a building-materials shop. Marathi first (English toggle).
One Flutter codebase for **Android (Samsung S25 Ultra)**, **iPhone 17 Pro** and **Windows laptop**.

It replaces the three paper registers:

| Paper register | In the app |
|---|---|
| खाता वही + INDEX (page no. → customer) | **ग्राहक** tab – search by name / page no. / phone, khata page with running बाकी, WhatsApp reminder & statement |
| रोजमेळ (cash in / out, PhonePe, RTGS) | **रोजमेळ** tab – day view, opening → in / out → closing, one chip per account (C, H, D, P, T) |
| स्टॉक रजिस्टर (daily, one column per item) | **स्टॉक → दैनिक स्टॉक रजिस्टर** – same layout: opening, each bill as `15/275`, closing |

Under the hood it is full double-entry (Tally-style): every entry is a balanced voucher, so Trial Balance,
P&L and Balance Sheet come out automatically. GST is not calculated – GST money goes to the single **GST** ledger,
and any entry can be flagged **GST बिल हवे** (report: *Entries needing GST bill*).

## Fast entry

On the sale/purchase screen, type the same shorthand as the register and press Enter:

```
M 12×285      → 12 bags of M cement at ₹285
U 15/275      → 15 bags Ultratech at ₹275
8mm 120/62    → 120 kg 8mm steel at ₹62
W 10          → 10 bags W at the default rate
M 7=2000      → 7 bags for ₹2,000 in total (rate worked out)
M १०×२८५      → Marathi digits work too
```

The 🎤 button does the same by voice. Pay-mode chips: **उधार** (credit), **C** cash, **H/D/P** PhonePe accounts,
**T** bank/RTGS. A partly paid bill leaves the rest as बाकी automatically.

Item short codes and account codes can be changed in **अधिक → खाती** and the item form.

## Hamali and transport on bills

Every sale bill has **हमाली** and **गाडी भाडे** fields, added to the customer's bill:

* **हमाली** → income *हमाली (बिलात घेतली)*. Labourers are paid at day end as the expense *हमाली*;
  the difference is your profit (Rojmal → *दिवस अखेर हिशोब* shows charged vs paid).
* **गाडी भाडे, आपली गाडी** → income *गाडी भाडे (आपली गाडी)*. The driver's monthly pay is the *पगार* expense.
* **गाडी भाडे, outside transporter** (dropdown, add new from there) → owed to that transporter.
  The optional *ट्रान्सपोर्टरला द्यायचे* field records his fare if it differs; the extra is your income.
  Pay him from the day-end card (*पैसे द्या*).

## व्याज (interest on overdue balances)

Owner only. Set a rate per account (khata → ✏️ → *व्याज दर*, % per month), then khata → ⋮ → **व्याज लावा**:
pick the period (from the last interest entry by default; 1 / 3 / 6 / 12 month chips), see the day-by-day
working and tap **खात्यात लावा** – it goes on the khata as a *व्याज* entry (income: *व्याज मिळाले*).
Simple interest on the daily balance (month = 30 days); no interest on days with nothing owed or on earlier
interest. Reports → **व्याज यादी** lists every account with a rate and charges all at once.

## PDFs

PDFs and prints are in English (the PDF engine cannot join Marathi letters): names use the saved English
name, or are spelt in English letters. Set the English shop name in *दुकान माहिती*. Screens and Excel stay Marathi.

## उसना माल (bags lent / borrowed)

Khata page → ⋮ → **माल उसना दिला** when bags are given to come back as bags (no money), and
**उसना माल आला** when they come back (or when we borrow). Stock moves; money never does. The khata and
customer list show **माल येणे / माल देणे** in bags next to the ₹ balance; Reports → *उसना माल* lists all.
Bags that were already out before the books start: owner turns on **सुरुवातीचा उसना माल** in the same
screen – counted as owed, but no change to stock (the opening count already left them out), money or profit.
Old entries (जुनी नोंद) stay reference only.

## रोख मोजणी (cash count)

Rojmal → calculator icon (or **+** → रोख मोजणी): type how many notes of each kind (or just the
total). The app shows cash as per the books, cash counted and the difference. One tap books it to
the built-in *रोख फरक (कमी/जास्त)* account – short as a loss, extra as income – so the books match
the drawer. Reports → *रोख फरक (मोजणी)* lists every day's difference and the running total.

## वराई (company hamali)

When the company's truck driver hands over hamali money for the labourers, type it in the purchase
bill's **वराई मिळाली** field, or use Rojmal → **+** / day-end card → **वराई मिळाली** on its own.
It goes into cash and the built-in *वराई (कंपनीकडून हमाली)* account, never into the company's
khata. The day-end card adds it to the hamali taken on bills: **हमालांना द्यायचे** = bills + वराई.

## Books start, financial year and old entries

Set on first launch (and later in **अधिक → दुकान माहिती व हिशोब वर्ष**): the **books start date**
(e.g. 08-11-26) and the **month the financial year starts** (April by default).
Rojmal, stock and profit count from the books start. Older history goes in as
**जुनी नोंद** (khata page → ⋮ → जुनी नोंद जोडा): a full bill (items, hamali, transport, round off,
money received at the time) or a money entry. Old entries are **reference only**: they change nothing –
no balance, opening balance, cash, sales, hamali, profit or stock. They show on the khata page under
*जुन्या नोंदी – फक्त माहितीसाठी*, so you can show a customer how their opening balance came about.

## हस्ते (through whom)

Every entry has an optional **हस्ते** field – who brought / took the money or goods when the owner
was not there (e.g. "मुलगा", "ड्रायव्हर राजू"). It shows on the khata and day book.

## वसुली वायदे (payment promises)

After calling a customer, record the date they promised to pay: khata page → 📅 button, or
**अहवाल → वसुली वायदे**. The home screen shows how many promises are due today or overdue.
From the list: call, WhatsApp reminder, *पैसे आले* (marks kept and opens a receipt), *पुढे ढकला*
(new date; old one marked missed) or *रद्द*. Promises never change any balance.

Dates can be typed (14/9/26, 140926, 14/9) or picked from the calendar; Enter moves on.

## GST (owner only)

On sale and purchase bills the owner sees a **GST बिल** card (5 / 12 / 18 / 28 %). GST on purchases is
input credit, GST on sales is output tax, both in the **GST** ledger. Reports → *GST सारांश* shows
input vs output and net payable by month. Party GSTIN is on the customer/supplier form; the bill
PDF becomes a tax invoice with CGST/SGST when GST is charged. Staff cannot make GST bills or see GST reports.

## Bank statements

**अधिक → बँक स्टेटमेंट जुळवणी**: upload the PDF, Excel or CSV statement from the bank app / net-banking
(any bank). Password-locked PDFs ask for the password; scanned (photo) PDFs can't be read.
PDFs are read in the browser with the bundled pdf.js (Apache-2.0, `web/pdfjs`). Lines already in the books are matched automatically
(same amount, ±3 days). For the rest, tap the suggested name (found from the narration or phone number)
to create the receipt / payment, pick another party, or ignore. Uploading the same statement twice is safe.
Statement balance vs books balance shows any difference.

## Backup

**अधिक → पूर्ण बॅकअप फाइल** saves every entry to one file. On a new phone, the first screen has
**बॅकअप फाइलमधून परत आणा**.

## Roles

* **मालक (Owner)** – everything: delete, edit old entries, P&L / Balance Sheet, opening balances, items, users.
* **कर्मचारी (Staff)** – today's sales / receipts / expenses only, no delete, no profit reports.
  Enforced in the app *and* in the database (Postgres row-level security, see `supabase/migrations`).
  Every create / edit / delete is kept in **बदल इतिहास** (audit log) with the old values.

## Two ways to run

### 1. This device only (no setup)
Just build and run. First launch asks for shop name, owner PIN and (optional) staff PIN.
Data stays on that device; use **अहवाल → बॅकअप** to export Excel.

### 2. All devices in sync (recommended) – offline-first
Each phone/laptop keeps its own copy and works without internet; changes sync when online.

1. Create a free project at **supabase.com**. In *SQL Editor* run the files in `supabase/migrations/` in order.
   In *Authentication → Providers* keep Email enabled.
2. Create a free instance at **powersync.com**, connect it to the Supabase database
   (Supabase → Settings → Database → connection string), enable *Supabase Auth*,
   and paste `powersync/sync-rules.yaml` into *Sync Rules*.
3. Build with the three values:

```bash
flutter run --dart-define=SUPABASE_URL=https://xxxx.supabase.co --dart-define=SUPABASE_KEY=sb_publishable_... --dart-define=POWERSYNC_URL=https://xxxx.powersync.journeyapps.com
```

The owner signs up → **दुकान सुरू करा**. To add your father/staff: **अधिक → वापरकर्ते → कर्मचारी जोडा (ईमेल)**;
they sign up with that email and land in the same shop.

## Moving from the paper books

* **अधिक → Excel नमुना** downloads a template (`name | page_no | phone | balance | name_en | type`).
  Fill it from the INDEX page + last balance of each khata page, then **जुनी बाकी आयात**.
* Set each item's opening stock from the last closing row of the stock register (स्टॉक → item → ✏️).

## Building

```bash
flutter pub get
```

```bash
flutter build apk --release --dart-define=...      # Android – install the APK on the S25 Ultra
```

```bash
flutter build windows --release --dart-define=...  # run on a Windows PC
```

* **iPhone**: needs an Apple Developer account ($99/year). Without a Mac, use Codemagic (codemagic.io):
  connect the repo, add the same `--dart-define` values, build iOS and send to TestFlight.
* **Web app + demo for GitHub Pages** (stamps every file so phones load the new version on refresh):

```bash
./tool/build_web.sh build/site
```

  Then publish `build/site` to the `gh-pages` branch. The demo (sample data, owner PIN 1234 / staff PIN 5678) is in `build/site/demo`.

If you upgrade the `powersync` / `sqlite_async` packages, rebuild the web worker:

```bash
dart compile js -O4 -o web/powersync_db.worker.js tool/powersync_db.worker.dart
```

## Code map

```
lib/
  core/        schema (one definition → PowerSync + SQLite), money/date helpers, seed ledgers & items, i18n, sync connector, demo data
  accounting/  models, voucher_service (posting rules, audit, permissions), ledger_repo (balances, khata, rojmal), reports
  inventory/   stock_repo (stock, item ledger, daily register, weighted-average cost)
  shared/      shortcode parser, widgets, PDF/Excel/WhatsApp export
  features/    home, voucher entry, customers/khata, rojmal, stock, reports, settings, login/PIN
supabase/      Postgres schema + row-level security
powersync/     sync rules
test/          voucher balancing, khata running-balance test, rojmal, stock register, parser, permissions
```

Run tests: `flutter test`
