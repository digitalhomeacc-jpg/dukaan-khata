import 'package:dukaan_khata/accounting/fresh_start.dart';
import 'package:dukaan_khata/accounting/health.dart';
import 'package:dukaan_khata/accounting/ledger_repo.dart';
import 'package:dukaan_khata/accounting/models.dart';
import 'package:dukaan_khata/accounting/voucher_service.dart';
import 'package:dukaan_khata/core/audit.dart';
import 'package:dukaan_khata/core/demo.dart';
import 'package:dukaan_khata/core/money.dart';
import 'package:dukaan_khata/inventory/stock_repo.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_db.dart';

void main() {
  test('fresh start: every entry gone, every balance exactly the same, books start today', () async {
    final keep = Books.start;
    Books.start = isoDate(DateTime.now().subtract(const Duration(days: 70)));
    AuditLog.actor = const Actor(userId: 'u', name: 'Owner', isOwner: true);
    try {
      final db = await openTestDb('demo');
      final vs = VoucherService(db, 'demo'), lr = LedgerRepo(db, 'demo'), sr = StockRepo(db, 'demo');
      await loadDemoData(vs, lr, sr);
      final fs = FreshStart(db, 'demo');
      final before = await fs.balances(db);
      final n = await fs.entryCount();
      expect(n, greaterThan(20), reason: 'enough entries for several steps of 7');
      expect(before.values.any((b) => b != 0), isTrue);

      final progress = <int>[];
      await fs.run(todayIso(), onProgress: (d, t) => progress.add(d), chunk: 7);
      expect(progress.length, greaterThan(3));
      expect(progress.last, n);
      expect(await fs.entryCount(), 0);
      expect((await db.get('SELECT COUNT(*) AS n FROM voucher_lines'))['n'], 0);
      expect((await db.get('SELECT COUNT(*) AS n FROM inventory_lines'))['n'], 0);
      final after = await fs.balances(db);
      for (final e in before.entries) {
        expect(after[e.key], e.value, reason: 'balance of ${e.key}');
      }
      // a customer's khata now opens today with that balance
      final cust = before.entries.firstWhere((e) => e.value > 0 && e.key.length > 20).key;
      final st = await lr.statement(cust);
      expect(st.rows, isEmpty);
      expect(st.closing, before[cust]);
      expect(Books.start, todayIso());
      // the books check finds nothing wrong afterwards
      final health = await HealthCheck(db, 'demo', vs, lr, sr).run();
      expect(health.map((i) => '${i.kind} ${i.title}: ${i.detail}'), isEmpty);
      // and new entries work as usual
      await vs.save(VoucherInput(type: VoucherType.receipt, date: todayIso(), partyId: cust, payLedgerId: vs.sys('cash'), amount: 100), AuditLog.actor);
      expect(await lr.balanceAt(cust), before[cust]! - 100);
      await db.close();
    } finally {
      Books.start = keep;
    }
  });

  test('khata mode: an udhaar sale is just an amount – khata up, sales up, no cash, no stock', () async {
    Books.start = isoDate(DateTime.now().subtract(const Duration(days: 70)));
    AuditLog.actor = const Actor(userId: 'u', name: 'Owner', isOwner: true);
    final db = await openTestDb('demo');
    final vs = VoucherService(db, 'demo'), lr = LedgerRepo(db, 'demo'), sr = StockRepo(db, 'demo');
    await loadDemoData(vs, lr, sr);
    final cust = (await lr.list([LedgerGroup.customer])).first.id;
    final cash = vs.sys('cash');
    final b0 = await lr.balanceAt(cust), c0 = await lr.balanceAt(cash);
    final stock0 = (await db.get('SELECT COUNT(*) AS n FROM inventory_lines'))['n'];
    // exactly what the खाता मोड form sends
    await vs.save(
        VoucherInput(type: VoucherType.sale, date: todayIso(), partyId: cust, payLedgerId: null, amount: 250000, paid: 0, narration: 'सिमेंट 10'),
        AuditLog.actor);
    expect(await lr.balanceAt(cust), b0 + 250000);
    expect(await lr.balanceAt(cash), c0);
    expect((await db.get('SELECT COUNT(*) AS n FROM inventory_lines'))['n'], stock0);
    // the lines balance: what the customer owes = what was sold
    final v = await db.get("SELECT id FROM vouchers WHERE narration = 'सिमेंट 10'");
    final s = await db.get('SELECT SUM(debit) AS d, SUM(credit) AS c FROM voucher_lines WHERE voucher_id = ? AND deleted = 0', [v['id']]);
    expect(s['d'], s['c']);
    expect(s['d'], 250000);
    await db.close();
  });
}
