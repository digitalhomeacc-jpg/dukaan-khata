import 'package:expense_tracker/logic/summary.dart';
import 'package:expense_tracker/models.dart';
import 'package:flutter_test/flutter_test.dart';

Txn t(String id, double amt, DateTime at, String? m, {bool debit = true, String? cat, bool excluded = false}) =>
    Txn(id: id, amount: amt, isDebit: debit, txnAt: at, merchant: m, categoryId: cat, excluded: excluded);

void main() {
  final txns = [
    t('1', 200, DateTime(2026, 1, 5), 'Hotel Vijay', cat: 'food'),
    t('2', 300, DateTime(2026, 2, 7), 'HOTEL VIJAY', cat: 'food'),
    t('3', 100, DateTime(2026, 3, 9), 'Hotel  Vijay.'),
    t('4', 500, DateTime(2026, 3, 1), 'Ravindra Annasaheb P'),
    t('5', 700, DateTime(2026, 3, 2), 'Ravindra Annasaheb Patil'),
    t('6', 50, DateTime(2026, 3, 3), 'Chai'),
    t('7', 999, DateTime(2026, 3, 3), 'Hotel Vijay', debit: false), // money received: not a place you spent at
    t('8', 999, DateTime(2026, 3, 3), 'Amazon Pay Balance', excluded: true), // top-up: not spending
    t('9', 80, DateTime(2026, 3, 4), 'Vijay Kumar', cat: 'fr'), // friend: not spending
  ];

  test('same place under different spellings and cut-short names is one group', () {
    final g = payeeGroups(txns, loanCategoryIds: {'fr'});
    expect(g.length, 3);
    final hotel = g.first;
    expect(hotel.name, 'Hotel Vijay');
    expect(hotel.count, 3);
    expect(hotel.total, 600);
    expect(hotel.average, 200);
    expect(hotel.categoryId, 'food');
    expect(hotel.byMonth.length, 3);
    expect(hotel.perMonth, 1);
    final ravindra = g.firstWhere((x) => x.key.startsWith('ravindra'));
    expect(ravindra.name, 'Ravindra Annasaheb Patil');
    expect(ravindra.count, 2);
    expect(ravindra.total, 1200);
  });

  test('period filter', () {
    final g = payeeGroups(txns, from: DateTime(2026, 3, 1), loanCategoryIds: {'fr'});
    expect(g.firstWhere((x) => x.key == 'hotel vijay').count, 1);
  });

  test('your share only for split payments', () {
    final g = payeeGroups([t('p', 900, DateTime(2026, 3, 1), 'Pizza Hut')],
        shares: shareTotals(const [TxnShare(id: 's', txnId: 'p', person: 'Rahul', amount: 600)]));
    expect(g.single.total, 300);
  });

  test('money that came back from a place (Zerodha withdrawals, refunds)', () {
    final g = payeeGroups([
      t('a', 10000, DateTime(2026, 1, 1), 'Zerodha Broking', cat: 'inv'),
      t('b', 5000, DateTime(2026, 2, 1), 'Zerodha Broking Limited Dscnb Account', cat: 'inv'),
      t('c', 12000, DateTime(2026, 3, 1), 'Zerodha Broking', debit: false, cat: 'inv'),
    ]);
    expect(g.single.count, 2);
    expect(g.single.total, 15000);
    expect(g.single.received, 12000);
    expect(g.single.net, -3000);
    expect(g.single.byMonth.length, 2);
  });

  test('investments are not spending or income', () {
    final s = summarize([
      t('a', 10000, DateTime(2026, 1, 1), 'Zerodha Broking', cat: 'inv'),
      t('b', 50, DateTime(2026, 1, 2), 'Chai'),
      t('c', 12000, DateTime(2026, 1, 3), 'Zerodha Broking', debit: false, cat: 'inv'),
    ], DateTime(2026, 1), loanCategoryIds: {'inv'});
    expect(s.spent, 50);
    expect(s.received, 0);
  });
}

