import 'dart:math' as math;

import '../models.dart';
import 'summary.dart';

double _r(double v) => (v * 100).roundToDouble() / 100;
DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);

// ------------------------------------------------------------------ 1. search

/// Payments matching every word of [query]: an amount ("800", "1,799.71"), the payee, note, bank text, UPI ID,
/// category or account name, or a #tag.
List<Txn> searchTxns(
  Iterable<Txn> txns,
  String query, {
  String? Function(String? id)? categoryName,
  String? Function(String? id)? accountName,
}) {
  final words = query.toLowerCase().replaceAll(',', '').split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
  if (words.isEmpty) return const [];
  return txns.where((t) {
    final hay = [
      t.title,
      t.note ?? '',
      t.details ?? '',
      t.payeeVpa ?? '',
      t.bankName ?? '',
      categoryName?.call(t.categoryId) ?? '',
      accountName?.call(t.accountId) ?? '',
    ].join(' ').toLowerCase();
    return words.every((w) => double.tryParse(w) != null ? matchesAmount(t, w) || hay.contains(w) : hay.contains(w));
  }).toList()..sort((a, b) => b.txnAt.compareTo(a.txnAt));
}

// ------------------------------------------------------------------ 2. month in review

class MonthReview {
  MonthReview({
    required this.month,
    required this.spent,
    required this.received,
    required this.prevSpent,
    required this.byCategory,
    required this.changes,
    required this.byDay,
    required this.noSpendDays,
    required this.biggest,
  });

  final DateTime month;
  final double spent, received, prevSpent;
  final List<MapEntry<String?, double>> byCategory;

  /// Category → (this month, the month before), the biggest moves first.
  final List<({String? categoryId, double now, double before})> changes;

  /// Spending on each day of the month (index 0 = the 1st).
  final List<double> byDay;
  final int noSpendDays;
  final Txn? biggest;

  double get kept => received - spent;
}

MonthReview monthReview(
  List<Txn> txns,
  DateTime month, {
  Set<String> notSpendingIds = const {},
  ShareTotals shares = ShareTotals.none,
  DateTime? now,
}) {
  final start = DateTime(month.year, month.month), end = DateTime(month.year, month.month + 1);
  final prev = DateTime(month.year, month.month - 1);
  final s = summarizeBetween(txns, start, end, loanCategoryIds: notSpendingIds, shares: shares);
  final p = summarizeBetween(txns, prev, start, loanCategoryIds: notSpendingIds, shares: shares);
  final before = {for (final e in p.byCategory) e.key: e.value};
  final nowCat = {for (final e in s.byCategory) e.key: e.value};
  final changes = [
    for (final k in {...before.keys, ...nowCat.keys})
      (categoryId: k, now: _r(nowCat[k] ?? 0), before: _r(before[k] ?? 0)),
  ]..sort((a, b) => (b.now - b.before).abs().compareTo((a.now - a.before).abs()));
  final days = DateTime(month.year, month.month + 1, 0).day;
  final byDay = List<double>.filled(days, 0);
  Txn? biggest;
  for (final t in txns) {
    if (!t.isDebit || t.txnAt.isBefore(start) || !t.txnAt.isBefore(end) || !counts(t, notSpendingIds)) continue;
    final own = shares.own(t);
    byDay[t.txnAt.day - 1] += own;
    if (biggest == null || own > shares.own(biggest)) biggest = t;
  }
  final today = _day(now ?? DateTime.now());
  final lastDay = today.isBefore(end) && !today.isBefore(start) ? today.day : days;
  return MonthReview(
    month: start,
    spent: s.spent,
    received: s.received,
    prevSpent: p.spent,
    byCategory: s.byCategory,
    changes: changes.take(5).toList(),
    byDay: [for (final d in byDay) _r(d)],
    noSpendDays: [for (var i = 0; i < lastDay; i++) byDay[i]].where((d) => d < 0.005).length,
    biggest: biggest,
  );
}

// ------------------------------------------------------------------ 4. subscriptions

/// A payee paid the same way month after month: what it costs a year, whether the price went up, whether it
/// went quiet (maybe cancelled, or paid elsewhere).
typedef Subscription = ({
  String name,
  double lastAmount,
  double? previousAmount,
  int months,
  DateTime last,
  double perYear,
  bool quiet,
  String? categoryId,
});

