import 'package:dukaan_khata/accounting/voucher_service.dart';
import 'package:dukaan_khata/accounting/ledger_repo.dart';
import 'package:dukaan_khata/core/audit.dart';
import 'package:dukaan_khata/core/backup.dart';
import 'package:dukaan_khata/core/money.dart';
import 'package:dukaan_khata/core/seed.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_db.dart';

// The Nov 2026 bug: a phone that had not finished downloading re-created the
// built-in accounts blank, wiping the opening balances the owner had typed.
void main() {
  const biz = 'biz1';
  test('wiped built-in accounts are found from the history and put back', () async {
    AuditLog.actor = const Actor(userId: 'u1', name: 'Owner', isOwner: true);
    final db = await openTestDb(biz);
    final lr = LedgerRepo(db, biz);
    final cash = systemLedgerId(biz, 'cash'), upi = systemLedgerId(biz, 'upi_p'), bank = systemLedgerId(biz, 'bank');
    Future<int> opening(String id) async => (await db.get('SELECT opening_balance o FROM ledgers WHERE id = ?', [id]))['o'] as int;

    expect(await lr.resetDamage(), isEmpty, reason: 'a fresh shop has nothing to fix');
    await lr.update(cash, name: 'रोख गल्ला', nameEn: 'Cash', openingBalance: Money.fromRupees(45210.50));
    await lr.update(upi, name: 'फोनपे', openingBalance: -Money.fromRupees(1200));
    await lr.update(bank, name: 'बँक', openingBalance: Money.fromRupees(9000));
    await lr.update(bank, name: 'बँक', openingBalance: 0); // a real later edit to 0 is respected
    expect(await lr.resetDamage(), isEmpty);

    // the bug: rows replaced by blank copies without any history line
    for (final id in [cash, upi, bank]) {
      await db.execute('DELETE FROM ledgers WHERE id = ?', [id]);
    }
    await db.writeTransaction((tx) => ensureSystemLedgers(tx, biz));
    expect(await opening(cash), 0);

    final fixes = await lr.resetDamage();
    expect({for (final f in fixes) f.id}, {cash, upi, bank});
    // bank: only its name came back to default; the owner really set its opening to 0
    expect(fixes.firstWhere((f) => f.id == bank).changes.keys, isNot(contains('opening_balance')));
    final c = fixes.firstWhere((f) => f.id == cash);
    expect(c.changes['opening_balance'], ('', '45,210.50'));
    expect(c.changes['name']!.$2, 'रोख गल्ला');

    await lr.repair(fixes);
    expect(await opening(cash), Money.fromRupees(45210.50));
    expect(await opening(upi), -Money.fromRupees(1200));
    expect(await opening(bank), 0);
    expect((await db.get('SELECT name FROM ledgers WHERE id = ?', [cash]))['name'], 'रोख गल्ला');
    expect(await lr.resetDamage(), isEmpty, reason: 'fixed, and the repair is in the history');
    await db.close();
  });

  test('cloud start never re-creates an account the server already has', () async {
    final db = await openTestDb(biz);
    final cash = systemLedgerId(biz, 'cash');
    await db.execute('DELETE FROM ledgers WHERE id = ?', [cash]); // not downloaded yet
    await db.writeTransaction((tx) => ensureSystemLedgers(tx, biz, only: const {})); // server: all present
    expect(await db.getOptional('SELECT id FROM ledgers WHERE id = ?', [cash]), isNull);
    await db.writeTransaction((tx) => ensureSystemLedgers(tx, biz, only: {cash})); // server: genuinely missing
    expect(await db.getOptional('SELECT id FROM ledgers WHERE id = ?', [cash]), isNotNull);
    await db.close();
  });

  test('openings typed before the history existed come back from a backup file', () async {
    final db = await openTestDb(biz);
    final lr = LedgerRepo(db, biz);
    final cash = systemLedgerId(biz, 'cash'), upi = systemLedgerId(biz, 'upi_h');
    // typed with no history line (as before the history feature)
    await db.execute('UPDATE ledgers SET opening_balance = ? WHERE id = ?', [Money.fromRupees(81234.25), cash]);
    await db.execute('UPDATE ledgers SET opening_balance = ? WHERE id = ?', [-Money.fromRupees(500), upi]);
    final file = await Backup.export(db, biz);
    expect((await lr.compareWithBackup(file)).$2, isEmpty);

    for (final id in [cash, upi]) {
      await db.execute('DELETE FROM ledgers WHERE id = ?', [id]);
    }
    await db.writeTransaction((tx) => ensureSystemLedgers(tx, biz));
    expect(await lr.resetDamage(), isEmpty, reason: 'nothing in the history to go by');

    final (_, fixes) = await lr.compareWithBackup(file);
    expect({for (final f in fixes) f.id}, {cash, upi});
    await lr.repair(fixes);
    Future<int> opening(String id) async => (await db.get('SELECT opening_balance o FROM ledgers WHERE id = ?', [id]))['o'] as int;
    expect(await opening(cash), Money.fromRupees(81234.25));
    expect(await opening(upi), -Money.fromRupees(500));
    expect((await lr.compareWithBackup(file)).$2, isEmpty);
    await expectLater(lr.compareWithBackup(await Backup.export(db, 'other')), throwsFormatException);
    await db.close();
  });
}
