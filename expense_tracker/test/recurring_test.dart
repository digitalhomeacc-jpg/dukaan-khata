import 'package:expense_tracker/logic/recurring.dart';
import 'package:expense_tracker/models.dart';
import 'package:flutter_test/flutter_test.dart';

Txn tx(String id, double amount, DateTime at, {String? merchant, bool debit = true, String? account}) =>
    Txn(id: id, amount: amount, isDebit: debit, txnAt: at, merchant: merchant, accountId: account);

void main() {
  final rent = Recurring(id: 'rent', name: 'Rent', amount: 8000, startsOn: DateTime(2026, 9, 1));
  final netflix = Recurring(id: 'nf', name: 'Netflix', amount: 649, startsOn: DateTime(2026, 8, 23));

  test('due dates keep the day, or the month\'s last day', () {
    final r = Recurring(id: 'x', name: 'X', amount: 1, startsOn: DateTime(2026, 1, 31));
    expect(
      [for (var n = 0; n < 4; n++) dueDate(r, n)],
      [DateTime(2026, 1, 31), DateTime(2026, 2, 28), DateTime(2026, 3, 31), DateTime(2026, 4, 30)],
    );
    final w = Recurring(id: 'w', name: 'W', amount: 1, startsOn: DateTime(2026, 11, 2), every: 'week');
    expect(dueDate(w, 2), DateTime(2026, 11, 16));
    final y = Recurring(id: 'y', name: 'Y', amount: 1, startsOn: DateTime(2024, 2, 29), every: 'year');
    expect(dueDate(y, 1), DateTime(2025, 2, 28));
  });

  test('a bank payment by name and amount settles its due date; a same-amount stranger does not', () {
    final txns = [
      tx('a', 649, DateTime(2026, 10, 23, 9), merchant: 'Netflix'),
      tx('b', 649, DateTime(2026, 11, 22, 21), merchant: 'Corner shop'), // same amount, not Netflix
    ];
    final plan = planRecurring([netflix], const [], txns, DateTime(2026, 11, 24));
    expect(plan.matches.map((m) => (m.txn.id, m.due)), [('a', DateTime(2026, 10, 23))]);
    // Aug and Sep are older than the look-back; Nov 23 is overdue (only offered, the shop is never picked).
    expect(plan.due.where((d) => d.state == DueState.overdue).map((d) => d.due), [DateTime(2026, 11, 23)]);
    expect(candidatesFor(netflix, DateTime(2026, 11, 23), txns, {'a'}).map((t) => t.id), ['b']);
  });

  test('a payee you confirmed once is matched by itself after that', () {
    final runs = [
      RecurringRun(id: 'r1', recurringId: 'rent', dueOn: DateTime(2026, 9, 1), kind: 'matched', txnId: 's'),
    ];
    final txns = [
      tx('s', 8000, DateTime(2026, 9, 1), merchant: 'Ramesh Kumar'),
      tx('o', 8000, DateTime(2026, 10, 2), merchant: 'Ramesh Kumar'),
      tx('p', 8000, DateTime(2026, 10, 1), merchant: 'Someone else'),
    ];
    final plan = planRecurring([rent], runs, txns, DateTime(2026, 10, 5));
    expect(plan.matches.map((m) => m.txn.id), ['o']);
  });

  test('each payment settles one due date, each due date once', () {
    final weekly = Recurring(id: 'w', name: 'Maid', amount: 500, startsOn: DateTime(2026, 11, 2), every: 'week');
    final txns = [tx('1', 500, DateTime(2026, 11, 3), merchant: 'Maid')];
    final plan = planRecurring([weekly], const [], txns, DateTime(2026, 11, 10));
    expect(plan.matches.length, 1);
    expect(plan.matches.single.due, DateTime(2026, 11, 2));
    final settled = [
      RecurringRun(id: 'x', recurringId: 'w', dueOn: DateTime(2026, 11, 2), kind: 'matched', txnId: '1'),
    ];
    final again = planRecurring([weekly], settled, txns, DateTime(2026, 11, 10));
    expect(again.matches, isEmpty);
    expect(again.due.map((d) => (d.due, d.state)), [
      (DateTime(2026, 11, 9), DueState.overdue),
      (DateTime(2026, 11, 16), DueState.upcoming),
    ]);
  });

  test('cash repeats are added on their day, once; bank ones never', () {
    final maid = Recurring(id: 'm', name: 'Maid', amount: 3000, startsOn: DateTime(2026, 10, 5), autoAdd: true);
    final plan = planRecurring([maid, rent], const [], const [], DateTime(2026, 11, 5));
    expect(plan.autoAdds.map((a) => (a.recurring.id, a.due)), [
      ('m', DateTime(2026, 10, 5)),
      ('m', DateTime(2026, 11, 5)),
    ]);
    expect(plan.due.where((d) => d.recurring.id == 'm' && d.state != DueState.upcoming), isEmpty);
    final done = [
      RecurringRun(id: '1', recurringId: 'm', dueOn: DateTime(2026, 10, 5), kind: 'added'),
      RecurringRun(id: '2', recurringId: 'm', dueOn: DateTime(2026, 11, 5), kind: 'added'),
    ];
    expect(planRecurring([maid], done, const [], DateTime(2026, 11, 5)).autoAdds, isEmpty);
  });

  test('bills that vary match by name in a range; a set account must match', () {
    final power = Recurring(
      id: 'p',
      name: 'MSEDCL electricity',
      amount: 900,
      startsOn: DateTime(2026, 11, 10),
      varies: true,
      accountId: 'hdfc',
    );
    final txns = [
      tx('x', 1240, DateTime(2026, 11, 11), merchant: 'Msedcl', account: 'slice'),
      tx('y', 1240, DateTime(2026, 11, 12), merchant: 'Msedcl', account: 'hdfc'),
    ];
    expect(planRecurring([power], const [], txns, DateTime(2026, 11, 14)).matches.single.txn.id, 'y');
  });

  test('suggestions: the same payee and amount in 3+ months, not habits', () {
    final now = DateTime(2026, 11, 20);
    final txns = [
      for (final m in [8, 9, 10, 11]) tx('n$m', 649, DateTime(2026, m, 23), merchant: 'Netflix'),
      for (final m in [8, 9, 10, 11])
        for (final d in [1, 5, 9, 14]) tx('t$m$d', 80, DateTime(2026, m, d), merchant: 'Tea stall'),
    ];
    final s = suggestRecurring(txns, const [], now);
    expect(s.map((x) => (x.name, x.amount, x.months)), [('Netflix', 649.0, 4)]);
    expect(suggestRecurring(txns, [netflix], now), isEmpty);
  });
}