List<Subscription> findSubscriptions(Iterable<Txn> txns, {DateTime? now, Set<String> notSpendingIds = const {}}) {
  final n = now ?? DateTime.now();
  final since = DateTime(n.year, n.month - 6, n.day);
  final byPayee = <String, List<Txn>>{};
  for (final t in txns) {
    if (!t.isDebit || t.txnAt.isBefore(since) || !counts(t, notSpendingIds) || t.amount < 49) continue;
    byPayee.putIfAbsent(t.title.toLowerCase(), () => []).add(t);
  }
  final out = <Subscription>[];
  for (final list in byPayee.values) {
    final months = {for (final t in list) '${t.txnAt.year}-${t.txnAt.month}'};
    // Once a month (not a daily habit), in at least 3 of the last 6 months.
    if (months.length < 3 || list.length > months.length + 1) continue;
    list.sort((a, b) => a.txnAt.compareTo(b.txnAt));
    final amounts = list.map((t) => t.amount).toList();
    final steady = amounts.toSet().length <= 2 || (amounts.reduce(math.max) / amounts.reduce(math.min)) < 1.3;
    if (!steady) continue;
    final last = list.last;
    final prev = list.length > 1 ? list[list.length - 2].amount : null;
    out.add((
      name: last.title,
      lastAmount: last.amount,
      previousAmount: prev != null && (prev - last.amount).abs() > 0.5 ? prev : null,
      months: months.length,
      last: last.txnAt,
      perYear: _r(last.amount * 12),
      quiet: n.difference(last.txnAt).inDays > 45,
      categoryId: last.categoryId,
    ));
  }
  out.sort((a, b) => b.perYear.compareTo(a.perYear));
  return out;
}

// ------------------------------------------------------------------ 5. unusual spends

/// Recent payments far above what you usually pay there: at least 2.5× your typical payment at that place (4+
/// earlier payments in 6 months) and ₹300 more.
List<({Txn txn, double usual})> unusualSpends(
  Iterable<Txn> txns, {
  DateTime? now,
  int recentDays = 14,
  Set<String> notSpendingIds = const {},
}) {
  final n = now ?? DateTime.now();
  final recentFrom = n.subtract(Duration(days: recentDays));
  final historyFrom = n.subtract(const Duration(days: 180));
  final byPayee = <String, List<Txn>>{};
  for (final t in txns) {
    if (!t.isDebit || t.txnAt.isBefore(historyFrom) || !counts(t, notSpendingIds)) continue;
    byPayee.putIfAbsent(t.title.toLowerCase(), () => []).add(t);
  }
  final out = <({Txn txn, double usual})>[];
  for (final list in byPayee.values) {
    for (final t in list.where((t) => !t.txnAt.isBefore(recentFrom))) {
      final earlier = list.where((x) => x.txnAt.isBefore(t.txnAt)).map((x) => x.amount).toList()..sort();
      if (earlier.length < 4) continue;
      final median = earlier[earlier.length ~/ 2];
      if (t.amount >= median * 2.5 && t.amount - median >= 300) out.add((txn: t, usual: median));
    }
  }
  out.sort((a, b) => b.txn.txnAt.compareTo(a.txn.txnAt));
  return out;
}

// ------------------------------------------------------------------ 7. month-end forecast

/// Money in your bank accounts and cash at the end of the month: now, minus what is due (repeats, EMIs), plus
/// what comes in (repeats you get), minus your usual everyday spending for the days left.
typedef Forecast = ({
  double now,
  double dues,
  double incoming,
  double everyday,
  double perDay,
  int daysLeft,
  double end,
});

