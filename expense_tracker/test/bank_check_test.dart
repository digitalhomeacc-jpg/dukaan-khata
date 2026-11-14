// ignore_for_file: invalid_use_of_visible_for_testing_member
import 'package:expense_tracker/data/app_data.dart';
import 'package:expense_tracker/logic/summary.dart';
import 'package:expense_tracker/models.dart';
import 'package:expense_tracker/screens/friends_screen.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

const me = 'me', ravi = 'ravi';

SharedEntry entry(String id, double amount, {String? mine, String? theirs, String? mergedInto}) => SharedEntry(
  id: id,
  linkId: 'L',
  creditor: me,
  debtor: ravi,
  amount: amount,
  kind: 'payment',
  at: DateTime(2026, 11, 1),
  createdBy: me,
  confirmedAmount: mergedInto == null ? amount : null,
  confirmedAt: DateTime(2026, 11, 1),
  creditorTxn: mine,
  debtorTxn: theirs,
  mergedInto: mergedInto,
  deletedAt: mergedInto == null ? null : DateTime(2026, 11, 2),
);

void main() {
  final entries = [
    entry('a', 500, mine: 't1', theirs: 'u1'),
    entry('b', 300, mine: 't2'),
    entry('c', 200, theirs: 'u3'),
    entry('d', 100),
    entry('dup', 500, theirs: 'u1x', mergedInto: 'a'),
  ];

  test('check with banks: what each bank backs; merged duplicates are not counted', () {
    final c = bankCheck(entries, 'L', me);
    expect(c[Backing.both], (count: 1, amount: 500.0));
    expect(c[Backing.mine], (count: 1, amount: 300.0));
    expect(c[Backing.theirs], (count: 1, amount: 200.0));
    expect(c[Backing.none], (count: 1, amount: 100.0));
    expect(sharedBalance(entries, 'L', me), -1100); // the merged duplicate never counts
  });

  testWidgets('friend page shows the check and each record\'s banks', (tester) async {
    final data = AppData.preview(
      myId: me,
      categories: const [],
      transactions: const [],
      links: const [FriendLink(id: 'L', a: me, b: ravi, aNameForB: 'Ravi Kumar', bNameForA: 'Asha', code: 'abc')],
      sharedEntries: entries,
    );
    tester.view.physicalSize = const Size(400, 2400) * 3;
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: FriendDetailScreen(data: data, person: 'Ravi Kumar'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Check with banks'), findsOneWidget);
    expect(find.text('In both banks (1)'), findsOneWidget);
    expect(find.text('Only in Ravi\'s bank (1)'), findsOneWidget);
    expect(find.textContaining('in both banks ✓'), findsOneWidget);
    expect(find.textContaining('added by hand'), findsOneWidget);
    expect(find.textContaining('merged'), findsNothing); // the duplicate is hidden
  });
}
