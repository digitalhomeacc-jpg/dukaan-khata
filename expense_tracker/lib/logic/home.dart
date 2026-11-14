import 'dart:math' as math;

import '../models.dart';
import 'summary.dart';

/// The Home screen's numbers, from the same rules as every other screen (transfers, loans, friends' parts and
/// investments are never spending).
class HomeStats {
  HomeStats({
    required this.today,
    required this.week,
    required this.lastWeekSoFar,
    required this.month,
    required this.monthReceived,
    required this.last7,
    required this.streak,
    required this.streakIsNoSpend,
    this.budget,
    this.dailyLimit,
  });

  /// Spent today, this week (Monday on), and last week up to the same weekday and time.
  final double today, week, lastWeekSoFar;
  final double month, monthReceived;

  /// Spent each of the last 7 days, oldest first (today last).
  final List<({DateTime day, double spent})> last7;

  /// Days in a row (up to today) within the daily limit, or with no spending when there is no budget.
  final int streak;
  final bool streakIsNoSpend;

  /// The monthly budget (all spending) and what is fine per day for the rest of the month.
  final double? budget;
  final double? dailyLimit;

  double? get budgetLeft => budget == null ? null : budget! - month;
  int daysLeftIn(DateTime now) => DateTime(now.year, now.month + 1, 0).day - now.day + 1;

  /// What can still be spent each day (today included) to stay in budget.
  double? perDayLeft(DateTime now) =>
      budget == null ? null : math.max(0, (budgetLeft ?? 0) / daysLeftIn(now)).toDouble();
}

HomeStats homeStats(
  Iterable<Txn> txns,
  DateTime now, {
  Set<String> notSpendingIds = const {},
  ShareTotals shares = ShareTotals.none,
  double? monthlyBudget,
}) {
  final list = txns is List<Txn> ? txns : txns.toList();
  final today = DateTime(now.year, now.month, now.day);
  final tomorrow = today.add(const Duration(days: 1));
  double spent(DateTime from, DateTime to) =>
      summarizeBetween(list, from, to, loanCategoryIds: notSpendingIds, shares: shares).spent;

  // Spending per day for the last 60 days, in one pass.
  final from = today.subtract(const Duration(days: 60));
  final byDay = <DateTime, double>{};
  for (final t in list) {
    if (!t.isDebit || t.txnAt.isBefore(from) || !t.txnAt.isBefore(tomorrow) || !counts(t, notSpendingIds)) continue;
    final a = shares.own(t);
    if (a <= 0) continue;
    final d = DateTime(t.txnAt.year, t.txnAt.month, t.txnAt.day);
    byDay[d] = (byDay[d] ?? 0) + a;
  }
  final weekStart = today.subtract(Duration(days: today.weekday - 1));
  final monthStart = DateTime(now.year, now.month);
  final daysInMonth = DateTime(now.year, now.month + 1, 0).day;
  final limit = monthlyBudget == null ? null : monthlyBudget / daysInMonth;

  var streak = 0;
  for (var d = today; !d.isBefore(from); d = d.subtract(const Duration(days: 1))) {
    final s = byDay[d] ?? 0;
    final ok = limit == null ? s < 0.005 : s <= limit + 0.005;
    if (!ok) break;
    streak++;
  }
  final m = summarizeBetween(list, monthStart, tomorrow, loanCategoryIds: notSpendingIds, shares: shares);
  return HomeStats(
    today: spent(today, tomorrow),
    week: spent(weekStart, tomorrow),
    lastWeekSoFar: spent(weekStart.subtract(const Duration(days: 7)), now.subtract(const Duration(days: 7))),
    month: m.spent,
    monthReceived: m.received,
    last7: [
      for (var i = 6; i >= 0; i--)
        (day: today.subtract(Duration(days: i)), spent: byDay[today.subtract(Duration(days: i))] ?? 0),
    ],
    streak: streak,
    streakIsNoSpend: limit == null,
    budget: monthlyBudget,
    dailyLimit: limit,
  );
}
