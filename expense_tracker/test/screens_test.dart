import 'package:expense_tracker/data/app_data.dart';
import 'package:expense_tracker/models.dart';
import 'package:expense_tracker/screens/accounts_screen.dart';
import 'package:expense_tracker/screens/categories_screen.dart';
import 'package:expense_tracker/screens/loans_screen.dart';
import 'package:expense_tracker/screens/gmail_setup_screen.dart';
import 'package:expense_tracker/screens/insights_screen.dart';
import 'package:expense_tracker/screens/settings_screen.dart';
import 'package:expense_tracker/screens/transactions_screen.dart';
import 'package:expense_tracker/screens/txn_editor.dart';
import 'package:expense_tracker/screens/unread_emails_screen.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

AppData sample() {
  final now = DateTime.now();
  const food = Category(id: 'f', name: 'Food & Dining', icon: 'restaurant', color: 0xFFFF5722);
  const shop = Category(id: 's', name: 'Shopping', icon: 'shopping_bag', color: 0xFFE91E63);
  const loan = Category(id: 'l', name: 'Personal loans', icon: 'handshake', color: 0xFF3F51B5, isLoan: true);
  return AppData.preview(
    categories: const [food, shop, loan],
    accounts: const [
      Account(id: 'cash', name: 'Cash', kind: AccountKind.cash, openingBalance: 1000),
      Account(id: 'hdfc', name: 'HDFC A/c ••4321', bank: 'HDFC', last4: '4321', openingBalance: 20000),
      Account(id: 'card', name: 'ICICI Card ••5678', kind: AccountKind.card),
    ],
    profile: {'display_name': 'Asha', 'ingest_token': 'ab' * 24, 'last_sync_at': now.toUtc().toIso8601String()},
    unread: [UnreadEmail(id: 'u', from: 'alerts@hdfcbank.net', subject: 'Alert', body: 'Rs 99 something', receivedAt: now)],
    transactions: [
      Txn(id: '1', amount: 250, isDebit: true, txnAt: now, merchant: 'SWIGGY LIMITED', categoryId: 'f', bank: 'HDFC', accountLast4: '4321', source: 'email', accountId: 'hdfc'),
      Txn(id: '6', amount: 5000, isDebit: false, txnAt: now, merchant: 'Rahul', categoryId: 'l', accountId: 'cash'),
      Txn(id: '7', amount: 2000, isDebit: true, txnAt: now, merchant: 'ATM', accountId: 'hdfc', counterAccountId: 'cash', excluded: true),
      Txn(id: '2', amount: 1249, isDebit: true, txnAt: now.subtract(const Duration(minutes: 5)), merchant: 'A VERY LONG MERCHANT NAME THAT DOES NOT FIT ON ONE LINE PVT LTD', categoryId: 's'),
      Txn(id: '3', amount: 85000, isDebit: false, txnAt: now, merchant: 'ACME TECHNOLOGIES'),
      Txn(id: '4', amount: 80, isDebit: true, txnAt: now, merchant: 'CHAI POINT'),
      Txn(id: '5', amount: 15430, isDebit: false, txnAt: now, excluded: true, merchant: 'Card bill'),
    ],
  );
}

Future<void> pump(WidgetTester tester, Widget child, {Size size = const Size(360, 780)}) async {
  tester.view.physicalSize = size * 3;
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(home: child));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('transactions list shows totals and rows', (tester) async {
    await pump(tester, TransactionsScreen(data: sample()));
    expect(find.text('Spent'), findsWidgets);
    expect(find.text('SWIGGY LIMITED'), findsOneWidget);
    expect(find.text('1 payment needs a category'), findsOneWidget);
    await tester.tap(find.text('1 payment needs a category'));
    await tester.pumpAndSettle();
    expect(find.text('SWIGGY LIMITED'), findsNothing);
    expect(find.text('CHAI POINT'), findsOneWidget);
  });

  testWidgets('loan is not counted in the month totals', (tester) async {
    await pump(tester, TransactionsScreen(data: sample()));
    // Spent: 250 + 1249 + 80 (loan of 5000 and the ATM move are left out).
    expect(find.text('₹1,579'), findsOneWidget);
    expect(find.text('₹85,000'), findsOneWidget);
  });

  testWidgets('accounts tab shows balances and opens one account', (tester) async {
    final data = sample();
    await pump(tester, AccountsScreen(data: data));
    expect(find.text('₹8,000'), findsOneWidget); // cash: 1000 + 5000 + 2000
    expect(find.text('₹17,750'), findsOneWidget); // HDFC: 20000 − 250 − 2000
    await tester.tap(find.text('Cash'));
    await tester.pumpAndSettle();
    expect(find.text('Rahul'), findsOneWidget);
    expect(find.text('SWIGGY LIMITED'), findsNothing);
  });

  testWidgets('loans tab shows who owes whom', (tester) async {
    final data = sample();
    await pump(tester, LoansScreen(data: data));
    expect(find.text('Rahul'), findsOneWidget);
    expect(find.text('You owe'), findsWidgets);
    await tester.tap(find.text('Rahul'));
    await tester.pumpAndSettle();
    expect(find.text('You owe Rahul'), findsOneWidget);
    expect(find.text('I paid back'), findsOneWidget);
  });

  testWidgets('loan editor asks for the friend', (tester) async {
    final data = sample();
    await pump(tester, TxnEditor(data: data, existing: data.transactions.firstWhere((t) => t.id == '6')));
    expect(find.text("Friend's name"), findsOneWidget);
    expect(find.text('Received in'), findsOneWidget);
  });

  testWidgets('insights', (tester) async {
    await pump(tester, InsightsScreen(data: sample()));
    expect(find.text('Food & Dining'), findsOneWidget);
    expect(find.text('No category'), findsOneWidget);
  });

  testWidgets('settings, gmail setup, categories, unread emails render', (tester) async {
    final data = sample();
    await pump(tester, SettingsScreen(data: data));
    expect(find.text('Asha'), findsOneWidget);
    await pump(tester, GmailSetupScreen(data: data));
    expect(find.text('Connected'), findsOneWidget);
    await pump(tester, CategoriesScreen(data: data));
    expect(find.text('Shopping'), findsOneWidget);
    await pump(tester, Scaffold(body: UnreadEmailsListOnly(data: data)));
  });

  testWidgets('editor for an email transaction', (tester) async {
    final data = sample();
    await pump(tester, TxnEditor(data: data, existing: data.transactions.first));
    await tester.ensureVisible(find.text('Shopping'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Shopping'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.textContaining('Always use this category'), 100,
        scrollable: find.byType(Scrollable).first);
    expect(find.textContaining('Always use this category'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Added from a bank email'), 200, scrollable: find.byType(Scrollable).first);
    expect(find.text('Added from a bank email'), findsOneWidget);
  });

  testWidgets('editor validates a new entry', (tester) async {
    await pump(tester, TxnEditor(data: sample()));
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('Enter an amount'), findsOneWidget);
  });
}

/// UnreadEmailsScreen refreshes from the server on open; render its list body only.
class UnreadEmailsListOnly extends StatelessWidget {
  const UnreadEmailsListOnly({super.key, required this.data});
  final AppData data;
  @override
  Widget build(BuildContext context) => Text('${data.unread.length} unread · ${UnreadEmailsScreen(data: data).runtimeType}');
}
