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

/// Whether a transaction counts as spending / income. Card bill payments,
/// moves between own accounts (`excluded`) and personal loans do not.
bool counts(Txn t, Set<String> loanCategoryIds) =>
    !t.excluded && !t.isLoanTransfer && !loanCategoryIds.contains(t.categoryId);

/// Totals for one month, without transfers and loans so money is not counted twice.
MonthSummary summarize(Iterable<Txn> txns, DateTime month, {Set<String> loanCategoryIds = const {}}) {
  var spent = 0.0, received = 0.0;
  final cat = <String?, double>{};
  final merch = <String, double>{};
  for (final t in txns) {
    if (!counts(t, loanCategoryIds) || !inMonth(t.txnAt, month)) continue;
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
List<MapEntry<DateTime, double>> monthlySpend(Iterable<Txn> txns, DateTime lastMonth, int count,
    {Set<String> loanCategoryIds = const {}}) {
  final first = addMonths(monthStart(lastMonth), -(count - 1));
  final totals = {for (var i = 0; i < count; i++) addMonths(first, i): 0.0};
  for (final t in txns) {
    if (!counts(t, loanCategoryIds) || !t.isDebit) continue;
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

/// Current balance of each account: opening balance + money in − money out.
/// A move between own accounts changes both sides.
Map<String, double> accountBalances(Iterable<Txn> txns, Iterable<Account> accounts) {
  final bal = {for (final a in accounts) a.id: a.openingBalance};
  for (final t in txns) {
    final signed = t.isDebit ? -t.amount : t.amount;
    if (t.accountId != null && bal.containsKey(t.accountId)) bal[t.accountId!] = bal[t.accountId]! + signed;
    if (t.excluded && t.counterAccountId != null && bal.containsKey(t.counterAccountId)) {
      bal[t.counterAccountId!] = bal[t.counterAccountId]! - signed;
    }
  }
  return bal.map((k, v) => MapEntry(k, _round(v)));
}

/// Money in and out of one account in a month (moves from other own accounts included).
({double moneyIn, double moneyOut}) accountFlow(Iterable<Txn> txns, String accountId, DateTime month) {
  var moneyIn = 0.0, moneyOut = 0.0;
  for (final t in txns) {
    if (!inMonth(t.txnAt, month)) continue;
    final here = t.accountId == accountId;
    final other = t.excluded && t.counterAccountId == accountId;
    if (!here && !other) continue;
    final incoming = here ? !t.isDebit : t.isDebit;
    if (incoming) {
      moneyIn += t.amount;
    } else {
      moneyOut += t.amount;
    }
  }
  return (moneyIn: _round(moneyIn), moneyOut: _round(moneyOut));
}

class LoanBalance {
  LoanBalance(this.person, this.balance, this.txns);

  final String person;

  /// Positive: you owe them. Negative: they owe you.
  final double balance;
  final List<Txn> txns;

  bool get settled => balance.abs() < 0.005;
}

/// Running balance per friend over all loan transactions. Received money is
/// borrowing (or being repaid); spent money is lending (or repaying).
List<LoanBalance> loanBalances(Iterable<Txn> txns, Set<String> loanCategoryIds) {
  final byPerson = <String, List<Txn>>{};
  final names = <String, String>{};
  for (final t in txns) {
    if (!loanCategoryIds.contains(t.categoryId)) continue;
    final key = t.title.toLowerCase().trim();
    names.putIfAbsent(key, () => t.title);
    byPerson.putIfAbsent(key, () => []).add(t);
  }
  final out = [
    for (final e in byPerson.entries)
      LoanBalance(
        names[e.key]!,
        _round(e.value.fold(0.0, (s, t) => s + (t.isDebit ? -t.amount : t.amount))),
        e.value..sort((a, b) => b.txnAt.compareTo(a.txnAt)),
      ),
  ];
  // Open loans first (largest first), settled ones last.
  out.sort((a, b) {
    if (a.settled != b.settled) return a.settled ? 1 : -1;
    return b.balance.abs().compareTo(a.balance.abs());
  });
  return out;
}

double _round(double v) => (v * 100).roundToDouble() / 100;

// --------------------------------------------------------------- lender loans

class LoanStatus {
  LoanStatus({
    required this.owed,
    required this.borrowed,
    required this.repaid,
    required this.emisPaid,
    required this.emisLeft,
    required this.nextDueAmount,
    required this.nextDueDate,
    required this.nextDuePaid,
    required this.owedIsEmiBased,
  });

  /// What is still to be paid back.
  final double owed;
  final double borrowed;
  final double repaid;
  final int? emisPaid;
  final int? emisLeft;
  final double? nextDueAmount;
  final DateTime? nextDueDate;

  /// The latest due amount has already been paid.
  final bool nextDuePaid;

  /// `owed` is EMIs left × EMI (includes interest), not borrowed − repaid.
  final bool owedIsEmiBased;
}

DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);

/// Next date with this day of the month on or after [from] (31 → last day of short months).
DateTime nextDueOn(int dueDay, DateTime from) {
  DateTime onMonth(int y, int m) {
    final last = DateTime(y, m + 1, 0).day;
    return DateTime(y, m, dueDay > last ? last : dueDay);
  }

  final d = _day(from);
  final thisMonth = onMonth(d.year, d.month);
  return thisMonth.isBefore(d) ? onMonth(d.year, d.month + 1) : thisMonth;
}

LoanStatus loanStatus(Loan loan, Iterable<LoanEvent> allEvents, {DateTime? now}) {
  final today = _day(now ?? DateTime.now());
  final events = allEvents.where((e) => e.loanId == loan.id).toList()..sort((a, b) => a.at.compareTo(b.at));
  var borrowed = 0.0, repaid = 0.0, sinceIn = 0.0, sinceOut = 0.0;
  var repayCount = 0;
  for (final e in events) {
    final after = loan.outstandingAt == null || e.at.isAfter(loan.outstandingAt!);
    if (e.kind == LoanEventKind.repay) {
      repaid += e.amount;
      repayCount++;
      if (after) sinceOut += e.amount;
    } else {
      borrowed += e.amount;
      if (after) sinceIn += e.amount;
    }
  }

  int? emisPaid, emisLeft;
  if (loan.kind == LoanKind.emi && loan.tenureMonths != null) {
    emisPaid = (loan.emisPaidBefore + repayCount).clamp(0, loan.tenureMonths!);
    emisLeft = loan.tenureMonths! - emisPaid;
  }

  double owed;
  var emiBased = false;
  if (loan.outstanding != null) {
    owed = loan.outstanding! + sinceIn - sinceOut;
  } else if (emisLeft != null && loan.emiAmount != null) {
    owed = emisLeft * loan.emiAmount!;
    emiBased = true;
  } else {
    owed = (loan.principal ?? 0) + borrowed - repaid;
  }
  if (owed < 0) owed = 0;

  // Next due: the lender's latest reminder, else the EMI day.
  double? dueAmount = loan.nextDueAmount;
  DateTime? dueDate = loan.nextDueDate;
  var duePaid = false;
  if (dueDate != null) {
    final windowStart = dueDate.subtract(const Duration(days: 7));
    duePaid = events.any((e) =>
        e.kind == LoanEventKind.repay && !e.at.isBefore(windowStart) && e.amount >= (dueAmount ?? 0) * 0.95);
  }
  if ((dueDate == null || duePaid) && loan.dueDay != null && loan.emiAmount != null && (emisLeft ?? 1) > 0) {
    // Already paid this month's EMI? Then the next one is next month.
    final lastRepay = events.lastWhere((e) => e.kind == LoanEventKind.repay,
        orElse: () => LoanEvent(id: '', loanId: '', kind: LoanEventKind.borrow, amount: 0, at: DateTime(2000)));
    var from = today;
    if (lastRepay.kind == LoanEventKind.repay && lastRepay.at.year == today.year && lastRepay.at.month == today.month) {
      from = DateTime(today.year, today.month + 1, 1);
    }
    dueDate = nextDueOn(loan.dueDay!, from);
    dueAmount = loan.emiAmount;
    duePaid = false;
  }
  if (owed == 0 && loan.kind == LoanKind.emi && emisLeft == 0) {
    dueDate = null;
    dueAmount = null;
  }

  return LoanStatus(
    owed: _round(owed),
    borrowed: _round(borrowed + (loan.principal ?? 0)),
    repaid: _round(repaid),
    emisPaid: emisPaid,
    emisLeft: emisLeft,
    nextDueAmount: dueAmount,
    nextDueDate: dueDate,
    nextDuePaid: duePaid,
    owedIsEmiBased: emiBased,
  );
}
