// ignore_for_file: invalid_use_of_visible_for_testing_member
import 'package:expense_tracker/data/app_data.dart';
import 'package:expense_tracker/logic/summary.dart';
import 'package:expense_tracker/models.dart';
import 'package:expense_tracker/screens/quick_add.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  final now = DateTime.now();
  final txns = [
    for (final (i, who) in const ['Saket', 'Saket', 'Vaibhav', 'Saket'].indexed)
      Txn(
        id: 't$i',
        amount: 800,
        isDebit: true,
        txnAt: now.subtract(Duration(days: i * 7)),
        merchant: who,
        categoryId: 'thali',
        accountId: 'h',
        method: 'upi',
      ),
    Txn(id: 'c1', amount: 20, isDebit: true, txnAt: now, merchant: 'Chai', categoryId: 'chai'),
    Txn(id: 'r1', amount: 800, isDebit: false, txnAt: now, merchant: 'Saket'),
  ];

  test('repeat payments are learned: amount, category, usual person and account', () {
    final f = frequentEntries(txns, now: now);
    expect(f, hasLength(1)); // chai only once
    expect((f.single.amount, f.single.count, f.single.categoryId), (800.0, 4, 'thali'));
    expect(f.single.usualPayee, 'Saket');
    expect(f.single.payees, ['Saket', 'Vaibhav']);
    expect(f.single.usualAccountId, 'h');
  });

  test('searching 800 finds ₹800 payments, not ₹80', () {
    expect(matchesAmount(txns.first, '800'), isTrue);
    expect(matchesAmount(txns.first, '₹800'), isTrue);
    expect(matchesAmount(txns.first, '80'), isFalse);
    expect(matchesAmount(txns.first, 'saket'), isFalse);
  });

  testWidgets('Add sheet offers the repeat payment; all ₹800 payments at a glance', (tester) async {
    final data = AppData.preview(
      transactions: txns,
      categories: const [Category(id: 'thali', name: 'Thali', icon: 'restaurant', color: 0xFFFF5722)],
    );
    tester.view.physicalSize = const Size(360, 780) * 3;
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (c) => Scaffold(
            body: TextButton(onPressed: () => openAddSheet(c, data), child: const Text('add')),
          ),
        ),
      ),
    );
    await tester.tap(find.text('add'));
    await tester.pumpAndSettle();
    expect(find.text('Again?'), findsOneWidget);
    expect(find.text('₹800 · Thali'), findsOneWidget);
    await tester.tap(find.byTooltip('All ₹800 payments'));
    await tester.pumpAndSettle();
    expect(find.text('All ₹800 payments'), findsOneWidget);
    expect(find.text('5 times'), findsOneWidget); // 4 paid + 1 received
    expect(find.text('Add another ₹800'), findsOneWidget);
  });
}
