// ignore_for_file: invalid_use_of_visible_for_testing_member
import 'package:expense_tracker/data/app_data.dart';
import 'package:expense_tracker/models.dart';
import 'package:expense_tracker/screens/friends_screen.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

const me = 'me', ravi = 'ravi';

void main() {
  final day = DateTime(2026, 11, 10);
  AppData sample() => AppData.preview(
    myId: me,
    categories: const [Category(id: 'fr', name: 'Friends', icon: 'group', color: 0, isLoan: true)],
    accounts: const [Account(id: 'h', name: 'HDFC', kind: AccountKind.bank)],
    transactions: [
      // A correction added by hand (no account): never "in your bank".
      Txn(id: 'fix', amount: 700, isDebit: true, txnAt: day, merchant: 'Ravi Kumar', categoryId: 'fr'),
      Txn(
        id: 'upi',
        amount: 250,
        isDebit: false,
        txnAt: day,
        merchant: 'Ravi Kumar',
        categoryId: 'fr',
        accountId: 'h',
        source: 'email',
      ),
    ],
    links: const [FriendLink(id: 'L', a: me, b: ravi, aNameForB: 'Ravi Kumar', bNameForA: 'Asha', code: 'abc')],
    sharedEntries: [
      SharedEntry(
        id: 'a',
        linkId: 'L',
        creditor: me,
        debtor: ravi,
        amount: 700,
        kind: 'payment',
        at: day,
        createdBy: me,
        confirmedAmount: 700,
        confirmedAt: day,
        creditorTxn: 'fix',
      ),
      SharedEntry(
        id: 'b',
        linkId: 'L',
        creditor: ravi,
        debtor: me,
        amount: 250,
        kind: 'payment',
        at: day,
        createdBy: me,
        confirmedAmount: 250,
        confirmedAt: day,
        debtorTxn: 'upi',
      ),
      SharedEntry(
        id: 'c',
        linkId: 'L',
        creditor: ravi,
        debtor: me,
        amount: 305,
        kind: 'expense',
        at: day,
        createdBy: ravi,
        confirmedAmount: 305,
        confirmedAt: day,
        description: 'Sahil Stores',
      ),
      SharedEntry(
        id: 'd',
        linkId: 'L',
        creditor: ravi,
        debtor: me,
        amount: 100,
        kind: 'settle',
        at: day,
        createdBy: me,
        description: 'Balance set: you owe ₹100 (was they owe you ₹0)',
      ),
    ],
  );

  Future<void> pump(WidgetTester tester, Widget w) async {
    tester.view.physicalSize = const Size(400, 2600) * 3;
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: w));
    await tester.pumpAndSettle();
  }

  testWidgets('a correction is not "in your bank"; "Balance set" reads as itself', (tester) async {
    await pump(tester, FriendDetailScreen(data: sample(), person: 'Ravi Kumar'));
    expect(find.textContaining('added by hand, not in a bank'), findsWidgets);
    expect(find.textContaining('only in your bank'), findsOneWidget); // the ₹250 UPI
    expect(find.text('Balance set: you owe ₹100 (was they owe you ₹0)'), findsOneWidget);
  });

  testWidgets('"All payments with" also lists what is shared but not in your bank', (tester) async {
    await pump(tester, FriendDetailScreen(data: sample(), person: 'Ravi Kumar'));
    await tester.tap(find.text('All payments with Ravi'));
    await tester.pumpAndSettle();
    expect(find.text('Shared with Ravi, not in your bank (3)'), findsOneWidget);
    expect(find.textContaining('Your share · Sahil Stores'), findsOneWidget);
  });
}
