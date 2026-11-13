// ignore_for_file: invalid_use_of_visible_for_testing_member
import 'package:expense_tracker/data/app_data.dart';
import 'package:expense_tracker/logic/summary.dart';
import 'package:expense_tracker/models.dart';
import 'package:expense_tracker/screens/budgets_screen.dart';
import 'package:expense_tracker/screens/friends_screen.dart';
import 'package:expense_tracker/screens/people_review_screen.dart';
import 'package:expense_tracker/screens/places_screen.dart';
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
    budgets: const [
      Budget(id: 'b1', amount: 5000),
      Budget(id: 'b2', categoryId: 'f', amount: 1000),
    ],
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

  testWidgets('set what is really owed: the rest is a friend\'s spends', (tester) async {
    await pump(tester, FriendDetailScreen(data: sample(), person: 'Rahul Kumar'));
    expect(find.text('Rahul Kumar owes you'), findsOneWidget);
    await tester.tap(find.text('Set balance'));
    await tester.pumpAndSettle();
    expect(find.text('What is really owed?'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '200');
    await tester.pumpAndSettle();
    expect(find.text('The other ₹300 was:'), findsOneWidget);
    expect(find.text("Rahul's spends through me"), findsOneWidget);
  });

  test('a friend who only sent money is still found, under a name a statement cut short', () {
    final now = DateTime.now();
    final groups = payeeGroups([
      Txn(id: 'a', amount: 500, isDebit: false, txnAt: now, merchant: 'Vaibhav Chetan Parma'),
    ], withMoneyInOnly: true);
    expect(groups, hasLength(1));
    expect(groups.single.received, 500);
    expect(sameName(groups.single.keys.single, 'vaibhav chetan parmar'), isTrue);
    expect(payeeGroups([Txn(id: 'a', amount: 500, isDebit: false, txnAt: now, merchant: 'Vaibhav C')]), isEmpty);
  });

  test('a parent\'s account behind a friend\'s UPI ID is suggested as the friend', () {
    final now = DateTime.now();
    final txns = [
      Txn(
        id: 'a',
        amount: 400,
        isDebit: false,
        txnAt: now,
        merchant: 'Vaibhav Chetan Parma',
        details: 'UPI-VAIBHAV CHETAN PARMA-VAIBHAVPARMAR25-1@OKAXIS-HDFC0000591-6182',
      ),
      Txn(
        id: 'b',
        amount: 800,
        isDebit: true,
        txnAt: now,
        merchant: 'Chetan V Parmar',
        details: 'UPI-CHETAN V PARMAR-VAIBHAVPARMAR25@OKICICI-BARB0MALEAS-1079',
      ),
      Txn(id: 'c', amount: 250, isDebit: true, txnAt: now, merchant: 'Chetan V Parmar', source: 'email'),
      Txn(
        id: 'd',
        amount: 90,
        isDebit: true,
        txnAt: now,
        merchant: 'Ramesh Kumar',
        details: 'UPI-RAMESH KUMAR-RAMESH12@OKSBI-SBIN0-1',
      ),
    ];
    final c = samePersonCandidates(txns, 'Vaibhav Chetan Parmar');
    expect(c, hasLength(1));
    expect(c.single.name, 'Chetan V Parmar');
    expect(c.single.count, 2);
    expect(c.single.out, 1050);
    expect(c.single.why, contains('vaibhavparmar25@okicici'));
    expect(samePersonCandidates(txns, 'Vaibhav Chetan Parmar', skip: {'chetan v parmar'}), isEmpty);
  });

  testWidgets('a person you only got money from opens without errors', (tester) async {
    final now = DateTime.now();
    final data = AppData.preview(
      categories: const [Category(id: 'fr', name: 'Friends', icon: 'group', color: 0xFF3F51B5, isLoan: true)],
      transactions: [
        Txn(
          id: 'a',
          amount: 400,
          isDebit: false,
          txnAt: now,
          merchant: 'Vaibhav Chetan Parma',
          details: 'UPI-VAIBHAV CHETAN PARMA-VAIBHAVPARMAR25-1@OKAXIS-HDFC0000591-6182',
        ),
        Txn(
          id: 'b',
          amount: 800,
          isDebit: true,
          txnAt: now,
          merchant: 'Chetan V Parmar',
          details: 'UPI-CHETAN V PARMAR-VAIBHAVPARMAR25@OKICICI-BARB0MALEAS-1079',
        ),
      ],
    );
    await pump(tester, PlaceDetailScreen(data: data, keys: const {'vaibhav chetan parma'}));
    expect(find.text('Also Vaibhav?'), findsOneWidget);
    expect(find.text('Chetan V Parmar'), findsOneWidget);
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
    await tester.scrollUntilVisible(
      find.textContaining('Your spending: ₹300'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.textContaining('Rahul Kumar owes you ₹300'), findsOneWidget);
  });

  testWidgets('budgets screen', (tester) async {
    await pump(tester, BudgetsScreen(data: sample()));
    expect(find.text('All spending'), findsOneWidget);
    expect(find.textContaining('spent'), findsWidgets);
  });
}
