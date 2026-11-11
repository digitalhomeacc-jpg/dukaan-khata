import 'package:sqlite_async/sqlite_async.dart';

import '../accounting/models.dart';
import '../accounting/voucher_service.dart' show goodsOpeningMarker;
import '../core/audit.dart';
import '../core/ids.dart';
import '../core/money.dart';

class StockMove {
  final String voucherId;
  final String date;
  final VoucherType type;
  final int vno;
  final String? partyName;
  final String? pageNo;
  final double qtyIn;
  final double qtyOut;
  final int rate;
  final double balance;
  StockMove(this.voucherId, this.date, this.type, this.vno, this.partyName, this.pageNo, this.qtyIn, this.qtyOut,
      this.rate, this.balance);
}

/// One row of the daily stock register (a bill, with qty per item column).
class RegisterRow {
  final String voucherId;
  final int serial;
  final VoucherType type;
  final String? partyName;
  final String? pageNo;
  final String? payCode;
  final int amount;
  final int paid;
  final Map<String, double> qty; // itemId → qty (+in / −out)
  final Map<String, int> rate;
  final String? payName; // रोख / फोनपे / bank – the account the money went to
  final String? payNameEn;
  final String? partyNameEn;
  final String? haste;
  RegisterRow(this.voucherId, this.serial, this.type, this.partyName, this.pageNo, this.payCode, this.amount,
      this.paid, this.qty, this.rate, {this.payName, this.payNameEn, this.partyNameEn, this.haste});

  bool get isIn => qty.values.any((q) => q > 0) && !qty.values.any((q) => q < 0);
}

class DailyRegister {
  final String date;
  final List<Item> items; // columns
  final Map<String, double> opening;
  final List<RegisterRow> rows;
  DailyRegister(this.date, this.items, this.opening, this.rows);

  double totalOut(String itemId) =>
      rows.fold(0.0, (s, r) => s + ((r.qty[itemId] ?? 0) < 0 ? -(r.qty[itemId]!) : 0));
  double totalIn(String itemId) =>
      rows.fold(0.0, (s, r) => s + ((r.qty[itemId] ?? 0) > 0 ? r.qty[itemId]! : 0));
  double closing(String itemId) => (opening[itemId] ?? 0) + totalIn(itemId) - totalOut(itemId);
  bool moved(String itemId) => rows.any((r) => r.qty.containsKey(itemId));
}

/// Bags lent to / borrowed from one party (उसना माल), net per item.
/// [qty] > 0: the party owes us bags; < 0: we owe them.
class GoodsOwed {
  final String partyId;
  final String partyName;
  final String? pageNo;
  final Item item;
  final double qty;
  GoodsOwed(this.partyId, this.partyName, this.pageNo, this.item, this.qty);
}

class StockRepo {
  /// + bags the party owes us, − bags we owe (from the entry type, so opening
  /// entries without a stock direction count too).
  static const _goodsSign = "CASE v.vtype WHEN 'goods_out' THEN il.qty ELSE -il.qty END";

  final SqliteConnection db;
  final String businessId;
  StockRepo(this.db, this.businessId);

  static const _stockExpr =
      '(COALESCE(i.opening_qty,0) + COALESCE((SELECT SUM(il.qty * il.direction) FROM inventory_lines il '
      'WHERE il.item_id = i.id AND il.deleted = 0), 0))';

  String get _listSql => 'SELECT i.*, $_stockExpr AS stock FROM items i WHERE i.business_id = ? '
      'AND COALESCE(i.archived,0) = 0 ORDER BY i.sort_order, i.name';

  Future<List<Item>> list() async => (await db.getAll(_listSql, [businessId])).map(Item.fromRow).toList();

  Stream<List<Item>> watch() => db
      .watch(_listSql, parameters: [businessId], triggerOnTables: const ['items', 'inventory_lines'])
      .map((rs) => rs.map(Item.fromRow).toList());

  Future<Item?> byId(String id) async {
    final r = await db.getOptional('SELECT i.*, $_stockExpr AS stock FROM items i WHERE i.id = ?', [id]);
    return r == null ? null : Item.fromRow(r);
  }

