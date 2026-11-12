import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../accounting/models.dart';
import '../accounting/voucher_service.dart';
import '../core/money.dart';
import '../state/app_controller.dart';
import 'voucher_screen.dart';

/// Demo build only: proves the edit screen changes nothing by itself.
///
/// Makes one entry of every kind (cash / credit / part paid / split, hamali,
/// outside transporter, GST, round off, वराई, सूट, returns, old entries,
/// उसना माल, stock correction, a hidden item, 3-decimal quantities …), then
/// opens each one in the real edit screen, saves it untouched, and compares
/// every balance, stock figure, entry row and posting before and after.
class EditSelfTest {
  static Future<Map<String, Object?>> snapshot(AppController app) async {
    final db = app.db, b = app.businessId;
    return {
      for (final r in await db.getAll(
          'SELECT l.id, l.name, l.opening_balance + COALESCE((SELECT SUM(debit - credit) FROM voucher_lines WHERE ledger_id = l.id AND deleted = 0), 0) AS bal '
          'FROM ledgers l WHERE l.business_id = ?',
          [b]))
        'balance of ${r['name']}': r['bal'],
      for (final r in await db.getAll(
          'SELECT i.name, COALESCE(i.opening_qty, 0) + COALESCE((SELECT SUM(qty * direction) FROM inventory_lines WHERE item_id = i.id AND deleted = 0), 0) AS s '
          'FROM items i WHERE i.business_id = ?',
          [b]))
        'stock of ${r['name']}': r['s'],
      for (final r in await db.getAll(
          'SELECT id, vtype, vno, vdate, party_id, amount, paid, hamali, transport, transporter_id, transporter_fare, gst_rate, gst, '
          // an unpaid bill opens as "on credit": its unused pay mode is not a figure
          "CASE WHEN paid = 0 AND party_id IS NOT NULL AND vtype IN ('sale','purchase','sales_return','purchase_return') THEN NULL ELSE pay_ledger_id END AS pay, "
          'narration, ref_no, haste, gst_bill_needed, status, deleted FROM vouchers WHERE business_id = ?',
          [b]))
        'entry ${r['vtype']} #${r['vno']} (${r['id']})': _entry(r),
      for (final r in await db.getAll(
          'SELECT vl.voucher_id, l.name, SUM(vl.debit) AS d, SUM(vl.credit) AS c FROM voucher_lines vl JOIN ledgers l ON l.id = vl.ledger_id '
          'WHERE vl.business_id = ? AND vl.deleted = 0 GROUP BY vl.voucher_id, vl.ledger_id',
          [b]))
        'posting ${r['voucher_id']} → ${r['name']}': '${r['d']} / ${r['c']}',
      for (final r in await db.getAll(
          'SELECT voucher_id, item_id, qty, rate, amount, direction FROM inventory_lines WHERE business_id = ? AND deleted = 0 ORDER BY id', [b]))
        'item line ${r['voucher_id']} ${r['item_id']} ${r['qty']}': r.values.join(' | '),
    };
  }

  /// The very first old entries had no kind marker (money received was kept
  /// in "paid"). Saving writes today's layout with the same meaning, so both
  /// layouts are read as one here.
  static String _entry(Map<String, Object?> r) {
    final m = Map<String, Object?>.from(r);
    if (m['vtype'] == 'history' && m['pay'] == null) {
      final received = m['amount'] == 0 && ((m['paid'] as int?) ?? 0) > 0;
      m['pay'] = '$historyKindPrefix${received ? 'received' : 'sale'}';
      if (received) {
        m['amount'] = m['paid'];
        m['paid'] = 0;
      }
    }
    // a bill with money paid and no mode stored was posted to cash
    if (m['pay'] == null && const {'sale', 'purchase', 'sales_return', 'purchase_return'}.contains(m['vtype']) && ((m['paid'] as int?) ?? 0) > 0) {
      m['pay'] = 'cash';
    } else if ('${m['pay']}'.endsWith(':cash')) {
      m['pay'] = 'cash';
    }
    return m.values.join(' | ');
  }

