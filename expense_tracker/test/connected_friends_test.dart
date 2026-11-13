// ignore_for_file: invalid_use_of_visible_for_testing_member
import 'package:expense_tracker/data/app_data.dart';
import 'package:expense_tracker/logic/summary.dart';
import 'package:expense_tracker/models.dart';
import 'package:expense_tracker/screens/friends_screen.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

const me = 'me', ravi = 'ravi';

AppData sample() {
  final now = DateTime.now();
  return AppData.preview(
    myId: me,
    categories: const [Category(id: 'fr', name: 'Friends', icon: 'group', color: 0xFF3F51B5, isLoan: true)],
    aliases: const {'vijay kumar': 'Ravi Kumar'},
    links: const [
      FriendLink(id: 'L', a: me, b: ravi, aNameForB: 'Ravi Kumar', bNameForA: 'Asha', code: 'abc'),
      FriendLink(id: 'P', a: me, aNameForB: 'Priya Desai', code: 'xyz'),
    ],
    sharedEntries: [
      SharedEntry(
        id: 'e1',
        linkId: 'L',
        creditor: me,
        debtor: ravi,
        amount: 500,
        kind: 'payment',
        at: now,
        createdBy: me,
      ),
      SharedEntry(
        id: 'e2',
        linkId: 'L',
        creditor: ravi,
        debtor: me,
        amount: 200,
        kind: 'payment',
        at: now,
        createdBy: ravi,
      ),
      SharedEntry(
        id: 'e3',
        linkId: 'L',
        creditor: me,
        debtor: ravi,
        amount: 300,
        kind: 'expense',
        at: now,
        createdBy: me,
        description: 'Pizza',
      ),
      SharedEntry(
        id: 'e4',
        linkId: 'L',
        creditor: me,
        debtor: ravi,
        amount: 999,
        kind: 'payment',
        at: now,
        createdBy: ravi,
        deletedAt: now,
        deletedBy: ravi,
      ),
    ],
    questions: const [MatchQuestion(id: 'q', entryId: 'e2', txnId: 't9')],
    transactions: [
      Txn(id: 't1', amount: 500, isDebit: true, txnAt: now, merchant: 'Ravi Kumar', categoryId: 'fr', source: 'email'),
      Txn(
        id: 't2',
        amount: 100,
        isDebit: false,
        txnAt: now,
        merchant: 'Vijay Kumar',
        categoryId: 'fr',
        source: 'email',
      ),
      Txn(id: 't9', amount: 200, isDebit: true, txnAt: now, merchant: 'Kiran Shah', source: 'email'),
      Txn(id: 't3', amount: 50, isDebit: true, txnAt: now, merchant: 'Priya Desai', categoryId: 'fr', source: 'email'),
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
  test('also-known-as names count as the friend', () {
    final d = sample();
    final l = loanBalances(d.transactions, d.loanCategoryIds, aliases: d.aliases);
    final ravi = l.firstWhere((x) => x.person == 'Ravi Kumar');
    expect(ravi.balance, -400); // sent 500, got 100 from his father's account
    expect(l.any((x) => x.person == 'Vijay Kumar'), false);
  });

  test('connected friend balance comes from the shared record (removed entries ignored)', () {
    expect(sharedBalance(sample().sharedEntries, 'L', me), -600); // 500 + 300 − 200: Ravi owes 600
  });

  testWidgets('friends list uses the shared balance and shows the question', (tester) async {
    await pump(tester, FriendsScreen(data: sample()));
    expect(find.text('₹600'), findsWidgets);
    expect(find.textContaining('connected'), findsOneWidget);
    expect(find.text('Same payment?'), findsOneWidget);
    expect(find.textContaining('Kiran Shah'), findsWidgets);
  });

  testWidgets('connected friend page: shared history', (tester) async {
    await pump(tester, FriendDetailScreen(data: sample(), person: 'Ravi Kumar'));
    expect(find.text('Ravi Kumar owes you'), findsOneWidget);
    expect(find.text('Connected'), findsOneWidget);
    expect(find.textContaining("Ravi Kumar's share · Pizza"), findsOneWidget);
    expect(find.textContaining('removed by Ravi Kumar'), findsOneWidget);
    expect(find.textContaining('Also: vijay kumar'), findsOneWidget);
  });

  testWidgets('not connected friend page offers an invite', (tester) async {
    await pump(tester, FriendDetailScreen(data: sample(), person: 'Priya Desai'));
    expect(find.textContaining('Invite sent · code xyz'), findsOneWidget);
  });
}
