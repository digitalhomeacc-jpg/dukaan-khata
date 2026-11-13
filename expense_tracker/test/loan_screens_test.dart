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
  testWidgets('Accounts tab shows lender loans with details', (tester) async {
    final data = sample();
    await pump(tester, AccountsScreen(data: data));
    await tester.scrollUntilVisible(find.text('KreditBee'), 200, scrollable: find.byType(Scrollable).first);
    expect(find.text('Slice borrow'), findsOneWidget);
    expect(find.text('KreditBee'), findsOneWidget);
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
