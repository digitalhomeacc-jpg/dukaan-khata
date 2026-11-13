/**
 * Expense Tracker – Gmail bank alert sync.
 *
 * Runs inside YOUR OWN Google account (script.google.com). Every 5 minutes it
 * looks for new bank alert emails and sends only those emails to your
 * Expense Tracker account. Nothing else in your Gmail is read or sent.
 *
 * Set-up (the app's Settings → Gmail sync → "Copy script" fills in the two values below):
 *   1. Open https://script.google.com → New project, delete everything, paste this file.
 *   2. Select the function "setup" in the toolbar and press Run.
 *   3. Allow access (Advanced → Go to project → Allow; it is your own script).
 */

var CONFIG = {
  INGEST_URL: '__INGEST_URL__',
  INGEST_TOKEN: '__INGEST_TOKEN__',
  // Public app key of the Expense Tracker server (safe to share; required by Supabase).
  SUPABASE_KEY: '__SUPABASE_KEY__',
  // How far back to look the very first time.
  BACKFILL_DAYS: 30,
  // Add more sender addresses or domains here if your bank uses another one.
  EXTRA_SENDERS: [],
};

var BANK_SENDERS = [
  // HDFC
  'hdfcbank.net', 'hdfcbank.com', 'hdfcbank.bank.in',
  // ICICI
  'icicibank.com', 'icici.bank.in',
  // SBI and SBI Card
  'sbi.co.in', 'sbi.bank.in', 'sbicard.com',
  // Axis
  'axisbank.com', 'axis.bank.in', 'axisbank.bank.in',
];

var KEYWORDS = ['debited', 'credited', 'spent', 'debit', 'credit', 'withdrawn', 'UPI', 'transaction'];

var BATCH_SIZE = 25;
var MAX_BODY = 8000;

/** Run this once by hand. It installs the 5-minute timer and does the first sync. */
function setup() {
  checkConfig_();
  ScriptApp.getProjectTriggers().forEach(function (t) {
    if (t.getHandlerFunction() === 'syncBankEmails') ScriptApp.deleteTrigger(t);
  });
  ScriptApp.newTrigger('syncBankEmails').timeBased().everyMinutes(5).create();
  var result = syncBankEmails();
  Logger.log('Set-up done. First sync: ' + JSON.stringify(result));
}

/** Called by the timer. Safe to run by hand any time. */
function syncBankEmails() {
  checkConfig_();
  var props = PropertiesService.getUserProperties();
  var nowSec = Math.floor(Date.now() / 1000);
  var lastSec = Number(props.getProperty('lastSyncEpoch') || 0);
  // Overlap by 6 hours: emails can arrive late. The server skips duplicates.
  var sinceSec = lastSec ? lastSec - 6 * 3600 : nowSec - CONFIG.BACKFILL_DAYS * 86400;

  var senders = BANK_SENDERS.concat(CONFIG.EXTRA_SENDERS || []);
  var query = 'from:(' + senders.join(' OR ') + ') {' + KEYWORDS.join(' ') + '} after:' + sinceSec;

  var messages = [];
  var start = 0;
  while (true) {
    var threads = GmailApp.search(query, start, 100);
    threads.forEach(function (thread) {
      thread.getMessages().forEach(function (m) {
        if (m.getDate().getTime() / 1000 < sinceSec) return;
        if (!isBankSender_(m.getFrom(), senders)) return;
        messages.push({
          id: m.getId(),
          from: m.getFrom(),
          subject: m.getSubject() || '',
          date: m.getDate().toISOString(),
          body: (m.getPlainBody() || m.getBody() || '').slice(0, MAX_BODY),
        });
      });
    });
    if (threads.length < 100) break;
    start += 100;
  }

  var totals = { received: 0, parsed: 0, added: 0, unreadable: 0 };
  for (var i = 0; i < messages.length || i === 0; i += BATCH_SIZE) {
    var r = post_(messages.slice(i, i + BATCH_SIZE)); // an empty batch still marks "last sync"
    ['received', 'parsed', 'added', 'unreadable'].forEach(function (k) { totals[k] += r[k] || 0; });
  }
  props.setProperty('lastSyncEpoch', String(nowSec));
  return totals;
}

/** Sends everything from the last N days again (duplicates are skipped). */
function resyncLast30Days() {
  PropertiesService.getUserProperties().deleteProperty('lastSyncEpoch');
  Logger.log(JSON.stringify(syncBankEmails()));
}

/** Shows what the script can see, to find out why nothing arrives. Run it and read the log. */
function checkSetup() {
  var senders = BANK_SENDERS.concat(CONFIG.EXTRA_SENDERS || []);
  var since = Math.floor(Date.now() / 1000) - CONFIG.BACKFILL_DAYS * 86400;
  var from = 'from:(' + senders.join(' OR ') + ')';
  var all = GmailApp.search(from + ' after:' + since, 0, 100);
  var tx = GmailApp.search(from + ' {' + KEYWORDS.join(' ') + '} after:' + since, 0, 100);
  Logger.log('Bank emails in the last ' + CONFIG.BACKFILL_DAYS + ' days: ' + all.length +
    ' threads, ' + tx.length + ' look like transactions.');
  tx.slice(0, 10).forEach(function (t) {
    var m = t.getMessages()[0];
    Logger.log('  ' + m.getDate().toISOString().slice(0, 10) + ' | ' + m.getFrom() + ' | ' + m.getSubject());
  });
  if (!all.length) Logger.log('No bank emails found. Check that your bank sends email alerts, and add its sender to EXTRA_SENDERS.');
  var triggers = ScriptApp.getProjectTriggers().filter(function (t) { return t.getHandlerFunction() === 'syncBankEmails'; });
  Logger.log('Automatic sync: ' + (triggers.length ? 'on (every 5 minutes)' : 'OFF – run setup'));
  var last = PropertiesService.getUserProperties().getProperty('lastSyncEpoch');
  Logger.log('Last sync: ' + (last ? new Date(Number(last) * 1000).toString() : 'never'));
}

/** Stops the automatic sync. */
function stopSync() {
  ScriptApp.getProjectTriggers().forEach(function (t) { ScriptApp.deleteTrigger(t); });
  Logger.log('Automatic sync stopped.');
}

function post_(batch) {
  var res = UrlFetchApp.fetch(CONFIG.INGEST_URL, {
    method: 'post',
    contentType: 'application/json',
    headers: { 'x-ingest-token': CONFIG.INGEST_TOKEN, 'apikey': CONFIG.SUPABASE_KEY },
    payload: JSON.stringify({ messages: batch }),
    muteHttpExceptions: true,
  });
  var code = res.getResponseCode();
  if (code !== 200) {
    throw new Error('Expense Tracker server said ' + code + ': ' + res.getContentText().slice(0, 300));
  }
  return JSON.parse(res.getContentText());
}

function isBankSender_(from, senders) {
  var f = String(from).toLowerCase();
  return senders.some(function (s) { return f.indexOf(String(s).toLowerCase()) !== -1; });
}

function checkConfig_() {
  if ([CONFIG.INGEST_URL, CONFIG.INGEST_TOKEN, CONFIG.SUPABASE_KEY].some(function (v) { return v.indexOf('__') === 0; })) {
    throw new Error('Copy the script from the app (Settings → Gmail sync → Copy script); it fills in your URL and token.');
  }
}
