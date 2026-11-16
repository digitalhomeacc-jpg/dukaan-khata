import 'package:sqlite_async/sqlite_async.dart';

import '../core/money.dart';
import 'models.dart';

/// मालाप्रमाणे नफा - profit per item and per category, to the paise.
///
/// The rules (one financial year at a time, from the day the books start):
/// * Cost of an item = weighted average of what the goods really cost:
///   opening stock (opening rate) + purchases - purchase returns - the
///   company's discounts for those purchases.
/// * A company's discounts are spread over its purchases by value at the
///   year's rate: all of the financial year's discounts ÷ all of the year's
///   purchases from it (old statement lines before the books included).
///   Coins / GMC / gift schemes are kept out (valued separately later).
/// * Cost of goods used = opening value + purchases (net) - closing value.
///   Closing stock is valued at the same average, so goods still lying in
///   the shop carry their share of the discount - only sold goods'
///   discount becomes profit this year.
/// * Bags lent out (उधारी) are still ours and count in closing stock; bags
///   borrowed are not. Stock corrections (damage, shortage) simply leave
///   less in closing stock, so their cost lands in "cost of goods used".
/// * Every rupee is accounted for: the item figures are checked against
///   the account books (sales, purchase, discount accounts) and the net
///   profit is worked out a second, independent way from the accounts.
class ItemPnl {
  ItemPnl(this.item);
  final Item item;
  double openQty = 0, purQty = 0, saleQty = 0, adjQty = 0, closeQty = 0;
  int openVal = 0, purVal = 0, sales = 0;
  double disc = 0; // company discounts on this item's purchases (paise, unrounded)
  int discR = 0, closeVal = 0, cost = 0;
  double avg = 0; // net cost per unit (paise)
  final flags = <String>[]; // opening_rate_missing | no_cost | negative_stock
  /// Opening stock had no opening rate and was valued from the last old
  /// (statement) purchases at their real cost – complete, just worth knowing.
  bool openFromOld = false;

  int get netPur => purVal - discR;
  int get profit => sales - cost;
}

class StockPnl {
  StockPnl(this.from, this.to);
  final String from, to;
  final items = <ItemPnl>[];

  // the account books for the same period (paise; income positive)
  int salesAcct = 0, purchaseAcct = 0; // net of returns
  int discRecd = 0, discToGoods = 0, discSchemes = 0;
  int get discOther => discRecd - discToGoods - discSchemes; // e.g. the share for goods bought before the books
  final otherIncome = <(String, int)>[];
  final expenses = <(String, int)>[];

  int get openTotal => items.fold(0, (s, i) => s + i.openVal);
  int get closeTotal => items.fold(0, (s, i) => s + i.closeVal);
  int get itemSales => items.fold(0, (s, i) => s + i.sales);
  int get itemPurchases => items.fold(0, (s, i) => s + i.purVal);
  int get itemCost => items.fold(0, (s, i) => s + i.cost);
  int get goodsProfit => items.fold(0, (s, i) => s + i.profit);

  /// Bill amounts that are in the sales / purchase account but not on any
  /// item line (should be 0; anything else is shown, never hidden).
  int get salesGap => salesAcct - itemSales;
  int get purchaseGap => purchaseAcct - itemPurchases;

  int get netProfit =>
      goodsProfit +
      salesGap -
      purchaseGap +
      discOther +
      discSchemes +
      otherIncome.fold<int>(0, (s, e) => s + e.$2) -
      expenses.fold<int>(0, (s, e) => s + e.$2);

  /// The same profit straight from the accounts: closing - opening stock -
  /// Σ (debit - credit) of every sales / purchase / income / expense account.
  int accountsProfit = 0;
  bool get proven => accountsProfit == netProfit;
}

class StockPnlEngine {
  StockPnlEngine(this.db, this.businessId);
  final SqliteConnection db;
  final String businessId;

  static const _notScheme = "AND COALESCE(v.narration, '') NOT LIKE '%coin%' AND COALESCE(v.narration, '') NOT LIKE '%GMC%' "
      "AND COALESCE(v.narration, '') NOT LIKE '%gift%'";

  String _dayBefore(String d) => isoDate(parseIso(d).subtract(const Duration(days: 1)));
  String _later(String a, String b) => a.compareTo(b) >= 0 ? a : b;

