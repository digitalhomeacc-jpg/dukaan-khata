import '../models.dart';

/// Repeats: when each one is due, which payment settled it, and what is due soon.
///
/// Money rules (nothing ever changes quietly):
/// - a bank payment is only ever *matched* to a due date (it already counts once), never copied;
/// - each due date is settled at most once, and a payment settles at most one due date;
/// - only a repeat marked "add by itself" (cash) creates an entry, once, on its due day.

DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);

int _daysIn(int year, int month) => DateTime(year, month + 1, 0).day;

/// The [n]th due date (0 = the first). Monthly and yearly keep the start's day, or the month's last day.
DateTime dueDate(Recurring r, int n) {
  final s = r.startsOn;
  switch (r.every) {
    case 'week':
      return DateTime(s.year, s.month, s.day + 7 * n);
    case 'year':
      return DateTime(s.year + n, s.month, s.day.clamp(1, _daysIn(s.year + n, s.month)));
    default:
      final m = s.month - 1 + n;
      final y = s.year + m ~/ 12, mo = m % 12 + 1;
      return DateTime(y, mo, s.day.clamp(1, _daysIn(y, mo)));
  }
}

/// Every due date from the start up to and including [until].
List<DateTime> dueDatesUntil(Recurring r, DateTime until) {
  final out = <DateTime>[];
  final end = _day(until);
  for (var n = 0; n < 2000; n++) {
    final d = dueDate(r, n);
    if (d.isAfter(end)) break;
    out.add(d);
  }
  return out;
}

/// The first due date on or after [from].
DateTime nextDueFrom(Recurring r, DateTime from) {
  final f = _day(from);
  for (var n = 0; n < 2000; n++) {
    final d = dueDate(r, n);
    if (!d.isBefore(f)) return d;
  }
  return dueDate(r, 0);
}

bool _nameMatch(String name, String title) {
  final a = name.toLowerCase(), b = title.toLowerCase();
  if (a == b) return true;
  final words = RegExp(r'[a-z]{4,}').allMatches(a).map((m) => m[0]!);
  return words.any(b.contains) || RegExp(r'[a-z]{4,}').allMatches(b).map((m) => m[0]!).any(a.contains);
}

/// How many days around the due date a payment may come.
int windowDays(Recurring r) => r.every == 'week' ? 2 : 5;

/// The payment that settled this due date, if any: the same payee ([names]: the repeat's name and the payees
/// of payments you confirmed for it before), the same direction, within a few days, the same amount (or for a
/// bill that varies, a similar one), from the repeat's account when it has one. Same amount alone is never
/// enough: those are only offered ([candidatesFor]) for you to pick.
Txn? matchFor(Recurring r, DateTime due, Iterable<Txn> txns, Set<String> used, {Set<String> names = const {}}) {
  final w = windowDays(r);
  Txn? best;
  var bestScore = -1 << 30;
  for (final t in txns) {
    if (used.contains(t.id) || t.isDebit != r.isDebit || t.excluded || t.isLoanTransfer) continue;
    if (r.accountId != null && t.accountId != r.accountId) continue;
    final days = _day(t.txnAt).difference(due).inDays;
    if (days.abs() > w) continue;
    if (!_nameMatch(r.name, t.title) && !names.contains(t.title.toLowerCase())) continue;
    if (r.varies) {
      if (t.amount < r.amount * 0.25 || t.amount > r.amount * 4) continue;
    } else if ((t.amount - r.amount).abs() > 0.5) {
      continue;
    }
    final score = -days.abs();
    if (score > bestScore) {
      bestScore = score;
      best = t;
    }
  }
  return best;
}

/// Payments that might be this due date (same amount, near the date, any payee) for you to pick from.
List<Txn> candidatesFor(Recurring r, DateTime due, Iterable<Txn> txns, Set<String> used) {
  final out =
      txns.where((t) {
        if (used.contains(t.id) || t.isDebit != r.isDebit || t.excluded || t.isLoanTransfer) return false;
        if (_day(t.txnAt).difference(due).inDays.abs() > windowDays(r) + 3) return false;
        return r.varies ? t.amount >= r.amount * 0.25 && t.amount <= r.amount * 4 : (t.amount - r.amount).abs() <= 0.5;
      }).toList()..sort(
        (a, b) => _day(a.txnAt).difference(due).inDays.abs().compareTo(_day(b.txnAt).difference(due).inDays.abs()),
      );
  return out.take(6).toList();
}

/// Payees of payments already confirmed for each repeat: "Rent" learns that it is paid to "Ramesh Kumar".
Map<String, Set<String>> learnedPayees(Iterable<RecurringRun> runs, Iterable<Txn> txns) {
  final byId = {for (final t in txns) t.id: t};
  final out = <String, Set<String>>{};
  for (final run in runs) {
    final t = byId[run.txnId];
    if (t != null && run.kind == 'matched') out.putIfAbsent(run.recurringId, () => {}).add(t.title.toLowerCase());
  }
  return out;
}

enum DueState { upcoming, today, overdue }

typedef DueItem = ({Recurring recurring, DateTime due, DueState state});

