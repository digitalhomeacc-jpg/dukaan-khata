import 'package:expense_tracker/data/app_data.dart';
import 'package:expense_tracker/models.dart';
import 'package:expense_tracker/screens/accounts_screen.dart';
import 'package:expense_tracker/logic/summary.dart';
import 'package:expense_tracker/screens/categories_screen.dart';
import 'package:expense_tracker/screens/category_report_screen.dart';
import 'package:expense_tracker/screens/change_history_screen.dart';
import 'package:expense_tracker/screens/friends_screen.dart';
import 'package:expense_tracker/screens/gmail_setup_screen.dart';
import 'package:expense_tracker/screens/insights_screen.dart';
import 'package:expense_tracker/screens/settings_screen.dart';
import 'package:expense_tracker/screens/transactions_screen.dart';
import 'package:expense_tracker/screens/txn_editor.dart';
import 'package:expense_tracker/screens/unread_emails_screen.dart';
import 'package:expense_tracker/ui/category_picker.dart';
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
    unread: [
      UnreadEmail(id: 'u', from: 'alerts@hdfcbank.net', subject: 'Alert', body: 'Rs 99 something', receivedAt: now),
    ],
    transactions: [
      Txn(
        id: '1',
        amount: 250,
        isDebit: true,
        txnAt: now,
        merchant: 'SWIGGY LIMITED',
        categoryId: 'f',
        bank: 'HDFC',
        accountLast4: '4321',
        source: 'email',
        accountId: 'hdfc',
      ),
      Txn(id: '6', amount: 5000, isDebit: false, txnAt: now, merchant: 'Rahul', categoryId: 'l', accountId: 'cash'),
      Txn(
        id: '7',
        amount: 2000,
        isDebit: true,
        txnAt: now,
        merchant: 'ATM',
        accountId: 'hdfc',
        counterAccountId: 'cash',
        excluded: true,
      ),
      Txn(
        id: '2',
        amount: 1249,
        isDebit: true,
        txnAt: now.subtract(const Duration(minutes: 5)),
        merchant: 'A VERY LONG MERCHANT NAME THAT DOES NOT FIT ON ONE LINE PVT LTD',
        categoryId: 's',
      ),
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
    expect(find.textContaining('need a category'), findsOneWidget);
    expect(find.textContaining('Quick sort'), findsOneWidget);
    await tester.ensureVisible(find.widgetWithText(ChoiceChip, 'No category'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ChoiceChip, 'No category'));
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

  testWidgets('friends tab shows who owes whom', (tester) async {
    final data = sample();
    await pump(tester, FriendsScreen(data: data));
    expect(find.text('Rahul'), findsOneWidget);
    expect(find.text('You owe'), findsWidgets);
    await tester.tap(find.text('Rahul'));
    await tester.pumpAndSettle();
    expect(find.text('You owe Rahul'), findsOneWidget);
    expect(find.text('Settle up'), findsOneWidget);
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
    expect(find.text('Change history'), findsOneWidget);
    await pump(tester, GmailSetupScreen(data: data));
    expect(find.text('Connected'), findsOneWidget);
    await pump(tester, CategoriesScreen(data: data));
    expect(find.text('Shopping'), findsOneWidget);
    await pump(tester, Scaffold(body: UnreadEmailsListOnly(data: data)));
  });

  testWidgets('a day of an account opens as a passbook page', (tester) async {
    final data = sample();
    final t = data.transactions.firstWhere((t) => t.accountId != null);
    final account = data.account(t.accountId)!;
    await pump(tester, DayLedgerScreen(data: data, account: account, day: t.txnAt, bankBalance: 1000000));
    expect(find.text('Start of day'), findsOneWidget);
    expect(find.textContaining('Bank says'), findsOneWidget);
    expect(find.text('Add missing entry'), findsOneWidget);
  });

  testWidgets('details of a payment from a bank email open, with the email', (tester) async {
    final now = DateTime.now();
    final data = AppData.preview(
      categories: const [],
      accounts: const [Account(id: 'h', name: 'HDFC A/c ••6516', kind: AccountKind.bank)],
      transactions: [
        Txn(
          id: 'e',
          amount: 200,
          isDebit: true,
          txnAt: now,
          merchant: 'Ravi Kumar',
          source: 'email',
          accountId: 'h',
          payeeVpa: '0678@y',
          emailSubject: 'You have done a UPI txn. Check details!',
          emailBody:
              'Dear Customer,\n\nRs.200.00 is debited from your account ending 6516 towards VPA '
              '*****0678@ybl (RAVI KUMAR) on 04-11-26.\n\nUPI transaction reference no.: 668101105272.\n\n'
              'Warm Regards,\nHDFC Bank\nhttps://example.com/x',
        ),
      ],
    );
    await pump(tester, TxnEditor(data: data, existing: data.transactions.single));
    expect(tester.takeException(), isNull);
    expect(find.text('Bank email'), findsOneWidget);
    expect(find.text('668101105272'), findsOneWidget);
    await tester.tap(find.text('Show the bank email'));
    await tester.pumpAndSettle();
    expect(find.textContaining('is debited from your account'), findsOneWidget);
    expect(find.textContaining('Warm Regards'), findsNothing);
  });

  testWidgets('new category form scrolls on a small phone and can be saved from the top', (tester) async {
    final data = sample();
    tester.view.physicalSize = const Size(360, 560) * 3;
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (c) => Scaffold(
            body: TextButton(onPressed: () => openCategoryForm(c, data), child: const Text('open')),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.widgetWithText(FilledButton, 'Save'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Loans with friends'), 200, scrollable: find.byType(Scrollable).last);
    expect(find.text('Loans with friends'), findsOneWidget);
  });

  testWidgets('categories report: ranges, spent and received, a category\'s payments', (tester) async {
    final data = sample();
    await pump(tester, CategoryReportScreen(data: data));
    expect(tester.takeException(), isNull);
    expect(find.text('This month'), findsOneWidget);
    expect(find.text('Spent'), findsWidgets);
    await tester.tap(find.text('12 months'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(InkWell).at(0), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  test('categories report adds up spending by category in a date range', () {
    final t = [
      Txn(id: 'a', amount: 100, isDebit: true, txnAt: DateTime(2026, 1, 5), categoryId: 'f'),
      Txn(id: 'b', amount: 50, isDebit: true, txnAt: DateTime(2026, 1, 31, 23), categoryId: 'f'),
      Txn(id: 'c', amount: 70, isDebit: true, txnAt: DateTime(2026, 2, 1), categoryId: 'f'),
      Txn(id: 'd', amount: 30, isDebit: true, txnAt: DateTime(2026, 1, 10)),
      Txn(id: 'e', amount: 500, isDebit: false, txnAt: DateTime(2026, 1, 10), categoryId: 's'),
      Txn(id: 'x', amount: 999, isDebit: true, txnAt: DateTime(2026, 1, 10), excluded: true),
    ];
    final out = categoryReport(t, DateTime(2026, 1, 1), DateTime(2026, 2, 1), debits: true);
    expect(out.map((l) => (l.id, l.total, l.count)), [('f', 150.0, 2), (null, 30.0, 1)]);
    final into = categoryReport(t, DateTime(2026, 1, 1), DateTime(2026, 2, 1), debits: false);
    expect(into.single.total, 500);
  });

  testWidgets('change history: one action, its before and after, and undo', (tester) async {
    final data = sample();
    final cat = data.categories.firstWhere((c) => c.name == 'Shopping');
    final rows = [
      {
        'id': 2,
        'batch': 77,
        'at': '2026-11-14T06:50:00Z',
        'tbl': 'vpa_rules',
        'op': 'insert',
        'row_key': {'user_id': 'u', 'vpa': 'upta@n'},
        'before': null,
        'after': {'user_id': 'u', 'vpa': 'upta@n', 'category_id': cat.id},
        'context': null,
        'by_user': true,
        'undone': false,
      },
      {
        'id': 1,
        'batch': 77,
        'at': '2026-11-14T06:50:00Z',
        'tbl': 'transactions',
        'op': 'update',
        'row_key': {'id': 't1'},
        'before': {'category_id': null},
        'after': {'category_id': cat.id},
        'context': {'merchant': 'Ravi Kumar', 'amount': 2000, 'txn_at': '2026-09-12T00:41:00Z'},
        'by_user': true,
        'undone': false,
      },
      {
        'id': 5,
        'batch': 60,
        'at': '2026-11-14T06:00:00Z',
        'tbl': 'shared_entries',
        'op': 'insert',
        'row_key': {'id': 's1'},
        'before': null,
        'after': {'amount': 600},
        'context': {
          'amount': 600,
          'kind': 'expense',
          'description': 'Pizza',
          'creditor': 'friend-id',
          'debtor': 'me',
          'link_id': 'x',
        },
        'by_user': false,
        'undone': false,
        'actor': 'friend-id',
      },
      {
        'id': 0,
        'batch': 50,
        'at': '2026-11-14T05:00:00Z',
        'tbl': 'transactions',
        'op': 'insert',
        'row_key': {'id': 't9'},
        'before': null,
        'after': {'amount': 10},
        'context': {'merchant': 'Zomato'},
        'by_user': false,
        'undone': false,
      },
    ];
    await pump(tester, ChangeHistoryScreen(data: data, loader: () async => rows));
    expect(find.textContaining('Category → Shopping · 1 payment'), findsOneWidget);
    expect(find.textContaining('Added 1 payment'), findsNothing); // automatic, hidden under "My changes"
    await tester.tap(find.textContaining('Category → Shopping'));
    await tester.pumpAndSettle();
    expect(find.text('Undo this'), findsOneWidget);
    expect(find.text('Category: No category → Shopping'), findsOneWidget);
    expect(find.textContaining('Category rule for UPI ••upta@n'), findsOneWidget);
    // A friend's change to an entry between you shows under "My changes" too.
    await tester.scrollUntilVisible(
      find.textContaining('Added with your friend'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.textContaining('Added with your friend: Shared expense “Pizza” ₹600 · you owe'), findsOneWidget);
    await tester.tap(find.text('All, incl. automatic'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Added 1 payment'), findsOneWidget);
  });

  testWidgets('editor for an email transaction', (tester) async {
    final data = sample();
    await pump(tester, TxnEditor(data: data, existing: data.transactions.first));
    expect(find.text('Bank email'), findsOneWidget);
    await tester.scrollUntilVisible(find.byType(CategoryField), 200, scrollable: find.byType(Scrollable).first);
    await tester.tap(find.byType(CategoryField));
    await tester.pumpAndSettle();
    // The picker: groups listed, search offers to add a new detail.
    await tester.enterText(find.widgetWithText(TextField, 'Search or add (e.g. Cigarettes)'), 'Cigar');
    await tester.pumpAndSettle();
    expect(find.text('Add “Cigar”'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, 'Cigar'), 'shop');
    await tester.pumpAndSettle();
    // Two quick taps choose once and close the sheet.
    await tester.tap(find.text('Shopping').last);
    await tester.tap(find.text('Shopping').last, warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(find.text('Search or add (e.g. Cigarettes)'), findsNothing);
    expect(find.text('Shopping'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.textContaining('Always use this category'),
      100,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.textContaining('Always use this category'), findsOneWidget);
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
  Widget build(BuildContext context) =>
      Text('${data.unread.length} unread · ${UnreadEmailsScreen(data: data).runtimeType}');
}
