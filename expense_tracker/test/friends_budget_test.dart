import 'package:expense_tracker/logic/summary.dart';
import 'package:expense_tracker/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('people vs shops', () {
    for (final n in ['Sanket Pramod Patil', 'Hiteshasva Gupta', 'Yash Bhagwant Gawali', 'Shresth Sharma']) {
      expect(looksLikePerson(n), true, reason: n);
    }
    for (final n in [
      'Hotel Vijay',
      'HP Petrol Pump Loni Bk Vivid K',
      'Bhai Pan Stall',
      'Atharva Foods',
      'Swiggy Limited',
      'Apple Media Services',
      'snkt.patil7200-1@okicici',
      'slice',
      'Zomato',
      'Om book',
      'Aayush medical and general store',
    ]) {
      expect(looksLikePerson(n), false, reason: n);
    }
  });

  test('friends: money sent and received is not spending or income; balance per friend', () {
    final txns = [
      Txn(id: '1', amount: 500, isDebit: true, txnAt: DateTime(2026, 11, 2), merchant: 'Rahul Kumar', categoryId: 'fr'),
      Txn(
        id: '2',
        amount: 200,
        isDebit: false,
        txnAt: DateTime(2026, 11, 3),
        merchant: 'Rahul Kumar',
        categoryId: 'fr',
      ),
      Txn(
        id: '3',
        amount: 300,
        isDebit: true,
        txnAt: DateTime(2026, 11, 4),
        merchant: 'Dinner',
        categoryId: 'food',
        paidBy: 'Priya',
      ),
      Txn(id: '4', amount: 100, isDebit: true, txnAt: DateTime(2026, 11, 5), merchant: 'Chai', categoryId: 'food'),
    ];
    final s = summarize(txns, DateTime(2026, 11), loanCategoryIds: {'fr'});
    expect(s.spent, 400); // chai + your share of dinner
    expect(s.received, 0);
    final b = {
      for (final l in loanBalances(txns, {'fr'})) l.person: l.balance,
    };
    expect(b['Rahul Kumar'], -300); // Rahul owes you 300
    expect(b['Priya'], 300); // you owe Priya 300
  });

  test('budget progress uses the month summary', () {
    final month = summarize([
      Txn(id: '1', amount: 1800, isDebit: true, txnAt: DateTime(2026, 11, 2), categoryId: 'food'),
      Txn(id: '2', amount: 2500, isDebit: true, txnAt: DateTime(2026, 11, 3), categoryId: 'shop'),
    ], DateTime(2026, 11));
    final p = budgetProgress(const [
      Budget(id: 'a', categoryId: 'food', amount: 2000),
      Budget(id: 'b', amount: 4000),
      Budget(id: 'c', categoryId: 'shop', amount: 2000),
    ], month);
    expect(p.first.budget.categoryId, isNull); // overall first
    expect(p.first.spent, 4300);
    expect(p.first.over, true);
    expect(p[1].budget.categoryId, 'shop'); // then most used
    expect(p[1].over, true);
    expect(p[2].close, true); // food 90%
    expect(p[2].left, 200);
  });

  test('people to review skips shops, decided names and friends-of-record', () {
    final txns = [
      Txn(
        id: '1',
        amount: 50,
        isDebit: true,
        txnAt: DateTime(2026, 11, 2),
        merchant: 'Shresth Sharma',
        source: 'email',
      ),
      Txn(
        id: '2',
        amount: 70,
        isDebit: false,
        txnAt: DateTime(2026, 11, 3),
        merchant: 'Shresth  Sharma',
        source: 'email',
      ),
      Txn(id: '3', amount: 90, isDebit: true, txnAt: DateTime(2026, 11, 3), merchant: 'Hotel Vijay', source: 'email'),
      Txn(id: '4', amount: 90, isDebit: true, txnAt: DateTime(2026, 11, 3), merchant: 'Rahul Kumar', source: 'email'),
    ];
    final p = peopleToReview(txns, decided: {'rahul kumar'});
    expect(p.single.name, 'Shresth Sharma');
    expect(p.single.count, 2);
    expect(p.single.sent, 50);
    expect(p.single.received, 70);
  });
}
