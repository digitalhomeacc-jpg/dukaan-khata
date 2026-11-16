import 'package:expense_tracker/logic/duplicates.dart';
import 'package:expense_tracker/models.dart';
import 'package:flutter_test/flutter_test.dart';

Txn t(String id, double amount, DateTime at, {String source = 'manual', String? account, String? details}) => Txn(
  id: id,
  amount: amount,
  isDebit: true,
  txnAt: at,
  merchant: id,
  source: source,
  accountId: account,
  details: details,
);

void main() {
  final d = DateTime(2026, 11, 10, 13);
  test('same reference first; typed by hand next to the bank email; never two real payments', () {
    final txns = [
      t('email', 500, d, source: 'email', account: 'h', details: 'UPI 610000000001'),
      t('stmt', 500, DateTime(2026, 11, 11, 6), source: 'statement', account: 'h', details: 'UPI-X-610000000001-UPI'),
      t('hand', 300, d, account: 'h'),
      t('mail300', 300, d.add(const Duration(hours: 1)), source: 'email', account: 'h'),
      // Two different references: two real payments.
      t('r1', 200, d, source: 'email', account: 'h', details: 'ref 610000000005'),
      t('r2', 200, d, source: 'statement', account: 'h', details: 'ref 610000000006'),
      // Different accounts: not the same.
      t('x1', 90, d, account: 'h'),
      t('x2', 90, d, account: 'slice'),
      // Two bank emails hours apart: two chais.
      t('c1', 20, d, source: 'email', account: 'h'),
      t('c2', 20, d.add(const Duration(hours: 3)), source: 'email', account: 'h'),
      // Far apart in time.
      t('f1', 70, d, account: 'h'),
      t('f2', 70, d.add(const Duration(days: 5)), account: 'h'),
    ];
    final pairs = suspectedDuplicates(txns);
    expect(pairs.map((p) => (p.a.id, p.b.id, p.sameRef)), [('email', 'stmt', true), ('hand', 'mail300', false)]);
    expect(suspectedDuplicates(txns, notDuplicates: {pairKey('mail300', 'hand')}).length, 1);
  });
}
