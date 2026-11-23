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
  const ShareTotals({this.othersPart = const {}, this.paidBack = const {}, this.parts = const {}});

  /// Payment id → its split across your own categories (₹300 Groceries + ₹200 Cigarettes).
  final Map<String, List<({String? categoryId, double amount})>> parts;

  /// Payment id → friends' parts of it.
  final Map<String, double> othersPart;

  /// Received-money id → the part of it that was friends paying you back.
  final Map<String, double> paidBack;

  static const none = ShareTotals();

  /// The part of a transaction that is really yours: your share of a group payment,
  /// and nothing for money friends sent to cover their share.
  double own(Txn t) => math.max(0, t.amount - ((t.isDebit ? othersPart : paidBack)[t.id] ?? 0));

  /// Your part of a payment by category: its parts, and what is left in its own category. Always adds up
  /// to exactly [own] (parts never take more than that).
  List<({String? categoryId, double amount})> byCategory(Txn t) {
    final mine = own(t);
    final split = t.isDebit ? parts[t.id] : null;
    if (split == null || split.isEmpty) return [(categoryId: t.categoryId, amount: mine)];
    final out = <({String? categoryId, double amount})>[];
    var left = mine;
    for (final p in split) {
      final a = math.min(p.amount, left);
      if (a <= 0) break;
      out.add((categoryId: p.categoryId, amount: a));
      left -= a;
    }
    if (left > 0.004) out.add((categoryId: t.categoryId, amount: _round(left)));
    return out;
  }
}