  Future<String> save({
    String? id,
    required String name,
    String? nameEn,
    required String category,
    required String unit,
    String? shortCode,
    int saleRate = 0,
    int purchaseRate = 0,
    double openingQty = 0,
    int openingRate = 0,
    double lowStock = 0,
    String? subcategory, // null = leave as it is; '' = none
  }) async {
    String? n(String? s) => (s == null || s.trim().isEmpty) ? null : s.trim();
    if (id == null) {
      final newIdV = newId();
      final order = await db.get('SELECT COALESCE(MAX(sort_order),0)+1 AS o FROM items WHERE business_id = ?', [businessId]);
      await db.execute(
        'INSERT INTO items (id, business_id, name, name_en, category, subcategory, unit, short_code, sale_rate, purchase_rate, '
        'opening_qty, opening_rate, low_stock, sort_order, archived, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?)',
        [newIdV, businessId, name.trim(), n(nameEn), category, n(subcategory), unit, n(shortCode)?.toUpperCase(), saleRate, purchaseRate,
          openingQty, openingRate, lowStock, order['o'], nowIso()],
      );
      await _log(newIdV, 'create', null, await _snap(newIdV));
      return newIdV;
    }
    final before = await _snap(id);
    await db.execute(
      'UPDATE items SET name=?, name_en=?, category=?, unit=?, short_code=?, sale_rate=?, purchase_rate=?, '
      'opening_qty=?, opening_rate=?, low_stock=?${subcategory != null ? ', subcategory=?' : ''} WHERE id=?',
      [name.trim(), n(nameEn), category, unit, n(shortCode)?.toUpperCase(), saleRate, purchaseRate, openingQty,
        openingRate, lowStock, if (subcategory != null) n(subcategory), id],
    );
    await _log(id, 'edit', before, await _snap(id));
    return id;
  }

  /// Several items at once (stock tab, multi-select): only the given fields
  /// change; every item gets its own line in the change history.
  Future<void> bulkUpdate(List<String> ids, {String? category, String? subcategory, String? unit, bool? archived}) async {
    for (final id in ids) {
      final before = await _snap(id);
      final sets = <String>[], args = <Object?>[];
      void set(String col, Object? v) {
        sets.add('$col = ?');
        args.add(v);
      }

      if (category != null) set('category', category);
      if (subcategory != null) set('subcategory', subcategory.trim().isEmpty ? null : subcategory.trim());
      if (unit != null) set('unit', unit);
      if (archived != null) set('archived', archived ? 1 : 0);
      if (sets.isEmpty) return;
      await db.execute('UPDATE items SET ${sets.join(', ')} WHERE id = ?', [...args, id]);
      await _log(id, archived == true ? 'hide' : 'edit', before, await _snap(id));
    }
  }

  /// Subcategories already used (for suggestions), optionally within a category.
  /// Units in use (the standard ones plus any the shop made).
  Future<List<String>> units(List<String> standard) async => [
        ...standard,
        for (final r in await db.getAll(
            "SELECT DISTINCT unit FROM items WHERE business_id = ? AND unit IS NOT NULL AND unit <> '' ORDER BY unit", [businessId]))
          if (!standard.contains(r['unit'])) r['unit'] as String,
      ];

  Future<List<String>> subcategories({String? category}) async => [
        for (final r in await db.getAll(
            "SELECT DISTINCT subcategory FROM items WHERE business_id = ? AND COALESCE(subcategory, '') <> '' "
            "${category != null ? 'AND category = ? ' : ''}ORDER BY subcategory",
            [businessId, if (category != null) category]))
          r['subcategory'] as String
      ];

  Future<void> setArchived(String id, bool v) async {
    final before = await _snap(id);
    await db.execute('UPDATE items SET archived = ? WHERE id = ?', [v ? 1 : 0, id]);
    await _log(id, v ? 'hide' : 'unhide', before, await _snap(id));
  }

  // ---- बदल इतिहास for items
  Future<Map<String, Object?>> _snap(String id) async {
    final r = await db.getOptional('SELECT * FROM items WHERE id = ?', [id]);
    if (r == null) return {};
    String m(Object? p) => (p as int? ?? 0) == 0 ? '' : Money.fmt(p as int);
    String q(Object? x) => (x as num? ?? 0) == 0 ? '' : '$x';
    return {
      'name': r['name'],
      'name_en': r['name_en'],
      'category': r['category'],
      'subcategory': r['subcategory'],
      'unit': r['unit'],
      'short_code': r['short_code'],
      'sale_rate': m(r['sale_rate']),
      'purchase_rate': m(r['purchase_rate']),
      'opening_qty': q(r['opening_qty']),
      'opening_rate': m(r['opening_rate']),
      'low_stock': q(r['low_stock']),
      'hidden': (r['archived'] as int? ?? 0) == 1 ? '✓' : '',
    };
  }

  Future<void> _log(String id, String action, Map<String, Object?>? before, Map<String, Object?>? after) => AuditLog.write(db,
      businessId: businessId, recordId: id, action: action, kind: 'item', title: '${(after ?? before)?['name'] ?? ''}', before: before, after: after);