  /// The year's figures up to [to] (from the financial year's start, or the
  /// books' start if later).
  Future<StockPnl> compute(String to) async {
    final from = _later(fyStart(to), Books.start);
    // opening values: the books' opening rates, or last year's closing
    Map<String, int>? prevClose;
    if (from.compareTo(Books.start) > 0) {
      final prev = await compute(_dayBefore(from));
      prevClose = {for (final i in prev.items) i.item.id: i.closeVal};
    }
    final out = StockPnl(from, to);
    final b = businessId;

    final items = [
      for (final r in await db.getAll('SELECT * FROM items WHERE business_id = ? ORDER BY sort_order, name', [b]))
        Item.fromRow(r)
    ].where((i) => i.category != serviceCategory).toList();

    // quantity owned at a moment: in the shop + lent out - borrowed
    Future<Map<String, double>> owned(String date, {required bool before}) async {
      final op = before ? '<' : '<=';
      final m = <String, double>{};
      for (final r in await db.getAll(
          'SELECT il.item_id, SUM(il.qty * il.direction) AS q FROM inventory_lines il JOIN vouchers v ON v.id = il.voucher_id '
          'WHERE il.business_id = ? AND il.deleted = 0 AND v.deleted = 0 AND il.vdate $op ? GROUP BY il.item_id',
          [b, date])) {
        m[r['item_id'] as String] = (r['q'] as num).toDouble();
      }
      for (final r in await db.getAll(
          "SELECT il.item_id, SUM(CASE v.vtype WHEN 'goods_out' THEN il.qty ELSE -il.qty END) AS q FROM inventory_lines il "
          'JOIN vouchers v ON v.id = il.voucher_id WHERE il.business_id = ? AND il.deleted = 0 AND v.deleted = 0 '
          "AND v.vtype IN ('goods_out', 'goods_in') AND (il.vdate $op ? OR v.pay_ledger_id = 'opening') GROUP BY il.item_id",
          [b, date])) {
        m[r['item_id'] as String] = (m[r['item_id'] as String] ?? 0) + (r['q'] as num).toDouble();
      }
      return m;
    }

    final openMoves = await owned(from, before: true);
    final closeMoves = await owned(to, before: false);

    // the period's movements per item and kind
    final mv = <String, Map<String, (double, int)>>{};
    for (final r in await db.getAll(
        'SELECT il.item_id, v.vtype, SUM(il.qty) AS q, SUM(il.amount) AS a FROM inventory_lines il JOIN vouchers v ON v.id = il.voucher_id '
        'WHERE il.business_id = ? AND il.deleted = 0 AND v.deleted = 0 AND il.vdate BETWEEN ? AND ? '
        "AND v.vtype IN ('purchase', 'purchase_return', 'sale', 'sales_return', 'stock_adjust') GROUP BY il.item_id, v.vtype",
        [b, from, to])) {
      (mv[r['item_id'] as String] ??= {})[r['vtype'] as String] =
          ((r['q'] as num).toDouble(), (r['a'] as num).toInt());
    }

    // stock corrections keep their sign in the direction column
    final adj = <String, double>{};
    for (final r in await db.getAll(
        'SELECT il.item_id, SUM(il.qty * il.direction) AS q FROM inventory_lines il JOIN vouchers v ON v.id = il.voucher_id '
        "WHERE il.business_id = ? AND il.deleted = 0 AND v.deleted = 0 AND v.vtype = 'stock_adjust' AND il.vdate BETWEEN ? AND ? "
        'GROUP BY il.item_id',
        [b, from, to])) {
      adj[r['item_id'] as String] = (r['q'] as num).toDouble();
    }

    // company discounts: the year's rate per supplier (the same rule as the
    // Real cost report): all of that financial year's discounts ÷ all of that
    // year's purchases from it, old statement lines included
    final ratesByFy = <String, Map<String, double>>{};
    Future<Map<String, double>> fyRates(String fyFrom) async {
      if (ratesByFy[fyFrom] case final r?) return r;
      final y = int.parse(fyFrom.substring(0, 4)), mo = int.parse(fyFrom.substring(5, 7));
      final fyEnd = isoDate(DateTime(y + 1, mo, 1).subtract(const Duration(days: 1)));
      final upto = to.compareTo(fyEnd) < 0 ? to : fyEnd;
      final disc = <String, int>{}, value = <String, int>{};
      for (final r in await db.getAll(
          'SELECT v.party_id AS p, SUM(vl.credit - vl.debit) AS d FROM voucher_lines vl JOIN vouchers v ON v.id = vl.voucher_id '
          'WHERE vl.business_id = ? AND vl.ledger_id = ? AND vl.deleted = 0 AND v.deleted = 0 AND vl.vdate BETWEEN ? AND ? $_notScheme '
          'GROUP BY v.party_id',
          [b, '$b:discount_recd', fyFrom, upto])) {
        if (r['p'] != null) disc[r['p'] as String] = (r['d'] as num).toInt();
      }
      for (final r in await db.getAll(
          "SELECT party_id AS p, SUM(amount) AS d FROM vouchers v WHERE business_id = ? AND vtype = 'history' AND deleted = 0 "
          "AND vdate BETWEEN ? AND ? AND (status LIKE 'stmt:discount%' OR (COALESCE(status, '') NOT LIKE 'stmt:%' "
          "AND pay_ledger_id = 'hist:paid' AND (narration LIKE '%discount%' OR narration LIKE '%सूट%' OR narration LIKE '%सवलत%' "
          "OR narration LIKE '%scheme%'))) $_notScheme GROUP BY party_id",
          [b, fyFrom, upto])) {
        if (r['p'] != null) disc[r['p'] as String] = (disc[r['p'] as String] ?? 0) + (r['d'] as num).toInt();
      }
      for (final r in await db.getAll(
          "SELECT v.party_id AS p, SUM(CASE WHEN v.vtype = 'purchase_return' THEN -il.amount ELSE il.amount END) AS a "
          'FROM inventory_lines il JOIN vouchers v ON v.id = il.voucher_id WHERE il.business_id = ? AND il.deleted = 0 AND v.deleted = 0 '
          'AND il.vdate BETWEEN ? AND ? '
          "AND (v.vtype IN ('purchase', 'purchase_return') OR (v.vtype = 'history' AND v.pay_ledger_id = 'hist:purchase')) GROUP BY v.party_id",
          [b, fyFrom, upto])) {
        if (r['p'] != null) value[r['p'] as String] = (r['a'] as num).toInt();
      }
      return ratesByFy[fyFrom] = {
        for (final e in value.entries)
          if (e.value > 0) e.key: (disc[e.key] ?? 0) / e.value
      };
    }

    final rates = await fyRates(fyStart(to));
    double rateOf(String? p) => p == null ? 0 : rates[p] ?? 0;

    final discByItem = <String, double>{};
    for (final r in await db.getAll(
        "SELECT il.item_id, v.party_id AS p, SUM(CASE WHEN v.vtype = 'purchase_return' THEN -il.amount ELSE il.amount END) AS a "
        'FROM inventory_lines il JOIN vouchers v ON v.id = il.voucher_id WHERE il.business_id = ? AND il.deleted = 0 AND v.deleted = 0 '
        "AND il.vdate BETWEEN ? AND ? AND v.vtype IN ('purchase', 'purchase_return') GROUP BY il.item_id, v.party_id",
        [b, from, to])) {
      final id = r['item_id'] as String;
      discByItem[id] = (discByItem[id] ?? 0) + (r['a'] as num).toInt() * rateOf(r['p'] as String?);
    }

    // old (statement) purchases before the books, newest first – used only to
    // value opening stock that has no opening rate
    final oldBuys = <String, List<(String, String?, double, int)>>{}; // item → date, supplier, qty, amount
    if (prevClose == null) {
      for (final r in await db.getAll(
          'SELECT il.item_id, il.vdate, v.party_id AS p, il.qty AS q, il.amount AS a FROM inventory_lines il '
          'JOIN vouchers v ON v.id = il.voucher_id WHERE il.business_id = ? AND il.deleted = 0 AND v.deleted = 0 '
          "AND v.vtype = 'history' AND v.pay_ledger_id = 'hist:purchase' AND il.vdate < ? AND il.qty > 0 "
          'ORDER BY il.vdate DESC, v.created_at DESC, il.id DESC',
          [b, Books.start])) {
        (oldBuys[r['item_id'] as String] ??= [])
            .add((r['vdate'] as String, r['p'] as String?, (r['q'] as num).toDouble(), (r['a'] as num).toInt()));
      }
    }

    for (final it in items) {
      final p = ItemPnl(it);
      final m = mv[it.id] ?? const {};
      double q(String k) => m[k]?.$1 ?? 0;
      int a(String k) => m[k]?.$2 ?? 0;
      p.openQty = it.openingQty + (openMoves[it.id] ?? 0);
      p.closeQty = it.openingQty + (closeMoves[it.id] ?? 0);
      p.purQty = q('purchase') - q('purchase_return');
      p.purVal = a('purchase') - a('purchase_return');
      p.saleQty = q('sale') - q('sales_return');
      p.sales = a('sale') - a('sales_return');
      p.adjQty = adj[it.id] ?? 0;
      p.disc = discByItem[it.id] ?? 0;
      p.discR = p.disc.round();
      if (prevClose != null) {
        p.openVal = prevClose[it.id] ?? 0;
      } else if (it.openingRate > 0 || p.openQty <= 0) {
        p.openVal = (p.openQty * it.openingRate).round(); // the rate typed in always wins
      } else {
        // no opening rate: the bags in the shop on the first day are the last
        // ones bought – value them from the newest old purchases, each at its
        // year's real cost (bill − that year's discount)
        var need = p.openQty, val = 0.0;
        for (final (date, sup, bq, ba) in oldBuys[it.id] ?? const <(String, String?, double, int)>[]) {
          if (need <= 0.0001) break;
          final take = need < bq ? need : bq;
          final r = (await fyRates(fyStart(date)))[sup] ?? 0;
          val += take * (ba / bq) * (1 - r);
          need -= take;
        }
        if (need > 0.0001) {
          // old purchases do not cover it: the rest at the purchase rate – flagged
          p.flags.add('opening_rate_missing');
          val += need * it.purchaseRate;
        } else {
          p.openFromOld = true;
        }
        p.openVal = val.round();
      }
      final qty = p.openQty + p.purQty;
      final val = p.openVal + p.netPur;
      if (qty > 0.0001) {
        p.avg = val / qty;
      } else {
        p.avg = (it.openingRate > 0 ? it.openingRate : it.purchaseRate).toDouble();
        if (p.saleQty > 0 || p.closeQty > 0) p.flags.add('no_cost');
      }

      if (p.closeQty < -0.0001) p.flags.add('negative_stock');
      p.closeVal = (p.closeQty * p.avg).round();
      // what the goods that left cost - exact to the paise by construction
      p.cost = p.openVal + p.netPur - p.closeVal;

      if (p.openQty != 0 || p.purQty != 0 || p.saleQty != 0 || p.closeQty != 0 || p.adjQty != 0) out.items.add(p);
    }

    // the account books for the same days
    final acct = <String, (String, String, int)>{}; // id → name, group, debit - credit
    for (final r in await db.getAll(
        'SELECT l.id, l.name, l.grp, COALESCE(SUM(vl.debit - vl.credit), 0) AS m FROM ledgers l '
        'JOIN voucher_lines vl ON vl.ledger_id = l.id AND vl.deleted = 0 AND vl.vdate BETWEEN ? AND ? '
        'WHERE l.business_id = ? AND l.grp IN (\'sales\', \'sales_return\', \'purchase\', \'purchase_return\', \'income\', \'expense\', \'direct_expense\') '
        'GROUP BY l.id',
        [from, to, b])) {
      acct[r['id'] as String] = (r['name'] as String, r['grp'] as String, (r['m'] as num).toInt());
    }
    int g(String grp) => acct.values.where((e) => e.$2 == grp).fold(0, (s, e) => s + e.$3);
    out.salesAcct = -(g('sales') + g('sales_return'));
    out.purchaseAcct = g('purchase') + g('purchase_return');
    out.discRecd = -(acct['$b:discount_recd']?.$3 ?? 0);
    out.discToGoods = out.items.fold(0, (s, i) => s + i.discR);
    out.discSchemes = ((await db.get(
            'SELECT COALESCE(SUM(vl.credit - vl.debit), 0) AS d FROM voucher_lines vl JOIN vouchers v ON v.id = vl.voucher_id '
            'WHERE vl.business_id = ? AND vl.ledger_id = ? AND vl.deleted = 0 AND v.deleted = 0 AND vl.vdate BETWEEN ? AND ? '
            "AND (COALESCE(v.narration, '') LIKE '%coin%' OR COALESCE(v.narration, '') LIKE '%GMC%' OR COALESCE(v.narration, '') LIKE '%gift%')",
            [b, '$b:discount_recd', from, to]))['d'] as num)
        .toInt();
    for (final e in acct.entries) {
      if (e.key == '$b:discount_recd') continue;
      final (name, grp, m) = e.value;
      if (m == 0) continue;
      if (grp == 'income') out.otherIncome.add((name, -m));
      if (grp == 'expense' || grp == 'direct_expense') out.expenses.add((name, m));
    }
    out.otherIncome.sort((x, y) => y.$2.compareTo(x.$2));
    out.expenses.sort((x, y) => y.$2.compareTo(x.$2));
    // independent check: straight from the accounts and the stock values
    out.accountsProfit = out.closeTotal - out.openTotal - acct.values.fold<int>(0, (s, e) => s + e.$3);
    return out;
  }
}