Forecast monthEndForecast({
  required double balanceNow,
  required double dues,
  required double incoming,
  required List<Txn> txns,
  Set<String> notSpendingIds = const {},
  ShareTotals shares = ShareTotals.none,
  DateTime? now,
}) {
  final n = now ?? DateTime.now();
  final today = _day(n);
  final from = today.subtract(const Duration(days: 30));
  // Everyday spending: the last 30 days, leaving out single payments of ₹5,000 or more (rent, big buys).
  var everyday = 0.0;
  for (final t in txns) {
    if (!t.isDebit || t.txnAt.isBefore(from) || !t.txnAt.isBefore(today) || !counts(t, notSpendingIds)) continue;
    final own = shares.own(t);
    if (own < 5000) everyday += own;
  }
  final perDay = everyday / 30;
  final daysLeft = DateTime(n.year, n.month + 1, 0).day - n.day;
  final spend = perDay * daysLeft;
  return (
    now: _r(balanceNow),
    dues: _r(dues),
    incoming: _r(incoming),
    everyday: _r(spend),
    perDay: _r(perDay),
    daysLeft: daysLeft,
    end: _r(balanceNow - dues + incoming - spend),
  );
}

// ------------------------------------------------------------------ 9. tags

final _tag = RegExp(r'#([\p{L}\p{N}_-]+)', unicode: true);

Set<String> tagsOf(Txn t) => {for (final m in _tag.allMatches(t.note ?? '')) m.group(1)!.toLowerCase()};

/// Every #tag in your notes with what went out and came in under it.
List<({String tag, double out, double into, int count})> tagTotals(
  Iterable<Txn> txns, {
  ShareTotals shares = ShareTotals.none,
}) {
  final m = <String, ({double out, double into, int count})>{};
  for (final t in txns) {
    for (final tag in tagsOf(t)) {
      final v = m[tag] ?? (out: 0.0, into: 0.0, count: 0);
      m[tag] = t.isDebit
          ? (out: v.out + shares.own(t), into: v.into, count: v.count + 1)
          : (out: v.out, into: v.into + t.amount, count: v.count + 1);
    }
  }
  return [for (final e in m.entries) (tag: e.key, out: _r(e.value.out), into: _r(e.value.into), count: e.value.count)]
    ..sort((a, b) => b.out.compareTo(a.out));
}

// ------------------------------------------------------------------ 10. year in review

class YearReview {
  YearReview({
    required this.from,
    required this.to,
    required this.spent,
    required this.received,
    required this.byMonth,
    required this.byCategory,
    required this.interest,
    required this.invested,
    required this.topPlaces,
  });

  final DateTime from, to;
  final double spent, received, interest, invested;
  final List<({DateTime month, double spent, double received})> byMonth;
  final List<MapEntry<String?, double>> byCategory;
  final List<MapEntry<String, double>> topPlaces;
}

/// A year (Indian financial year from April, or any 12 months): totals, month by month, by category, bank
/// interest earned (for tax), and money put into investments.
YearReview yearReview(
  List<Txn> txns,
  DateTime from, {
  Set<String> notSpendingIds = const {},
  Set<String> investmentIds = const {},
  ShareTotals shares = ShareTotals.none,
}) {
  final to = DateTime(from.year + 1, from.month, from.day);
  final s = summarizeBetween(txns, from, to, loanCategoryIds: notSpendingIds, shares: shares);
  var interest = 0.0, invested = 0.0;
  for (final t in txns) {
    if (t.txnAt.isBefore(from) || !t.txnAt.isBefore(to)) continue;
    if (!t.isDebit && RegExp(r'interest', caseSensitive: false).hasMatch(t.title)) interest += t.amount;
    if (t.isDebit && investmentIds.contains(t.categoryId)) invested += t.amount;
  }
  return YearReview(
    from: from,
    to: to,
    spent: s.spent,
    received: s.received,
    byMonth: [
      for (var i = 0; i < 12; i++)
        () {
          final m = DateTime(from.year, from.month + i);
          final x = summarizeBetween(
            txns,
            m,
            DateTime(m.year, m.month + 1),
            loanCategoryIds: notSpendingIds,
            shares: shares,
          );
          return (month: m, spent: x.spent, received: x.received);
        }(),
    ],
    byCategory: s.byCategory,
    interest: _r(interest),
    invested: _r(invested),
    topPlaces: s.byMerchant.take(10).toList(),
  );
}

/// The Indian financial year (April–March) a day falls in.
DateTime financialYearOf(DateTime d) => DateTime(d.month >= 4 ? d.year : d.year - 1, 4);
