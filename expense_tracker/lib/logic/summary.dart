import '../models.dart';

DateTime monthStart(DateTime d) => DateTime(d.year, d.month);
DateTime addMonths(DateTime month, int n) => DateTime(month.year, month.month + n);

bool inMonth(DateTime t, DateTime month) => t.year == month.year && t.month == month.month;

class MonthSummary {
  MonthSummary({required this.spent, required this.received, required this.byCategory, required this.byMerchant});

  final double spent;
  final double received;

  /// Spending per category id (`null` = uncategorised), largest first.
  final List<MapEntry<String?, double>> byCategory;

  /// Spending per merchant, largest first.
  final List<MapEntry<String, double>> byMerchant;

  double get net => received - spent;
}

/// Totals for one month. Transactions marked `excluded` (card bill payments,
/// own-account transfers) are left out so money is not counted twice.
MonthSummary summarize(Iterable<Txn> txns, DateTime month) {
  var spent = 0.0, received = 0.0;
  final cat = <String?, double>{};
  final merch = <String, double>{};
  for (final t in txns) {
    if (t.excluded || !inMonth(t.txnAt, month)) continue;
    if (t.isDebit) {
      spent += t.amount;
      cat[t.categoryId] = (cat[t.categoryId] ?? 0) + t.amount;
      merch[t.title] = (merch[t.title] ?? 0) + t.amount;
    } else {
      received += t.amount;
    }
  }
  int desc<K>(MapEntry<K, double> a, MapEntry<K, double> b) => b.value.compareTo(a.value);
  return MonthSummary(
    spent: _round(spent),
    received: _round(received),
    byCategory: cat.entries.toList()..sort(desc),
    byMerchant: merch.entries.toList()..sort(desc),
  );
}

/// Spending for the [count] months ending with [lastMonth], oldest first.
List<MapEntry<DateTime, double>> monthlySpend(Iterable<Txn> txns, DateTime lastMonth, int count) {
  final first = addMonths(monthStart(lastMonth), -(count - 1));
  final totals = {for (var i = 0; i < count; i++) addMonths(first, i): 0.0};
  for (final t in txns) {
    if (t.excluded || !t.isDebit) continue;
    final key = monthStart(t.txnAt);
    if (totals.containsKey(key)) totals[key] = totals[key]! + t.amount;
  }
  return totals.entries.map((e) => MapEntry(e.key, _round(e.value))).toList();
}

/// Transactions of a month grouped by calendar day, newest day first.
List<MapEntry<DateTime, List<Txn>>> groupByDay(Iterable<Txn> txns) {
  final days = <DateTime, List<Txn>>{};
  for (final t in txns) {
    days.putIfAbsent(DateTime(t.txnAt.year, t.txnAt.month, t.txnAt.day), () => []).add(t);
  }
  final out = days.entries.toList()..sort((a, b) => b.key.compareTo(a.key));
  for (final e in out) {
    e.value.sort((a, b) => b.txnAt.compareTo(a.txnAt));
  }
  return out;
}

double _round(double v) => (v * 100).roundToDouble() / 100;