typedef RecurringPlan = ({
  List<({Recurring recurring, DateTime due, Txn txn})> matches,
  List<({Recurring recurring, DateTime due})> autoAdds,
  List<DueItem> due,
});

/// What to do now: payments to match, cash repeats to add, and what is due (overdue first, then soon).
/// Overdue dates older than [lookBack] days are let go; bank payments are matched up to a year back.
RecurringPlan planRecurring(
  Iterable<Recurring> recurring,
  Iterable<RecurringRun> runs,
  Iterable<Txn> txns,
  DateTime now, {
  int lookBack = 45,
  int ahead = 30,
}) {
  final today = _day(now);
  final settled = {for (final r in runs) '${r.recurringId}|${_day(r.dueOn).toIso8601String()}'};
  final used = {for (final r in runs) ?r.txnId};
  final txnList = txns.toList();
  final learned = learnedPayees(runs, txnList);
  final open = <({Recurring recurring, DateTime due})>[];
  for (final r in recurring.where((r) => r.active)) {
    for (final d in dueDatesUntil(r, today.add(Duration(days: windowDays(r))))) {
      if (d.isBefore(today.subtract(const Duration(days: 366)))) continue;
      if (!settled.contains('${r.id}|${d.toIso8601String()}')) open.add((recurring: r, due: d));
    }
  }
  // Earlier dates take the earlier payments.
  open.sort((a, b) => a.due.compareTo(b.due));
  final matches = <({Recurring recurring, DateTime due, Txn txn})>[];
  final matched = <String>{};
  for (final o in open) {
    final t = matchFor(o.recurring, o.due, txnList, used, names: learned[o.recurring.id] ?? const {});
    if (t == null) continue;
    used.add(t.id);
    matched.add('${o.recurring.id}|${o.due.toIso8601String()}');
    matches.add((recurring: o.recurring, due: o.due, txn: t));
  }
  bool isOpen(Recurring r, DateTime d) =>
      !settled.contains('${r.id}|${d.toIso8601String()}') && !matched.contains('${r.id}|${d.toIso8601String()}');

  final autoAdds = [
    for (final o in open)
      if (o.recurring.autoAdd &&
          !o.due.isAfter(today) &&
          isOpen(o.recurring, o.due) &&
          !o.due.isBefore(today.subtract(Duration(days: lookBack))))
        o,
  ];
  final added = {for (final a in autoAdds) '${a.recurring.id}|${a.due.toIso8601String()}'};

  final due = <DueItem>[];
  for (final r in recurring.where((r) => r.active)) {
    for (final d in dueDatesUntil(r, today)) {
      if (d.isBefore(today.subtract(Duration(days: lookBack)))) continue;
      if (!isOpen(r, d) || added.contains('${r.id}|${d.toIso8601String()}')) continue;
      due.add((recurring: r, due: d, state: d == today ? DueState.today : DueState.overdue));
    }
    final next = nextDueFrom(r, today.add(const Duration(days: 1)));
    if (!next.isAfter(today.add(Duration(days: ahead))) && isOpen(r, next)) {
      due.add((recurring: r, due: next, state: DueState.upcoming));
    }
  }
  due.sort((a, b) => a.due.compareTo(b.due));
  return (matches: matches, autoAdds: autoAdds, due: due);
}

/// A payment you make (or get) every month, worth offering as a repeat: the same payee and amount in at least
/// 3 of the last 6 months, not already a repeat, not a loan or a move between your accounts.
typedef RecurringSuggestion = ({
  String name,
  double amount,
  bool isDebit,
  int months,
  DateTime last,
  String? categoryId,
  String? accountId,
});

List<RecurringSuggestion> suggestRecurring(Iterable<Txn> txns, Iterable<Recurring> existing, DateTime now) {
  final since = DateTime(now.year, now.month - 6, now.day);
  final have = existing.map((r) => r.name.toLowerCase()).toSet();
  final groups = <String, List<Txn>>{};
  for (final t in txns) {
    if (t.txnAt.isBefore(since) || t.excluded || t.isLoanTransfer || t.amount < 50) continue;
    final key = '${t.title.toLowerCase()}|${t.isDebit}|${t.amount.toStringAsFixed(2)}';
    groups.putIfAbsent(key, () => []).add(t);
  }
  final out = <RecurringSuggestion>[];
  for (final g in groups.values) {
    final months = {for (final t in g) '${t.txnAt.year}-${t.txnAt.month}'}.length;
    if (months < 3) continue;
    // Several a month is a habit (chai, thali), not a bill.
    if (g.length > months + 1) continue;
    g.sort((a, b) => a.txnAt.compareTo(b.txnAt));
    final last = g.last;
    if (have.contains(last.title.toLowerCase())) continue;
    if (now.difference(last.txnAt).inDays > 45) continue;
    out.add((
      name: last.title,
      amount: last.amount,
      isDebit: last.isDebit,
      months: months,
      last: last.txnAt,
      categoryId: last.categoryId,
      accountId: last.accountId,
    ));
  }
  out.sort((a, b) => b.amount.compareTo(a.amount));
  return out.take(8).toList();
}
