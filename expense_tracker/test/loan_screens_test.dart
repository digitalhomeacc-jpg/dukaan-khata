// ignore_for_file: invalid_use_of_visible_for_testing_member
import 'package:expense_tracker/data/app_data.dart';
import 'package:expense_tracker/models.dart';
import 'package:expense_tracker/screens/lender_loans.dart';
import 'package:expense_tracker/screens/accounts_screen.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

AppData sample() {
  final now = DateTime.now();
  return AppData.preview(
    transactions: const [],
    categories: const [],
    loans: [
      Loan(
        id: 's',
        lender: 'slice',
        name: 'Slice borrow',
        kind: LoanKind.creditLine,
        nextDueAmount: 506.54,
        nextDueDate: DateTime(now.year, now.month, 5),
      ),
      const Loan(
        id: 'k',
        lender: 'kreditbee',
        name: 'KreditBee',
        principal: 20000,
        emiAmount: 2100,
        tenureMonths: 12,
        emisPaidBefore: 3,
        dueDay: 5,
        interestRate: 24,
      ),
    ],
    loanEvents: [
      LoanEvent(
        id: '1',
        loanId: 's',
        kind: LoanEventKind.borrow,
        amount: 1500,
        at: now.subtract(const Duration(days: 20)),
        fromEmail: true,
      ),
      LoanEvent(
        id: '2',
        loanId: 's',
        kind: LoanEventKind.spend,
        amount: 136,
        at: now.subtract(const Duration(days: 6)),
        note: 'Aayush medical and general store',
        fromEmail: true,
      ),
      LoanEvent(
        id: '3',
        loanId: 'k',
        kind: LoanEventKind.repay,
        amount: 2100,
        at: now.subtract(const Duration(days: 8)),
        note: 'Added by hand',
      ),
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
  testWidgets('loan page: credit left and a schedule pasted from a screenshot', (tester) async {
    final data = sample();
    await pump(tester, LoanDetailScreen(data: data, loanId: 's'));
    expect(find.text('Credit left'), findsOneWidget);
    await tester.tap(find.text('Repayment schedule'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Paste from a screenshot'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), "Due on 05 Dec '26\n₹4,940.24\nDue on 05 Jan '27\n₹4,800.71");
    await tester.tap(find.text('Read it'));
    await tester.pumpAndSettle();
    expect(find.text('₹4,940.24'), findsOneWidget);
    expect(find.text('₹4,800.71'), findsOneWidget);
    expect(find.text('2 dues left · ₹9,740.95'), findsOneWidget);
  });

  testWidgets('a loan\'s own account is not a second debt on the Accounts tab', (tester) async {
    final now = DateTime.now();
    final data = AppData.preview(
      categories: const [],
      accounts: const [
        Account(id: 'h', name: 'HDFC A/c ••6516', kind: AccountKind.bank),
        Account(id: 'sb', name: 'Slice borrow', kind: AccountKind.card),
      ],
      loans: const [Loan(id: 's', lender: 'slice', name: 'Slice loan', kind: LoanKind.creditLine, accountId: 'sb')],
      transactions: [Txn(id: 't', amount: 136, isDebit: true, txnAt: now, merchant: 'Medical store', accountId: 'sb')],
    );
    await pump(tester, AccountsScreen(data: data));
    expect(find.text('HDFC A/c ••6516'), findsOneWidget);
    expect(find.text('Slice borrow'), findsNothing);
    expect(find.text('₹136'), findsNothing); // not in card dues
  });

  testWidgets('Accounts tab shows lender loans with details', (tester) async {
    final data = sample();
    await pump(tester, AccountsScreen(data: data));
    // The summary on top: total owed and what is due next.
    await tester.scrollUntilVisible(find.text('You owe in all'), 200, scrollable: find.byType(Scrollable).first);
    expect(find.text('Coming up'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('4 of 12 EMIs paid · 8 left'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Slice borrow'), findsWidgets);
    expect(find.text('KreditBee'), findsWidgets);
    expect(find.text('4 of 12 EMIs paid · 8 left'), findsOneWidget);
    expect(find.text('₹16,800'), findsOneWidget); // 8 × 2,100
    expect(find.text('₹1,636'), findsOneWidget); // slice: 1,500 + 136
  });

  testWidgets('loan details page', (tester) async {
    final data = sample();
    await pump(tester, LoanDetailScreen(data: data, loanId: 'k'));
    expect(find.text('Mark EMI paid'), findsOneWidget);
    expect(find.text('24% a year'), findsOneWidget);
    await tester.tap(find.text('Mark EMI paid'));
    await tester.pumpAndSettle();
    expect(find.text('Mark a payment'), findsOneWidget);
    expect(find.text('2100'), findsOneWidget); // EMI filled in
  });

  testWidgets('add-a-loan form', (tester) async {
    final data = sample();
    await pump(
      tester,
      Builder(
        builder: (c) => TextButton(onPressed: () => openLoanForm(c, data), child: const Text('go')),
      ),
    );
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    expect(find.text('Add a loan'), findsOneWidget);
    await tester.tap(find.text('Fibe'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextFormField, 'Fibe'), findsOneWidget);
  });
}
