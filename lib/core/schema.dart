// Single source of truth for the database tables.
//
// The same definition produces:
//  * the PowerSync client schema (used by the app – offline-first + sync), and
//  * plain CREATE TABLE statements (used by unit tests with an in-memory DB).
//
// Money is stored as INTEGER paise (₹1 = 100) to avoid floating point errors.
// Quantities are REAL (steel is sold in kg with decimals).
import 'package:powersync/powersync.dart' as ps;

enum ColType { text, integer, real }

class ColDef {
  final String name;
  final ColType type;
  const ColDef(this.name, this.type);
  const ColDef.t(this.name) : type = ColType.text;
  const ColDef.i(this.name) : type = ColType.integer;
  const ColDef.r(this.name) : type = ColType.real;
}

class TableDef {
  final String name;
  final List<ColDef> columns;
  final Map<String, List<String>> indexes;
  /// Kept on this device only (never synced or backed up).
  final bool localOnly;
  const TableDef(this.name, this.columns, {this.indexes = const {}, this.localOnly = false});
}

const List<TableDef> appTables = [
  TableDef('businesses', [
    ColDef.t('name'),
    ColDef.t('name_en'), // English shop name for PDFs / bills
    ColDef.t('phone'),
    ColDef.t('address'),
    ColDef.t('gstin'),
    ColDef.t('books_start'), // YYYY-MM-DD – first day of the books
    ColDef.i('fy_start_month'), // 4 = April
    ColDef.t('created_at'),
  ]),
  TableDef('members', [
    ColDef.t('business_id'),
    ColDef.t('user_id'),
    ColDef.t('email'),
    ColDef.t('name'),
    ColDef.t('role'), // owner | staff
  ], indexes: {
    'members_business': ['business_id'],
  }),
  // Every account: customers, suppliers, cash, PhonePe, bank, sales, expenses, GST…
  TableDef('ledgers', [
    ColDef.t('business_id'),
    ColDef.t('name'), // usually Marathi (as written in the register)
    ColDef.t('name_en'), // optional English / transliteration for search
    ColDef.t('grp'), // see LedgerGroup
    ColDef.t('phone'),
    ColDef.t('address'),
    ColDef.t('page_no'), // old khata page no. from the paper INDEX
    ColDef.t('gstin'), // party GSTIN (for GST bills)
    ColDef.t('short_code'), // C, H, D, P, T for money accounts
    ColDef.i('opening_balance'), // paise, +ve = receivable/debit
    ColDef.i('credit_limit'),
    ColDef.i('salary'), // staff: monthly salary (paise)
    ColDef.i('salary_cut'), // staff: advance recovered per month (paise)
    ColDef.i('interest_rate'), // व्याज: % per month × 100 (150 = 1.5 % दरमहा), 0 = none
    ColDef.i('system'), // 1 = built-in ledger, cannot be deleted
    ColDef.i('archived'),
    ColDef.t('created_at'),
  ], indexes: {
    'ledgers_business_grp': ['business_id', 'grp'],
  }),
  TableDef('items', [
    ColDef.t('business_id'),
    ColDef.t('name'),
    ColDef.t('name_en'),
    ColDef.t('category'), // cement | steel | blocks | plumbing | other
    ColDef.t('unit'), // bag | kg | nos | ft | ton | brass
    ColDef.t('short_code'), // U, A, M, 8MM …
    ColDef.i('sale_rate'), // paise per unit
    ColDef.i('purchase_rate'),
    ColDef.r('opening_qty'),
    ColDef.i('opening_rate'),
    ColDef.r('low_stock'),
    ColDef.i('sort_order'),
    ColDef.i('archived'),
    ColDef.t('created_at'),
  ], indexes: {
    'items_business': ['business_id'],
  }),
  TableDef('vouchers', [
    ColDef.t('business_id'),
    ColDef.t('vtype'), // see VoucherType
    ColDef.i('vno'),
    ColDef.t('vdate'), // YYYY-MM-DD
    ColDef.t('party_id'), // customer / supplier / expense ledger
    ColDef.t('pay_ledger_id'), // cash / PhonePe / bank used
    ColDef.i('amount'), // total value (paise)
    ColDef.i('paid'), // amount settled immediately (paise)
    ColDef.t('narration'),
    ColDef.t('ref_no'), // bill no / vehicle no / cheque no
    ColDef.i('gst_bill_needed'),
    ColDef.i('hamali'), // labour charged on the bill (paise)
    ColDef.i('transport'), // transport charged on the bill (paise)
    ColDef.t('transporter_id'), // null = own vehicle
    ColDef.i('transporter_fare'), // owed to outside transporter (paise)
    ColDef.i('gst_rate'), // percent ×100 (1800 = 18%), 0 = no GST bill
    ColDef.i('gst'), // GST amount on this bill (paise)
    ColDef.t('haste'), // हस्ते – who brought / took the money or goods (optional)
    ColDef.t('status'), // promises: open | done | missed
    ColDef.t('created_by'),
    ColDef.t('created_at'),
    ColDef.t('updated_at'),
    ColDef.i('deleted'),
    ColDef.i('version'),
  ], indexes: {
    'vouchers_business_date': ['business_id', 'vdate'],
    'vouchers_party': ['party_id'],
  }),
  TableDef('voucher_lines', [
    ColDef.t('business_id'),
    ColDef.t('voucher_id'),
    ColDef.t('ledger_id'),
    ColDef.i('debit'),
    ColDef.i('credit'),
    ColDef.t('vdate'),
    ColDef.i('deleted'),
  ], indexes: {
    'vlines_voucher': ['voucher_id'],
    'vlines_ledger_date': ['ledger_id', 'vdate'],
  }),
  TableDef('inventory_lines', [
    ColDef.t('business_id'),
    ColDef.t('voucher_id'),
    ColDef.t('item_id'),
    ColDef.r('qty'),
    ColDef.i('rate'),
    ColDef.i('amount'),
    ColDef.i('direction'), // +1 stock in, -1 stock out
    ColDef.t('vdate'),
    ColDef.i('deleted'),
  ], indexes: {
    'ilines_voucher': ['voucher_id'],
    'ilines_item_date': ['item_id', 'vdate'],
  }),
  // Lines imported from a bank statement, matched to vouchers.
  TableDef('bank_lines', [
    ColDef.t('business_id'),
    ColDef.t('bank_ledger_id'),
    ColDef.t('import_id'),
    ColDef.t('tdate'), // YYYY-MM-DD
    ColDef.t('description'),
    ColDef.t('ref'),
    ColDef.i('debit'), // money out of the bank (paise)
    ColDef.i('credit'), // money into the bank (paise)
    ColDef.i('balance'),
    ColDef.t('fingerprint'), // de-duplicates re-uploads
    ColDef.t('voucher_id'), // matched / created voucher
    ColDef.t('status'), // open | matched | ignored
    ColDef.t('created_at'),
  ], indexes: {
    'bank_lines_bank_date': ['bank_ledger_id', 'tdate'],
    'bank_lines_fp': ['fingerprint'],
  }),
  // Changes the server refused (shown in the sync panel instead of vanishing).
  TableDef('sync_errors', [
    ColDef.t('at'),
    ColDef.t('tables'),
    ColDef.t('message'),
    ColDef.t('ops'), // JSON of the refused changes
  ], localOnly: true),
  TableDef('audit_log', [
    ColDef.t('business_id'),
    ColDef.t('voucher_id'),
    ColDef.t('action'), // create | edit | delete
    ColDef.t('user_id'),
    ColDef.t('user_name'),
    ColDef.t('at'),
    ColDef.t('snapshot'), // JSON: kind, title, before, after
    ColDef.t('received_at'), // set by the server when the change reached it (can't be altered by a phone)
  ], indexes: {
    'audit_voucher': ['voucher_id'],
  }),
];

