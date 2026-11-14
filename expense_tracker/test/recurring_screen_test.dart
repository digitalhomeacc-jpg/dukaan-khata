// ignore_for_file: invalid_use_of_visible_for_testing_member
import 'package:expense_tracker/data/app_data.dart';
import 'package:expense_tracker/models.dart';
import 'package:expense_tracker/screens/recurring_screen.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);

  AppData sample() => AppData.preview(
    categories: const [Category(id: 'h', name: 'Rent', icon: 'home', color: 0xFF795548)],
    accounts: const [Account(id: 'c', name: 'Cash', kind: AccountKind.cash)],
    transactions: [
      // Same amount as the rent but another payee: offered, never filed by itself.
      Txn(
        id: 'p',
        amount: 8000,
        isDebit: true,
        txnAt: today.subtract(const Duration(days: 2)),
        merchant: 'Ramesh Kumar',
      ),
      for (var m = 1; m <= 4; m++)
        Txn(
          id: 'n$m',
          amount: 649,
          isDebit: true,
          txnAt: DateTime(now.year, now.month - m + 1, 1),
          merchant: 'Netflix',
        ),
    ],
    recurring: [
      Recurring(
        id: 'rent',
        name: 'Rent',
        amount: 8000,
        startsOn: today.subtract(const Duration(days: 3)),
        categoryId: 'h',
      ),
      Recurring(id: 'jio', name: 'Jio', amount: 299, startsOn: today.add(const Duration(days: 1))),
    ],
  );

  Future<void> pump(WidgetTester tester, Widget child) async {
    tester.view.physicalSize = const Size(400, 900) * 3;
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: child));
    await tester.pumpAndSettle();
  }

  testWidgets('late and tomorrow dues, suggestions, and what to do with a late one', (tester) async {
    final data = sample();
    await pump(tester, RecurringScreen(data: data));
    expect(find.text('3 days late · not seen yet'), findsOneWidget);
    expect(find.text('Tomorrow'), findsOneWidget);
    expect(find.text('Netflix · ₹649'), findsOneWidget); // looks like a repeat
    await tester.tap(find.text('3 days late · not seen yet'));
    await tester.pumpAndSettle();
    expect(find.text('Already paid? Is it one of these?'), findsOneWidget);
    expect(find.textContaining('Ramesh Kumar · ₹8,000'), findsOneWidget);
    expect(find.text('Paid in cash: add it'), findsOneWidget);
    expect(find.text('Skip this time (not paid)'), findsOneWidget);
  });

  testWidgets('cash repeats can be added by themselves; bank ones explain they are matched', (tester) async {
    final data = sample();
    await pump(tester, RecurringEditor(data: data, existing: data.recurring.first));
    expect(find.text('Add it by itself on the day'), findsNothing);
    expect(find.textContaining('never added twice'), findsOneWidget);
    await tester.tap(find.widgetWithText(ChoiceChip, 'Cash'));
    await tester.pumpAndSettle();
    expect(find.text('Add it by itself on the day'), findsOneWidget);
  });
}
