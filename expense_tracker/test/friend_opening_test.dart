// ignore_for_file: invalid_use_of_visible_for_testing_member
import 'package:expense_tracker/data/app_data.dart';
import 'package:expense_tracker/logic/summary.dart';
import 'package:expense_tracker/models.dart';
import 'package:expense_tracker/screens/friends_screen.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

const me = 'me', ravi = 'ravi';

SharedEntry e(String id, double amount, DateTime at, {bool iPaid = true}) => SharedEntry(
  id: id,
  linkId: 'L',
  creditor: iPaid ? me : ravi,
  debtor: iPaid ? ravi : me,
  amount: amount,
  kind: 'payment',
  at: at,
  createdBy: me,
  confirmedAmount: amount,
  confirmedAt: at,
);

void main() {
  final opening = FriendOpening(
    id: 'o',
    linkId: 'L',
    asOf: DateTime(2026, 11, 10),
    owedBy: me,
    amount: 86,
    createdBy: me,
    confirmedAt: DateTime(2026, 11, 11),
  );

  test('agreed opening: its amount plus only later entries; old ones imported later never move it', () {
    final before = [
      e('a', 7078, DateTime(2026, 11, 3)),
      e('b', 250, DateTime(2026, 11, 10, 22)), // on the opening day: already in it
      e('c', 100, DateTime(2026, 11, 12)), // after: counts (you paid him: he owes ₹100 less of your ₹86)
    ];
    expect(sharedBalance(before, 'L', me, opening: opening), -14); // 86 − 100
    // His statement import later adds an old transfer from October: history only, nothing changes.
    final after = [...before, e('old', 5000, DateTime(2026, 10, 20), iPaid: false)];
    expect(sharedBalance(after, 'L', me, opening: opening), -14);
    // Without an opening, everything counts.
    expect(sharedBalance(before, 'L', me), -7428);
  });

  testWidgets('friend page: the opening, a proposal to OK, and older entries marked history only', (tester) async {
    final data = AppData.preview(
      myId: me,
      categories: const [],
      transactions: const [],
      links: const [FriendLink(id: 'L', a: me, b: ravi, aNameForB: 'Ravi Kumar', bNameForA: 'Asha', code: 'abc')],
      sharedEntries: [e('a', 7078, DateTime(2026, 11, 3)), e('c', 100, DateTime(2026, 11, 12))],
      openings: [
        opening,
        FriendOpening(id: 'p', linkId: 'L', asOf: DateTime(2026, 11, 13), owedBy: ravi, amount: 20, createdBy: ravi),
      ],
    );
    tester.view.physicalSize = const Size(400, 2600) * 3;
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: FriendDetailScreen(data: data, person: 'Ravi Kumar'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Opening balance'), findsOneWidget);
    // No OK: the latest opening counts at once (Ravi's ₹20 from the 13th).
    expect(find.textContaining('Ravi owed you ₹20, set by Ravi'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'OK'), findsNothing);
    expect(find.textContaining('before the opening balance · history only'), findsNWidgets(2)); // both before the 13th
    expect(data.openingsWaitingForMe, isEmpty);
  });
}
