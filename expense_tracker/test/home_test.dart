import 'package:expense_tracker/logic/home.dart';
import 'package:expense_tracker/models.dart';
import 'package:flutter_test/flutter_test.dart';

Txn tx(String id, double amount, DateTime at, {bool debit = true, bool excluded = false}) =>
    Txn(id: id, amount: amount, isDebit: debit, txnAt: at, merchant: id, excluded: excluded);

void main() {
  // Saturday 14 Nov 2026, 6 pm.
  final now = DateTime(2026, 11, 14, 18);

  test('today, this week against last week so far, the month, and transfers never counted', () {
    final txns = [
      tx('chai', 20, DateTime(2026, 11, 14, 9)),
      tx('lunch', 180, DateTime(2026, 11, 14, 13)),
      tx('to savings', 5000, DateTime(2026, 11, 14, 10), excluded: true),
      tx('mon', 300, DateTime(2026, 11, 9, 12)),
      tx('lastweek', 400, DateTime(2026, 11, 3, 12)), // Tue last week: before the same time
      tx('lastweek late', 999, DateTime(2026, 11, 7, 19)), // Sat last week after 6 pm: not yet "so far"
      tx('salary', 40000, DateTime(2026, 11, 1), debit: false),
    ];
    final s = homeStats(txns, now);
    expect(s.today, 200);
    expect(s.week, 500);
    expect(s.lastWeekSoFar, 400);
    expect(s.month, 1899);
    expect(s.monthReceived, 40000);
    expect(s.last7.last.spent, 200);
    expect(s.last7.first.day, DateTime(2026, 11, 8));
  });

  test('budget: what is left per day, and the streak of days within the daily limit', () {
    final txns = [for (var d = 1; d <= 14; d++) tx('d$d', d == 10 ? 2000 : 300, DateTime(2026, 11, d, 12))];
    final s = homeStats(txns, now, monthlyBudget: 15000); // ₹500 a day
    expect(s.dailyLimit, 500);
    expect(s.streak, 4); // 11–14 Nov; the 10th was ₹2,000
    expect(s.streakIsNoSpend, isFalse);
    expect(s.month, 13 * 300 + 2000);
    expect(s.perDayLeft(now), closeTo((15000 - 5900) / 17, 0.001)); // 14th–30th
  });

  test('no budget: the streak counts days with no spending', () {
    final s = homeStats([tx('x', 50, DateTime(2026, 11, 11, 12))], now);
    expect(s.streak, 3); // 12, 13, 14
    expect(s.streakIsNoSpend, isTrue);
  });
}
