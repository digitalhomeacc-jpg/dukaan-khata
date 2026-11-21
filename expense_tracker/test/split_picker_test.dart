// ignore_for_file: invalid_use_of_visible_for_testing_member
import 'package:expense_tracker/data/app_data.dart';
import 'package:expense_tracker/models.dart';
import 'package:expense_tracker/screens/split_section.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  testWidgets('split a bank payment: pick friends from a list, equally, never more than the bill', (tester) async {
    final pay = Txn(
      id: 'z',
      amount: 1200,
      isDebit: true,
      txnAt: DateTime(2026, 11, 15),
      merchant: 'Zomato',
      source: 'email',
    );
    final data = AppData.preview(
      myId: 'me',
      categories: const [],
      transactions: [pay],
      links: const [
        FriendLink(id: 'L', a: 'me', b: 'v', aNameForB: 'Abhinav Mukesh Pandey', bNameForA: 'S', code: 'x'),
      ],
    );
    data.people = {'rohan desai': 'friend'};
    data.personNames = {'rohan desai': 'Rohan Desai'};
    tester.view.physicalSize = const Size(400, 1600) * 3;
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SplitSection(data: data, payment: pay),
        ),
      ),
    );
    await tester.tap(find.text('Add a friend\'s part'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(FilterChip, 'Abhinav Mukesh Pandey'), findsOneWidget);
    expect(find.widgetWithText(FilterChip, 'Rohan Desai'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilterChip, 'Abhinav Mukesh Pandey'));
    await tester.tap(find.widgetWithText(FilterChip, 'Rohan Desai'));
    await tester.pumpAndSettle();
    expect(find.text('₹400'), findsNWidgets(2)); // you + 2 friends
    expect(find.text('Your part stays ₹400 · friends owe you ₹800'), findsOneWidget);
    // Typing a name you already have picks that person, not a new one.
    await tester.enterText(find.widgetWithText(TextField, 'Someone else'), 'rohan  DESAI');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.widgetWithText(FilterChip, 'rohan  DESAI'), findsNothing);
  });
}
