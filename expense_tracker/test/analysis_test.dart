// ignore_for_file: invalid_use_of_visible_for_testing_member
import 'package:expense_tracker/data/app_data.dart';
import 'package:expense_tracker/logic/analysis.dart';
import 'package:expense_tracker/models.dart';
import 'package:expense_tracker/screens/analysis_screen.dart';
import 'package:expense_tracker/ui/paid_with.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  final txns = [
    // October (the period before)
    Txn(id: 'o1', amount: 1000, isDebit: true, txnAt: DateTime(2026, 10, 5, 13), merchant: 'Zomato', categoryId: 'f'),
    // November
    Txn(id: 'n1', amount: 10000, isDebit: false, txnAt: DateTime(2026, 11, 1, 10), merchant: 'Home', categoryId: 'h'),
    Txn(
      id: 'n2',
      amount: 1500,
      isDebit: true,
      txnAt: DateTime(2026, 11, 2, 23, 30),
      merchant: 'Zomato',
      categoryId: 'f',
      source: 'email',
    ),
    Txn(
      id: 'n3',
      amount: 50,
      isDebit: true,
      txnAt: DateTime(2026, 11, 3, 9),
      merchant: 'Chai',
      categoryId: 'c',
      source: 'email',
    ),
    Txn(
      id: 'n4',
      amount: 30,
      isDebit: true,
      txnAt: DateTime(2026, 11, 3, 18),
      merchant: 'Chai',
      categoryId: 'c',
      source: 'statement',
    ),
    Txn(id: 'x', amount: 5000, isDebit: true, txnAt: DateTime(2026, 11, 4), merchant: 'Own account', excluded: true),
    // Netflix three months running
    for (final m in [8, 9, 10])
      Txn(id: 'nf$m', amount: 199, isDebit: true, txnAt: DateTime(2026, m, 10), merchant: 'Netflix'),
  ];

  test('self analysis: kept, change against before, discipline, times, regular costs', () {
    final a = analyse(txns, DateTime(2026, 11, 1), DateTime(2026, 11, 11), today: DateTime(2026, 11, 10, 12));
    expect(a.received, 10000);
    expect(a.spent, 1580); // the move between own accounts is left out
    expect(a.saved, 8420);
    expect(a.savingsRate, closeTo(0.842, 0.001));
    expect(a.days, 10);
    expect(a.noSpendDays, 8); // spent on the 2nd and 3rd only
    expect(a.noSpendStreak, 7); // 4th–10th
    expect(a.smallCount, 2);
    expect(a.smallTotal, 80);
    expect(a.byTimeOfDay[3], 1500); // late-night Zomato
    expect(a.byTimeOfDay[0], 50); // morning chai; the statement chai has no real time
    expect(a.timedCount, 2);
    expect(a.prevSpent, 0); // the 10 days just before (22–31 Oct) had no spending
  });

  test('a whole month is compared with the month before', () {
    final a = analyse(txns, DateTime(2026, 11, 1), DateTime(2026, 12, 1), today: DateTime(2026, 11, 30, 12));
    // November so far (30 days) against the 30 days before: 2–31 Oct had Zomato 1,000 and Netflix 199.
    expect(a.prevSpent, 1199);
    final food = a.changes.firstWhere((c) => c.categoryId == 'f');
    expect((food.before, food.now), (1000.0, 1500.0));
  });

  test('regular costs: the same payee in 3 of the last 6 months', () {
    final a = analyse(txns, DateTime(2026, 11, 1), DateTime(2026, 12, 1), today: DateTime(2026, 11, 30));
    expect(a.recurring.map((r) => r.name), contains('Netflix'));
    expect(a.recurring.firstWhere((r) => r.name == 'Netflix').months, 3);
  });

  testWidgets('the self analysis screen and the paid-with filter open', (tester) async {
    final data = AppData.preview(transactions: txns, categories: const []);
    tester.view.physicalSize = const Size(360, 780) * 3;
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: AnalysisScreen(data: data)));
    await tester.pumpAndSettle();
    expect(find.text('Money in and out'), findsOneWidget);
    expect(find.text('All accounts'), findsOneWidget);
    expect(const PaidWith.method('upi').keep(txns.first), isFalse);
  });
}
