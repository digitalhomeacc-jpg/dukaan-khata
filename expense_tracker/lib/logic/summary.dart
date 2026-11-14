import 'dart:math' as math;

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

/// How much of each payment friends cover, and which money received was a friend paying their part.
class ShareTotals {
  const ShareTotals({this.othersPart = const {}, this.paidBack = const {}});

  /// Payment id → friends' parts of it.
  final Map<String, double> othersPart;

  /// Received-money id → the part of it that was friends paying you back.
  final Map<String, double> paidBack;

  static const none = ShareTotals();

  /// The part of a transaction that is really yours: your share of a group payment,
  /// and nothing for money friends sent to cover their share.
  double own(Txn t) => math.max(0, t.amount - ((t.isDebit ? othersPart : paidBack)[t.id] ?? 0));
}

ShareTotals shareTotals(Iterable<TxnShare> shares) {
  final others = <String, double>{}, back = <String, double>{};
  for (final s in shares) {
    others[s.txnId] = (others[s.txnId] ?? 0) + s.amount;
    if (s.paidTxnId != null) back[s.paidTxnId!] = (back[s.paidTxnId!] ?? 0) + s.amount;
  }
  return ShareTotals(othersPart: others, paidBack: back);
}

/// Totals for one month, without transfers and loans so money is not counted twice.
MonthSummary summarize(
  Iterable<Txn> txns,
  DateTime month, {
  Set<String> loanCategoryIds = const {},
  ShareTotals shares = ShareTotals.none,
}) => summarizeBetween(
  txns,
  DateTime(month.year, month.month),
  DateTime(month.year, month.month + 1),
  loanCategoryIds: loanCategoryIds,
  shares: shares,
);

