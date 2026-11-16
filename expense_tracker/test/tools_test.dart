import 'package:expense_tracker/logic/tools.dart';
import 'package:expense_tracker/models.dart';
import 'package:flutter_test/flutter_test.dart';

Txn t(String m, double a, DateTime at, {bool debit = true, String? note, String? cat, bool excluded = false}) => Txn(
  id: '$m$a$at',
  amount: a,
  isDebit: debit,
  txnAt: at,
  merchant: m,
  note: note,
  categoryId: cat,
  excluded: excluded,
);

void main() {
  final now = DateTime(2026, 11, 20, 12);

  test('search: amount, name, note, tag; every word must match', () {
    final txns = [
      t('Zomato', 1799.71, now, note: 'dinner #goa'),
      t('Swiggy', 800, now),
      t('Thali House', 800, now, note: 'lunch'),
    ];
    expect(searchTxns(txns, '800').map((x) => x.title), unorderedEquals(['Swiggy', 'Thali House']));
    expect(searchTxns(txns, '800 lunch').single.title, 'Thali House');
    expect(searchTxns(txns, '1,799.71').single.title, 'Zomato');
    expect(searchTxns(txns, '#goa').single.title, 'Zomato');
    expect(searchTxns(txns, 'zomato dinner').length, 1);
  });

  test('month in review: totals, against last month, calendar, no-spend days so far', () {
    final txns = [
      t('A', 100, DateTime(2026, 11, 2), cat: 'food'),
      t('B', 300, DateTime(2026, 11, 5), cat: 'food'),
      t('C', 50, DateTime(2026, 10, 5), cat: 'food'),
      t('Move', 999, DateTime(2026, 11, 5), excluded: true),
      t('Salary', 5000, DateTime(2026, 11, 1), debit: false),
    ];
    final r = monthReview(txns, DateTime(2026, 11), now: now);
    expect(r.spent, 400);
    expect(r.received, 5000);
    expect(r.prevSpent, 50);
    expect(r.byDay[4], 300);
    expect(r.noSpendDays, 18); // 20 days so far, 2 with spending
    expect(r.biggest!.title, 'B');
    expect(r.changes.first, (categoryId: 'food', now: 400.0, before: 50.0));
  });

  test('subscriptions: monthly payees, yearly cost, price rise, gone quiet; not daily habits', () {
    final txns = [
      for (final m in [7, 8, 9]) t('Netflix', 499, DateTime(2026, m, 3)),
      t('Netflix', 649, DateTime(2026, 10, 3)),
      t('Netflix', 649, DateTime(2026, 11, 3)),
      for (final m in [5, 6, 7, 8]) t('Gym', 1500, DateTime(2026, m, 1)),
      for (final m in [8, 9, 10, 11])
        for (final d in [1, 4, 8, 12]) t('Chai', 60, DateTime(2026, m, d)),
    ];
    final s = findSubscriptions(txns, now: now);
    final netflix = s.firstWhere((x) => x.name == 'Netflix');
    expect(netflix.perYear, 649 * 12);
    expect(netflix.previousAmount, null); // the last two were the same: the rise was in October
    expect(s.firstWhere((x) => x.name == 'Gym').quiet, isTrue);
    expect(s.any((x) => x.name == 'Chai'), isFalse);
  });

  test('unusual spends: far above what you usually pay there', () {
    final txns = [
      for (var i = 1; i <= 5; i++) t('Hotel Vijay', 200, DateTime(2026, 9, i * 3)),
      t('Hotel Vijay', 1800, DateTime(2026, 11, 18)),
      t('Hotel Vijay', 250, DateTime(2026, 11, 19)),
    ];
    final u = unusualSpends(txns, now: now);
    expect(u.single.txn.amount, 1800);
    expect(u.single.usual, 200);
  });

  test('month-end forecast: now − dues + incoming − everyday spending for the days left', () {
    final txns = [
      for (var d = 21; d <= 31; d++) t('x', 300, DateTime(2026, 10, d)),
      t('Rent', 9000, DateTime(2026, 11, 1)),
    ];
    final f = monthEndForecast(balanceNow: 20000, dues: 1500, incoming: 0, txns: txns, now: now);
    expect(f.daysLeft, 10);
    expect(f.perDay, closeTo(300 * 11 / 30, 0.01)); // rent left out as a one-off
    expect(f.end, closeTo(20000 - 1500 - 110 * 10, 0.01));
  });

  test('tags and the financial year', () {
    final txns = [t('A', 100, now, note: 'flight #Goa'), t('B', 50, now, note: '#goa #food'), t('C', 70, now)];
    expect(tagTotals(txns).first, (tag: 'goa', out: 150.0, into: 0.0, count: 2));
    expect(financialYearOf(DateTime(2026, 3, 31)), DateTime(2025, 4));
    expect(financialYearOf(DateTime(2026, 4, 1)), DateTime(2026, 4));
  });

  test('year in review: interest earned, invested, month by month', () {
    final txns = [
      t('Bank interest', 43, DateTime(2026, 6, 30), debit: false),
      t('Groww', 5000, DateTime(2026, 7, 1), cat: 'inv'),
      t('Food', 100, DateTime(2026, 4, 2)),
    ];
    final y = yearReview(txns, DateTime(2026, 4), investmentIds: {'inv'}, notSpendingIds: {'inv'});
    expect(y.interest, 43);
    expect(y.invested, 5000);
    expect(y.spent, 100);
    expect(y.byMonth.first.spent, 100);
    expect(y.byMonth.length, 12);
  });
}