ShareTotals shareTotals(Iterable<TxnShare> shares, {Iterable<TxnPart> parts = const []}) {
  final others = <String, double>{}, back = <String, double>{};
  for (final s in shares) {
    others[s.txnId] = (others[s.txnId] ?? 0) + s.amount;
    if (s.paidTxnId != null) back[s.paidTxnId!] = (back[s.paidTxnId!] ?? 0) + s.amount;
  }
  final split = <String, List<({String? categoryId, double amount})>>{};
  for (final p in parts) {
    (split[p.txnId] ??= []).add((categoryId: p.categoryId, amount: p.amount));
  }
  return ShareTotals(othersPart: others, paidBack: back, parts: split);
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
      for (final p in shares.byCategory(t)) {
        cat[p.categoryId] = (cat[p.categoryId] ?? 0) + p.amount;
      }
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

  /// How much of each payment is in this category (less than the payment when it is split).
  final Map<String, double> amounts = {};
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
    if (shares.own(t) <= 0) continue;
    for (final p in shares.byCategory(t)) {
      final l = lines.putIfAbsent(p.categoryId, () => CategoryLine(p.categoryId));
      l.total += p.amount;
      l.txns.add(t);
      l.amounts[t.id] = p.amount;
    }
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

/// The day the app stopped matching the bank, when it matched on an earlier day: the place to look for a
/// missing or extra entry. Null when there is no earlier matching day (then an opening balance may be off).
({DateTime day, double bank})? differenceStartedOn(
  Iterable<Txn> txns,
  Account account,
  Iterable<BalanceReading> readings,
) {
  final lastOfDay = <DateTime, BalanceReading>{};
  for (final r in readings.where((r) => r.accountId == account.id && account.counts(r.asOf))) {
    final d = DateTime(r.asOf.year, r.asOf.month, r.asOf.day);
    final cur = lastOfDay[d];
    if (cur == null || r.asOf.isAfter(cur.asOf)) lastOfDay[d] = r;
  }
  final days = lastOfDay.keys.toList()..sort();
  var matchedBefore = false;
  ({DateTime day, double bank})? start;
  for (final d in days) {
    final r = lastOfDay[d]!;
    final ok = (r.balance - appBalanceFor(txns, account, r)).abs() < 1;
    if (ok) {
      matchedBefore = true;
      start = null;
    } else if (matchedBefore && start == null) {
      start = (day: d, bank: r.balance);
    }
  }
  return start;
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
  return BalanceCheck(bank: latest.balance, app: appBalanceFor(txns, account, latest), asOf: latest.asOf);
}

/// The app's balance to compare with a bank balance. End-of-day balances (statements, daily emails: 23:59)
/// against the day's close, exactly. A balance from a payment alert during the day against its moment; but that
/// minute is often not meaningful (statement lines have no time, the app puts them at 6 am; two emails can
/// arrive in the same minute), so if the app's balance is the bank's at any point of that day they agree. A
/// payment really missing or extra never makes any point of the day match.
double appBalanceFor(Iterable<Txn> txns, Account account, BalanceReading r) {
  final d = r.asOf;
  final endOfDay = d.hour == 23 && d.minute == 59;
  final v = balanceAt(txns, account, endOfDay ? DateTime(d.year, d.month, d.day, 23, 59, 59) : d);
  // A statement's closing balance is the day's close: it must match exactly that.
  if ((r.balance - v).abs() < 1 || endOfDay) return v;
  for (final b in balancesThroughDay(txns, account, d)) {
    if ((r.balance - b).abs() < 1) return b;
  }
  return v;
}

/// The account's balance at the start of [day]'s date and after each of that day's payments, in order.
List<double> balancesThroughDay(Iterable<Txn> txns, Account account, DateTime day) {
  final start = DateTime(day.year, day.month, day.day);
  final end = start.add(const Duration(days: 1));
  var bal = balanceAt(txns, account, start.subtract(const Duration(microseconds: 1)));
  final out = [bal];
  final that = txns.where((t) => !t.txnAt.isBefore(start) && t.txnAt.isBefore(end) && _effect(t, account) != 0).toList()
    ..sort((a, b) => a.txnAt.compareTo(b.txnAt));
  for (final t in that) {
    bal = _round(bal + _effect(t, account));
    out.add(bal);
  }
  return out;
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

/// One thing that moves the balance with a friend: a Friends-ledger payment, their unpaid share of a bill you paid
/// ("share"), or a bill they paid for you ("paidBy"). [amount] is signed: positive, you owe them more.
/// [history]: before your fresh start with them (the opening balance stands in for it).
class FriendItem {
  const FriendItem({
    required this.key,
    required this.name,
    required this.at,
    required this.amount,
    required this.kind,
    this.txn,
    this.share,
    this.history = false,
  });

  final String key;
  final String name;
  final DateTime at;
  final double amount;
  final String kind;
  final Txn? txn;
  final TxnShare? share;
  final bool history;
}

/// The key a payee name counts under as a friend ("Also known as" names go to the main name).
String friendKeyOf(String name, Map<String, String> aliases) =>
    (aliases[name.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim()] ?? name.trim()).toLowerCase();

/// Everything that moves a balance with a friend, for everyone. The one source for balances and statements.
List<FriendItem> friendItems(
  Iterable<Txn> txns,
  Set<String> loanCategoryIds, {
  Iterable<TxnShare> shares = const [],
  Map<String, String> aliases = const {},
  Map<String, ({String name, DateTime from, double opening})> starts = const {},
}) {
  bool before(String key, DateTime at) {
    final s = starts[key];
    return s != null && at.isBefore(s.from);
  }

  final txnById = {for (final t in txns) t.id: t};
  String canon(String name) => aliases[name.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim()] ?? name.trim();
  final out = <FriendItem>[];
  for (final s in shares) {
    if (s.paid) continue;
    final person = canon(s.person);
    final key = person.toLowerCase();
    final shared = txnById[s.txnId];
    out.add(
      FriendItem(
        key: key,
        name: person,
        at: shared?.txnAt ?? DateTime(2000),
        amount: -s.amount,
        kind: 'share',
        txn: shared,
        share: s,
        history: shared != null && before(key, shared.txnAt),
      ),
    );
  }
  for (final t in txns) {
    if (t.paidBy != null && t.paidBy!.trim().isNotEmpty) {
      // A friend paid for you: you owe them your share.
      final person = canon(t.paidBy!);
      final key = person.toLowerCase();
      out.add(
        FriendItem(
          key: key,
          name: person,
          at: t.txnAt,
          amount: t.amount,
          kind: 'paidBy',
          txn: t,
          history: before(key, t.txnAt),
        ),
      );
      continue;
    }
    if (!loanCategoryIds.contains(t.categoryId)) continue;
    final person = canon(t.title);
    final key = person.toLowerCase();
    out.add(
      FriendItem(
        key: key,
        name: person,
        at: t.txnAt,
        amount: t.isDebit ? -t.amount : t.amount,
        kind: 'payment',
        txn: t,
        history: before(key, t.txnAt),
      ),
    );
  }
  return out;
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
  final names = <String, String>{};
  final sums = <String, double>{};
  final payments = <String, List<Txn>>{};
  for (final i in friendItems(txns, loanCategoryIds, shares: shares, aliases: aliases, starts: starts)) {
    if (i.history) continue;
    names.putIfAbsent(i.key, () => i.name);
    sums[i.key] = (sums[i.key] ?? 0) + i.amount;
    final list = payments.putIfAbsent(i.key, () => []);
    if (i.kind == 'payment') list.add(i.txn!);
  }
  for (final MapEntry(:key, :value) in starts.entries) {
    if (value.opening.abs() < 0.005 && !payments.containsKey(key)) continue;
    names.putIfAbsent(key, () => value.name);
    payments.putIfAbsent(key, () => []);
  }
  final out = [
    for (final e in payments.entries)
      LoanBalance(
        names[e.key]!,
        _round((sums[e.key] ?? 0) + (starts[e.key]?.opening ?? 0)),
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

/// One line of a friend's statement. [balance] after this line (positive: you owe them); null for history and for
/// payments that do not count (your own spends with them).
typedef FriendLine = ({
  DateTime at,
  String status, // 'counted', 'history', 'opening', 'notCounted'
  String kind, // 'payment', 'share', 'paidBy', 'opening', 'spend'
  double amount, // signed like the balance
  double? balance,
  Txn? txn,
  TxnShare? share,
});

/// A friend's statement, newest first, built from the same items as their balance: what counts and the running
/// balance (ending exactly at the balance on their page), the opening balance of a fresh start, older history,
/// and payments with them that are your own spending (shown, never counted).
List<FriendLine> friendStatement(
  String person,
  Iterable<Txn> txns,
  Set<String> loanCategoryIds, {
  Iterable<TxnShare> shares = const [],
  Map<String, String> aliases = const {},
  Map<String, ({String name, DateTime from, double opening})> starts = const {},
}) {
  final key = friendKeyOf(person, aliases);
  final start = starts[key] ?? starts[key.replaceAll(RegExp(r'\s+'), ' ')];
  final items = friendItems(
    txns,
    loanCategoryIds,
    shares: shares,
    aliases: aliases,
    starts: starts,
  ).where((i) => i.key == key).toList();
  final counted = {for (final i in items) ?i.txn?.id};
  final lines =
      <({DateTime at, String status, String kind, double amount, Txn? txn, TxnShare? share, int order})>[
        for (final i in items)
          (
            at: i.at,
            status: i.history ? 'history' : 'counted',
            kind: i.kind,
            amount: i.amount,
            txn: i.txn,
            share: i.share,
            order: 1,
          ),
        if (start != null)
          (at: start.from, status: 'opening', kind: 'opening', amount: start.opening, txn: null, share: null, order: 0),
        for (final t in txns)
          if (!counted.contains(t.id) && friendKeyOf(t.title, aliases) == key)
            (
              at: t.txnAt,
              status: 'notCounted',
              kind: 'spend',
              amount: t.isDebit ? -t.amount : t.amount,
              txn: t,
              share: null,
              order: 1,
            ),
      ]..sort((a, b) {
        final c = a.at.compareTo(b.at);
        return c != 0 ? c : a.order.compareTo(b.order);
      });
  var balance = 0.0;
  final out = <FriendLine>[];
  for (final l in lines) {
    double? after;
    if (l.status == 'opening') {
      balance = l.amount;
      after = _round(balance);
    } else if (l.status == 'counted') {
      balance += l.amount;
      after = _round(balance);
    }
    out.add((at: l.at, status: l.status, kind: l.kind, amount: l.amount, balance: after, txn: l.txn, share: l.share));
  }
  return out.reversed.toList();
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

/// Reads a repayment schedule from text, e.g. copied from a screenshot with Live Text:
/// "Due on 05 Dec '26 ₹4,940.24 Due on 05 Jan '27 ₹4,800.71…" or "05/12/2026 4940.24". Sorted by date.
List<({DateTime date, double amount})> parseSchedule(String text) {
  const months = {
    'jan': 1,
    'feb': 2,
    'mar': 3,
    'apr': 4,
    'may': 5,
    'jun': 6,
    'jul': 7,
    'aug': 8,
    'sep': 9,
    'oct': 10,
    'nov': 11,
    'dec': 12,
  };
  int year(String y) => y.length == 2 ? 2000 + int.parse(y) : int.parse(y);
  final dates = <({int at, int end, DateTime date})>[];
  for (final m in RegExp(r"(\d{1,2})(?:st|nd|rd|th)?\s*([A-Za-z]{3})[a-z]*\.?,?\s*['’]?(\d{2,4})").allMatches(text)) {
    final mo = months[m.group(2)!.toLowerCase()];
    if (mo == null) continue;
    dates.add((at: m.start, end: m.end, date: DateTime(year(m.group(3)!), mo, int.parse(m.group(1)!))));
  }
  for (final m in RegExp(r'\b(\d{1,2})[/\-.](\d{1,2})[/\-.](\d{2,4})\b').allMatches(text)) {
    final d = int.parse(m.group(1)!), mo = int.parse(m.group(2)!);
    if (mo < 1 || mo > 12 || d < 1 || d > 31) continue;
    dates.add((at: m.start, end: m.end, date: DateTime(year(m.group(3)!), mo, d)));
  }
  dates.sort((a, b) => a.at.compareTo(b.at));
  final out = <({DateTime date, double amount})>[];
  for (var i = 0; i < dates.length; i++) {
    final until = i + 1 < dates.length ? dates[i + 1].at : text.length;
    final part = text.substring(dates[i].end, until);
    final a = RegExp(
      r'(?:₹|rs\.?|inr)?\s*(\d{1,3}(?:,\d{2,3})+(?:\.\d{1,2})?|\d+\.\d{1,2}|\d{3,})',
      caseSensitive: false,
    ).firstMatch(part);
    if (a == null) continue;
    final amount = double.tryParse(a.group(1)!.replaceAll(',', ''));
    if (amount == null || amount <= 0) continue;
    out.add((date: dates[i].date, amount: amount));
  }
  out.sort((a, b) => a.date.compareTo(b.date));
  return out;
}

/// A credit line's spending power now: what the lender showed, less borrowing and spending since,
/// plus repayments since (roughly: repayments also cover interest).
double? creditLeft(Loan loan, Iterable<LoanEvent> events) {
  final base = loan.availableCredit;
  if (base == null) return null;
  var left = base;
  for (final e in events.where((e) => e.loanId == loan.id)) {
    if (loan.availableAt != null && !e.at.isAfter(loan.availableAt!)) continue;
    left += e.kind == LoanEventKind.repay ? e.amount : -e.amount;
  }
  return _round(left < 0 ? 0 : left);
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
    // The lender's own schedule, when there is one: exact dues, not estimates.
    if (loan.schedule.isNotEmpty) {
      final today = _day(now ?? DateTime.now());
      // Each scheduled EMI is paid by a repayment from 15 days before to 10 days after it (paid early or late),
      // each repayment paying one EMI. Unpaid ones from the last 45 days stay, as late.
      final repays = events.where((x) => x.loanId == loan.id && x.kind == LoanEventKind.repay).toList()
        ..sort((a, b) => a.at.compareTo(b.at));
      final used = <String>{};
      final schedule = [...loan.schedule]..sort((a, b) => a.date.compareTo(b.date));
      for (final e in schedule) {
        final due = _day(e.date);
        // The lender says the next due is later: this one is paid.
        if (loan.nextDueDate != null && due.isBefore(_day(loan.nextDueDate!))) continue;
        final paid = repays
            .where(
              (x) =>
                  !used.contains(x.id) &&
                  x.amount >= e.amount * 0.9 &&
                  !x.at.isBefore(due.subtract(const Duration(days: 15))) &&
                  x.at.isBefore(due.add(const Duration(days: 11))),
            )
            .firstOrNull;
        if (paid != null) {
          used.add(paid.id);
          continue;
        }
        if (due.isBefore(today.subtract(const Duration(days: 45)))) continue;
        out.add((date: e.date, amount: e.amount, loan: loan, estimate: false));
      }
      continue;
    }
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
/// Only what both people agreed to counts: a new entry or a changed amount waits for the other's OK
/// (the last agreed amount stands meanwhile), so a balance never moves on one person's say.
/// The balance with a connected friend (positive: you owe). With an agreed [opening]: that amount, plus only the
/// entries after its day; earlier entries (even ones a bank import adds later) are history and never count.
double sharedBalance(Iterable<SharedEntry> entries, String linkId, String me, {FriendOpening? opening}) => _round(
  (opening?.signedFor(me) ?? 0) +
      entries
          .where((e) => e.linkId == linkId && !e.gone && (opening == null || !beforeOpening(e, opening)))
          .fold(0.0, (s, e) => s + (e.debtor == me ? e.amount : (e.creditor == me ? -e.amount : 0))),
);

/// Dated on or before the opening balance's day: history only.
bool beforeOpening(SharedEntry e, FriendOpening o) {
  return !e.at.isAfter(o.cutoff);
}

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

/// UPI ID endings ("2002@o": the app keeps only the end) that different people share, so they say nothing about
/// who was paid: 3 or more full names on one ending, or 2 on an ending that is a year (born in 2002). A real UPI ID
/// has one account holder. Same rule as the database (vpa_is_shared).
Set<String> sharedVpaTails(Iterable<Txn> txns) {
  final names = <String, Set<String>>{};
  for (final t in txns) {
    final v = t.payeeVpa, m = t.merchant;
    if (v == null || m == null) continue;
    final k = m.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();
    if (!RegExp(r'^[a-z]+ [a-z]').hasMatch(k)) continue;
    (names[v] ??= {}).add(k);
  }
  final year = RegExp(r'^(19[5-9][0-9]|20[0-2][0-9])@');
  return {
    for (final MapEntry(:key, :value) in names.entries)
      if (value.length >= 3 || (value.length >= 2 && year.hasMatch(key))) key,
  };
}

/// Other names the bank may use for [person]: payees whose UPI ID carries the person's name
/// ("abhinavpandey25@okicici" under "Mukesh V Pandey", a parent's account) or that share a UPI ID with them.
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
  final shared = sharedVpaTails(txns);
  final mine = <String>{
    for (final t in txns)
      if (t.payeeVpa != null &&
          !shared.contains(t.payeeVpa) &&
          t.merchant != null &&
          sameName(_payeeKey(t.merchant!), key))
        t.payeeVpa!,
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

/// Does this payee name mean that person? Statements cut names short ("Abhinav Mukesh Pande").
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
List<LedgerLine> placeLedger(
  Iterable<Txn> txns, {
  ShareTotals shares = ShareTotals.none,
  Map<String, double>? amounts,
}) {
  final sorted = txns.toList()..sort((a, b) => a.txnAt.compareTo(b.txnAt));
  var net = 0.0;
  final out = <LedgerLine>[];
  for (final t in sorted) {
    final v = amounts?[t.id] ?? shares.own(t);
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

// ------------------------------------------------------------ name search

/// A name you have paid or got money from before, for the "Paid to" box.
class NameSuggestion {
  NameSuggestion(this.name);

  final String name;
  int count = 0;
  DateTime? last;
  double lastAmount = 0;
  bool lastWasDebit = true;
  final Map<String?, int> _cats = {};

  /// Other names that led here: the bank's name, an "also known as", a UPI ID.
  final Set<String> via = {};
  int score = 0;

  String? get usualCategoryId =>
      _cats.isEmpty ? null : (_cats.entries.toList()..sort((a, b) => b.value.compareTo(a.value))).first.key;
}

String _norm(String s) =>
    s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9@ ]'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();

/// How well [query] matches [text]: the whole thing, a word's start, anywhere, the initials ("spp"), or its
/// letters in order. 0 = no match.
int matchScore(String text, String query) {
  final t = _norm(text), q = _norm(query);
  if (q.isEmpty || t.isEmpty) return 0;
  if (t == q) return 100;
  if (t.startsWith(q)) return 80;
  final words = t.split(' ');
  if (words.any((w) => w.startsWith(q))) return 60;
  // Every word of the query starts a word of the name, in any order ("patil sanket").
  final qWords = q.split(' ');
  if (qWords.length > 1 && qWords.every((qw) => words.any((w) => w.startsWith(qw)))) return 55;
  if (t.contains(q)) return 40;
  final squashed = t.replaceAll(' ', '');
  if (squashed.contains(q.replaceAll(' ', ''))) return 35;
  final initials = words.map((w) => w.isEmpty ? '' : w[0]).join();
  if (q.length >= 2 && initials.startsWith(q)) return 30;
  // Letters in order ("htl vjy" → "hotel vijay").
  var i = 0;
  for (final c in squashed.split('')) {
    if (i < q.replaceAll(' ', '').length && c == q.replaceAll(' ', '')[i]) i++;
  }
  if (q.replaceAll(' ', '').length >= 3 && i == q.replaceAll(' ', '').length) return 10;
  return 0;
}

/// Every earlier name that matches [query] anywhere: in the name, the bank's own name for it, an "also known
/// as" name, or its UPI ID. Best matches first, then the ones you pay most.
List<NameSuggestion> nameSuggestions(
  Iterable<Txn> txns,
  String query, {
  Map<String, String> aliases = const {},
  Iterable<String> extraNames = const [],
  int limit = 12,
}) {
  if (query.trim().isEmpty) return const [];
  final byKey = <String, NameSuggestion>{};
  NameSuggestion of(String name) => byKey.putIfAbsent(_norm(name), () => NameSuggestion(name.trim()));
  for (final n in extraNames) {
    if (n.trim().isNotEmpty) of(n);
  }
  for (final t in txns) {
    final name = t.merchant?.trim();
    if (name == null || name.isEmpty) continue;
    final s = of(name);
    s.count++;
    if (s.last == null || t.txnAt.isAfter(s.last!)) {
      s.last = t.txnAt;
      s.lastAmount = t.amount;
      s.lastWasDebit = t.isDebit;
    }
    s._cats[t.categoryId] = (s._cats[t.categoryId] ?? 0) + 1;
    final alsoBank = t.bankName?.trim();
    if (alsoBank != null && alsoBank.isNotEmpty && _norm(alsoBank) != _norm(name)) s.via.add(alsoBank);
    if (t.payeeVpa != null) s.via.add('UPI ••${t.payeeVpa}');
  }
  for (final e in aliases.entries) {
    of(e.value).via.add(e.key);
  }
  final out = <NameSuggestion>[];
  for (final s in byKey.values) {
    var best = matchScore(s.name, query);
    for (final v in s.via) {
      final m = matchScore(v, query);
      if (m > 0 && m - 5 > best) best = m - 5; // found through another name: just below a direct match
    }
    if (best == 0) continue;
    s.score = best;
    out.add(s);
  }
  out.sort((a, b) => b.score != a.score ? b.score.compareTo(a.score) : b.count.compareTo(a.count));
  return out.take(limit).toList();
}

// ------------------------------------------------------------ quick entries

/// A payment you make again and again (₹800 thali, ₹20 chai): one tap to add it again.
class FrequentEntry {
  FrequentEntry(this.amount, this.isDebit, this.categoryId);

  final double amount;
  final bool isDebit;
  final String? categoryId;
  int count = 0;
  DateTime? last;
  final Map<String, int> _payees = {};
  final Map<String?, int> _accounts = {};
  final Map<String, int> _methods = {};

  String? _top<K>(Map<K, int> m) =>
      m.isEmpty ? null : (m.entries.toList()..sort((a, b) => b.value.compareTo(a.value))).first.key?.toString();
  String? get usualPayee => _top(_payees);
  String? get usualAccountId => _top(_accounts);
  String get usualMethod => _top(_methods) ?? 'upi';

  /// Everyone it went to, most often first ("Kunal, Abhinav").
  List<String> get payees =>
      (_payees.entries.toList()..sort((a, b) => b.value.compareTo(a.value))).map((e) => e.key).toList();
}

/// Same amount, same category, same direction, 3+ times in the last [days]: most used first.
List<FrequentEntry> frequentEntries(Iterable<Txn> txns, {DateTime? now, int days = 120, int limit = 8}) {
  final since = (now ?? DateTime.now()).subtract(Duration(days: days));
  final by = <String, FrequentEntry>{};
  for (final t in txns) {
    if (t.excluded || t.isLoanTransfer || t.txnAt.isBefore(since) || t.amount <= 0) continue;
    final k = '${t.isDebit}|${t.amount.toStringAsFixed(2)}|${t.categoryId}';
    final f = by.putIfAbsent(k, () => FrequentEntry(t.amount, t.isDebit, t.categoryId));
    f.count++;
    if (f.last == null || t.txnAt.isAfter(f.last!)) f.last = t.txnAt;
    if (t.merchant != null && t.merchant!.trim().isNotEmpty) {
      f._payees[t.merchant!.trim()] = (f._payees[t.merchant!.trim()] ?? 0) + 1;
    }
    f._accounts[t.accountId] = (f._accounts[t.accountId] ?? 0) + 1;
    f._methods[t.method] = (f._methods[t.method] ?? 0) + 1;
  }
  final out = by.values.where((f) => f.count >= 3).toList()
    ..sort((a, b) => b.count != a.count ? b.count.compareTo(a.count) : b.last!.compareTo(a.last!));
  return out.take(limit).toList();
}

/// Does [query] look like an amount, and does [t] have it? "800" matches ₹800 and ₹800.50; "80" does not match ₹800.
bool matchesAmount(Txn t, String query) {
  final q = query.replaceAll(RegExp(r'[₹,\s]'), '');
  if (q.isEmpty || double.tryParse(q) == null) return false;
  final whole = t.amount.truncate().toString();
  return q.contains('.') ? t.amount.toStringAsFixed(2).startsWith(q) : whole == q;
}

// ------------------------------------------------------------------ groups

/// Everyone's net in a group: positive = they are owed, negative = they owe. Always adds up to zero.
Map<String, double> groupBalances(Iterable<GroupExpense> items, List<String> members) {
  final net = {'me': 0.0, for (final m in members) m: 0.0};
  for (final e in items) {
    if (e.isSettle) {
      // The payer has paid off that much; the receiver is owed that much less.
      net[e.paidBy] = (net[e.paidBy] ?? 0) + e.amount;
      if (e.paidTo != null) net[e.paidTo!] = (net[e.paidTo!] ?? 0) - e.amount;
      continue;
    }
    net[e.paidBy] = (net[e.paidBy] ?? 0) + e.amount;
    for (final s in e.shares.entries) {
      net[s.key] = (net[s.key] ?? 0) - s.value;
    }
  }
  return {for (final e in net.entries) e.key: _round(e.value)};
}

/// The fewest payments that settle everyone: the biggest debtor pays the biggest creditor, repeat.
List<({String from, String to, double amount})> simplifyDebts(Map<String, double> balances) {
  final owe = [
    for (final e in balances.entries)
      if (e.value < -0.004) MapEntry(e.key, -e.value),
  ];
  final owed = [
    for (final e in balances.entries)
      if (e.value > 0.004) MapEntry(e.key, e.value),
  ];
  final out = <({String from, String to, double amount})>[];
  while (owe.isNotEmpty && owed.isNotEmpty) {
    owe.sort((a, b) => b.value.compareTo(a.value));
    owed.sort((a, b) => b.value.compareTo(a.value));
    final d = owe.first, c = owed.first;
    final pay = _round(math.min(d.value, c.value));
    out.add((from: d.key, to: c.key, amount: pay));
    owe[0] = MapEntry(d.key, d.value - pay);
    owed[0] = MapEntry(c.key, c.value - pay);
    owe.removeWhere((e) => e.value < 0.005);
    owed.removeWhere((e) => e.value < 0.005);
  }
  return out;
}

/// Splits [total] equally among [people], in paise, the leftover paise going to the first ones, so the parts
/// always add up to the total exactly.
Map<String, double> splitEqually(double total, List<String> people) {
  if (people.isEmpty) return const {};
  final paise = (total * 100).round();
  final base = paise ~/ people.length, extra = paise % people.length;
  return {for (final (i, p) in people.indexed) p: (base + (i < extra ? 1 : 0)) / 100};
}

/// What each member owes you directly in a group (negative: you owe them), the way your Friends ledger
/// counts it: your payments they share, their payments you share, and settle-ups as they were credited.
Map<String, double> groupPairwise(Iterable<GroupExpense> items, List<String> members) {
  final p = {for (final m in members) m: 0.0};
  void add(String who, double v) => p[who] = (p[who] ?? 0) + v;
  for (final e in items) {
    if (e.isSettle) {
      if (e.paidTo != 'me' && e.paidBy != 'me') continue;
      final sign = e.paidTo == 'me' ? -1 : 1;
      final counted = e.shares.isEmpty ? {(e.paidTo == 'me' ? e.paidBy : e.paidTo!): e.amount} : e.shares;
      for (final c in counted.entries) {
        add(c.key, sign * c.value);
      }
    } else if (e.paidBy == 'me') {
      for (final s in e.shares.entries) {
        if (s.key != 'me') add(s.key, s.value);
      }
    } else {
      add(e.paidBy, -(e.shares['me'] ?? 0));
    }
  }
  return {for (final e in p.entries) e.key: _round(e.value)};
}

/// Who a settle-up between you and [other] really counts for in your Friends ledger. When the fewest-payments
/// plan routes money through [other] (e.g. Ravi pays you what Asha owed you, because Ravi owed Asha), the
/// extra is counted for the friends whose debt it clears, so no one's balance with you shifts. Always adds up
/// to [amount]; anything beyond all debts stays with [other].
Map<String, double> allocateSettle({
  required Map<String, double> pairwise,
  required String other,
  required bool toMe,
  required double amount,
}) {
  // How much each friend's debt in this direction is: owes you (toMe) or you owe them (from you).
  double open(String m) => math.max(0, toMe ? (pairwise[m] ?? 0) : -(pairwise[m] ?? 0));
  var left = (amount * 100).round();
  final out = <String, int>{};
  final first = math.min(left, (open(other) * 100).round());
  if (first > 0) out[other] = first;
  left -= first;
  final rest = [
    for (final m in pairwise.keys)
      if (m != other && open(m) > 0.004) m,
  ]..sort((a, b) => open(b).compareTo(open(a)));
  for (final m in rest) {
    if (left <= 0) break;
    final take = math.min(left, (open(m) * 100).round());
    out[m] = take;
    left -= take;
  }
  if (left > 0) out[other] = (out[other] ?? 0) + left;
  return {for (final e in out.entries) e.key: e.value / 100};
}

/// Where a shared record with a connected friend is backed: both banks, only one, or neither (added by hand).
enum Backing { both, mine, theirs, none }

/// [inMyBank]: whether my linked payment is in a bank account (one added by hand, with no account, is not).
Backing backingOf(SharedEntry e, String me, {bool Function(String txnId)? inMyBank}) {
  var mine = e.creditor == me ? e.creditorTxn : e.debtorTxn;
  if (mine != null && inMyBank != null && !inMyBank(mine)) mine = null;
  final theirs = e.creditor == me ? e.debtorTxn : e.creditorTxn;
  if (mine != null && theirs != null) return Backing.both;
  if (mine != null) return Backing.mine;
  if (theirs != null) return Backing.theirs;
  return Backing.none;
}

/// "Check with banks" for one friend: how many counted records each bank backs, and their amounts.
Map<Backing, ({int count, double amount})> bankCheck(
  Iterable<SharedEntry> entries,
  String linkId,
  String me, {
  bool Function(String txnId)? inMyBank,
}) {
  final out = {for (final b in Backing.values) b: (count: 0, amount: 0.0)};
  for (final e in entries) {
    if (e.linkId != linkId || e.gone || e.kind == 'expense') continue;
    final b = backingOf(e, me, inMyBank: inMyBank);
    out[b] = (count: out[b]!.count + 1, amount: _round(out[b]!.amount + e.amount));
  }
  return out;
}

/// Every loan event: the stored ones, plus each payment linked to a loan that has none yet (so a loan never
/// waits for a server rule to count an EMI). An EMI the lender's own email already recorded (same amount,
/// within 5 days) is not counted twice; money borrowed counts from the day the loan was added.
List<LoanEvent> loanEventsWithPayments(List<LoanEvent> stored, Iterable<Txn> txns, Iterable<Loan> loans) {
  final have = {for (final e in stored) ?e.txnId};
  final byId = {for (final l in loans) l.id: l};
  final out = [...stored];
  for (final t in txns) {
    final loan = byId[t.loanId];
    if (loan == null || have.contains(t.id)) continue;
    final kind = switch (t.loanRole) {
      'repay' => LoanEventKind.repay,
      'borrow' => LoanEventKind.borrow,
      _ => null,
    };
    if (kind == null) continue;
    if (kind == LoanEventKind.borrow && loan.createdAt != null && t.txnAt.isBefore(loan.createdAt!)) continue;
    final inEmail = stored.any(
      (e) =>
          e.loanId == loan.id &&
          e.kind == kind &&
          e.fromEmail &&
          e.txnId == null &&
          (e.amount - t.amount).abs() < 1 &&
          e.at.difference(t.txnAt).inDays.abs() <= 5,
    );
    if (inEmail) continue;
    out.add(
      LoanEvent(
        id: 'txn:${t.id}',
        loanId: loan.id,
        kind: kind,
        amount: t.amount,
        at: t.txnAt,
        note: 'Bank payment',
        txnId: t.id,
      ),
    );
  }
  return out;
}

// ------------------------------------------------------- shared entry in my bank

/// Your bank payments that could be shared entry [e]: the same money, the right way round (you paid: money out),
/// not a loan, not left out, and not already one both banks agree on. Payments to this friend first, then the
/// nearest in time. Within a week of the entry, or at any date with [anyDate].
List<Txn> bankMatchesFor(
  SharedEntry e,
  String me,
  List<Txn> txns,
  List<SharedEntry> entries, {
  bool Function(Txn t)? isFriend,
  bool anyDate = false,
}) {
  if (e.kind == 'expense') return const [];
  final iPaid = e.creditor == me;
  final agreed = <String>{
    for (final x in entries)
      if (!x.gone && x.id != e.id && (x.kind == 'expense' || (x.creditorTxn != null && x.debtorTxn != null))) ...[
        if (x.creditorTxn != null) x.creditorTxn!,
        if (x.debtorTxn != null) x.debtorTxn!,
      ],
  };
  final out = [
    for (final t in txns)
      if (t.isDebit == iPaid &&
          (t.amount - e.amount).abs() < 0.005 &&
          !t.excluded &&
          t.loanRole == null &&
          t.paidBy == null &&
          !agreed.contains(t.id) &&
          (anyDate || t.txnAt.difference(e.at).inHours.abs() <= 7 * 24))
        t,
  ];
  int friendFirst(Txn t) => isFriend != null && isFriend(t) ? 0 : 1;
  out.sort((a, b) {
    final f = friendFirst(a).compareTo(friendFirst(b));
    if (f != 0) return f;
    return a.txnAt.difference(e.at).abs().compareTo(b.txnAt.difference(e.at).abs());
  });
  return out;
}

/// What your history with a friend adds up to at a fresh start (positive: you owed them): to compare with the
/// opening balance you set. Null without a fresh start. Changing an old entry changes this, never the opening.
double? friendHistoryTotal(
  String person,
  Iterable<Txn> txns,
  Set<String> loanCategoryIds, {
  Iterable<TxnShare> shares = const [],
  Map<String, String> aliases = const {},
  Map<String, ({String name, DateTime from, double opening})> starts = const {},
}) {
  final key = friendKeyOf(person, aliases);
  if (!starts.containsKey(key)) return null;
  final items = friendItems(txns, loanCategoryIds, shares: shares, aliases: aliases, starts: starts);
  return _round(items.where((i) => i.key == key && i.history).fold(0.0, (v, i) => v + i.amount));
}

/// The same for a connected friend: the shared entries up to the opening balance.
double sharedHistoryTotal(List<SharedEntry> entries, String linkId, String me, FriendOpening opening) => sharedBalance(
  [
    for (final e in entries)
      if (beforeOpening(e, opening)) e,
  ],
  linkId,
  me,
);

/// The other half of "lent and returned" for [t]: in the Friends ledger too, the same person (any of their names,
/// or a name the statement cut short), the same amount the other way, within 30 days; the nearest one.
Txn? roundTripPartner(
  Txn t,
  Iterable<Txn> txns,
  Set<String> loanCategoryIds, {
  Map<String, String> aliases = const {},
}) {
  if (!loanCategoryIds.contains(t.categoryId)) return null;
  final key = friendKeyOf(t.title, aliases);
  Txn? best;
  for (final x in txns) {
    if (x.id == t.id || x.isDebit == t.isDebit || !loanCategoryIds.contains(x.categoryId)) continue;
    if ((x.amount - t.amount).abs() >= 0.005 || x.txnAt.difference(t.txnAt).inSeconds.abs() > 30 * 86400) continue;
    final k = friendKeyOf(x.title, aliases);
    if (!sameName(k, key) && !sameName(key, k)) continue;
    if (best == null || x.txnAt.difference(t.txnAt).abs() < best.txnAt.difference(t.txnAt).abs()) best = x;
  }
  return best;
}
