import 'package:expense_tracker/logic/goals.dart';
import 'package:expense_tracker/models.dart';
import 'package:flutter_test/flutter_test.dart';

Txn tx(String id, double amount, DateTime at, {bool debit = true, String? cat, String? account}) =>
    Txn(id: id, amount: amount, isDebit: debit, txnAt: at, merchant: id, categoryId: cat, accountId: account);

void main() {
  const food = Category(id: 'food', name: 'Food', icon: 'restaurant', color: 0);
  const snacks = Category(id: 'snacks', name: 'Snacks', icon: 'restaurant', color: 0, parentId: 'food');

  test('save by a date: money kept since the start, pace and what is needed per week', () {
    final g = Goal(
      id: 'g',
      kind: 'save',
      name: 'Trip',
      startsOn: DateTime(2026, 11, 1),
      targetAmount: 30000,
      deadline: DateTime(2027, 1, 30),
    );
    final txns = [
      tx('salary', 40000, DateTime(2026, 11, 1, 10), debit: false),
      tx('rent', 15000, DateTime(2026, 11, 3)),
      tx('old', 9999, DateTime(2026, 10, 30)), // before the goal: not counted
    ];
    final p = goalProgress(g, txns: txns, accounts: const [], categories: const [], now: DateTime(2026, 11, 15));
    expect(p.done, 25000);
    expect(p.onTrack, isTrue); // 14 of 90 days gone: ₹4,666.67 expected
    expect(p.daysLeft, 76);
    expect(p.perWeekNeeded, closeTo(5000 / (76 / 7), 0.01));
    expect(p.fraction, closeTo(25000 / 30000, 1e-9));
  });

  test('save into an account: only that account\'s growth counts', () {
    const acc = Account(id: 'sav', name: 'Savings', kind: AccountKind.bank, openingBalance: 1000);
    final g = Goal(
      id: 'g',
      kind: 'save',
      name: 'Fund',
      startsOn: DateTime(2026, 11, 1),
      targetAmount: 10000,
      deadline: DateTime(2026, 12, 31),
      accountId: 'sav',
    );
    final txns = [
      tx('in', 3000, DateTime(2026, 11, 5), debit: false, account: 'sav'),
      tx('elsewhere', 50000, DateTime(2026, 11, 5), debit: false, account: 'other'),
    ];
    final p = goalProgress(g, txns: txns, accounts: const [acc], categories: const [], now: DateTime(2026, 11, 20));
    expect(p.done, 3000);
  });

  test('cut a category by 20%: the usual month, this month against the limit, sub-categories included', () {
    final g = Goal(
      id: 'c',
      kind: 'cut',
      name: 'Less food',
      startsOn: DateTime(2026, 11, 1),
      categoryId: 'food',
      cutPct: 20,
    );
    final txns = [
      for (final m in [8, 9, 10]) tx('f$m', 5000, DateTime(2026, m, 10), cat: 'food'),
      tx('s', 1000, DateTime(2026, 11, 2), cat: 'snacks'),
      tx('f', 1000, DateTime(2026, 11, 9), cat: 'food'),
      tx('other', 7000, DateTime(2026, 11, 9), cat: 'rent'),
    ];
    final p = goalProgress(
      g,
      txns: txns,
      accounts: const [],
      categories: const [food, snacks],
      now: DateTime(2026, 11, 15),
    );
    expect(p.baseline, 5000);
    expect(p.target, 4000);
    expect(p.monthSpent, 2000);
    expect(p.expectedNow, 2000); // 15 of 30 days
    expect(p.onTrack, isTrue);
    expect(p.weekLimit, closeTo(4000 * 7 / 30, 0.01));
    expect(p.weeks.map((w) => w.value), [0, 1000, 1000]); // weeks from 26 Oct, 2 Nov, 9 Nov: newest last
  });
}
