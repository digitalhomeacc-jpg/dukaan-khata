// ignore_for_file: invalid_use_of_visible_for_testing_member
import 'package:expense_tracker/data/app_data.dart';
import 'package:expense_tracker/models.dart';
import 'package:expense_tracker/screens/friends_screen.dart';
import 'package:expense_tracker/screens/groups_screen.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

AppData sample() {
  final now = DateTime.now();
  final data = AppData.preview(
    categories: const [Category(id: 'f', name: 'Food & Dining', icon: 'restaurant', color: 0xFFFF5722)],
    accounts: const [Account(id: 'c', name: 'Cash', kind: AccountKind.cash)],
    transactions: const [],
  );
  data.groups = const [Group(id: 'g', name: 'Hill trip', emoji: '⛰️', members: ['Asha', 'Ravi'])];
  data.groupExpenses = [
    GroupExpense(
      id: '1',
      groupId: 'g',
      amount: 900,
      paidBy: 'me',
      at: now,
      description: 'Hotel',
      categoryId: 'f',
      shares: const {'me': 300, 'Asha': 300, 'Ravi': 300},
    ),
    GroupExpense(
      id: '2',
      groupId: 'g',
      amount: 300,
      paidBy: 'Asha',
      at: now,
      description: 'Cab',
      shares: const {'me': 100, 'Asha': 100, 'Ravi': 100},
    ),
  ];
  return data;
}

Future<void> pump(WidgetTester tester, Widget child) async {
  tester.view.physicalSize = const Size(360, 780) * 3;
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(home: child));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('friends tab shows the group and where you stand', (tester) async {
    await pump(tester, FriendsScreen(data: sample()));
    expect(find.text('⛰️ Hill trip'), findsOneWidget);
    expect(find.text('You get ₹500'), findsOneWidget);
  });

  testWidgets('group page: totals, fewest payments, everyone', (tester) async {
    await pump(tester, GroupScreen(data: sample(), groupId: 'g'));
    expect(find.text('You get back ₹500'), findsOneWidget);
    expect(find.text('Group spent ₹1,200 · your share ₹400'), findsOneWidget);
    expect(find.text('Settle in 2 payments'), findsOneWidget);
    expect(find.text('Ravi → You'), findsOneWidget);
    expect(find.text('owes ₹400'), findsOneWidget);
    await tester.tap(find.text('Paid').first);
    await tester.pumpAndSettle();
    expect(find.text('UPI / bank'), findsOneWidget);
    expect(find.text('Cash'), findsOneWidget);
  });

  testWidgets('add expense: equal split adds up', (tester) async {
    final data = sample();
    await pump(tester, GroupExpenseEditor(data: data, group: data.groups.first));
    await tester.enterText(find.widgetWithText(TextField, 'Amount'), '100');
    await tester.pumpAndSettle();
    expect(find.text('₹33.34'), findsOneWidget);
    expect(find.text('₹33.33'), findsNWidgets(2));
  });
}
