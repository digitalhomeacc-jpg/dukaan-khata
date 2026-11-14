// ignore_for_file: invalid_use_of_visible_for_testing_member
import 'package:expense_tracker/data/app_data.dart';
import 'package:expense_tracker/models.dart';
import 'package:expense_tracker/screens/txn_editor.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  testWidgets('a new udhaar bill split equally: your part and theirs, and you still owe the place all of it', (
    tester,
  ) async {
    final data = AppData.preview(
      categories: const [Category(id: 'f', name: 'Food', icon: 'restaurant', color: 0xFFFF5722)],
      accounts: const [Account(id: 'c', name: 'Cash', kind: AccountKind.cash)],
      transactions: const [],
    );
    tester.view.physicalSize = const Size(400, 2600) * 3;
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: TxnEditor(data: data)));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, 'Amount').first, '200');
    await tester.enterText(find.byType(TextFormField).at(1), 'Hotel Vijay');
    await tester.tap(find.text('On credit (udhaar), pay later'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add a friend'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Friend'), 'Ravi');
    await tester.tap(find.text('Split equally (2)'));
    await tester.pumpAndSettle();
    expect(find.text('100'), findsOneWidget);
    expect(
      find.text('Your part ₹100 is your spending. Friends owe you ₹100; you owe Hotel Vijay all ₹200.'),
      findsOneWidget,
    );
  });
}