  /// One entry of every kind, made through the same service the screens use.
  static Future<void> seed(AppController app) async {
    final vs = app.vouchers, lr = app.ledgers, sr = app.stock, a = app.actor;
    final today = todayIso();
    final old = isoDate(parseIso(Books.start).subtract(const Duration(days: 5)));
    final cash = vs.sys('cash'), bank = vs.sys('bank');
    final upi = (await lr.list([LedgerGroup.upi])).first.id;
    final c = await lr.create(name: 'Selftest Customer', group: LedgerGroup.customer, openingBalance: 4350800);
    final s = await lr.create(name: 'Selftest Supplier', group: LedgerGroup.supplier, openingBalance: -2500000);
    final d = await lr.create(name: 'Selftest Driver', group: LedgerGroup.transporter);
    final items = (await sr.list()).where((i) => !i.isService).toList();
    final x = items[0].id, y = items[1].id;
    final svc = await sr.save(name: 'Selftest Service', category: serviceCategory, unit: 'job', saleRate: 50000);
    final hidden = await sr.save(name: 'Selftest Hidden Item', category: 'other', unit: 'nos', saleRate: 12000);
    VoucherInput sale({String? party, String? pay, int paid = 0, List<ItemLine>? lines, int hamali = 0, int transport = 0, String? driver, int? fare,
            int gst = 0, int round = 0, String? haste, String? note, String? ref, bool gstBill = false}) =>
        VoucherInput(type: VoucherType.sale, date: today, partyId: party, payLedgerId: pay, paid: paid, items: lines ?? [ItemLine(x, 10, 28500)],
            hamali: hamali, transport: transport, transporterId: driver, transporterFare: fare, gstRate: gst, roundOff: round, haste: haste,
            narration: note, refNo: ref, gstBillNeeded: gstBill);
    // sales: cash without a name, on credit, part paid, paid in full, pay mode chosen but nothing paid
    await vs.save(sale(pay: cash, paid: 285000), a);
    await vs.save(sale(party: c, note: 'credit bill', haste: 'Ramu', ref: 'MH12-1234', gstBill: true), a);
    await vs.save(sale(party: c, pay: cash, paid: 100000), a);
    await vs.save(sale(party: c, pay: upi, paid: 285000), a);
    await vs.save(sale(party: c, pay: cash, paid: 0), a);
    await vs.save(sale(party: c, paid: 40000), a); // paid, but no mode stored (old / imported data)
    // charges: hamali, own vehicle, outside driver at a lower fare, GST, round off, typed total, 3-decimal qty, service
    await vs.save(sale(party: c, hamali: 30000, transport: 50000), a);
    await vs.save(sale(party: c, hamali: 10000, transport: 80000, driver: d, fare: 70000), a);
    await vs.save(sale(party: c, gst: 1800, round: -700), a);
    await vs.save(sale(party: c, pay: cash, paid: 50000, round: 300, lines: [ItemLine(x, 12.345, 6175), ItemLine.fromTotal(y, 7, 199900), ItemLine(svc, 2, 50000)]), a);
    // a bill with an item that is hidden afterwards
    await vs.save(sale(party: c, lines: [ItemLine(hidden, 3, 12000), ItemLine(x, 1, 28500)]), a);
    await sr.setArchived(hidden, true);
    // split payments: a cash bill, a जमा and a payment
    final sp1 = await vs.save(sale(pay: cash, paid: 285000), a);
    await vs.saveSplit(sp1, a, ledgerId: upi, amount: 120000);
    final sp2 = await vs.save(VoucherInput(type: VoucherType.receipt, date: today, partyId: c, payLedgerId: cash, amount: 500000), a);
    await vs.saveSplit(sp2, a, ledgerId: upi, amount: 200000);
    final sp3 = await vs.save(VoucherInput(type: VoucherType.payment, date: today, partyId: s, payLedgerId: cash, amount: 400000), a);
    await vs.saveSplit(sp3, a, ledgerId: bank, amount: 150000);
    // purchases: credit with वराई, part paid with GST + round off, cash
    await vs.save(VoucherInput(type: VoucherType.purchase, date: today, partyId: s, items: [ItemLine(x, 100, 25000)], varhai: 84000), a);
    await vs.save(
        VoucherInput(type: VoucherType.purchase, date: today, partyId: s, payLedgerId: bank, paid: 1000000, items: [ItemLine(y, 50.5, 6000)], gstRate: 1800, roundOff: 200),
        a);
    await vs.save(VoucherInput(type: VoucherType.purchase, date: today, payLedgerId: cash, paid: 60000, items: [ItemLine(y, 10, 6000)]), a);
    // returns
    await vs.save(VoucherInput(type: VoucherType.salesReturn, date: today, partyId: c, items: [ItemLine(x, 2, 28500)]), a);
    await vs.save(VoucherInput(type: VoucherType.salesReturn, date: today, partyId: c, payLedgerId: cash, paid: 28500, items: [ItemLine(x, 1, 28500)]), a);
    await vs.save(VoucherInput(type: VoucherType.purchaseReturn, date: today, partyId: s, items: [ItemLine(x, 5, 25000)]), a);
    // जमा / पैसे दिले with सूट, expense, contra
    await vs.save(VoucherInput(type: VoucherType.receipt, date: today, partyId: c, payLedgerId: upi, amount: 4350000, discount: 800, haste: 'Son'), a);
    await vs.save(VoucherInput(type: VoucherType.payment, date: today, partyId: s, payLedgerId: bank, amount: 100000, discount: 500), a);
    await vs.save(VoucherInput(type: VoucherType.payment, date: today, partyId: vs.sys('freight'), payLedgerId: cash, amount: 30000, narration: 'tractor'), a);
    await vs.save(VoucherInput(type: VoucherType.payment, date: today, partyId: d, payLedgerId: cash, amount: 70000), a);
    await vs.save(VoucherInput(type: VoucherType.contra, date: today, partyId: bank, payLedgerId: cash, amount: 500000, narration: 'deposit'), a);
    // stock only: उसना माल, stock correction (+ and −)
    await vs.save(VoucherInput(type: VoucherType.goodsOut, date: today, partyId: c, items: [ItemLine(x, 30, 0)]), a);
    await vs.save(VoucherInput(type: VoucherType.goodsIn, date: today, partyId: c, items: [ItemLine(x, 10, 0)]), a);
    await vs.save(VoucherInput(type: VoucherType.stockAdjust, date: today, items: [ItemLine(x, -2, 0), ItemLine(y, 3.5, 0)], narration: 'count'), a);
    // old entries (reference only): bill with items + charges, amount-only bill, money in / out, old opening
    await vs.save(
        VoucherInput(type: VoucherType.history, date: old, partyId: c, payLedgerId: '${historyKindPrefix}sale', items: [ItemLine(x, 5, 27300)], hamali: 5000, paid: 50000),
        a);
    await vs.save(VoucherInput(type: VoucherType.history, date: old, partyId: c, payLedgerId: '${historyKindPrefix}sale', amount: 136500), a);
    await vs.save(VoucherInput(type: VoucherType.history, date: old, partyId: c, payLedgerId: '${historyKindPrefix}received', amount: 3000000), a);
    await vs.save(VoucherInput(type: VoucherType.history, date: old, partyId: s, payLedgerId: '${historyKindPrefix}paid', amount: 200000), a);
    await vs.save(VoucherInput(type: VoucherType.history, date: old, partyId: s, payLedgerId: '${historyKindPrefix}purchase', items: [ItemLine(y, 40, 6000)]), a);
    await vs.save(VoucherInput(type: VoucherType.history, date: old, partyId: c, payLedgerId: '${historyKindPrefix}opening', amount: 1500000), a);
  }

