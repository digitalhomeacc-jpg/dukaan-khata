// ignore_for_file: invalid_use_of_visible_for_testing_member
import 'package:expense_tracker/data/app_data.dart';
import 'package:expense_tracker/screens/import_statement_screen.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  testWidgets('import screen explains the format and offers a file', (tester) async {
    tester.view.physicalSize = const Size(360, 780) * 3;
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: ImportStatementScreen(data: AppData.preview(transactions: const [], categories: const []))));
    expect(find.textContaining('XLS (Excel) or Delimited'), findsOneWidget);
    expect(find.text('Choose statement file'), findsOneWidget);
  });
}
