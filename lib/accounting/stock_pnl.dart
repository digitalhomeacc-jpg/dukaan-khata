import 'dart:convert';

import 'package:sqlite_async/sqlite_async.dart';

import '../core/money.dart';
import 'ledger_repo.dart' show oldEntryEffect;
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
  final flags = <String>[]; // opening_rate_missing | old_balance_mismatch | no_cost | negative_stock

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
    Map<String, List<String>>? prevFlags;
    if (from.compareTo(Books.start) > 0) {
      final prev = await compute(_dayBefore(from));
      prevClose = {for (final i in prev.items) i.item.id: i.closeVal};
      prevFlags = {for (final i in prev.items) if (i.flags.isNotEmpty) i.item.id: [...i.flags]};
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

    // company discounts: the year's rate per supplier, applied to this period's purchases
    final fy = fyStart(to);
    final fyDisc = <String, int>{}, fyValue = <String, int>{};
    for (final r in await db.getAll(
        'SELECT v.party_id AS p, SUM(vl.credit - vl.debit) AS d FROM voucher_lines vl JOIN vouchers v ON v.id = vl.voucher_id '
        'WHERE vl.business_id = ? AND vl.ledger_id = ? AND vl.deleted = 0 AND v.deleted = 0 AND vl.vdate BETWEEN ? AND ? $_notScheme '
        'GROUP BY v.party_id',
        [b, '$b:discount_recd', fy, to])) {
      if (r['p'] != null) fyDisc[r['p'] as String] = (r['d'] as num).toInt();
    }
    for (final r in await db.getAll(
        "SELECT party_id AS p, SUM(amount) AS d FROM vouchers v WHERE business_id = ? AND vtype = 'history' AND deleted = 0 "
        "AND vdate BETWEEN ? AND ? AND (status LIKE 'stmt:discount%' OR (COALESCE(status, '') NOT LIKE 'stmt:%' "
        "AND pay_ledger_id = 'hist:paid' AND (narration LIKE '%discount%' OR narration LIKE '%सवलत%' OR narration LIKE '%scheme%'))) "
        '$_notScheme GROUP BY party_id',
        [b, fy, to])) {
      if (r['p'] != null) fyDisc[r['p'] as String] = (fyDisc[r['p'] as String] ?? 0) + (r['d'] as num).toInt();
    }
    for (final r in await db.getAll(
        "SELECT v.party_id AS p, SUM(CASE WHEN v.vtype = 'purchase_return' THEN -il.amount ELSE il.amount END) AS a "
        'FROM inventory_lines il JOIN vouchers v ON v.id = il.voucher_id WHERE il.business_id = ? AND il.deleted = 0 AND v.deleted = 0 '
        'AND il.vdate BETWEEN ? AND ? '
        "AND (v.vtype IN ('purchase', 'purchase_return') OR (v.vtype = 'history' AND v.pay_ledger_id = 'hist:purchase')) GROUP BY v.party_id",
        [b, fy, to])) {
      if (r['p'] != null) fyValue[r['p'] as String] = (r['a'] as num).toInt();
    }
    double rateOf(String? p) => p == null || (fyValue[p] ?? 0) <= 0 ? 0 : (fyDisc[p] ?? 0) / fyValue[p]!;

    final discByItem = <String, double>{};
    for (final r in await db.getAll(
        "SELECT il.item_id, v.party_id AS p, SUM(CASE WHEN v.vtype = 'purchase_return' THEN -il.amount ELSE il.amount END) AS a "
        'FROM inventory_lines il JOIN vouchers v ON v.id = il.voucher_id WHERE il.business_id = ? AND il.deleted = 0 AND v.deleted = 0 '
        "AND il.vdate BETWEEN ? AND ? AND v.vtype IN ('purchase', 'purchase_return') GROUP BY il.item_id, v.party_id",
        [b, from, to])) {
      final id = r['item_id'] as String;
      discByItem[id] = (discByItem[id] ?? 0) + (r['a'] as num).toInt() * rateOf(r['p'] as String?);
    }

    // 1. Check opening balance vs old entries per supplier (same check as OldMismatchScreen / parties_screen)
    final oldTotalByParty = <String, int>{};
    for (final r in await db.getAll(
        "SELECT party_id, amount, paid, pay_ledger_id FROM vouchers WHERE business_id = ? AND vtype = 'history' "
        'AND deleted = 0 AND party_id IS NOT NULL ORDER BY vdate',
        [b])) {
      final (_, d, c) = oldEntryEffect(r['pay_ledger_id'] as String?, (r['amount'] as int?) ?? 0, (r['paid'] as int?) ?? 0);
      final p = r['party_id'] as String;
      oldTotalByParty[p] = (oldTotalByParty[p] ?? 0) + (d - c);
    }
    final openBalByParty = <String, int>{}, curBalByParty = <String, int>{};
    for (final r in await db.getAll(
        'SELECT l.id, l.opening_balance, '
        '(l.opening_balance + COALESCE((SELECT SUM(vl.debit - vl.credit) FROM voucher_lines vl WHERE vl.ledger_id = l.id AND vl.deleted = 0), 0)) AS bal '
        'FROM ledgers l WHERE l.business_id = ?',
        [b])) {
      final id = r['id'] as String;
      openBalByParty[id] = (r['opening_balance'] as int?) ?? 0;
      curBalByParty[id] = (r['bal'] as num?)?.toInt() ?? 0;
    }

    // 2. Check latest uploaded supplier statement running balance & unmatched lines (from stmt_check:<partyId>)
    final stmtOkByParty = <String, bool>{};
    for (final r in await db.getAll(
        "SELECT voucher_id, snapshot FROM audit_log WHERE business_id = ? AND voucher_id LIKE 'stmt_check:%' ORDER BY at",
        [b])) {
      final id = (r['voucher_id'] as String).substring(11);
      try {
        final after = (jsonDecode(r['snapshot'] as String) as Map)['after'] as Map?;
        if (after != null) {
          final stmtBal = int.tryParse('${after['balance'] ?? ''}') ?? 0;
          final missing = int.tryParse('${after['missing'] ?? '0'}') ?? 0;
          final extra = int.tryParse('${after['extra'] ?? '0'}') ?? 0;
          final ourBal = curBalByParty[id] ?? 0;
          stmtOkByParty[id] = (stmtBal == -ourBal) && missing == 0 && extra == 0;
        }
      } catch (_) {}
    }

    bool partyFullyMatches(String? p) {
      if (p == null || !oldTotalByParty.containsKey(p)) return false;
      if (oldTotalByParty[p] != (openBalByParty[p] ?? 0)) return false;
      if (stmtOkByParty.containsKey(p) && stmtOkByParty[p] == false) return false;
      return true;
    }

    // Also track any supplier of this item (in-books or pre-books) whose uploaded statement running balance mismatches
    final itemSuppliers = <String, Set<String>>{};
    for (final r in await db.getAll(
        'SELECT DISTINCT il.item_id, v.party_id AS p FROM inventory_lines il JOIN vouchers v ON v.id = il.voucher_id '
        'WHERE il.business_id = ? AND il.deleted = 0 AND v.deleted = 0 AND v.party_id IS NOT NULL '
        "AND (v.vtype IN ('purchase', 'purchase_return') OR (v.vtype = 'history' AND v.pay_ledger_id = 'hist:purchase'))",
        [b])) {
      (itemSuppliers[r['item_id'] as String] ??= {}).add(r['p'] as String);
    }

    // Pre-books (history) purchases per item within the financial year, grouped by supplier
    final histPurByItem = <String, List<(String?, double, int)>>{};
    for (final r in await db.getAll(
        'SELECT il.item_id, v.party_id AS p, SUM(il.qty) AS q, SUM(il.amount) AS a '
        'FROM inventory_lines il JOIN vouchers v ON v.id = il.voucher_id '
        'WHERE il.business_id = ? AND il.deleted = 0 AND v.deleted = 0 '
        "AND v.vtype = 'history' AND v.pay_ledger_id = 'hist:purchase' AND il.vdate BETWEEN ? AND ? "
        'GROUP BY il.item_id, v.party_id',
        [b, fy, to])) {
      (histPurByItem[r['item_id'] as String] ??= [])
          .add((r['p'] as String?, (r['q'] as num).toDouble(), (r['a'] as num).toInt()));
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

      final histList = histPurByItem[it.id] ?? const [];
      final sups = itemSuppliers[it.id] ?? const <String>{};
      final hasHistMismatch = histList.any((h) => h.$1 != null && !partyFullyMatches(h.$1)) ||
          sups.any((s) => stmtOkByParty[s] == false);

      if (prevClose != null) {
        p.openVal = prevClose[it.id] ?? 0;
        if (hasHistMismatch && !p.flags.contains('old_balance_mismatch')) {
          p.flags.add('old_balance_mismatch');
        }
        for (final f in prevFlags?[it.id] ?? const <String>[]) {
          if ((f == 'opening_rate_missing' || f == 'old_balance_mismatch') && !p.flags.contains(f)) {
            p.flags.add(f);
          }
        }
      } else {
        var rate = it.openingRate.toDouble();
        if (p.openQty > 0) {
          if (hasHistMismatch) {
            // As soon as opening balance or uploaded statement running balance mismatches, revert to warning
            p.flags.add('old_balance_mismatch');
            if (rate <= 0) {
              p.flags.add('opening_rate_missing');
              rate = it.purchaseRate.toDouble();
            }
          } else if (rate <= 0) {
            // When both opening balance and running statement balance match, calculate net opening rate from this FY's old entries
            double hQty = 0, hNetVal = 0;
            for (final (supId, qh, ah) in histList) {
              if (partyFullyMatches(supId)) {
                hQty += qh;
                hNetVal += ah * (1.0 - rateOf(supId));
              }
            }
            if (hQty > 0.0001) {
              rate = hNetVal / hQty;
            } else {
              p.flags.add('opening_rate_missing');
              rate = it.purchaseRate.toDouble();
            }
          }
        } else if (hasHistMismatch) {
          p.flags.add('old_balance_mismatch');
        }
        p.openVal = (p.openQty * rate).round();
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