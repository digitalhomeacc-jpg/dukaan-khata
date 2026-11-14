// ignore_for_file: invalid_use_of_visible_for_testing_member
import 'package:expense_tracker/data/app_data.dart';
import 'package:expense_tracker/logic/summary.dart';
import 'package:expense_tracker/models.dart';
import 'package:expense_tracker/screens/insights_screen.dart';
import 'package:expense_tracker/screens/places_screen.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  testWidgets('places: "To sort" shows only places with payments that have no category', (tester) async {
    final now = DateTime.now();
    final data = AppData.preview(
      categories: const [Category(id: 'f', name: 'Food & Dining', icon: 'restaurant', color: 0xFFFF5722)],
      transactions: [
        Txn(id: '1', amount: 100, isDebit: true, txnAt: now, merchant: 'Cafe One', categoryId: 'f'),
        Txn(id: '2', amount: 80, isDebit: true, txnAt: now, merchant: 'Pan Stall'),
        Txn(id: '3', amount: 60, isDebit: true, txnAt: now, merchant: 'Pan Stall'),
      ],
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: PlacesView(data: data)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Cafe One'), findsOneWidget);
    await tester.tap(find.text('To sort (1)'));
    await tester.pumpAndSettle();
    expect(find.text('Cafe One'), findsNothing);
    expect(find.text('Pan Stall'), findsOneWidget);
    expect(find.textContaining('2 to sort'), findsOneWidget);
  });

  test('a place renamed the same on several UPI IDs is one place', () {
    final now = DateTime.now();
    final groups = payeeGroups([
      for (final (i, v) in const ['6835@y', '8806@y', '7506@y', '1611@y'].indexed)
        Txn(id: '$i', amount: 50, isDebit: true, txnAt: now, merchant: 'Bhai Pan Stall', payeeVpa: v),
    ]);
    expect(groups, hasLength(1));
    expect(groups.single.count, 4);
    expect(groups.single.vpas, hasLength(4));
  });

  testWidgets('Insights → Places groups repeated payees; a place shows its details', (tester) async {
    tester.view.physicalSize = const Size(360, 780) * 3;
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final now = DateTime.now();
    final data = AppData.preview(
      categories: const [Category(id: 'f', name: 'Food & Dining', icon: 'restaurant', color: 0xFFFF5722)],
      transactions: [
        for (var i = 0; i < 5; i++)
          Txn(
            id: 'h$i',
            amount: 200,
            isDebit: true,
            txnAt: now.subtract(Duration(days: i * 6)),
            merchant: i.isEven ? 'Hotel Vijay' : 'HOTEL VIJAY',
            categoryId: 'f',
          ),
        Txn(id: 'c', amount: 40, isDebit: true, txnAt: now, merchant: 'Bhai Pan Stall'),
      ],
    );
    await tester.pumpWidget(MaterialApp(home: InsightsScreen(data: data)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Places'));
    await tester.pumpAndSettle();
    expect(find.text('Hotel Vijay'), findsOneWidget);
    expect(find.textContaining('5× · avg ₹200'), findsOneWidget);
    expect(find.text('Most frequent'), findsOneWidget);
    await tester.tap(find.text('Hotel Vijay'));
    await tester.pumpAndSettle();
    expect(find.text('₹1,000'), findsWidgets);
    expect(find.text('Who is this?'), findsOneWidget);
    expect(find.text('Category for all its payments'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Ledger'), 300, scrollable: find.byType(Scrollable).last);
    expect(find.text('Ledger'), findsOneWidget);
  });
}
