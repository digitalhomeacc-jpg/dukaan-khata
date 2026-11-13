import 'package:expense_tracker/logic/summary.dart';
import 'package:expense_tracker/models.dart';
import 'package:flutter_test/flutter_test.dart';

Txn t(double amount, DateTime at, {bool debit = true, String? cat, String? merchant, bool excluded = false}) => Txn(
      id: '$amount$at',
      amount: amount,
      isDebit: debit,
      txnAt: at,
      categoryId: cat,
      merchant: merchant,
      excluded: excluded,
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
}
