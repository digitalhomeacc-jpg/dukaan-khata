import 'package:expense_tracker/logic/summary.dart';
import 'package:expense_tracker/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final at = DateTime(2026, 11, 1);
  GroupExpense exp(String id, double amount, String by, Map<String, double> shares) =>
      GroupExpense(id: id, groupId: 'g', amount: amount, paidBy: by, at: at, shares: shares);

  test('splitEqually always adds up to the paisa', () {
    for (final total in [100.0, 1000.0, 999.99, 0.01, 1234.57]) {
      for (var n = 1; n <= 7; n++) {
        final people = [for (var i = 0; i < n; i++) 'p$i'];
        final s = splitEqually(total, people);
        final sum = s.values.fold(0, (v, x) => v + (x * 100).round());
        expect(sum, (total * 100).round(), reason: '$total / $n');
      }
    }
    expect(splitEqually(100, ['me', 'A', 'B']), {'me': 33.34, 'A': 33.33, 'B': 33.33});
  });

  test('balances sum to zero and settle-ups clear them', () {
    final members = ['Asha', 'Ravi'];
    final items = [
      exp('1', 900, 'me', {'me': 300, 'Asha': 300, 'Ravi': 300}),
      exp('2', 300, 'Asha', {'me': 100, 'Asha': 100, 'Ravi': 100}),
    ];
    final b = groupBalances(items, members);
    expect(b['me'], closeTo(500, 0.001));
    expect(b['Asha'], closeTo(-100, 0.001));
    expect(b['Ravi'], closeTo(-400, 0.001));
    expect(b.values.fold(0.0, (v, x) => v + x), closeTo(0, 0.001));

    final plan = simplifyDebts(b);
    expect(plan.length, 2);
    expect(plan.every((p) => p.to == 'me'), isTrue);

    final settled = [
      ...items,
      for (final (i, p) in plan.indexed)
        GroupExpense(id: 's$i', groupId: 'g', kind: 'settle', amount: p.amount, paidBy: p.from, paidTo: p.to, at: at),
    ];
    final after = groupBalances(settled, members);
    expect(after.values.every((v) => v.abs() < 0.005), isTrue);
    expect(simplifyDebts(after), isEmpty);
  });

  test('simplifyDebts uses at most n-1 payments and moves the exact amounts', () {
    final b = {'me': 250.0, 'A': -100.0, 'B': -75.5, 'C': -74.5, 'D': 0.0};
    final plan = simplifyDebts(b);
    expect(plan.length, lessThanOrEqualTo(3));
    final net = {...b};
    for (final p in plan) {
      net[p.from] = net[p.from]! + p.amount;
      net[p.to] = net[p.to]! - p.amount;
    }
    expect(net.values.every((v) => v.abs() < 0.005), isTrue);
  });

  test('a settle routed through one friend keeps every friend balance with you right', () {
    final members = ['Asha', 'Ravi'];
    final items = [
      exp('1', 900, 'me', {'me': 300, 'Asha': 300, 'Ravi': 300}),
      exp('2', 300, 'Asha', {'me': 100, 'Asha': 100, 'Ravi': 100}),
    ];
    // Directly: Asha owes you 300 − 100 = 200, Ravi 300. The group plan says Ravi pays you 400, Asha 100.
    final p = groupPairwise(items, members);
    expect(p, {'Asha': 200, 'Ravi': 300});
    final a = allocateSettle(pairwise: p, other: 'Ravi', toMe: true, amount: 400);
    expect(a, {'Ravi': 300, 'Asha': 100});
    final after = [
      ...items,
      GroupExpense(
        id: 's1',
        groupId: 'g',
        kind: 'settle',
        amount: 400,
        paidBy: 'Ravi',
        paidTo: 'me',
        at: at,
        shares: a,
      ),
    ];
    final p2 = groupPairwise(after, members);
    expect(p2, {'Asha': 100, 'Ravi': 0});
    final b = allocateSettle(pairwise: p2, other: 'Asha', toMe: true, amount: 100);
    final done = groupPairwise([
      ...after,
      GroupExpense(
        id: 's2',
        groupId: 'g',
        kind: 'settle',
        amount: 100,
        paidBy: 'Asha',
        paidTo: 'me',
        at: at,
        shares: b,
      ),
    ], members);
    expect(done.values.every((v) => v.abs() < 0.005), isTrue);
  });

  test('you paying through a friend clears whom you really owed', () {
    final members = ['Asha', 'Ravi'];
    final items = [
      exp('1', 300, 'Asha', {'me': 150, 'Asha': 0, 'Ravi': 150}),
      exp('2', 100, 'Ravi', {'me': 50, 'Asha': 50, 'Ravi': 0}),
    ];
    final p = groupPairwise(items, members); // you owe Asha 150, Ravi 50
    expect(p, {'Asha': -150, 'Ravi': -50});
    final a = allocateSettle(pairwise: p, other: 'Asha', toMe: false, amount: 180);
    expect(a, {'Asha': 150, 'Ravi': 30});
    expect(a.values.fold(0.0, (v, x) => v + x), 180);
    // More than anyone is owed stays with the person paid.
    expect(allocateSettle(pairwise: {'Asha': 0}, other: 'Asha', toMe: true, amount: 50), {'Asha': 50});
  });
}
