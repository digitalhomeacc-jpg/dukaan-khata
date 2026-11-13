// ignore_for_file: invalid_use_of_visible_for_testing_member
import 'package:expense_tracker/data/app_data.dart';
import 'package:expense_tracker/logic/summary.dart';
import 'package:expense_tracker/models.dart';
import 'package:expense_tracker/screens/quick_sort_screen.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  final now = DateTime.now();
  final txns = [
    for (var i = 0; i < 3; i++) Txn(id: 's$i', amount: 100.0 + i, isDebit: true, txnAt: now.subtract(Duration(days: i)), merchant: 'Siddhant Joshi'),
    Txn(id: 'd', amount: 700, isDebit: true, txnAt: now, merchant: 'Dadasaheb Khad'),
    Txn(id: 'f', amount: 50, isDebit: true, txnAt: now, merchant: 'Chai', categoryId: 'food'),
  ];

  test('unsorted payments grouped by payee, biggest group first', () {
    final u = unsortedByPayee(txns, const {});
    expect(u.map((g) => g.name).toList(), ['Siddhant Joshi', 'Dadasaheb Khad']);
    expect(u.first.txns.length, 3);
    expect(u.first.total, 303);
  });

  testWidgets('quick sort shows the biggest payee with roles and both modes', (tester) async {
    tester.view.physicalSize = const Size(360, 780) * 3;
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final data = AppData.preview(
      transactions: txns,
      categories: const [
        Category(id: 'food', name: 'Food & Dining', icon: 'restaurant', color: 0xFFFF5722),
        Category(id: 'fr', name: 'Friends', icon: 'group', color: 0xFF3F51B5, isLoan: true),
      ],
    );
    await tester.pumpWidget(MaterialApp(home: QuickSortScreen(data: data)));
    await tester.pumpAndSettle();
    expect(find.text('Siddhant Joshi'), findsOneWidget);
    expect(find.text('All 3 at once'), findsOneWidget);
    expect(find.text('Friends ledger'), findsOneWidget);
    expect(find.text('Shop / service'), findsOneWidget);
    await tester.tap(find.text('One by one'));
    await tester.pumpAndSettle();
    expect(find.text('What was it?'), findsOneWidget);
    expect(find.text('3 left'), findsOneWidget);
  });
}
