import 'package:expense_tracker/logic/summary.dart';
import 'package:expense_tracker/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const acc = Account(id: 'h', name: 'HDFC', kind: AccountKind.bank, openingBalance: 1000);
  Txn t(String id, double a, DateTime at, {bool debit = true}) =>
      Txn(id: id, amount: a, isDebit: debit, txnAt: at, accountId: 'h', merchant: id, source: 'statement');
  final day = DateTime(2026, 11, 3);

  test('a morning bank balance agrees though the statement put the whole day at 6 am', () {
    final txns = [
      t('a', 100, day.add(const Duration(hours: 6))),
      t('b', 434, day.add(const Duration(hours: 6, seconds: 1))),
    ];
    // The bank said ₹900 at 8:12 am (after "a", before "b" in real life).
    final reading = BalanceReading(
      id: 'r',
      accountId: 'h',
      balance: 900,
      asOf: day.add(const Duration(hours: 8, minutes: 12)),
    );
    final c = checkBalance(txns, acc, [reading])!;
    expect(c.matches, isTrue);
    expect(c.difference, 0);
  });

  test('a payment really missing still shows', () {
    final txns = [t('a', 100, day.add(const Duration(hours: 6)))];
    final reading = BalanceReading(id: 'r', accountId: 'h', balance: 700, asOf: day.add(const Duration(hours: 23)));
    final c = checkBalance(txns, acc, [reading])!;
    expect(c.matches, isFalse);
    expect(c.difference, -200); // ₹200 left the bank that the app does not have
  });
}
