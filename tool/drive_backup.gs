// Dukaan Khata – automatic nightly backup to Google Drive (Google Apps Script).
//
// Runs on Google's computers every night, even when every phone is off.
// It signs in like the app does, downloads the whole shop from the cloud and
// saves it as one file in the Drive folder "Dukaan Khata Backups". The file is
// the same as the app's own backup: More → Backup → Restore reads it.
// The newest 60 backups are kept; older ones go to Drive's bin.
//
// Setup (once): paste this at script.google.com, set the two Script
// Properties EMAIL and PASSWORD (the owner's app login), then run setup().

const SUPABASE_URL = 'https://kbbhqurgkyimghvrhjts.supabase.co';
// publishable key: safe to share, the data is protected by the login above
const SUPABASE_KEY = 'sb_publishable_4beW7RKDIIKCiig-Ry0mwQ_6x-xyT_X';
const FOLDER = 'Dukaan Khata Backups';
const KEEP = 60;
const TABLES = ['businesses', 'members', 'ledgers', 'items', 'vouchers', 'voucher_lines', 'inventory_lines', 'bank_lines', 'audit_log'];

/** Run once: makes the nightly schedule (≈ 11 pm India time) and takes the first backup. */
function setup() {
  for (const t of ScriptApp.getProjectTriggers()) ScriptApp.deleteTrigger(t);
  ScriptApp.newTrigger('backupNow').timeBased().everyDays(1).atHour(23).inTimezone('Asia/Kolkata').create();
  backupNow();
}

/** The app's "Backup now" button opens this (Deploy → Web app, access: Anyone).
 *  It only takes a backup and answers how many rows went in – no shop data. */
function doGet() {
  const lock = LockService.getScriptLock();
  let out;
  try {
    lock.waitLock(120000);
    out = { ok: true, shops: backupNow() };
  } catch (e) {
    out = { ok: false, error: String(e && e.message || e) };
  } finally {
    try { lock.releaseLock(); } catch (e) {}
  }
  return ContentService.createTextOutput(JSON.stringify(out)).setMimeType(ContentService.MimeType.JSON);
}

/** Takes a backup now. */
function backupNow() {
  const props = PropertiesService.getScriptProperties();
  const email = props.getProperty('EMAIL'), password = props.getProperty('PASSWORD');
  if (!email || !password) throw new Error('Set the Script Properties EMAIL and PASSWORD first (Project Settings → Script Properties).');

  const login = UrlFetchApp.fetch(SUPABASE_URL + '/auth/v1/token?grant_type=password', {
    method: 'post',
    contentType: 'application/json',
    headers: { apikey: SUPABASE_KEY },
    payload: JSON.stringify({ email: email, password: password }),
    muteHttpExceptions: true,
  });
  if (login.getResponseCode() !== 200) throw new Error('Login failed: ' + login.getContentText());
  const token = JSON.parse(login.getContentText()).access_token;
  const headers = { apikey: SUPABASE_KEY, Authorization: 'Bearer ' + token };

  // every row, 1000 at a time
  function getAll(table, filter) {
    const out = [];
    for (let offset = 0; ; offset += 1000) {
      const r = UrlFetchApp.fetch(
        SUPABASE_URL + '/rest/v1/' + table + '?select=*&' + filter + '&order=id&limit=1000&offset=' + offset,
        { headers: headers, muteHttpExceptions: true });
      if (r.getResponseCode() !== 200) throw new Error(table + ': ' + r.getContentText());
      const rows = JSON.parse(r.getContentText());
      out.push.apply(out, rows);
      if (rows.length < 1000) return out;
    }
  }

  const folder = getFolder_();
  const shops = getAll('businesses', 'id=not.is.null');
  if (shops.length === 0) throw new Error('No shop found for ' + email);
  const done = [];
  for (const shop of shops) {
    const tables = {}, counts = {};
    let count = 0;
    for (const t of TABLES) {
      tables[t] = getAll(t, (t === 'businesses' ? 'id=eq.' : 'business_id=eq.') + encodeURIComponent(shop.id));
      counts[t] = tables[t].length;
      count += tables[t].length;
    }
    const json = JSON.stringify({
      format: 'dukaan-khata-backup',
      version: 1,
      business_id: shop.id,
      exported_at: new Date().toISOString(),
      tables: tables,
    });
    const stamp = Utilities.formatDate(new Date(), 'Asia/Kolkata', 'yyyy-MM-dd HH-mm');
    const name = 'Dukaan Khata ' + (shop.name || shop.id) + ' ' + stamp + '.json';
    folder.createFile(Utilities.newBlob(json, 'application/json', name));
    console.log('Saved ' + name + ' (' + count + ' rows) ' + JSON.stringify(counts));
    done.push({ file: name, rows: count, tables: counts });
  }
  prune_(folder);
  return done;
}

function getFolder_() {
  const it = DriveApp.getFoldersByName(FOLDER);
  return it.hasNext() ? it.next() : DriveApp.createFolder(FOLDER);
}

/** Keep the newest KEEP backups. */
function prune_(folder) {
  const files = [];
  const it = folder.getFiles();
  while (it.hasNext()) files.push(it.next());
  files.sort((a, b) => b.getDateCreated() - a.getDateCreated());
  for (const f of files.slice(KEEP)) f.setTrashed(true);
}
