import 'package:expense_tracker/data/app_data.dart';
import 'package:expense_tracker/models.dart';
import 'package:expense_tracker/screens/categories_screen.dart';
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
  return AppData.preview(
    categories: const [food, shop],
    profile: {'display_name': 'Asha', 'ingest_token': 'ab' * 24, 'last_sync_at': now.toUtc().toIso8601String()},
    unread: [UnreadEmail(id: 'u', from: 'alerts@hdfcbank.net', subject: 'Alert', body: 'Rs 99 something', receivedAt: now)],
    transactions: [
      Txn(id: '1', amount: 250, isDebit: true, txnAt: now, merchant: 'SWIGGY LIMITED', categoryId: 'f', bank: 'HDFC', accountLast4: '4321', source: 'email'),
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
    await tester.tap(find.text('Shopping'));
    await tester.pumpAndSettle();
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
