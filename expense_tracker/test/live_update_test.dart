import 'package:expense_tracker/logic/duplicates.dart';
import 'package:expense_tracker/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('live updates send numbers as text: goals, repeats and openings still read', () {
    final g = Goal.fromMap({
      'id': 'g',
      'kind': 'cut',
      'name': 'Breathing',
      'starts_on': '2026-11-17',
      'category_id': 'cig',
      'cut_pct': '40.00',
      'target_amount': null,
      'archived': false,
    });
    expect(g.cutPct, 40);
    final r = Recurring.fromMap({'id': 'r', 'name': 'Rent', 'amount': '9000.00', 'starts_on': '2026-12-01'});
    expect(r.amount, 9000);
    final o = FriendOpening.fromMap({
      'id': 'o',
      'link_id': 'L',
      'as_of': '2026-11-10',
      'amount': '86.00',
      'created_by': 'me',
      'owed_by': 'me',
    });
    expect(o.amount, 86);
  });

  test('three identical entries: one "all are real" answers every pair', () {
    final d = DateTime(2026, 11, 10, 12);
    final txns = [
      for (final id in ['a', 'b', 'c'])
        Txn(id: id, amount: 800, isDebit: true, txnAt: d, merchant: 'Thali', accountId: 'h'),
    ];
    expect(suspectedDuplicates(txns).length, 3);
    final answered = {pairKey('a', 'b'), pairKey('a', 'c'), pairKey('b', 'c')};
    expect(suspectedDuplicates(txns, notDuplicates: answered), isEmpty);
  });
}
