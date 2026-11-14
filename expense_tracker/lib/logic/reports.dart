import 'package:intl/intl.dart';

import '../models.dart';
import 'summary.dart';

/// One account over a period, like a bank statement: what it started with, what came in and went out, and
/// what it ended with. Always: opening + moneyIn − moneyOut = closing.
typedef AccountStatement = ({Account account, double opening, double moneyIn, double moneyOut, double closing});

AccountStatement accountStatement(Iterable<Txn> txns, Account account, DateTime from, DateTime to) {
  final before = from.subtract(const Duration(microseconds: 1));
  final last = to.subtract(const Duration(microseconds: 1));
  final opening = balanceAt(txns, account, before);
  final closing = balanceAt(txns, account, last);
  // In and out from the same arithmetic as the balance, so the four numbers always agree.
  var moneyIn = 0.0, moneyOut = 0.0;
  for (final t in txns) {
    if (t.txnAt.isBefore(from) || !t.txnAt.isBefore(to)) continue;
    final e = effectOn(t, account);
    if (e > 0) moneyIn += e;
    if (e < 0) moneyOut -= e;
  }
  double r(double v) => (v * 100).roundToDouble() / 100;
  return (account: account, opening: r(opening), moneyIn: r(moneyIn), moneyOut: r(moneyOut), closing: r(closing));
}

/// Income and expenses for a period, by category (like a profit-and-loss account). Transfers between your
/// own accounts, friends' money and investments are left out, as everywhere else.
typedef IncomeExpense = ({
  List<MapEntry<String?, double>> income,
  List<MapEntry<String?, double>> expenses,
  double totalIncome,
  double totalExpenses,
});

IncomeExpense incomeExpense(
  Iterable<Txn> txns,
  DateTime from,
  DateTime to, {
  Set<String> notSpendingIds = const {},
  ShareTotals shares = ShareTotals.none,
}) {
  final inLines = categoryReport(txns, from, to, debits: false, notSpendingIds: notSpendingIds, shares: shares);
  final outLines = categoryReport(txns, from, to, debits: true, notSpendingIds: notSpendingIds, shares: shares);
  final income = [for (final l in inLines) MapEntry(l.id, l.total)];
  final expenses = [for (final l in outLines) MapEntry(l.id, l.total)];
  double sum(List<MapEntry<String?, double>> l) => (l.fold(0.0, (v, e) => v + e.value) * 100).roundToDouble() / 100;
  return (income: income, expenses: expenses, totalIncome: sum(income), totalExpenses: sum(expenses));
}

// --------------------------------------------------------------------------- CSV (opens in Excel / Sheets)

String _cell(Object? v) {
  final s = v == null ? '' : '$v';
  return s.contains(RegExp(r'[",\n\r]')) ? '"${s.replaceAll('"', '""')}"' : s;
}

/// Rows as CSV, with a byte-order mark so Excel reads ₹ and Indian names correctly.
String toCsv(List<List<Object?>> rows) => '﻿${rows.map((r) => r.map(_cell).join(',')).join('\r\n')}\r\n';

String _amount(double v) => v.toStringAsFixed(2);

/// Every transaction in the period: one row each, with everything known about it.
String transactionsCsv(
  Iterable<Txn> txns,
  DateTime from,
  DateTime to, {
  required String? Function(String? id) categoryName,
  required String? Function(String? id) groupName,
  required String? Function(String? id) accountName,
  ShareTotals shares = ShareTotals.none,
}) {
  final list = txns.where((t) => !t.txnAt.isBefore(from) && t.txnAt.isBefore(to)).toList()
    ..sort((a, b) => a.txnAt.compareTo(b.txnAt));
  final date = DateFormat('yyyy-MM-dd'), time = DateFormat('HH:mm');
  return toCsv([
    [
      'Date',
      'Time',
      'Account',
      'Money out',
      'Money in',
      'Your part',
      'Paid to / from',
      'Category',
      'Group',
      'Split into',
      'Note',
      'Bank details',
      'Counted',
      'From',
    ],
    for (final t in list)
      [
        date.format(t.txnAt),
        t.source == 'statement' ? '' : time.format(t.txnAt),
        accountName(t.accountId) ?? '',
        t.isDebit ? _amount(t.amount) : '',
        t.isDebit ? '' : _amount(t.amount),
        _amount(shares.own(t)),
        t.title,
        categoryName(t.categoryId) ?? '',
        groupName(t.categoryId) ?? '',
        (shares.parts[t.id] ?? const [])
            .map((p) => '${categoryName(p.categoryId) ?? 'No category'} ${_amount(p.amount)}')
            .join('; '),
        t.note ?? '',
        t.details ?? '',
        t.excluded ? 'No (between your accounts)' : 'Yes',
        switch (t.source) {
          'email' => 'Bank email',
          'statement' => 'Statement',
          _ => 'Added by you',
        },
      ],
  ]);
}

String statementsCsv(List<AccountStatement> rows, String period) => toCsv([
  ['Account statements', period],
  ['Account', 'Opening', 'Money in', 'Money out', 'Closing'],
  for (final r in rows)
    [r.account.name, _amount(r.opening), _amount(r.moneyIn), _amount(r.moneyOut), _amount(r.closing)],
]);

String incomeExpenseCsv(IncomeExpense ie, String period, String? Function(String? id) categoryName) => toCsv([
  ['Income and expenses', period],
  [],
  ['Income', 'Amount'],
  for (final e in ie.income) [categoryName(e.key) ?? 'No category', _amount(e.value)],
  ['Total income', _amount(ie.totalIncome)],
  [],
  ['Expenses', 'Amount'],
  for (final e in ie.expenses) [categoryName(e.key) ?? 'No category', _amount(e.value)],
  ['Total expenses', _amount(ie.totalExpenses)],
  [],
  [ie.totalIncome >= ie.totalExpenses ? 'Kept' : 'Spent more than came in', _amount(ie.totalIncome - ie.totalExpenses)],
]);