ps.Schema buildPowerSyncSchema() {
  return ps.Schema([
    for (final t in appTables)
      ps.Table(
        t.name,
        [
          for (final c in t.columns)
            switch (c.type) {
              ColType.text => ps.Column.text(c.name),
              ColType.integer => ps.Column.integer(c.name),
              ColType.real => ps.Column.real(c.name),
            },
        ],
        indexes: [
          for (final e in t.indexes.entries)
            ps.Index(e.key, [for (final c in e.value) ps.IndexedColumn(c)]),
        ],
        localOnly: t.localOnly,
      ),
  ]);
}

/// Plain SQLite DDL – used by tests and by the Postgres migration generator.
List<String> buildSqliteDdl() {
  final out = <String>[];
  for (final t in appTables) {
    final cols = t.columns.map((c) {
      final type = switch (c.type) {
        ColType.text => 'TEXT',
        ColType.integer => 'INTEGER',
        ColType.real => 'REAL',
      };
      return '${c.name} $type';
    }).join(', ');
    out.add('CREATE TABLE IF NOT EXISTS ${t.name} (id TEXT PRIMARY KEY, $cols)');
    for (final e in t.indexes.entries) {
      out.add('CREATE INDEX IF NOT EXISTS ${e.key} ON ${t.name} (${e.value.join(', ')})');
    }
  }
  return out;
}
