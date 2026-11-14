// ignore_for_file: invalid_use_of_visible_for_testing_member
import 'package:expense_tracker/data/app_data.dart';
import 'package:expense_tracker/logic/reports.dart';
import 'package:expense_tracker/logic/summary.dart';
import 'package:expense_tracker/models.dart';
import 'package:expense_tracker/screens/reports_screen.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  final h = Account(id: 'h', name: 'HDFC', openingBalance: 1000, openingDate: DateTime(2026, 10, 1));
  const cash = Account(id: 'c', name: 'Cash', kind: AccountKind.cash);
  final txns = [
    Txn(
      id: 'a',
      amount: 200,
      isDebit: true,
      txnAt: DateTime(2026, 10, 20),
      accountId: 'h',
      merchant: 'Zomato',
      categoryId: 'f',
    ),
    Txn(
      id: 'b',
      amount: 5000,
      isDebit: false,
      txnAt: DateTime(2026, 11, 1),
      accountId: 'h',
      merchant: 'Home',
      categoryId: 'inc',
    ),
    Txn(
      id: 'c',
      amount: 300,
      isDebit: true,
      txnAt: DateTime(2026, 11, 2),
      accountId: 'h',
      merchant: 'Hotel, "Vijay"',
      categoryId: 'f',
      note: 'thali\nparcel',
    ),
    // ATM: HDFC → Cash, a move: out of one, into the other, not spending.
    Txn(
      id: 'd',
      amount: 1000,
      isDebit: true,
      txnAt: DateTime(2026, 11, 3),
      accountId: 'h',
      merchant: 'ATM cash',
      excluded: true,
      counterAccountId: 'c',
    ),
  ];
  final from = DateTime(2026, 11, 1), to = DateTime(2026, 12, 1);

  test('account statement: opening + in − out = closing, moves count on both sides', () {
    final s = accountStatement(txns, h, from, to);
    expect((s.opening, s.moneyIn, s.moneyOut, s.closing), (800.0, 5000.0, 1300.0, 4500.0));
    expect(s.opening + s.moneyIn - s.moneyOut, s.closing);
    final c = accountStatement(txns, cash, from, to);
    expect((c.opening, c.moneyIn, c.moneyOut, c.closing), (0.0, 1000.0, 0.0, 1000.0));
  });

  test('income and expenses leave out moves between your own accounts', () {
    final ie = incomeExpense(txns, from, to);
    expect(ie.totalIncome, 5000);
    expect(ie.totalExpenses, 300); // not the 1,000 ATM move
  });

  test('Excel file: one row per transaction, commas, quotes and new lines kept safe', () {
    final csv = transactionsCsv(
      txns,
      from,
      to,
      categoryName: (id) => {'f': 'Food', 'inc': 'Salary'}[id],
      groupName: (_) => null,
      accountName: (id) => id == 'h' ? 'HDFC' : null,
    );
    final lines = csv.substring(1).split('\r\n')..removeLast();
    expect(lines.first, startsWith('Date,Time,Account,Money out,Money in'));
    expect(csv, contains('"Hotel, ""Vijay"""')); // quotes doubled, comma inside quotes
    expect(csv, contains('"thali\nparcel"'));
    expect(csv, contains('No (between your accounts)'));
    expect(csv.startsWith('﻿'), isTrue); // so Excel reads ₹ correctly
    expect(lines, hasLength(1 + 3)); // header + 3 November rows; the note's line break sits inside quotes
  });

  testWidgets('reports screen shows statements, income and expenses, and downloads', (tester) async {
    final data = AppData.preview(transactions: txns, categories: const [], accounts: [h, cash]);
    tester.view.physicalSize = const Size(360, 780) * 3;
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: ReportsScreen(data: data)));
    await tester.pumpAndSettle();
    expect(find.text('Account statements'), findsWidgets);
    expect(find.text('HDFC'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('All transactions'), 300, scrollable: find.byType(Scrollable).first);
    expect(find.text('All transactions'), findsOneWidget);
    expect(shareTotals(const []).own(txns.first), 200);
  });
}
