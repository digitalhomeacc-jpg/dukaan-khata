import 'package:expense_tracker/logic/summary.dart';
import 'package:expense_tracker/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final nov = DateTime(2026, 11);

  group('group food order: you pay 600, two friends send 200 each', () {
    final txns = [
      Txn(
        id: 'pay',
        amount: 600,
        isDebit: true,
        txnAt: DateTime(2026, 11, 10, 20),
        merchant: 'Zomato',
        categoryId: 'food',
      ),
      Txn(id: 'r1', amount: 200, isDebit: false, txnAt: DateTime(2026, 11, 10, 20, 5), merchant: 'Rahul'),
      Txn(id: 'r2', amount: 200, isDebit: false, txnAt: DateTime(2026, 11, 10, 21), merchant: 'Priya'),
      Txn(id: 'salary', amount: 1000, isDebit: false, txnAt: DateTime(2026, 11, 1), merchant: 'Acme'),
    ];
    final shares = [
      TxnShare(id: 'a', txnId: 'pay', person: 'Rahul', amount: 200, paidTxnId: 'r1'),
      TxnShare(id: 'b', txnId: 'pay', person: 'Priya', amount: 200, paidTxnId: 'r2'),
    ];

    test('only your share is spending; friends paying back is not income', () {
      final s = summarize(txns, nov, shares: shareTotals(shares));
      expect(s.spent, 200);
      expect(s.received, 1000);
      expect(s.byCategory.single.value, 200);
      expect(monthlySpend(txns, nov, 1, shares: shareTotals(shares)).single.value, 200);
    });

    test('a friend who has not paid yet owes you', () {
      final unpaid = [shares[0], const TxnShare(id: 'b', txnId: 'pay', person: 'Priya', amount: 200)];
      final l = loanBalances(txns.take(2), const {}, shares: unpaid);
      expect(l.single.person, 'Priya');
      expect(l.single.balance, -200);
      // Your spending is still only your share.
      expect(summarize(txns, nov, shares: shareTotals(unpaid)).spent, 200);
    });
  });

  group('bank balance check', () {
    const hdfc = Account(id: 'h', name: 'HDFC', openingBalance: 1000);
    final txns = [
      Txn(id: '1', amount: 300, isDebit: true, txnAt: DateTime(2026, 11, 2), accountId: 'h'),
      Txn(id: '2', amount: 500, isDebit: false, txnAt: DateTime(2026, 11, 3), accountId: 'h'),
      Txn(
        id: '3',
        amount: 200,
        isDebit: true,
        txnAt: DateTime(2026, 11, 3, 12),
        accountId: 'h',
        counterAccountId: 'c',
        excluded: true,
      ),
      Txn(id: '4', amount: 50, isDebit: true, txnAt: DateTime(2026, 11, 5), accountId: 'h'),
      Txn(id: 'x', amount: 999, isDebit: true, txnAt: DateTime(2026, 11, 4), accountId: 'other'),
    ];

    test('running balance after each transaction', () {
      final r = runningBalances(txns, hdfc);
      expect(r, {'1': 700, '2': 1200, '3': 1000, '4': 950});
      expect(r.containsKey('x'), false);
    });

    test('matches the bank at the time of its email', () {
      final c = checkBalance(txns, hdfc, [
        BalanceReading(id: 'a', accountId: 'h', balance: 1200, asOf: DateTime(2026, 11, 3, 6)),
        BalanceReading(id: 'b', accountId: 'h', balance: 1000, asOf: DateTime(2026, 11, 4, 23, 59)),
        BalanceReading(id: 'z', accountId: 'other', balance: 5, asOf: DateTime(2026, 11, 9)),
      ])!;
      expect(c.bank, 1000);
      expect(c.app, 1000);
      expect(c.matches, true);
    });

    test('a missing transaction shows as a difference', () {
      final c = checkBalance(txns, hdfc, [
        BalanceReading(id: 'a', accountId: 'h', balance: 900, asOf: DateTime(2026, 11, 6)),
      ])!;
      expect(c.app, 950);
      expect(c.difference, -50);
      expect(c.matches, false);
    });

    test('no reading, no check', () {
      expect(checkBalance(txns, hdfc, const []), isNull);
    });
  });

  test('opening balance on a date: earlier transactions are history only', () {
    final a = Account(id: 'h', name: 'HDFC', openingBalance: 5000, openingDate: DateTime(2026, 4, 1));
    final txns = [
      Txn(id: 'older', amount: 200, isDebit: false, txnAt: DateTime(2026, 3, 30), accountId: 'h'),
      Txn(id: 'old', amount: 999, isDebit: true, txnAt: DateTime(2026, 3, 31, 23), accountId: 'h'),
      Txn(id: 'n1', amount: 1000, isDebit: true, txnAt: DateTime(2026, 4, 1, 9), accountId: 'h'),
      Txn(id: 'n2', amount: 300, isDebit: false, txnAt: DateTime(2026, 4, 2), accountId: 'h'),
    ];
    expect(accountBalances(txns, [a])['h'], 4300);
    // Before the opening date, balances are worked back from it: 5,000 after 'old', 5,999 before it.
    expect(runningBalances(txns, a), {'n1': 4000, 'n2': 4300, 'old': 5000, 'older': 5999});
    expect(balanceAt(txns, a, DateTime(2026, 4, 1, 12)), 4000);
  });

  group('one payment split into categories', () {
    final now = DateTime(2026, 11, 14);
    final t = Txn(id: 'p', amount: 500, isDebit: true, txnAt: now, merchant: 'Saket', categoryId: 'food');
    final parts = [const TxnPart(id: 'a', txnId: 'p', categoryId: 'groc', amount: 300)];

    test('the total never changes; only how it is divided', () {
      final s = summarizeBetween(
        [t],
        DateTime(2026, 11),
        DateTime(2026, 12),
        shares: shareTotals(const [], parts: parts),
      );
      expect(s.spent, 500);
      expect(Map.fromEntries(s.byCategory), {'groc': 300.0, 'food': 200.0});
    });

    test('the category report counts each part in its own category', () {
      final r = categoryReport(
        [t],
        DateTime(2026, 11),
        DateTime(2026, 12),
        debits: true,
        shares: shareTotals(const [], parts: parts),
      );
      expect({for (final l in r) l.id: l.total}, {'groc': 300.0, 'food': 200.0});
      expect(r.firstWhere((l) => l.id == 'groc').amounts['p'], 300);
    });

    test('with a friend\'s share taken out, parts never exceed your part', () {
      final shares = shareTotals(const [TxnShare(id: 's', txnId: 'p', person: 'Ravi', amount: 250)], parts: parts);
      // Yours is 250 of the 500: the 300 part is cut to 250, nothing left in Food, total still 250.
      expect(shares.byCategory(t).map((e) => (e.categoryId, e.amount)).toList(), [('groc', 250.0)]);
      expect(summarizeBetween([t], DateTime(2026, 11), DateTime(2026, 12), shares: shares).spent, 250);
    });
  });
}