  Future<double> stockAt(String itemId, String date, {bool before = false}) async {
    final r = await db.get(
      'SELECT COALESCE(i.opening_qty,0) + COALESCE((SELECT SUM(qty * direction) FROM inventory_lines '
      'WHERE item_id = i.id AND deleted = 0 AND vdate ${before ? '<' : '<='} ?),0) AS q FROM items i WHERE i.id = ?',
      [date, itemId],
    );
    return (r['q'] as num).toDouble();
  }

  /// Item ledger (stock card) with running quantity.
  Future<List<StockMove>> movements(String itemId, {String? from, String? to}) async {
    final item = (await byId(itemId))!;
    double bal = from == null ? item.openingQty : await stockAt(itemId, from, before: true);
    final rows = await db.getAll(
      'SELECT v.id, v.vdate, v.vtype, v.vno, p.name AS party_name, p.page_no, il.qty, il.direction, il.rate '
      'FROM inventory_lines il JOIN vouchers v ON v.id = il.voucher_id LEFT JOIN ledgers p ON p.id = v.party_id '
      'WHERE il.item_id = ? AND il.deleted = 0 AND il.direction <> 0 ${from != null ? 'AND il.vdate >= ?' : ''} ${to != null ? 'AND il.vdate <= ?' : ''} '
      'ORDER BY il.vdate, v.created_at',
      [itemId, if (from != null) from, if (to != null) to],
    );
    return [
      for (final r in rows)
        () {
          final q = (r['qty'] as num).toDouble();
          final d = r['direction'] as int;
          bal += q * d;
          return StockMove(r['id'] as String, r['vdate'] as String, VoucherType.fromCode(r['vtype'] as String),
              (r['vno'] as int?) ?? 0, r['party_name'] as String?, r['page_no'] as String?, d > 0 ? q : 0,
              d < 0 ? q : 0, r['rate'] as int, bal);
        }()
    ];
  }

  /// The paper stock register for one day: opening per item, every bill, closing.
  Future<DailyRegister> dailyRegister(String date) async {
    final items = (await list()).where((i) => !i.isService).toList(); // services have no stock
    final opening = <String, double>{};
    final openRows = await db.getAll(
      'SELECT i.id, COALESCE(i.opening_qty,0) + COALESCE((SELECT SUM(qty * direction) FROM inventory_lines '
      'WHERE item_id = i.id AND deleted = 0 AND vdate < ?),0) AS q FROM items i WHERE i.business_id = ?',
      [date, businessId],
    );
    for (final r in openRows) {
      opening[r['id'] as String] = (r['q'] as num).toDouble();
    }
    final lines = await db.getAll(
      'SELECT v.id, v.vtype, v.amount, v.paid, v.created_at, v.haste, p.name AS party_name, p.name_en AS party_name_en, p.page_no, '
      'pl.short_code AS pay_code, pl.name AS pay_name, pl.name_en AS pay_name_en, '
      'il.item_id, il.qty, il.direction, il.rate FROM inventory_lines il JOIN vouchers v ON v.id = il.voucher_id '
      'LEFT JOIN ledgers p ON p.id = v.party_id LEFT JOIN ledgers pl ON pl.id = v.pay_ledger_id '
      'WHERE il.business_id = ? AND il.vdate = ? AND il.deleted = 0 AND il.direction <> 0 ORDER BY v.created_at',
      [businessId, date],
    );
    final byVoucher = <String, RegisterRow>{};
    var serial = 0;
    for (final r in lines) {
      final vid = r['id'] as String;
      final row = byVoucher.putIfAbsent(
        vid,
        () => RegisterRow(vid, ++serial, VoucherType.fromCode(r['vtype'] as String), r['party_name'] as String?,
            r['page_no'] as String?, r['pay_code'] as String?, r['amount'] as int, r['paid'] as int, {}, {},
            payName: r['pay_name'] as String?, payNameEn: r['pay_name_en'] as String?,
            partyNameEn: r['party_name_en'] as String?, haste: r['haste'] as String?),
      );
      final item = r['item_id'] as String;
      row.qty[item] = (row.qty[item] ?? 0) + (r['qty'] as num).toDouble() * (r['direction'] as int);
      row.rate[item] = r['rate'] as int;
    }
    return DailyRegister(date, items, opening, byVoucher.values.toList());
  }

