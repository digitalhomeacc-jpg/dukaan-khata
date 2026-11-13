// ignore_for_file: invalid_use_of_visible_for_testing_member
import 'package:expense_tracker/data/app_data.dart';
import 'package:expense_tracker/models.dart';
import 'package:expense_tracker/screens/accounts_screen.dart';
import 'package:expense_tracker/screens/transactions_screen.dart';
import 'package:expense_tracker/screens/txn_editor.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

AppData sample({List<TxnShare> shares = const []}) {
  final now = DateTime.now();
  final at = DateTime(now.year, now.month, now.day, 12);
  return AppData.preview(
    categories: const [Category(id: 'f', name: 'Food & Dining', icon: 'restaurant', color: 0xFFFF5722)],
    accounts: const [Account(id: 'h', name: 'HDFC A/c ••6516', bank: 'HDFC', last4: '6516', openingBalance: 1000)],
    balanceReadings: [BalanceReading(id: 'b', accountId: 'h', balance: 900, asOf: at.add(const Duration(hours: 2)))],
    shares: shares,
    transactions: [
      Txn(id: 'pay', amount: 600, isDebit: true, txnAt: at, merchant: 'Zomato', categoryId: 'f', accountId: 'h'),
      Txn(id: 'r1', amount: 200, isDebit: false, txnAt: at.add(const Duration(minutes: 5)), merchant: 'Rahul Kumar Sharma', accountId: 'h'),
      Txn(id: 'r2', amount: 200, isDebit: false, txnAt: at.add(const Duration(minutes: 9)), merchant: 'Priya', accountId: 'h'),
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
  testWidgets('payment suggests money received around then', (tester) async {
    final data = sample();
    await pump(tester, TxnEditor(data: data, existing: data.transactions.first));
    await tester.scrollUntilVisible(find.text('Split with friends'), 200, scrollable: find.byType(Scrollable).first);
    expect(find.textContaining('Rahul Kumar Sharma · ₹200'), findsOneWidget);
    expect(find.text("Add a friend's part"), findsOneWidget);
  });

  testWidgets('split payment shows your share in the list and totals', (tester) async {
    final data = sample(shares: const [
      TxnShare(id: 'a', txnId: 'pay', person: 'Rahul Kumar Sharma', amount: 200, paidTxnId: 'r1'),
      TxnShare(id: 'b', txnId: 'pay', person: 'Priya', amount: 200),
    ]);
    await pump(tester, TransactionsScreen(data: data));
    expect(find.textContaining('Your share ₹200'), findsOneWidget);
    expect(find.text('₹200'), findsWidgets); // Spent card: only your share
    expect(find.textContaining("Paid back: Rahul Kumar Sharma's share"), findsOneWidget);
  });

  testWidgets('account shows bank balance and difference', (tester) async {
    final data = sample();
    await pump(tester, AccountsScreen(data: data));
    expect(find.textContaining('Bank says ₹900'), findsOneWidget);
    await tester.tap(find.text('HDFC A/c ••6516'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Differs from the bank by ₹100'), findsOneWidget);
    expect(find.textContaining('Bal ₹'), findsWidgets);
  });
}