  /// Runs the check and returns what moved (empty = the edit screen is exact).
  static Future<(int, List<String>)> run(BuildContext context) async {
    final app = App.read(context);
    await seed(app);
    final rows = await app.db.getAll(
        "SELECT id, vtype FROM vouchers WHERE business_id = ? AND deleted = 0 AND COALESCE(status, '') NOT LIKE '$splitPrefix%' "
        "AND vtype NOT IN ('booking', 'recurring', 'recurring_pay', 'salary', 'interest', 'promise', 'journal', 'opening') ORDER BY vdate, created_at",
        [app.businessId]);
    final problems = <String>[];
    var n = 0;
    for (final r in rows) {
      final before = await snapshot(app);
      if (!context.mounted) break;
      final res = await Navigator.push<String>(
          context,
          MaterialPageRoute(
              builder: (_) => VoucherScreen(type: VoucherType.fromCode(r['vtype'] as String), editId: r['id'] as String, autoSave: true)));
      n++;
      if (res != null) {
        problems.add('${r['vtype']} ${r['id']}: $res');
        continue;
      }
      final after = await snapshot(app);
      for (final k in {...before.keys, ...after.keys}) {
        if ('${before[k]}' != '${after[k]}') {
          // only the fields that differ
          final x = '${before[k]}'.split(' | '), y = '${after[k]}'.split(' | ');
          final d = x.length == y.length && x.length > 1
              ? [for (var i = 0; i < x.length; i++) if (x[i] != y[i]) 'field $i: ${x[i]} → ${y[i]}'].join(', ')
              : '${before[k]} → ${after[k]}';
          problems.add('${r['vtype']}: $k  $d');
        }
      }
    }
    final deep = await app.vouchers.deepCheck();
    problems.addAll(deep.map((d) => 'deep check ${d.$1.type.code} #${d.$1.vno}: ${d.$2}'));
    debugPrint('SELFTEST ${problems.isEmpty ? 'OK' : 'FAIL'}: $n entries re-saved, ${problems.length} problems');
    for (final p in problems) {
      debugPrint('SELFTEST PROBLEM: $p');
    }
    return (n, problems);
  }
}
