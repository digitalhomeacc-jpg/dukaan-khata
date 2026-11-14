import 'dart:math' as math;

import '../models.dart';
import 'summary.dart';

/// Self-analysis for a period: how money came and went, compared with the period just before.
class Analysis {
  Analysis({
    required this.spent,
    required this.received,
    required this.prevSpent,
    required this.prevReceived,
    required this.days,
    required this.noSpendDays,
    required this.noSpendStreak,
    required this.byWeekday,
    required this.byTimeOfDay,
    required this.timedCount,
    required this.smallCount,
    required this.smallTotal,
    required this.changes,
    required this.recurring,
    required this.biggest,
    required this.topPlaces,
  });

  final double spent, received, prevSpent, prevReceived;
  final int days;

  /// Days in the period with no spending at all, and the run of them up to the last day.
  final int noSpendDays, noSpendStreak;

  /// Monday = index 0.
  final List<double> byWeekday;

  /// Morning (5–12), afternoon (12–17), evening (17–22), late night (22–5). Only payments with a real time
  /// (bank alerts, added by hand): statement lines carry no time.
  final List<double> byTimeOfDay;
  final int timedCount;

  /// Payments under ₹[smallLimit]: easy to miss, they add up.
  final int smallCount;
  final double smallTotal;

  /// Categories that changed most against the period before: (category, now, before).
  final List<({String? categoryId, double now, double before})> changes;

  /// Paid again and again: payee, months seen, average a month.
  final List<({String name, int months, double perMonth, String? categoryId})> recurring;
  final List<Txn> biggest;
  final List<({String name, double total, int count})> topPlaces;

  double get saved => received - spent;

  /// Of what came in, how much stayed. Null when nothing came in.
  double? get savingsRate => received <= 0 ? null : saved / received;
  double get perDay => days == 0 ? 0 : spent / days;
  double get smallShare => spent == 0 ? 0 : smallTotal / spent;
}

const smallLimit = 200.0;

/// Works out [Analysis] for [from]..[to] (to not included).
Analysis analyse(
  Iterable<Txn> txns,
  DateTime from,
  DateTime to, {
  Set<String> notSpendingIds = const {},
  ShareTotals shares = ShareTotals.none,
  DateTime? today,
}) {
  final now = today ?? DateTime.now();
  final end = to.isAfter(now) ? DateTime(now.year, now.month, now.day + 1) : to;
  final length = end.difference(from);
  final prevFrom = from.subtract(length);
  final mine = txns.where((t) => counts(t, notSpendingIds)).toList();
  bool inP(Txn t, DateTime a, DateTime b) => !t.txnAt.isBefore(a) && t.txnAt.isBefore(b);

  final cur = summarizeBetween(mine, from, end, shares: shares);
  final prev = summarizeBetween(mine, prevFrom, from, shares: shares);

  final out = [
    for (final t in mine)
      if (t.isDebit && inP(t, from, end) && shares.own(t) > 0) t,
  ];
  final days = math.max(1, end.difference(from).inDays);

  // Days with no spending, and the current run of them.
  final spendDays = {for (final t in out) DateTime(t.txnAt.year, t.txnAt.month, t.txnAt.day)};
  var noSpend = 0, streak = 0;
  for (var i = 0; i < days; i++) {
    final d = DateTime(from.year, from.month, from.day + i);
    if (spendDays.contains(d)) {
      streak = 0;
    } else {
      noSpend++;
      streak++;
    }
  }

  final byWeekday = List<double>.filled(7, 0);
  final byTime = List<double>.filled(4, 0);
  var timed = 0, smallCount = 0;
  var smallTotal = 0.0;
  for (final t in out) {
    final v = shares.own(t);
    byWeekday[t.txnAt.weekday - 1] += v;
    if (t.source != 'statement') {
      final h = t.txnAt.hour;
      byTime[h >= 5 && h < 12 ? 0 : (h >= 12 && h < 17 ? 1 : (h >= 17 && h < 22 ? 2 : 3))] += v;
      timed++;
    }
    if (v < smallLimit) {
      smallCount++;
      smallTotal += v;
    }
  }

  // Category changes against the period before, biggest swings first.
  final nowBy = {for (final e in cur.byCategory) e.key: e.value};
  final beforeBy = {for (final e in prev.byCategory) e.key: e.value};
  final changes = [
    for (final id in {...nowBy.keys, ...beforeBy.keys})
      (categoryId: id, now: nowBy[id] ?? 0.0, before: beforeBy[id] ?? 0.0),
  ]..sort((a, b) => (b.now - b.before).abs().compareTo((a.now - a.before).abs()));

  // Recurring: the same payee in 3+ of the last 6 months up to the period's end.
  // Six calendar months: this one and the five before it (a rolling window would touch 7 months).
  final lastDay = end.subtract(const Duration(microseconds: 1));
  final since = DateTime(lastDay.year, lastDay.month - 5);
  final monthsOf = <String, Set<int>>{}, totalOf = <String, double>{}, nameOf = <String, String>{};
  final catOf = <String, Map<String?, int>>{};
  for (final t in mine) {
    if (!t.isDebit || t.merchant == null || !inP(t, since, end)) continue;
    final k = t.merchant!.toLowerCase().trim();
    nameOf.putIfAbsent(k, () => t.merchant!.trim());
    (monthsOf[k] ??= {}).add(t.txnAt.year * 12 + t.txnAt.month);
    totalOf[k] = (totalOf[k] ?? 0) + shares.own(t);
    final c = catOf[k] ??= {};
    c[t.categoryId] = (c[t.categoryId] ?? 0) + 1;
  }
  final recurring = [
    for (final e in monthsOf.entries)
      if (e.value.length >= 3)
        (
          name: nameOf[e.key]!,
          months: e.value.length,
          perMonth: totalOf[e.key]! / 6,
          categoryId: (catOf[e.key]!.entries.toList()..sort((a, b) => b.value.compareTo(a.value))).first.key,
        ),
  ]..sort((a, b) => b.perMonth.compareTo(a.perMonth));

  final biggest = [...out]..sort((a, b) => shares.own(b).compareTo(shares.own(a)));
  final places = <String, ({double total, int count})>{};
  for (final t in out) {
    final p = places[t.title] ?? (total: 0.0, count: 0);
    places[t.title] = (total: p.total + shares.own(t), count: p.count + 1);
  }
  final topPlaces = [for (final e in places.entries) (name: e.key, total: e.value.total, count: e.value.count)]
    ..sort((a, b) => b.total.compareTo(a.total));

  return Analysis(
    spent: cur.spent,
    received: cur.received,
    prevSpent: prev.spent,
    prevReceived: prev.received,
    days: days,
    noSpendDays: noSpend,
    noSpendStreak: streak,
    byWeekday: byWeekday,
    byTimeOfDay: byTime,
    timedCount: timed,
    smallCount: smallCount,
    smallTotal: smallTotal,
    changes: changes.take(6).toList(),
    recurring: recurring.take(8).toList(),
    biggest: biggest.take(5).toList(),
    topPlaces: topPlaces.take(5).toList(),
  );
}
