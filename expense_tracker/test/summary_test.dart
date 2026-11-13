import 'package:expense_tracker/logic/summary.dart';
import 'package:expense_tracker/models.dart';
import 'package:flutter_test/flutter_test.dart';

Txn t(
  double amount,
  DateTime at, {
  bool debit = true,
  String? cat,
  String? merchant,
  bool excluded = false,
  String? acc,
  String? to,
}) => Txn(
  id: '$amount$at',
  amount: amount,
  isDebit: debit,
  txnAt: at,
  categoryId: cat,
  merchant: merchant,
  excluded: excluded,
  accountId: acc,
  counterAccountId: to,
);

void main() {
  final nov = DateTime(2026, 11);
  final txns = [
    t(250, DateTime(2026, 11, 12, 13), cat: 'food', merchant: 'Swiggy'),
    t(150.5, DateTime(2026, 11, 12, 9), cat: 'food', merchant: 'Swiggy'),
    t(1000, DateTime(2026, 11, 3), cat: 'shop', merchant: 'Amazon'),
    t(80, DateTime(2026, 11, 1), merchant: 'Chai'),
    t(85000, DateTime(2026, 11, 1), debit: false, merchant: 'ACME'),
    t(15000, DateTime(2026, 11, 5), debit: false, excluded: true), // card bill payment
    t(15000, DateTime(2026, 11, 5), excluded: true),
    t(999, DateTime(2026, 10, 31, 23, 59), cat: 'shop'),
  ];

  test('month totals leave out excluded and other months', () {
    final s = summarize(txns, nov);
    expect(s.spent, 1480.5);
    expect(s.received, 85000);
    expect(s.net, 83519.5);
  });

  test('spending by category, largest first, uncategorised as null', () {
    final s = summarize(txns, nov);
    expect(s.byCategory.map((e) => e.key).toList(), ['shop', 'food', null]);
    expect(s.byCategory[1].value, 400.5);
  });

  test('spending by merchant', () {
    final s = summarize(txns, nov);
    expect(s.byMerchant.first.key, 'Amazon');
    expect(s.byMerchant[1].key, 'Swiggy');
    expect(s.byMerchant[1].value, 400.5);
  });

  test('six month trend ends with the chosen month', () {
    final trend = monthlySpend(txns, nov, 6);
    expect(trend.length, 6);
    expect(trend.first.key, DateTime(2026, 6));
    expect(trend.last.key, nov);
    expect(trend.last.value, 1480.5);
    expect(trend[4].value, 999);
  });

  test('trend across a year boundary', () {
    final trend = monthlySpend([t(10, DateTime(2027, 1, 2))], DateTime(2027, 2), 3);
    expect(trend.map((e) => e.key).toList(), [DateTime(2026, 12), DateTime(2027, 1), DateTime(2027, 2)]);
    expect(trend[1].value, 10);
  });

  test('group by day, newest first', () {
    final days = groupByDay(txns.where((x) => inMonth(x.txnAt, nov)));
    expect(days.first.key, DateTime(2026, 11, 12));
    expect(days.first.value.first.amount, 250); // 13:00 before 09:00
    expect(days.last.key, DateTime(2026, 11, 1));
  });

  test('parses rows from Supabase', () {
    final x = Txn.fromMap({
      'id': 'a',
      'amount': '1249.00',
      'direction': 'debit',
      'txn_at': '2026-11-12T04:11:07+00:00',
      'merchant': 'AMAZON',
      'source': 'email',
      'excluded': false,
    });
    expect(x.amount, 1249);
    expect(x.isDebit, true);
    expect(x.fromEmail, true);
    expect(x.txnAt.isUtc, false);
    expect(x.txnAt.toUtc(), DateTime.utc(2026, 11, 12, 4, 11, 7));
    expect(x.title, 'AMAZON');
  });

  group('personal loans', () {
    final loanTxns = [
      t(5000, DateTime(2026, 11, 2), debit: false, cat: 'loan', merchant: 'Rahul'), // borrowed
      t(2000, DateTime(2026, 11, 9), cat: 'loan', merchant: 'rahul '), // paid part back
      t(1500, DateTime(2026, 11, 4), cat: 'loan', merchant: 'Priya'), // lent
      t(700, DateTime(2026, 11, 6), debit: false, cat: 'loan', merchant: 'Sam'),
      t(700, DateTime(2026, 11, 7), cat: 'loan', merchant: 'Sam'), // settled
      t(300, DateTime(2026, 11, 7), cat: 'food', merchant: 'Swiggy'),
    ];

    test('are left out of spending and income', () {
      final s = summarize(loanTxns, nov, loanCategoryIds: {'loan'});
      expect(s.spent, 300);
      expect(s.received, 0);
      expect(monthlySpend(loanTxns, nov, 1, loanCategoryIds: {'loan'}).single.value, 300);
    });

    test('balance per friend, names matched loosely, open loans first', () {
      final l = loanBalances(loanTxns, {'loan'});
      expect(l.map((x) => x.person).toList(), ['Rahul', 'Priya', 'Sam']);
      expect(l[0].balance, 3000); // you owe Rahul
      expect(l[0].txns.length, 2);
      expect(l[1].balance, -1500); // Priya owes you
      expect(l[2].settled, true);
    });
  });

  group('accounts', () {
    const accounts = [
      Account(id: 'cash', name: 'Cash', kind: AccountKind.cash, openingBalance: 500),
      Account(id: 'hdfc', name: 'HDFC', openingBalance: 10000),
      Account(id: 'card', name: 'ICICI Card', kind: AccountKind.card, openingBalance: -2000),
    ];
    final txns = [
      t(85000, DateTime(2026, 11, 1), debit: false, acc: 'hdfc'), // salary in
      t(2000, DateTime(2026, 11, 2), acc: 'hdfc', to: 'cash', excluded: true), // ATM
      t(150, DateTime(2026, 11, 2), acc: 'cash'), // chai
      t(1249, DateTime(2026, 11, 3), acc: 'card'), // card spend
      t(3249, DateTime(2026, 11, 20), debit: false, acc: 'card', to: 'hdfc', excluded: true), // bill paid from HDFC
      t(99, DateTime(2026, 11, 4)), // no account
      t(400, DateTime(2026, 10, 30), acc: 'cash'),
    ];

    test('balances include opening balance and both sides of transfers', () {
      final b = accountBalances(txns, accounts);
      expect(b['cash'], 500 + 2000 - 150 - 400);
      expect(b['hdfc'], 10000 + 85000 - 2000 - 3249);
      expect(b['card'], 0); // -2000 - 1249 + 3249
    });

    test('a counter account is ignored unless the transaction is a transfer', () {
      final b = accountBalances([t(100, DateTime(2026, 11, 1), acc: 'hdfc', to: 'cash')], accounts);
      expect(b['cash'], 500);
      expect(b['hdfc'], 9900);
    });

    test('monthly flow per account', () {
      final cash = accountFlow(txns, 'cash', nov);
      expect(cash.moneyIn, 2000);
      expect(cash.moneyOut, 150);
      final hdfc = accountFlow(txns, 'hdfc', nov);
      expect(hdfc.moneyIn, 85000);
      expect(hdfc.moneyOut, 5249);
    });
  });
}
