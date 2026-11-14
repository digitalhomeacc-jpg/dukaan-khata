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
        confirmedAmount: 500,
        confirmedAt: now,
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
        confirmedAmount: 200,
        confirmedAt: now,
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
        confirmedAmount: 300,
        confirmedAt: now,
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
      // Waiting: Ravi added ₹150 you owe (not agreed yet); you asked him to OK ₹80.
      SharedEntry(
        id: 'w1',
        linkId: 'L',
        creditor: ravi,
        debtor: me,
        amount: 150,
        kind: 'expense',
        at: now,
        createdBy: ravi,
        changedBy: ravi,
        description: 'Chai',
      ),
      SharedEntry(
        id: 'w2',
        linkId: 'L',
        creditor: me,
        debtor: ravi,
        amount: 80,
        kind: 'payment',
        at: now,
        createdBy: me,
        changedBy: me,
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
    await tester.scrollUntilVisible(find.text('₹600'), 200, scrollable: find.byType(Scrollable).first);
    expect(find.text('₹600'), findsWidgets); // agreed balance only: the ₹150 waiting is not in it
    await tester.scrollUntilVisible(find.textContaining('connected'), 200, scrollable: find.byType(Scrollable).first);
    expect(find.textContaining('connected'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Same payment?'), -200, scrollable: find.byType(Scrollable).first);
    expect(find.text('Same payment?'), findsOneWidget);
    expect(find.textContaining('Kiran Shah'), findsWidgets);
  });

  testWidgets('connected friend page: shared history', (tester) async {
    await pump(tester, FriendDetailScreen(data: sample(), person: 'Ravi Kumar'));
    expect(find.text('Ravi Kumar owes you'), findsOneWidget);
    expect(find.text('Connected'), findsOneWidget);
    expect(find.text('Also known as'), findsOneWidget);
    expect(find.text('vijay kumar'), findsOneWidget);
    expect(find.text('Show as this name'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.textContaining("Ravi Kumar's share · Pizza"),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.textContaining("Ravi Kumar's share · Pizza"), findsOneWidget);
    await tester.scrollUntilVisible(
      find.textContaining('removed by Ravi Kumar'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.textContaining('removed by Ravi Kumar'), findsOneWidget);
  });

  testWidgets('not connected friend page offers an invite', (tester) async {
    await pump(tester, FriendDetailScreen(data: sample(), person: 'Priya Desai'));
    expect(find.textContaining('Invite sent · code xyz'), findsOneWidget);
  });

  test('a shared balance moves only on what both agreed', () {
    final d = sample();
    final me = d.me!;
    // 500 + 300 − 200 agreed; the ₹150 and ₹80 waiting for an OK do not count yet.
    expect(sharedBalance(d.sharedEntries, 'L', me), -600);
    final changed = SharedEntry(
      id: 'c',
      linkId: 'L',
      creditor: me,
      debtor: 'x',
      amount: 900,
      kind: 'payment',
      at: DateTime(2026),
      createdBy: me,
      confirmedAmount: 700,
      changedBy: me,
    );
    // A changed amount waiting for OK: the agreed 700 counts, not 900.
    expect(sharedBalance([changed], 'L', me), -700);
    expect(changed.waiting, isTrue);
  });

  testWidgets('changes from a friend wait for your OK, with a badge-worthy card', (tester) async {
    final d = sample();
    expect(d.waitingForMe.map((e) => e.id), ['w1']);
    await pump(tester, FriendsScreen(data: d));
    expect(find.text('1 change waiting for your OK'), findsOneWidget);
    expect(find.text('OK'), findsWidgets);
    expect(find.text('No'), findsWidgets);
    await pump(tester, FriendDetailScreen(data: d, person: 'Ravi Kumar'));
    await tester.scrollUntilVisible(
      find.textContaining("Waiting for Ravi Kumar's OK"),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.textContaining("Waiting for Ravi Kumar's OK"), findsOneWidget);
  });
}
