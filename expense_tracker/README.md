# Expense Tracker

A personal expense tracker for you and your friends. Each person has their own
login, and their bank alert emails (HDFC, ICICI, SBI, Axis) flow from **their own
Gmail** into **their own** account automatically.

```
 Gmail (each user)                Supabase (one project for everyone)        Phone app
┌───────────────────┐  every   ┌──────────────────────────────────────┐   ┌───────────┐
│ Google Apps Script│  5 min   │ Edge Function  ingest-email          │   │ Flutter   │
│ finds bank alerts ├─────────►│  token → user, parse, de-duplicate   │   │ Android / │
│ sends only those  │  HTTPS   │ Postgres + Row Level Security        │◄─►│ iOS / web │
└───────────────────┘          │  (each user sees only their rows)    │   │           │
                               └──────────────────────────────────────┘   └───────────┘
```

* **Login**: email + password (Supabase Auth). Forgot password works with an emailed code.
* **Gmail**: a small script in each person's Google account. No Google app review, no
  re-login every week, and only bank alert emails ever leave Gmail.
* **Parsing** happens on the server, so improving a parser helps everyone without
  anyone touching their script.
* **Auto-categories**: set a category once for "SWIGGY" and every Swiggy payment after that
  is filed under it.
* Card bill payments and own-account transfers are marked *not counted*, so money is not
  counted twice (you can toggle this on any transaction).
* Emails that look like a payment but can't be read land in *Settings → Emails we couldn't read*,
  where one tap turns them into a transaction.

## Folder layout

| Path | What |
|---|---|
| `lib/` | Flutter app (screens, Supabase data layer, monthly summaries) |
| `apps_script/Code.gs` | The Gmail script. The app copies it with the user's URL and key filled in |
| `supabase/migrations/0001_init.sql` | Tables, Row Level Security, new-user trigger with default categories |
| `supabase/functions/ingest-email/` | Edge Function + bank email parsers (`parsers.ts`) and their tests |
| `tool/preview_main.dart` | The app with sample data and no backend, for trying the UI |

## One-time set-up (you, the admin)

### 1. Supabase project

1. Create a free project at [supabase.com](https://supabase.com). Pick the **Mumbai** region.
2. **SQL Editor** → paste `supabase/migrations/0001_init.sql` → Run.
3. **Authentication → Sign In / Providers → Email**: leave email + password on.
   For a group of friends you can turn off *Confirm email*. Then nobody has to click a link before
   their first login.
4. **Authentication → Emails → Magic Link** template: add `{{ .Token }}` to the body, for example
   `Your code is {{ .Token }}`. The app's *Forgot password* screen asks for that code.
5. **Project Settings → API Keys**: note the **Project URL** and the **publishable** key (or the legacy
   *anon* key). Both are safe to ship inside the app. Never put the *secret / service_role* key in the app.

### 2. Deploy the email function

Install the [Supabase CLI](https://supabase.com/docs/guides/cli), then from this folder:

```bash
supabase login
supabase link --project-ref <your-project-ref>
supabase functions deploy ingest-email --no-verify-jwt
```

`--no-verify-jwt` is needed because the Gmail script proves who it is with each user's own
secret key (`x-ingest-token`), not with a Supabase login.

### 3. Build the app

```bash
flutter pub get
flutter run --dart-define=SUPABASE_URL=https://<ref>.supabase.co \
            --dart-define=SUPABASE_PUBLISHABLE_KEY=<publishable-or-anon-key>

# Android APK to send to friends:
flutter build apk --release --dart-define=SUPABASE_URL=... --dart-define=SUPABASE_PUBLISHABLE_KEY=...
# → build/app/outputs/flutter-apk/app-release.apk
```

Tip: put both values in `env.json` (git-ignored) and use `--dart-define-from-file=env.json`.

For iPhones, build from a Mac with Xcode (`flutter build ipa`) and share through TestFlight.
Or deploy the web build (`flutter build web`) to any static host and add it to the home screen.

## Each friend (about 3 minutes)

1. Install the app → **Create account** with email + password.
2. **Settings → Gmail sync → Copy script**.
3. Open **script.google.com** while signed in to the Gmail account that gets the bank emails →
   *New project* → delete the sample → paste → save.
4. Choose **setup** in the function list → **Run** → allow access
   (*Advanced → Go to … (unsafe) → Allow*: Google shows this for every personal script).

The last 30 days are imported straight away, then new alerts every 5 minutes.
Other functions in the script: `resyncLast30Days`, `stopSync`.

If a bank uses a sender address that isn't listed, add it to `EXTRA_SENDERS` at the top of the script.

## Privacy and security

* Row Level Security on every table: a user can only read or change their own rows, even with the
  public app key. The email function uses the service key on the server only.
* The per-user ingest key only allows *adding* bank emails to that one account. If it leaks, use
  **Settings → Gmail sync → Make a new secret key** and paste the script again.
* The script searches only bank sender domains and transaction keywords, and sends only those emails.
* Users cannot change their own ingest key or sync time directly. A database function does it.

## Development

```bash
flutter analyze && flutter test                                    # app: summaries + screens
node --test supabase/functions/ingest-email/parsers.test.ts        # parsers (Node 23.6+)
flutter run -d chrome -t tool/preview_main.dart                    # UI with sample data
```

### Adding or fixing a bank format

1. Copy the email text from *Emails we couldn't read*.
2. Add it as a test case in `parsers.test.ts` with the expected amount, direction and merchant.
3. Adjust `parsers.ts` until all tests pass, then `supabase functions deploy ingest-email --no-verify-jwt`.
   Users then run `resyncLast30Days` if they want earlier emails read again.