  /// Net उसना माल per party and item (only non-zero), optionally for one party.
  Future<List<GoodsOwed>> goodsOwed({String? partyId}) async {
    final items = {for (final i in await list()) i.id: i};
    final rows = await db.getAll(
      'SELECT v.party_id, p.name AS party_name, p.page_no, il.item_id, SUM($_goodsSign) AS q '
      'FROM inventory_lines il JOIN vouchers v ON v.id = il.voucher_id LEFT JOIN ledgers p ON p.id = v.party_id '
      "WHERE il.business_id = ? AND il.deleted = 0 AND v.deleted = 0 AND v.vtype IN ('goods_out', 'goods_in') "
      '${partyId != null ? 'AND v.party_id = ? ' : ''}'
      'GROUP BY v.party_id, il.item_id HAVING ABS(SUM($_goodsSign)) > 0.0001 ORDER BY p.name',
      [businessId, if (partyId != null) partyId],
    );
    return [
      for (final r in rows)
        if (items[r['item_id']] case final it?)
          GoodsOwed(r['party_id'] as String, (r['party_name'] as String?) ?? '?', r['page_no'] as String?, it,
              (r['q'] as num).toDouble()),
    ];
  }

  /// Every उसना माल entry with one party, newest first: (voucher id, date, type, "W सिमेंट 30, …").
  Future<List<(String, String, VoucherType, String, bool)>> goodsMoves(String partyId) async {
    final rows = await db.getAll(
      "SELECT v.id, v.vdate, v.vtype, v.pay_ledger_id, GROUP_CONCAT(i.name || ' ' || il.qty, ', ') AS what FROM vouchers v "
      'JOIN inventory_lines il ON il.voucher_id = v.id AND il.deleted = 0 JOIN items i ON i.id = il.item_id '
      "WHERE v.party_id = ? AND v.deleted = 0 AND v.vtype IN ('goods_out', 'goods_in') "
      'GROUP BY v.id ORDER BY v.vdate DESC, v.created_at DESC',
      [partyId],
    );
    return [
      for (final r in rows)
        (
          r['id'] as String,
          r['vdate'] as String,
          VoucherType.fromCode(r['vtype'] as String),
          ((r['what'] as String?) ?? '').replaceAllMapped(RegExp(r'(\d+)\.0\b'), (m) => m[1]!),
          r['pay_ledger_id'] == goodsOpeningMarker,
        ),
    ];
  }

  /// Net bags out on loan for an item up to [date] (lent − borrowed); they are
  /// still ours, so they count in the stock value.
  Future<double> lentAt(String itemId, String date, {bool before = false}) async {
    final r = await db.get(
      'SELECT COALESCE(SUM($_goodsSign), 0) AS q FROM inventory_lines il JOIN vouchers v ON v.id = il.voucher_id '
      "WHERE il.item_id = ? AND il.deleted = 0 AND v.deleted = 0 AND v.vtype IN ('goods_out', 'goods_in') "
      // opening bags were out before the books began – counted on every date
      "AND (il.vdate ${before ? '<' : '<='} ? OR v.pay_ledger_id = '$goodsOpeningMarker')",
      [itemId, date],
    );
    return (r['q'] as num).toDouble();
  }

  /// Weighted-average purchase cost per unit (paise) up to [date].
  Future<Map<String, double>> averageCosts({String? date}) async {
    final rows = await db.getAll(
      'SELECT i.id, COALESCE(i.opening_qty,0) AS oq, COALESCE(i.opening_rate, i.purchase_rate, 0) AS orate, '
      "COALESCE((SELECT SUM(qty) FROM inventory_lines il JOIN vouchers v ON v.id = il.voucher_id WHERE il.item_id = i.id "
      "AND il.deleted = 0 AND v.vtype = 'purchase' ${date != null ? 'AND il.vdate <= ?' : ''}),0) AS pq, "
      "COALESCE((SELECT SUM(il.amount) FROM inventory_lines il JOIN vouchers v ON v.id = il.voucher_id WHERE il.item_id = i.id "
      "AND il.deleted = 0 AND v.vtype = 'purchase' ${date != null ? 'AND il.vdate <= ?' : ''}),0) AS pa, "
      'COALESCE(i.purchase_rate,0) AS prate FROM items i WHERE i.business_id = ?',
      [if (date != null) date, if (date != null) date, businessId],
    );
    final out = <String, double>{};
    for (final r in rows) {
      final oq = (r['oq'] as num).toDouble();
      final orate = (r['orate'] as num).toDouble();
      final pq = (r['pq'] as num).toDouble();
      final pa = (r['pa'] as num).toDouble();
      final qty = oq + pq;
      out[r['id'] as String] = qty > 0 ? (oq * orate + pa) / qty : (r['prate'] as num).toDouble();
    }
    return out;
  }
}
