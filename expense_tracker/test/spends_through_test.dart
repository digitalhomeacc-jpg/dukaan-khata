// ignore_for_file: invalid_use_of_visible_for_testing_member
import 'package:expense_tracker/data/app_data.dart';
import 'package:expense_tracker/logic/summary.dart';
import 'package:expense_tracker/models.dart';
import 'package:expense_tracker/screens/split_section.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  final d = DateTime(2026, 11, 18, 22);
  final credit = Txn(
    id: 'in',
    amount: 500,
    isDebit: false,
    txnAt: d,
    merchant: 'Ravi Kumar',
    categoryId: 'fr',
    accountId: 'h',
  );
  final shop = Txn(
    id: 'shop',
    amount: 350,
    isDebit: true,
    txnAt: d.add(const Duration(hours: 14)),
    merchant: 'Book Depot',
    accountId: 'h',
  );

  test('their money spent for them: not your spending or income; you owe only what is left', () {
    final shares = [const TxnShare(id: 's', txnId: 'shop', person: 'Ravi Kumar', amount: 350)];
    final totals = shareTotals(shares);
    final s = summarizeBetween(
      [credit, shop],
      DateTime(2026, 11),
      DateTime(2026, 12),
      loanCategoryIds: {'fr'},
      shares: totals,
    );
    expect(s.spent, 0);
    expect(s.received, 0);
    final ravi = loanBalances([credit, shop], {'fr'}, shares: shares).firstWhere((l) => l.person == 'Ravi Kumar');
    expect(ravi.balance, 150); // you still hold ₹150 of his
  });

  testWidgets('a received payment offers what you paid for them around then', (tester) async {
    final data = AppData.preview(
      categories: const [Category(id: 'fr', name: 'Friends', icon: 'group', color: 0, isLoan: true)],
      transactions: [credit, shop],
    );
    tester.view.physicalSize = const Size(420, 1200) * 3;
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SpendsThroughSection(data: data, credit: credit),
        ),
      ),
    );
    expect(find.text('Their spends through you'), findsOneWidget);
    expect(find.textContaining('Book Depot · ₹350'), findsOneWidget);
  });
}