/// Totals from [from] up to (not including) [to].
MonthSummary summarizeBetween(
  Iterable<Txn> txns,
  DateTime from,
  DateTime to, {
  Set<String> loanCategoryIds = const {},
  ShareTotals shares = ShareTotals.none,
}) {
  var spent = 0.0, received = 0.0;
  final cat = <String?, double>{};
  final merch = <String, double>{};
  for (final t in txns) {
    if (!counts(t, loanCategoryIds) || t.txnAt.isBefore(from) || !t.txnAt.isBefore(to)) continue;
    final amount = shares.own(t);
    if (amount <= 0) continue;
    if (t.isDebit) {
      spent += amount;
      cat[t.categoryId] = (cat[t.categoryId] ?? 0) + amount;
      merch[t.title] = (merch[t.title] ?? 0) + amount;
    } else {
      received += amount;
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

/// One category over a date range: money out or in, how many payments, and which.
class CategoryLine {
  CategoryLine(this.id);

  final String? id;
  double total = 0;
  final List<Txn> txns = [];
  int get count => txns.length;
}

/// Spending ([debits] true) or money received by category from [from] up to (not including) [to],
/// leaving out transfers, friends' money and investments; friends' shares of a payment are not yours.
List<CategoryLine> categoryReport(
  Iterable<Txn> txns,
  DateTime from,
  DateTime to, {
  required bool debits,
  Set<String> notSpendingIds = const {},
  ShareTotals shares = ShareTotals.none,
}) {
  final lines = <String?, CategoryLine>{};
  for (final t in txns) {
    if (t.isDebit != debits || !counts(t, notSpendingIds)) continue;
    if (t.txnAt.isBefore(from) || !t.txnAt.isBefore(to)) continue;
    final v = shares.own(t);
    if (v <= 0) continue;
    final l = lines.putIfAbsent(t.categoryId, () => CategoryLine(t.categoryId));
    l.total += v;
    l.txns.add(t);
  }
  for (final l in lines.values) {
    l.total = _round(l.total);
    l.txns.sort((a, b) => b.txnAt.compareTo(a.txnAt));
  }
  return lines.values.toList()..sort((a, b) => b.total.compareTo(a.total));
}

/// Spending for the [count] months ending with [lastMonth], oldest first.
List<MapEntry<DateTime, double>> monthlySpend(
  Iterable<Txn> txns,
  DateTime lastMonth,
  int count, {
  Set<String> loanCategoryIds = const {},
  ShareTotals shares = ShareTotals.none,
}) {
  final first = addMonths(monthStart(lastMonth), -(count - 1));
  final totals = {for (var i = 0; i < count; i++) addMonths(first, i): 0.0};
  for (final t in txns) {
    if (!counts(t, loanCategoryIds) || !t.isDebit) continue;
    final key = monthStart(t.txnAt);
    if (totals.containsKey(key)) totals[key] = totals[key]! + shares.own(t);
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
  final byId = {for (final a in accounts) a.id: a};
  final bal = {for (final a in accounts) a.id: a.openingBalance};
  for (final t in txns) {
    final signed = t.isDebit ? -t.amount : t.amount;
    final a = byId[t.accountId];
    if (a != null && a.counts(t.txnAt)) bal[a.id] = bal[a.id]! + signed;
    final c = t.excluded ? byId[t.counterAccountId] : null;
    if (c != null && c.counts(t.txnAt)) bal[c.id] = bal[c.id]! - signed;
  }
  return bal.map((k, v) => MapEntry(k, _round(v)));
}

/// Effect of a transaction on one account's balance (0 when it doesn't touch it).
double _effect(Txn t, Account account) {
  if (!account.counts(t.txnAt)) return 0;
  final signed = t.isDebit ? -t.amount : t.amount;
  var e = 0.0;
  if (t.accountId == account.id) e += signed;
  if (t.excluded && t.counterAccountId == account.id) e -= signed;
  return e;
}

/// How a transaction moves [account]'s balance: negative for money out.
double effectOn(Txn t, Account account) => _effect(t, account);

/// Balance of [account] after each of its transactions, by transaction id.
Map<String, double> runningBalances(Iterable<Txn> txns, Account account) {
  final mine = txns.where((t) => _effect(t, account) != 0).toList()..sort((a, b) => a.txnAt.compareTo(b.txnAt));
  var bal = account.openingBalance;
  final out = <String, double>{};
  for (final t in mine) {
    bal += _effect(t, account);
    out[t.id] = _round(bal);
  }
  // Before the opening date entries don't move the balance, but their balance can be worked back from it:
  // the balance after each one is the opening balance minus what happened between it and the opening.
  final from = account.openingDate;
  if (from != null) {
    final earlier = txns.where((t) => t.txnAt.isBefore(from) && _rawEffect(t, account) != 0).toList()
      ..sort((a, b) => b.txnAt.compareTo(a.txnAt));
    var back = account.openingBalance;
    for (final t in earlier) {
      out[t.id] = _round(back);
      back -= _rawEffect(t, account);
    }
  }
  return out;
}

double _rawEffect(Txn t, Account account) {
  final signed = t.isDebit ? -t.amount : t.amount;
  var e = 0.0;
  if (t.accountId == account.id) e += signed;
  if (t.excluded && t.counterAccountId == account.id) e -= signed;
  return e;
}

/// The app's balance for [account] at [time].
double balanceAt(Iterable<Txn> txns, Account account, DateTime time) {
  var bal = account.openingBalance;
  for (final t in txns) {
    if (!t.txnAt.isAfter(time)) bal += _effect(t, account);
  }
  return _round(bal);
}

class BalanceCheck {
  BalanceCheck({required this.bank, required this.app, required this.asOf});

  final double bank;
  final double app;
  final DateTime asOf;

  /// Bank minus app: more than zero means money came in that the app doesn't know about.
  double get difference => _round(bank - app);
  bool get matches => difference.abs() < 1;
}

/// Compares the latest balance the bank told us with the app's balance at that moment.
BalanceCheck? checkBalance(Iterable<Txn> txns, Account account, Iterable<BalanceReading> readings) {
  BalanceReading? latest;
  for (final r in readings) {
    if (r.accountId == account.id && (latest == null || r.asOf.isAfter(latest.asOf))) latest = r;
  }
  if (latest == null) return null;
  return BalanceCheck(bank: latest.balance, app: balanceAt(txns, account, latest.asOf), asOf: latest.asOf);
}

/// Money in and out of one account in a month (moves from other own accounts included).
({double moneyIn, double moneyOut}) accountFlow(Iterable<Txn> txns, String accountId, DateTime month) =>
    accountFlowBetween(txns, accountId, DateTime(month.year, month.month), DateTime(month.year, month.month + 1));

({double moneyIn, double moneyOut}) accountFlowBetween(
  Iterable<Txn> txns,
  String accountId,
  DateTime from,
  DateTime to,
) {
  var moneyIn = 0.0, moneyOut = 0.0;
  for (final t in txns) {
    if (t.txnAt.isBefore(from) || !t.txnAt.isBefore(to)) continue;
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
/// Unpaid shares of group payments count as money the friend owes you.
List<LoanBalance> loanBalances(
  Iterable<Txn> txns,
  Set<String> loanCategoryIds, {
  Iterable<TxnShare> shares = const [],
  Map<String, String> aliases = const {},
  Map<String, ({String name, DateTime from, double opening})> starts = const {},
}) {
  // A fresh start: entries before it are history; the opening balance stands in for them.
  bool before(String key, DateTime at) {
    final s = starts[key];
    return s != null && at.isBefore(s.from);
  }

  final txnById = {for (final t in txns) t.id: t};
  // "Also known as": a payee name (e.g. a parent's account) counts as that friend.
  String canon(String name) => aliases[name.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim()] ?? name.trim();
  final byPerson = <String, List<Txn>>{};
  final names = <String, String>{};
  final owesYou = <String, double>{};
  for (final s in shares) {
    if (s.paid) continue;
    final person = canon(s.person);
    final key = person.toLowerCase();
    final shared = txnById[s.txnId];
    if (shared != null && before(key, shared.txnAt)) continue;
    names.putIfAbsent(key, () => person);
    owesYou[key] = (owesYou[key] ?? 0) + s.amount;
    byPerson.putIfAbsent(key, () => []);
  }
  final owedToThem = <String, double>{};
  for (final t in txns) {
    if (t.paidBy != null && t.paidBy!.trim().isNotEmpty) {
      // A friend paid for you: you owe them your share.
      final person = canon(t.paidBy!);
      final key = person.toLowerCase();
      if (before(key, t.txnAt)) continue;
      names.putIfAbsent(key, () => person);
      owedToThem[key] = (owedToThem[key] ?? 0) + t.amount;
      byPerson.putIfAbsent(key, () => []);
      continue;
    }
    if (!loanCategoryIds.contains(t.categoryId)) continue;
    final person = canon(t.title);
    final key = person.toLowerCase();
    if (before(key, t.txnAt)) continue;
    names.putIfAbsent(key, () => person);
    byPerson.putIfAbsent(key, () => []).add(t);
  }
  for (final MapEntry(:key, :value) in starts.entries) {
    if (value.opening.abs() < 0.005 && !byPerson.containsKey(key)) continue;
    names.putIfAbsent(key, () => value.name);
    byPerson.putIfAbsent(key, () => []);
  }
  final out = [
    for (final e in byPerson.entries)
      LoanBalance(
        names[e.key]!,
        _round(
          e.value.fold(0.0, (s, t) => s + (t.isDebit ? -t.amount : t.amount)) -
              (owesYou[e.key] ?? 0) +
              (owedToThem[e.key] ?? 0) +
              (starts[e.key]?.opening ?? 0),
        ),
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

/// Loan dues coming up, by date: each loan's next due, then its later EMIs (one a month) where known.
List<({DateTime date, double amount, Loan loan, bool estimate})> upcomingDues(
  Iterable<Loan> loans,
  Iterable<LoanEvent> events, {
  int months = 12,
  DateTime? now,
}) {
  final out = <({DateTime date, double amount, Loan loan, bool estimate})>[];
  for (final loan in loans.where((l) => !l.closed)) {
    final s = loanStatus(loan, events, now: now);
    final first = s.nextDueDate;
    if (first == null || s.nextDueAmount == null || s.owed <= 0) continue;
    var left = s.owed;
    if (!s.nextDuePaid) {
      out.add((date: first, amount: s.nextDueAmount!, loan: loan, estimate: false));
      left -= s.nextDueAmount!;
    }
    // Later months: the EMI, never more than what is still owed.
    final emi = loan.emiAmount;
    if (emi == null || emi <= 0) continue;
    var count = s.emisLeft == null ? months : s.emisLeft! - (s.nextDuePaid ? 0 : 1);
    for (var k = 1; k <= months && count > 0 && left > 0.5; k++, count--) {
      final amount = left < emi ? left : emi;
      out.add((
        date: DateTime(first.year, first.month + k, first.day),
        amount: _round(amount),
        loan: loan,
        estimate: true,
      ));
      left -= amount;
    }
  }
  return out..sort((a, b) => a.date.compareTo(b.date));
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
      // Payments before the loan was added are already in emisPaidBefore.
      if (loan.createdAt == null || e.at.isAfter(loan.createdAt!)) repayCount++;
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
    duePaid = events.any(
      (e) => e.kind == LoanEventKind.repay && !e.at.isBefore(windowStart) && e.amount >= (dueAmount ?? 0) * 0.95,
    );
  }
  if ((dueDate == null || duePaid) && loan.dueDay != null && loan.emiAmount != null && (emisLeft ?? 1) > 0) {
    // Already paid this month's EMI? Then the next one is next month.
    final lastRepay = events.lastWhere(
      (e) => e.kind == LoanEventKind.repay,
      orElse: () => LoanEvent(id: '', loanId: '', kind: LoanEventKind.borrow, amount: 0, at: DateTime(2000)),
    );
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

// -------------------------------------------------------------------- budgets

class BudgetProgress {
  BudgetProgress(this.budget, this.spent);

  final Budget budget;
  final double spent;

  double get left => budget.amount - spent;
  double get share => budget.amount == 0 ? 0 : spent / budget.amount;
  bool get over => spent > budget.amount;

  /// 80% or more used.
  bool get close => !over && share >= 0.8;
}

/// How much of each budget the month's spending (your share only) has used.
/// A group's budget covers the categories in it ([parentOf]: category → its group).
List<BudgetProgress> budgetProgress(
  Iterable<Budget> budgets,
  MonthSummary month, {
  Map<String, String?> parentOf = const {},
}) {
  final byCat = {for (final e in month.byCategory) e.key: e.value};
  double spentIn(String id) =>
      (byCat[id] ?? 0) +
      byCat.entries.where((e) => e.key != null && parentOf[e.key] == id).fold(0.0, (s, e) => s + e.value);
  return [
    for (final b in budgets) BudgetProgress(b, _round(b.categoryId == null ? month.spent : spentIn(b.categoryId!))),
  ]..sort((a, b) {
    if ((a.budget.categoryId == null) != (b.budget.categoryId == null)) return a.budget.categoryId == null ? -1 : 1;
    return b.share.compareTo(a.share);
  });
}

// -------------------------------------------------------------------- friends

const _businessWords = {
  'store',
  'stores',
  'shop',
  'shoppe',
  'hotel',
  'restaurant',
  'cafe',
  'caf',
  'food',
  'foods',
  'mart',
  'medical',
  'medicals',
  'pharmacy',
  'chemist',
  'pump',
  'petrol',
  'fuel',
  'service',
  'services',
  'pvt',
  'private',
  'ltd',
  'limited',
  'llp',
  'india',
  'enterprise',
  'enterprises',
  'traders',
  'trading',
  'agency',
  'agencies',
  'center',
  'centre',
  'bank',
  'general',
  'kirana',
  'bakery',
  'bakers',
  'sweets',
  'sweet',
  'dairy',
  'stall',
  'hospital',
  'clinic',
  'garage',
  'motors',
  'auto',
  'electricals',
  'electronics',
  'pay',
  'payment',
  'payments',
  'technologies',
  'tech',
  'solutions',
  'mall',
  'salon',
  'studio',
  'book',
  'books',
  'stationery',
  'transport',
  'travels',
  'tours',
  'school',
  'college',
  'academy',
  'gym',
  'fitness',
  'online',
  'retail',
  'wholesale',
  'industries',
  'corporation',
  'company',
  'co',
  'and',
  '&',
  'the',
  'pan',
  'tea',
  'juice',
  'bar',
  'dhaba',
  'canteen',
  'mess',
  'kitchen',
  'market',
  'bazaar',
  'super',
  'supermarket',
  'hardware',
  'textiles',
  'fashion',
  'collection',
  'jewellers',
  'opticals',
  'diagnostics',
  'labs',
  'lab',
  'insurance',
  'finance',
  'capital',
  'loan',
  'recharge',
  'broadband',
  'digital',
  'media',
  'apple',
  'google',
  'amazon',
  'slice',
  'swiggy',
  'zomato',
  'uber',
  'ola',
  'rapido',
  'blinkit',
  'zepto',
  'flipkart',
  'myntra',
  'paytm',
  'phonepe',
};

/// "Sanket Pramod Patil" → true; "Hotel Vijay", "HP Petrol Pump", "abc@ybl" → false.
bool looksLikePerson(String? name) {
  final n = name?.trim() ?? '';
  if (n.isEmpty || n.contains('@') || RegExp(r'\d').hasMatch(n)) return false;
  final words = n.toLowerCase().split(RegExp(r'\s+'));
  if (words.length < 2 || words.length > 4) return false;
  for (final w in words) {
    final clean = w.replaceAll('.', '');
    if (!RegExp(r'^[a-z]+$').hasMatch(clean)) return false;
    if (_businessWords.contains(clean)) return false;
  }
  return true;
}

class PayeeSummary {
  PayeeSummary(this.key, this.name, this.count, this.sent, this.received);

  final String key;
  final String name;
  final int count;
  final double sent;
  final double received;
}

/// People you paid or got money from that are not yet marked (friend or not), most frequent first.
List<PayeeSummary> peopleToReview(Iterable<Txn> txns, {Set<String> decided = const {}}) {
  final map = <String, PayeeSummary>{};
  for (final t in txns) {
    // Only bank payments: names typed by hand ("Pizza night") are not payees.
    if (!t.fromEmail || t.excluded || t.isLoanTransfer || t.paidBy != null) continue;
    final m = t.merchant?.trim();
    if (!looksLikePerson(m)) continue;
    final key = m!.toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
    if (decided.contains(key)) continue;
    final p = map[key];
    map[key] = PayeeSummary(
      key,
      p?.name ?? m,
      (p?.count ?? 0) + 1,
      (p?.sent ?? 0) + (t.isDebit ? t.amount : 0),
      (p?.received ?? 0) + (t.isDebit ? 0 : t.amount),
    );
  }
  return map.values.toList()..sort((a, b) => b.count.compareTo(a.count));
}

/// Balance with a connected friend from the shared record: positive = you owe them.
double sharedBalance(Iterable<SharedEntry> entries, String linkId, String me) => _round(
  entries
      .where((e) => e.linkId == linkId && !e.deleted)
      .fold(0.0, (s, e) => s + (e.debtor == me ? e.amount : (e.creditor == me ? -e.amount : 0))),
);

// --------------------------------------------------------------------- places

class PayeeGroup {
  PayeeGroup(this.key);

  final String key;
  final Set<String> keys = {};

  /// Its UPI IDs (shortened); null when the payments did not show one.
  final Set<String> vpas = {};
  final List<Txn> txns = [];
  final Map<String, int> _names = {};
  final Map<String?, int> _cats = {};

  /// Money paid to this place.
  double total = 0;

  /// Money that came back from it (refunds, withdrawals from an investment account).
  double received = 0;
  int receivedCount = 0;

  /// Money in minus money out: negative means it cost you.
  double get net => _round(received - total);

  /// Number of payments made to it.
  int get count => txns.where((t) => t.isDebit).length;

  /// The different ways the bank wrote this place's name.
  List<String> get spellings => _names.keys.toList();
  double get average => count == 0 ? 0 : _round(total / count);
  DateTime get first => txns.map((t) => t.txnAt).reduce((a, b) => a.isBefore(b) ? a : b);
  DateTime get last => txns.map((t) => t.txnAt).reduce((a, b) => a.isAfter(b) ? a : b);

  /// The last payment to it, or the last money from it when you never paid it.
  DateTime get lastPaid {
    final paid = txns.where((t) => t.isDebit).map((t) => t.txnAt);
    return paid.isEmpty ? last : paid.reduce((a, b) => a.isAfter(b) ? a : b);
  }

  /// The name used most often; on a tie the normally written one, then the longest
  /// (statements write names in capitals and cut them short).
  String get name {
    int caps(String s) => s == s.toUpperCase() ? 1 : 0;
    return (_names.entries.toList()..sort((a, b) {
          if (a.value != b.value) return b.value.compareTo(a.value);
          if (caps(a.key) != caps(b.key)) return caps(a.key).compareTo(caps(b.key));
          return b.key.length.compareTo(a.key.length);
        }))
        .first
        .key;
  }

  /// The category most of its payments have.
  String? get categoryId => (_cats.entries.toList()..sort((a, b) => b.value.compareTo(a.value))).first.key;

  /// Spending per month, oldest first.
  List<MapEntry<DateTime, double>> get byMonth {
    final m = <DateTime, double>{};
    for (final t in txns.where((t) => t.isDebit)) {
      final k = monthStart(t.txnAt);
      m[k] = (m[k] ?? 0) + t.amount;
    }
    return m.entries.map((e) => MapEntry(e.key, _round(e.value))).toList()..sort((a, b) => a.key.compareTo(b.key));
  }

  /// Visits per month over the time between the first and last visit (at least one month).
  double get perMonth {
    final paid = txns.where((t) => t.isDebit).map((t) => t.txnAt).toList();
    if (paid.isEmpty) return 0;
    final a = paid.reduce((x, y) => x.isBefore(y) ? x : y), b = paid.reduce((x, y) => x.isAfter(y) ? x : y);
    return paid.length / ((b.year - a.year) * 12 + b.month - a.month + 1);
  }
}

String _payeeKey(String s) =>
    s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9 ]'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();

/// Other names the bank may use for [person]: payees whose UPI ID carries the person's name
/// ("vaibhavparmar25@okicici" under "Chetan V Parmar", a parent's account) or that share a UPI ID with them.
List<({String name, int count, double out, double into, String why})> samePersonCandidates(
  Iterable<Txn> txns,
  String person, {
  Set<String> skip = const {},
}) {
  String letters(String s) => s.toLowerCase().replaceAll(RegExp(r'[^a-z]'), '');
  final words = person.toLowerCase().split(RegExp(r'\s+')).map(letters).where((w) => w.length >= 3).toList();
  if (words.length < 2) return const [];
  final key = person.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();
  final vpaRe = RegExp(r'([A-Za-z0-9._\-]{3,})@[A-Za-z]{2,}');
  final mine = <String>{
    for (final t in txns)
      if (t.payeeVpa != null && t.merchant != null && sameName(_payeeKey(t.merchant!), key)) t.payeeVpa!,
  };
  // Which names, and why.
  final why = <String, String>{};
  for (final t in txns) {
    final name = t.merchant?.trim();
    if (name == null || name.isEmpty) continue;
    final k = name.toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
    if (why.containsKey(k) || sameName(_payeeKey(name), key) || skip.contains(k)) continue;
    for (final m in vpaRe.allMatches('${t.details ?? ''} ${t.emailBody ?? ''}')) {
      final local = letters(m.group(1)!);
      if (local.contains(words.first) && local.contains(words.last)) {
        why[k] = 'pays from ${m.group(0)!.toLowerCase()}';
        break;
      }
    }
    if (!why.containsKey(k) && t.payeeVpa != null && mine.contains(t.payeeVpa)) why[k] = 'same UPI ID ••${t.payeeVpa}';
  }
  // All their payments.
  final found = <String, ({String name, int count, double out, double into, String why})>{};
  for (final t in txns) {
    final k = t.merchant?.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
    if (k == null || !why.containsKey(k)) continue;
    final prev = found[k];
    found[k] = (
      name: prev?.name ?? t.merchant!.trim(),
      count: (prev?.count ?? 0) + 1,
      out: (prev?.out ?? 0) + (t.isDebit ? t.amount : 0),
      into: (prev?.into ?? 0) + (t.isDebit ? 0 : t.amount),
      why: why[k]!,
    );
  }
  return found.values.toList()..sort((a, b) => b.count.compareTo(a.count));
}

/// Does this payee name mean that person? Statements cut names short ("Vaibhav Chetan Parma").
bool sameName(String payeeKey, String personKey) =>
    payeeKey == personKey ||
    payeeKey.startsWith('$personKey ') ||
    (payeeKey.length >= 12 && personKey.startsWith(payeeKey));

/// Money grouped by where it went (and what came back from there): same payee under
/// different spellings, a name a statement cut short, or another name for a friend all
/// count as one place. Only places you paid are listed.
List<PayeeGroup> payeeGroups(
  Iterable<Txn> txns, {
  DateTime? from,
  Set<String> loanCategoryIds = const {},
  ShareTotals shares = ShareTotals.none,
  Map<String, String> aliases = const {},
  bool withMoneyInOnly = false,
}) {
  final rows = <(Txn, String, double)>[];
  for (final t in txns) {
    if (!counts(t, loanCategoryIds) || (from != null && t.txnAt.isBefore(from))) continue;
    final name = t.merchant?.trim();
    if (name == null || name.isEmpty) continue;
    final own = shares.own(t);
    if (own <= 0) continue;
    final aka = aliases[name.toLowerCase().replaceAll(RegExp(r'\s+'), ' ')];
    rows.add((t, _payeeKey(aka ?? name), own));
    // Same name but a different UPI ID is a different place (a nashta centre and a restaurant).
  }
  // A short key that starts a longer one is the same payee ("ravindra annasaheb p" → "ravindra annasaheb patil").
  final keys = rows.map((r) => r.$2).toSet().toList()..sort((a, b) => b.length.compareTo(a.length));
  final canon = <String, String>{};
  for (final k in keys) {
    canon[k] = k;
    if (k.length < 10) continue;
    for (final longer in keys) {
      if (longer.length > k.length && longer.startsWith(k)) {
        canon[k] = canon[longer] ?? longer;
        break;
      }
    }
  }
  // Names that came with more than one UPI ID are split by it; payments without one join
  // the busiest UPI ID of that name.
  final vpasOf = <String, Map<String, int>>{};
  for (final (t, k, _) in rows) {
    if (t.payeeVpa != null) (vpasOf[canon[k]!] ??= {})[t.payeeVpa!] = ((vpasOf[canon[k]!] ?? {})[t.payeeVpa!] ?? 0) + 1;
  }
  // Written exactly the same on every UPI ID (e.g. you renamed them all "Bhai Pan Stall"): one place.
  // Different spellings ("Hotel Vijay" and "HOTEL VIJAY") on different UPI IDs stay apart.
  final spellingsOf = <String, Set<String>>{};
  for (final (t, k, _) in rows) {
    (spellingsOf[canon[k]!] ??= {}).add(t.merchant!.trim().replaceAll(RegExp(r'\s+'), ' '));
  }
  String groupKey(Txn t, String k) {
    final c = canon[k]!, seen = vpasOf[c];
    // A person pays from several UPI IDs and stays one; only businesses are split by UPI ID.
    if (seen == null || seen.length < 2 || looksLikePerson(t.merchant)) return c;
    if (spellingsOf[c]!.length < 2) return c;
    final v = t.payeeVpa ?? (seen.entries.toList()..sort((a, b) => b.value.compareTo(a.value))).first.key;
    return '$c|$v';
  }

  final groups = <String, PayeeGroup>{};
  for (final (t, k, own) in rows) {
    final gk = groupKey(t, k);
    final g = groups.putIfAbsent(gk, () => PayeeGroup(gk));
    if (t.payeeVpa != null) g.vpas.add(t.payeeVpa!);
    g.keys.add(t.merchant!.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim());
    g.txns.add(t);
    if (t.isDebit) {
      g.total += own;
    } else {
      g.received += own;
      g.receivedCount++;
    }
    final shown = t.merchant!.replaceAll(RegExp(r'\s+'), ' ').replaceAll(RegExp(r'[\s.,;:-]+$'), '').trim();
    g._names[shown] = (g._names[shown] ?? 0) + 1;
    g._cats[t.categoryId] = (g._cats[t.categoryId] ?? 0) + 1;
  }
  for (final g in groups.values) {
    g.total = _round(g.total);
    g.received = _round(g.received);
    g.txns.sort((a, b) => b.txnAt.compareTo(a.txnAt));
  }
  return groups.values.where((g) => withMoneyInOnly || g.count > 0).toList()
    ..sort((a, b) => b.count != a.count ? b.count.compareTo(a.count) : b.total.compareTo(a.total));
}

// ------------------------------------------------------------ category groups

/// Spending per category rolled up into its group: group id → (total, children with their totals).
List<({String? id, double total, List<MapEntry<String?, double>> children})> rollUp(
  List<MapEntry<String?, double>> byCategory,
  Map<String, String?> parentOf,
) {
  final groups = <String?, ({double total, Map<String?, double> kids})>{};
  for (final e in byCategory) {
    final parent = e.key == null ? null : parentOf[e.key];
    final gid = parent ?? e.key;
    final g = groups[gid] ?? (total: 0.0, kids: <String?, double>{});
    final kids = {...g.kids};
    if (parent != null) kids[e.key] = (kids[e.key] ?? 0) + e.value;
    groups[gid] = (total: g.total + e.value, kids: kids);
  }
  final out = [
    for (final e in groups.entries)
      (
        id: e.key,
        total: _round(e.value.total),
        children: e.value.kids.entries.toList()..sort((a, b) => b.value.compareTo(a.value)),
      ),
  ]..sort((a, b) => b.total.compareTo(a.total));
  return out;
}

// --------------------------------------------------------------- place ledger

/// One line of a place's ledger: money out or in, and the running net after it (in − out).
typedef LedgerLine = ({Txn txn, double out, double into, double net});

/// A place's or person's payments as a statement, newest first, with the running net.
List<LedgerLine> placeLedger(Iterable<Txn> txns, {ShareTotals shares = ShareTotals.none}) {
  final sorted = txns.toList()..sort((a, b) => a.txnAt.compareTo(b.txnAt));
  var net = 0.0;
  final out = <LedgerLine>[];
  for (final t in sorted) {
    final v = shares.own(t);
    net += t.isDebit ? -v : v;
    out.add((txn: t, out: t.isDebit ? v : 0, into: t.isDebit ? 0 : v, net: _round(net)));
  }
  return out.reversed.toList();
}

// ----------------------------------------------------------------- quick sort

/// Payments with no category, grouped by payee, biggest groups first: sort one payee at a time.
List<({String name, List<Txn> txns, double total})> unsortedByPayee(Iterable<Txn> txns, Set<String> notSpendingIds) {
  final groups = <String, List<Txn>>{};
  final names = <String, String>{};
  for (final t in txns) {
    if (t.categoryId != null || t.excluded || t.isLoanTransfer || notSpendingIds.contains(t.categoryId)) continue;
    final name = t.merchant?.trim();
    final key = name == null || name.isEmpty ? '' : _payeeKey(name);
    names.putIfAbsent(key, () => name == null || name.isEmpty ? 'No name' : name);
    (groups[key] ??= []).add(t);
  }
  final out =
      [
        for (final e in groups.entries)
          (
            name: names[e.key]!,
            txns: e.value..sort((a, b) => b.txnAt.compareTo(a.txnAt)),
            total: _round(e.value.fold(0.0, (s, t) => s + t.amount)),
          ),
      ]..sort(
        (a, b) => b.txns.length != a.txns.length ? b.txns.length.compareTo(a.txns.length) : b.total.compareTo(a.total),
      );
  return out;
}
