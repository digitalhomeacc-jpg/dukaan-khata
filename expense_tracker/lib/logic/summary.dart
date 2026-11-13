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
MonthSummary summarize(Iterable<Txn> txns, DateTime month,
    {Set<String> loanCategoryIds = const {}, ShareTotals shares = ShareTotals.none}) {
  var spent = 0.0, received = 0.0;
  final cat = <String?, double>{};
  final merch = <String, double>{};
  for (final t in txns) {
    if (!counts(t, loanCategoryIds) || !inMonth(t.txnAt, month)) continue;
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

/// Spending for the [count] months ending with [lastMonth], oldest first.
List<MapEntry<DateTime, double>> monthlySpend(Iterable<Txn> txns, DateTime lastMonth, int count,
    {Set<String> loanCategoryIds = const {}, ShareTotals shares = ShareTotals.none}) {
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

/// Balance of [account] after each of its transactions, by transaction id.
Map<String, double> runningBalances(Iterable<Txn> txns, Account account) {
  final mine = txns.where((t) => _effect(t, account) != 0).toList()
    ..sort((a, b) => a.txnAt.compareTo(b.txnAt));
  var bal = account.openingBalance;
  final out = <String, double>{};
  for (final t in mine) {
    bal += _effect(t, account);
    out[t.id] = _round(bal);
  }
  return out;
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
/// Unpaid shares of group payments count as money the friend owes you.
List<LoanBalance> loanBalances(Iterable<Txn> txns, Set<String> loanCategoryIds, {Iterable<TxnShare> shares = const []}) {
  final byPerson = <String, List<Txn>>{};
  final names = <String, String>{};
  final owesYou = <String, double>{};
  for (final s in shares) {
    if (s.paid) continue;
    final key = s.person.toLowerCase().trim();
    names.putIfAbsent(key, () => s.person.trim());
    owesYou[key] = (owesYou[key] ?? 0) + s.amount;
    byPerson.putIfAbsent(key, () => []);
  }
  final owedToThem = <String, double>{};
  for (final t in txns) {
    if (t.paidBy != null && t.paidBy!.trim().isNotEmpty) {
      // A friend paid for you: you owe them your share.
      final key = t.paidBy!.toLowerCase().trim();
      names.putIfAbsent(key, () => t.paidBy!.trim());
      owedToThem[key] = (owedToThem[key] ?? 0) + t.amount;
      byPerson.putIfAbsent(key, () => []);
      continue;
    }
    if (!loanCategoryIds.contains(t.categoryId)) continue;
    final key = t.title.toLowerCase().trim();
    names.putIfAbsent(key, () => t.title);
    byPerson.putIfAbsent(key, () => []).add(t);
  }
  final out = [
    for (final e in byPerson.entries)
      LoanBalance(
        names[e.key]!,
        _round(e.value.fold(0.0, (s, t) => s + (t.isDebit ? -t.amount : t.amount)) - (owesYou[e.key] ?? 0) + (owedToThem[e.key] ?? 0)),
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
List<BudgetProgress> budgetProgress(Iterable<Budget> budgets, MonthSummary month) {
  final byCat = {for (final e in month.byCategory) e.key: e.value};
  return [
    for (final b in budgets) BudgetProgress(b, _round(b.categoryId == null ? month.spent : (byCat[b.categoryId] ?? 0))),
  ]..sort((a, b) {
      if ((a.budget.categoryId == null) != (b.budget.categoryId == null)) return a.budget.categoryId == null ? -1 : 1;
      return b.share.compareTo(a.share);
    });
}

// -------------------------------------------------------------------- friends

const _businessWords = {
  'store', 'stores', 'shop', 'shoppe', 'hotel', 'restaurant', 'cafe', 'caf', 'food', 'foods', 'mart', 'medical',
  'medicals', 'pharmacy', 'chemist', 'pump', 'petrol', 'fuel', 'service', 'services', 'pvt', 'private', 'ltd', 'limited',
  'llp', 'india', 'enterprise', 'enterprises', 'traders', 'trading', 'agency', 'agencies', 'center', 'centre', 'bank',
  'general', 'kirana', 'bakery', 'bakers', 'sweets', 'sweet', 'dairy', 'stall', 'hospital', 'clinic', 'garage', 'motors',
  'auto', 'electricals', 'electronics', 'pay', 'payment', 'payments', 'technologies', 'tech', 'solutions', 'mall',
  'salon', 'studio', 'book', 'books', 'stationery', 'transport', 'travels', 'tours', 'school', 'college', 'academy',
  'gym', 'fitness', 'online', 'retail', 'wholesale', 'industries', 'corporation', 'company', 'co', 'and', '&', 'the',
  'pan', 'tea', 'juice', 'bar', 'dhaba', 'canteen', 'mess', 'kitchen', 'market', 'bazaar', 'super', 'supermarket',
  'hardware', 'textiles', 'fashion', 'collection', 'jewellers', 'opticals', 'diagnostics', 'labs', 'lab', 'insurance',
  'finance', 'capital', 'loan', 'recharge', 'broadband', 'digital', 'media', 'apple', 'google', 'amazon', 'slice',
  'swiggy', 'zomato', 'uber', 'ola', 'rapido', 'blinkit', 'zepto', 'flipkart', 'myntra', 'paytm', 'phonepe',
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
    map[key] = PayeeSummary(key, p?.name ?? m, (p?.count ?? 0) + 1,
        (p?.sent ?? 0) + (t.isDebit ? t.amount : 0), (p?.received ?? 0) + (t.isDebit ? 0 : t.amount));
  }
  return map.values.toList()..sort((a, b) => b.count.compareTo(a.count));
}
