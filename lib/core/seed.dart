import 'package:sqlite_async/sqlite_async.dart';

import '../accounting/models.dart';
import 'ids.dart';

/// Built-in ledgers every shop gets. `key` is a stable lookup used by the
/// posting rules (e.g. a sale credits the ledger with key 'sales').
class SeedLedger {
  final String key;
  final String name;
  final String nameEn;
  final LedgerGroup group;
  final String? code;
  const SeedLedger(this.key, this.name, this.nameEn, this.group, [this.code]);
}

const seedLedgers = <SeedLedger>[
  SeedLedger('cash', 'रोख', 'Cash', LedgerGroup.cash, 'C'),
  SeedLedger('upi_h', 'फोनपे (H)', 'PhonePe H', LedgerGroup.upi, 'H'),
  SeedLedger('upi_d', 'फोनपे (D)', 'PhonePe D', LedgerGroup.upi, 'D'),
  SeedLedger('upi_p', 'फोनपे (P)', 'PhonePe P', LedgerGroup.upi, 'P'),
  SeedLedger('bank', 'बँक / RTGS', 'Bank / RTGS', LedgerGroup.bank, 'T'),
  SeedLedger('sales', 'विक्री', 'Sales', LedgerGroup.sales),
  SeedLedger('sales_return', 'विक्री परत', 'Sales Return', LedgerGroup.salesReturn),
  SeedLedger('purchase', 'खरेदी', 'Purchase', LedgerGroup.purchase),
  SeedLedger('purchase_return', 'खरेदी परत', 'Purchase Return', LedgerGroup.purchaseReturn),
  SeedLedger('gst', 'GST', 'GST', LedgerGroup.gst),
  SeedLedger('history_adj', 'जुन्या नोंदी (समायोजन)', 'Old entries adjustment', LedgerGroup.capital),
  SeedLedger('capital', 'भांडवल / उचल', 'Capital / Drawings', LedgerGroup.capital),
  SeedLedger('freight', 'भाडे', 'Freight / Transport', LedgerGroup.directExpense),
  SeedLedger('hamali', 'हमाली', 'Labour (Hamali)', LedgerGroup.directExpense),
  SeedLedger('hamali_income', 'हमाली (बिलात घेतली)', 'Hamali charged', LedgerGroup.income),
  // वराई: hamali money the company's truck driver hands over for the labourers
  SeedLedger('varhai', 'वराई (कंपनीकडून हमाली)', 'Varhaai (company hamali)', LedgerGroup.income),
  SeedLedger('transport_income', 'गाडी भाडे (आपली गाडी)', 'Transport income (own vehicle)', LedgerGroup.income),
  SeedLedger('salary', 'पगार', 'Salary', LedgerGroup.expense),
  SeedLedger('rent', 'भाडे (दुकान)', 'Shop Rent', LedgerGroup.expense),
  SeedLedger('light', 'लाईट बिल', 'Electricity', LedgerGroup.expense),
  SeedLedger('tea', 'चहा पाणी', 'Tea / Water', LedgerGroup.expense),
  SeedLedger('misc_exp', 'इतर खर्च', 'Misc. Expense', LedgerGroup.expense),
  SeedLedger('discount_given', 'सूट दिली', 'Discount Allowed', LedgerGroup.expense),
  SeedLedger('discount_recd', 'सूट मिळाली', 'Discount Received', LedgerGroup.income),
  SeedLedger('round_off', 'राउंड ऑफ', 'Round off', LedgerGroup.expense),
  SeedLedger('service_income', 'सेवा उत्पन्न', 'Service income', LedgerGroup.income),
  SeedLedger('service_cost', 'सेवा खर्च / मजुरी', 'Service cost / labour', LedgerGroup.directExpense),
  SeedLedger('interest_income', 'व्याज मिळाले', 'Interest received', LedgerGroup.income),
  SeedLedger('other_income', 'इतर उत्पन्न', 'Other Income', LedgerGroup.income),
  // रोख मोजणी: counted cash vs books (short = loss, extra = income)
  SeedLedger('cash_diff', 'रोख फरक (कमी/जास्त)', 'Cash short / excess', LedgerGroup.expense),
  SeedLedger('stock_adj', 'स्टॉक फरक', 'Stock Adjustment', LedgerGroup.expense),
];

