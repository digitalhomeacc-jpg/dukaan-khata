import 'package:sqlite_async/sqlite_async.dart';

import '../core/audit.dart';
import '../core/money.dart';
import 'ledger_repo.dart';

/// नवीन सुरुवात – keep only the balances.
///
/// Every entry (sales, receipts, purchases, stock, old entries …) is deleted
/// and each account starts again from today with exactly the balance it has
/// now as its opening balance. Done a few hundred entries at a time: in each
/// step the money those entries moved is added to the accounts' opening
/// balances and the entries are removed, in one transaction that is checked
/// before it is saved – so every balance stays the same to the paise at every
/// moment, even if the phone stops half way (running it again finishes).
class FreshStart {
  FreshStart(this.db, this.businessId);
  final SqliteConnection db;
  final String businessId;

  static const chunk = 100; // ≈ 500 changes per upload: well inside the server time limit

  Future<int> entryCount() async =>
      ((await db.get('SELECT COUNT(*) AS n FROM vouchers WHERE business_id = ?', [businessId]))['n'] as num).toInt();

  /// Every account's balance (opening + all its live lines), by id.
  Future<Map<String, int>> balances(SqliteReadContext c) async => {
        for (final r in await c.getAll(
            'SELECT l.id, l.opening_balance + COALESCE((SELECT SUM(debit - credit) FROM voucher_lines vl '
            'WHERE vl.ledger_id = l.id AND vl.deleted = 0), 0) AS b FROM ledgers l WHERE l.business_id = ?',
            [businessId]))
          r['id'] as String: (r['b'] as num).toInt()
      };

  /// Runs it. [onProgress] (done, total). Throws if any balance would change.
  Future<void> run(String today, {void Function(int, int)? onProgress, int chunk = chunk}) async {
    final b = businessId;
    final start = await balances(db);
    final snapsBefore = {
      for (final r in await db.getAll('SELECT * FROM ledgers WHERE business_id = ?', [b])) r['id'] as String: LedgerRepo.snapRow(r)
    };
    final ids = [for (final r in await db.getAll('SELECT id FROM vouchers WHERE business_id = ? ORDER BY vdate, id', [b])) r['id'] as String];
    var done = 0;
    onProgress?.call(0, ids.length);

    Future<void> moveIntoOpening(SqliteWriteContext tx, String where, List<Object?> args) async {
      // the money these lines moved, per account, goes into its opening balance
      for (final r in await tx.getAll(
          'SELECT ledger_id, SUM(debit - credit) AS n FROM voucher_lines WHERE deleted = 0 AND $where GROUP BY ledger_id', args)) {
        final n = (r['n'] as num).toInt();
        if (n != 0) await tx.execute('UPDATE ledgers SET opening_balance = opening_balance + ? WHERE id = ?', [n, r['ledger_id']]);
      }
    }

    Future<void> checked(Future<void> Function(SqliteWriteContext tx) step) => db.writeTransaction((tx) async {
          final before = await balances(tx);
          await step(tx);
          final after = await balances(tx);
          for (final e in before.entries) {
            if (after[e.key] != e.value) throw StateError('err_fresh_balance');
          }
        });

    for (var i = 0; i < ids.length; i += chunk) {
      final part = ids.sublist(i, i + chunk > ids.length ? ids.length : i + chunk);
      final ph = List.filled(part.length, '?').join(',');
      await checked((tx) async {
        await moveIntoOpening(tx, 'voucher_id IN ($ph)', part);
        await tx.execute('DELETE FROM voucher_lines WHERE voucher_id IN ($ph)', part);
        await tx.execute('DELETE FROM inventory_lines WHERE voucher_id IN ($ph)', part);
        await tx.execute('DELETE FROM vouchers WHERE id IN ($ph)', part);
      });
      done += part.length;
      onProgress?.call(done, ids.length);
    }

    // anything left over (lines without an entry, bank statement lines), the
    // new start date, and one history line per account whose opening changed
    await checked((tx) async {
      await moveIntoOpening(tx, 'business_id = ?', [b]);
      await tx.execute('DELETE FROM voucher_lines WHERE business_id = ?', [b]);
      await tx.execute('DELETE FROM inventory_lines WHERE business_id = ?', [b]);
      await tx.execute('DELETE FROM bank_lines WHERE business_id = ?', [b]);
      await tx.execute('UPDATE businesses SET books_start = ? WHERE id = ?', [today, b]);
      for (final r in await tx.getAll('SELECT * FROM ledgers WHERE business_id = ?', [b])) {
        final id = r['id'] as String;
        final now = LedgerRepo.snapRow(r);
        final was = snapsBefore[id];
        if (was == null || was['opening_balance'] == now['opening_balance']) continue;
        await AuditLog.write(tx,
            businessId: b, recordId: id, action: 'edit', kind: 'ledger', title: '${r['name'] ?? ''}', before: was, after: now);
      }
      await AuditLog.write(tx,
          businessId: b,
          recordId: b,
          action: 'edit',
          kind: 'fresh_start',
          title: today,
          after: {'entries_removed': '${ids.length}', 'books_start': today});
    });

    // the final word: every balance exactly as it was
    final end = await balances(db);
    for (final e in start.entries) {
      if (end[e.key] != e.value) throw StateError('err_fresh_balance');
    }
    Books.start = today;
  }
}
