// ignore_for_file: invalid_use_of_visible_for_testing_member
import 'package:expense_tracker/data/app_data.dart';
import 'package:expense_tracker/models.dart';
import 'package:expense_tracker/screens/budgets_screen.dart';
import 'package:expense_tracker/screens/friends_screen.dart';
import 'package:expense_tracker/screens/people_review_screen.dart';
import 'package:expense_tracker/screens/shared_expense_screen.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

AppData sample() {
  final now = DateTime.now();
  return AppData.preview(
    categories: const [
      Category(id: 'f', name: 'Food & Dining', icon: 'restaurant', color: 0xFFFF5722),
      Category(id: 'fr', name: 'Friends', icon: 'group', color: 0xFF3F51B5, isLoan: true),
    ],
    accounts: const [Account(id: 'c', name: 'Cash', kind: AccountKind.cash)],
    budgets: const [Budget(id: 'b1', amount: 5000), Budget(id: 'b2', categoryId: 'f', amount: 1000)],
    shares: const [TxnShare(id: 's', txnId: 'pay', person: 'Priya Desai', amount: 300)],
    transactions: [
      Txn(id: 'pay', amount: 900, isDebit: true, txnAt: now, merchant: 'Pizza night', categoryId: 'f'),
      Txn(id: '1', amount: 500, isDebit: true, txnAt: now, merchant: 'Rahul Kumar', categoryId: 'fr'),
      Txn(id: '2', amount: 250, isDebit: true, txnAt: now, merchant: 'Shresth Sharma', source: 'email'),
      Txn(id: '3', amount: 40, isDebit: true, txnAt: now, merchant: 'Bhai Pan Stall', source: 'email'),
      Txn(id: '4', amount: 300, isDebit: true, txnAt: now, merchant: 'Dinner', categoryId: 'f', paidBy: 'Amit Shah'),
    ],
  );
}

Future<void> pump(WidgetTester tester, Widget child) async {
  tester.view.physicalSize = const Size(360, 780) * 3;
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(home: child));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('friends tab: totals, people to review, friend page', (tester) async {
    final data = sample();
    await pump(tester, FriendsScreen(data: data));
    expect(find.text('₹800'), findsOneWidget); // owed to you: Rahul 500 + Priya 300
    expect(find.text('₹300'), findsWidgets); // you owe Amit 300
    expect(find.textContaining('1 person you paid'), findsOneWidget); // Shresth (not the pan stall)
    await tester.tap(find.text('Priya Desai'));
    await tester.pumpAndSettle();
    expect(find.text('Priya Desai owes you'), findsOneWidget);
    expect(find.text('Remind'), findsOneWidget);
    expect(find.textContaining('Their part of Pizza night'), findsOneWidget);
  });

  testWidgets('people review lists people, not shops', (tester) async {
    await pump(tester, PeopleReviewScreen(data: sample()));
    expect(find.text('Shresth Sharma'), findsOneWidget);
    expect(find.text('Bhai Pan Stall'), findsNothing);
    expect(find.text('Who is this?'), findsOneWidget);
  });

  testWidgets('shared expense: equal split and summary', (tester) async {
    await pump(tester, SharedExpenseScreen(data: sample()));
    await tester.enterText(find.widgetWithText(TextField, 'What for?'), 'Pizza');
    await tester.enterText(find.widgetWithText(TextField, 'Total'), '900');
    await tester.tap(find.text('Rahul Kumar'));
    await tester.tap(find.text('Priya Desai'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.textContaining('Your spending: ₹300'), 200, scrollable: find.byType(Scrollable).first);
    expect(find.textContaining('Rahul Kumar owes you ₹300'), findsOneWidget);
  });

  testWidgets('budgets screen', (tester) async {
    await pump(tester, BudgetsScreen(data: sample()));
    expect(find.text('All spending'), findsOneWidget);
    expect(find.textContaining('spent'), findsWidgets);
  });
}
