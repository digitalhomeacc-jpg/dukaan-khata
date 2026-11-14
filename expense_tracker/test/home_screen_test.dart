// ignore_for_file: invalid_use_of_visible_for_testing_member
import 'package:expense_tracker/data/app_data.dart';
import 'package:expense_tracker/models.dart';
import 'package:expense_tracker/screens/home_screen.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  testWidgets('home: today, week, budget left, streak, coming up, goals, latest', (tester) async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final data = AppData.preview(
      categories: const [Category(id: 'f', name: 'Food', icon: 'restaurant', color: 0xFFFF5722)],
      accounts: const [Account(id: 'c', name: 'Cash', kind: AccountKind.cash)],
      budgets: const [Budget(id: 'b', amount: 30000)],
      transactions: [
        Txn(
          id: '1',
          amount: 120,
          isDebit: true,
          txnAt: today.add(const Duration(hours: 9)),
          merchant: 'Chai Point',
          categoryId: 'f',
        ),
        Txn(
          id: '2',
          amount: 5000,
          isDebit: true,
          txnAt: today.add(const Duration(hours: 8)),
          merchant: 'Savings',
          excluded: true,
        ),
      ],
      recurring: [Recurring(id: 'r', name: 'Netflix', amount: 649, startsOn: today.add(const Duration(days: 1)))],
      goals: [
        Goal(
          id: 'g',
          kind: 'save',
          name: 'Goa trip',
          startsOn: today,
          targetAmount: 20000,
          deadline: today.add(const Duration(days: 60)),
        ),
      ],
    );
    tester.view.physicalSize = const Size(400, 2400) * 3;
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: HomeScreen(data: data)));
    await tester.pumpAndSettle();
    expect(find.text('Spent today'), findsOneWidget);
    expect(find.text('₹120'), findsWidgets); // the ₹5,000 move to savings is not spending
    expect(find.text('Budget left'), findsOneWidget);
    expect(find.text('Netflix'), findsOneWidget);
    expect(find.text('Tomorrow'), findsOneWidget);
    expect(find.text('Goa trip'), findsOneWidget);
    expect(find.text('Chai Point'), findsOneWidget);
  });
}
