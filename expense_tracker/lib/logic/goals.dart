import 'dart:math' as math;

import '../models.dart';
import 'summary.dart';

/// Where a goal stands, from the same numbers as everything else in the app (transfers, loans, friends' money
/// and investments are never spending).
class GoalProgress {
  GoalProgress({
    required this.goal,
    required this.done,
    required this.target,
    required this.onTrack,
    required this.expectedNow,
    required this.weeks,
    this.perWeekNeeded,
    this.daysLeft,
    this.baseline,
    this.monthSpent,
    this.weekSpent,
    this.weekLimit,
  });

  final Goal goal;

  /// Save: kept / grown so far. Cut: spent in the category this month.
  final double done;

  /// Save: the amount to reach. Cut: this month's limit.
  final double target;
  final bool onTrack;

  /// Where you should be by today to be on track (pro-rata).
  final double expectedNow;

  /// Week by week (oldest first, up to 8): save = total so far at each week's end; cut = spent that week.
  final List<({DateTime start, double value})> weeks;

  /// Save: what to keep each week from now to reach it in time.
  final double? perWeekNeeded;
  final int? daysLeft;

  /// Cut: the usual month (average of the 3 months before the goal), this month, this week and its limit.
  final double? baseline;
  final double? monthSpent;
  final double? weekSpent;
  final double? weekLimit;

  double get fraction => target <= 0 ? 0 : (done / target).clamp(0, 1).toDouble();
  bool get reached => goal.isSave && done >= target - 0.005;
}

DateTime _d(DateTime t) => DateTime(t.year, t.month, t.day);
double _r(double v) => (v * 100).roundToDouble() / 100;

/// Monday of the week of [t].
DateTime weekStart(DateTime t) => _d(t).subtract(Duration(days: t.weekday - 1));

GoalProgress goalProgress(
  Goal g, {
  required List<Txn> txns,
  required List<Account> accounts,
  required List<Category> categories,
  Set<String> notSpendingIds = const {},
  ShareTotals shares = ShareTotals.none,
  DateTime? now,
}) {
  final n = now ?? DateTime.now();
  final today = _d(n);
  final start = _d(g.startsOn);
  if (g.isSave) {
    final target = g.targetAmount ?? 0;
    final account = accounts.where((a) => a.id == g.accountId).firstOrNull;
    double grownBy(DateTime to) {
      if (account != null) {
        return balanceAt(txns, account, to) - balanceAt(txns, account, start.subtract(const Duration(microseconds: 1)));
      }
      final s = summarizeBetween(txns, start, to, loanCategoryIds: notSpendingIds, shares: shares);
      return s.received - s.spent;
    }

    final done = _r(grownBy(n));
    final end = _d(g.deadline ?? today);
    final total = math.max(1, end.difference(start).inDays);
    final gone = today.difference(start).inDays.clamp(0, total);
    final expected = _r(target * gone / total);
    final daysLeft = end.difference(today).inDays;
    final weeksLeft = math.max(1.0, daysLeft / 7);
    final weeks = <({DateTime start, double value})>[];
    for (
      var w = weekStart(today);
      !w.isBefore(weekStart(start)) && weeks.length < 8;
      w = w.subtract(const Duration(days: 7))
    ) {
      final end = w.add(const Duration(days: 7));
      weeks.insert(0, (start: w, value: _r(grownBy(end.isAfter(n) ? n : end))));
    }
    return GoalProgress(
      goal: g,
      done: done,
      target: target,
      onTrack: done >= expected - 0.5,
      expectedNow: expected,
      weeks: weeks,
      perWeekNeeded: done >= target ? 0 : _r((target - done) / weeksLeft),
      daysLeft: daysLeft,
    );
  }

  // Cut: the category and its sub-categories.
  final ids = {
    g.categoryId,
    for (final c in categories)
      if (c.parentId == g.categoryId) c.id,
  };
  double spentIn(DateTime from, DateTime to) => categoryReport(
    txns,
    from,
    to,
    debits: true,
    notSpendingIds: notSpendingIds,
    shares: shares,
  ).where((l) => ids.contains(l.id)).fold(0.0, (v, l) => v + l.total);

  final baseline = _r(spentIn(DateTime(start.year, start.month - 3), DateTime(start.year, start.month)) / 3);
  final limit = _r(baseline * (1 - (g.cutPct ?? 0) / 100));
  final monthStart = DateTime(today.year, today.month);
  final daysInMonth = DateTime(today.year, today.month + 1, 0).day;
  final monthSpent = _r(spentIn(monthStart, today.add(const Duration(days: 1))));
  final expected = _r(limit * today.day / daysInMonth);
  final weekLimit = _r(limit * 7 / daysInMonth);
  final weeks = <({DateTime start, double value})>[];
  for (var w = weekStart(today); weeks.length < 8; w = w.subtract(const Duration(days: 7))) {
    if (w.isBefore(weekStart(start)) && weeks.isNotEmpty) break;
    weeks.insert(0, (start: w, value: _r(spentIn(w, w.add(const Duration(days: 7))))));
  }
  return GoalProgress(
    goal: g,
    done: monthSpent,
    target: limit,
    onTrack: monthSpent <= expected + 0.5,
    expectedNow: expected,
    weeks: weeks,
    baseline: baseline,
    monthSpent: monthSpent,
    weekSpent: weeks.last.value,
    weekLimit: weekLimit,
  );
}