class SeedItem {
  final String name;
  final String nameEn;
  final String category;
  final String unit;
  final String code;
  final int saleRatePaise;
  const SeedItem(this.name, this.nameEn, this.category, this.unit, this.code, this.saleRatePaise);
}

/// Starting item list based on the stock register columns (editable later).
const seedItems = <SeedItem>[
  SeedItem('W सिमेंट', 'W Cement', 'cement', 'bag', 'W', 28000),
  SeedItem('M सिमेंट (M.Pt)', 'M Cement', 'cement', 'bag', 'M', 28500),
  SeedItem('अल्ट्राटेक', 'Ultratech', 'cement', 'bag', 'U', 30000),
  SeedItem('सुप्रीम', 'Super', 'cement', 'bag', 'S', 29000),
  SeedItem('अंबुजा', 'Ambuja', 'cement', 'bag', 'A', 30000),
  SeedItem('सळई 6mm', 'TMT 6mm', 'steel', 'kg', '6', 6500),
  SeedItem('सळई 8mm', 'TMT 8mm', 'steel', 'kg', '8', 6200),
  SeedItem('सळई 10mm', 'TMT 10mm', 'steel', 'kg', '10', 6100),
  SeedItem('सळई 12mm', 'TMT 12mm', 'steel', 'kg', '12', 6100),
  SeedItem('सळई 16mm', 'TMT 16mm', 'steel', 'kg', '16', 6100),
  SeedItem('बाइंडिंग तार', 'Binding Wire', 'steel', 'kg', 'BW', 9000),
  SeedItem('ब्लॉक 6"', 'Block 6"', 'blocks', 'nos', 'B6', 4500),
  SeedItem('ब्लॉक 9"', 'Block 9"', 'blocks', 'nos', 'B9', 5500),
  SeedItem('पाईप', 'Pipe', 'plumbing', 'nos', 'PP', 0),
];

/// Creates the built-in ledgers and starter items for a new business.
/// Idempotent: does nothing if ledgers already exist.
Future<void> seedBusiness(SqliteWriteContext db, String businessId, {bool withItems = true}) async {
  final existing = await db.getOptional(
      'SELECT id FROM ledgers WHERE business_id = ? AND system = 1 LIMIT 1', [businessId]);
  if (existing != null) {
    await ensureSystemLedgers(db, businessId);
    return;
  }
  final now = nowIso();
  for (final l in seedLedgers) {
    await db.execute(
      'INSERT INTO ledgers (id, business_id, name, name_en, grp, short_code, opening_balance, '
      'credit_limit, system, archived, created_at) VALUES (?, ?, ?, ?, ?, ?, 0, 0, 1, 0, ?)',
      [systemLedgerId(businessId, l.key), businessId, l.name, l.nameEn, l.group.code, l.code, now],
    );
  }
  if (!withItems) return;
  var order = 0;
  for (final it in seedItems) {
    await db.execute(
      'INSERT INTO items (id, business_id, name, name_en, category, unit, short_code, sale_rate, '
      'purchase_rate, opening_qty, opening_rate, low_stock, sort_order, archived, created_at) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0, 0, 0, 0, ?, 0, ?)',
      [newId(), businessId, it.name, it.nameEn, it.category, it.unit, it.code, it.saleRatePaise, order++, now],
    );
  }
}

/// Adds built-in ledgers introduced by app updates to an existing shop.
/// [only]: the ids the server confirmed missing (cloud); null = local shop.
Future<void> ensureSystemLedgers(SqliteWriteContext db, String businessId, {Set<String>? only}) async {
  for (final l in seedLedgers) {
    final id = systemLedgerId(businessId, l.key);
    if (only != null && !only.contains(id)) continue;
    if (await db.getOptional('SELECT id FROM ledgers WHERE id = ?', [id]) != null) continue;
    await db.execute(
      'INSERT INTO ledgers (id, business_id, name, name_en, grp, short_code, opening_balance, '
      'credit_limit, system, archived, created_at) VALUES (?, ?, ?, ?, ?, ?, 0, 0, 1, 0, ?)',
      [id, businessId, l.name, l.nameEn, l.group.code, l.code, nowIso()],
    );
  }
}

/// Deterministic id for built-in ledgers, so every device of the same shop
/// agrees on e.g. the "Sales" ledger id even when seeded offline.
String systemLedgerId(String businessId, String key) => '$businessId:$key';
