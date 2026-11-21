import 'package:expense_tracker/logic/summary.dart';
import 'package:expense_tracker/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const fr = 'fr', food = 'food';
  Txn t(String id, double a, DateTime at, {bool debit = true, String m = 'Kiran Rao', String? cat = fr, String? paidBy}) =>
      Txn(id: id, amount: a, isDebit: debit, txnAt: at, merchant: m, categoryId: cat, paidBy: paidBy);

  // A fresh start on 10 Nov at ₹0; older money is history.
  final starts = {'kiran rao': (name: 'Kiran Rao', from: DateTime(2026, 11, 10), opening: 0.0)};
  final txns = [
    t('old', 873, DateTime(2026, 11, 4), debit: false), // history
    t('got', 1573, DateTime(2026, 11, 14), debit: false), // he sent you money: you owe him
    t('gave', 1420, DateTime(2026, 11, 15)), // you paid him back part
    t('bill', 900, DateTime(2026, 11, 16), m: 'Zomato', cat: food), // he owes his ₹300 share
    t('his', 600, DateTime(2026, 11, 17), m: 'Cafe', cat: food, paidBy: 'Kiran Rao'), // he paid for you
    t('sorted', 598, DateTime(2026, 11, 21), m: 'kiran rao', cat: null), // a payment with no category
    t('upi', 50, DateTime(2026, 11, 18), m: 'kiran5@okaxis', debit: false), // another name for him
  ];
  final shares = [TxnShare(id: 's', txnId: 'bill', person: 'Kiran Rao', amount: 300)];
  final aliases = {'kiran5@okaxis': 'Kiran Rao'};

  test('statement ends exactly at the balance; history and your own spends never count', () {
    final balance = loanBalances(txns, {fr}, shares: shares, aliases: aliases, starts: starts).single.balance;
    // 1573 − 1420 − 300 + 600 + 50 = 503 (you owe him)
    expect(balance, 503);
    final s = friendStatement('Kiran Rao', txns, {fr}, shares: shares, aliases: aliases, starts: starts);
    expect(s.map((l) => l.balance).nonNulls.first, balance);
    expect(s.firstWhere((l) => l.txn?.id == 'old').status, 'history');
    expect(s.firstWhere((l) => l.txn?.id == 'old').balance, isNull);
    expect(s.firstWhere((l) => l.txn?.id == 'sorted').status, 'notCounted');
    expect(s.firstWhere((l) => l.kind == 'opening').balance, 0);
    expect(s.firstWhere((l) => l.kind == 'share').amount, -300);
    expect(s.firstWhere((l) => l.kind == 'paidBy').amount, 600);
    // Newest first; running balance step by step (oldest to newest): 0, 1573, 153, −147, 453, 503.
    expect(s.reversed.map((l) => l.balance).nonNulls.toList(), [0, 1573, 153, -147, 453, 503]);
  });

  test('the payment with no category, once in the Friends ledger, settles it the same everywhere', () {
    final fixed = [
      for (final x in txns) x.id == 'sorted' ? t('sorted', 503, DateTime(2026, 11, 21), cat: fr) : x,
    ];
    final balance = loanBalances(fixed, {fr}, shares: shares, aliases: aliases, starts: starts).single.balance;
    expect(balance, 0);
    expect(
      friendStatement('Kiran Rao', fixed, {fr}, shares: shares, aliases: aliases, starts: starts).first.balance,
      0,
    );
  });

  test('a UPI ID ending three friends share (born in 2002) does not make them one person', () {
    Txn p(String id, String m, String vpa) =>
        Txn(id: id, amount: 10, isDebit: true, txnAt: DateTime(2026, 11, 1), merchant: m, payeeVpa: vpa);
    final txns = [
      p('1', 'Kunal Ramesh Shinde', '2002@o'),
      p('2', 'Amol Shrikant Bhosle', '2002@o'),
      p('3', 'Tanmay Rajesh Kokate', '2002@o'),
      p('4', 'Ravi Kumar', '7243@y'),
      p('5', 'Vijay Kumar', '7243@y'), // a parent's account: two names, not a year
    ];
    expect(sharedVpaTails(txns), {'2002@o'});
    expect(samePersonCandidates(txns, 'Kunal Ramesh Shinde'), isEmpty);
    expect(samePersonCandidates(txns, 'Ravi Kumar').single.name, 'Vijay Kumar');
  });
}
