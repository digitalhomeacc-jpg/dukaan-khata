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
    // No OK: everything not removed counts at once. 500 + 300 − 200 − 150 (chai Ravi paid) + 80 (you paid).
    expect(sharedBalance(sample().sharedEntries, 'L', me), -530);
  });

  testWidgets('friends list uses the shared balance and shows the question', (tester) async {
    await pump(tester, FriendsScreen(data: sample()));
    await tester.scrollUntilVisible(find.text('₹530'), 200, scrollable: find.byType(Scrollable).first);
    expect(find.text('₹530'), findsWidgets); // every entry counts at once
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
    expect(find.byTooltip('Options for vijay kumar'), findsOneWidget);
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

  testWidgets('connected under another name ("Also known as"): the page still shows the connection', (tester) async {
    final d = sample();
    // The connection was made as "vijay kumar", which shows as Ravi Kumar.
    d.links = const [FriendLink(id: 'L', a: me, b: ravi, aNameForB: 'vijay kumar', bNameForA: 'Asha', code: 'abc')];
    expect(d.linkFor('Ravi Kumar')?.id, 'L');
    expect(friendRows(d).where((r) => r.link != null).single.person, 'Ravi Kumar');
    await pump(tester, FriendDetailScreen(data: d, person: 'Ravi Kumar'));
    expect(find.text('Connected'), findsOneWidget);
    expect(find.text('Ravi Kumar owes you'), findsOneWidget);
    expect(find.textContaining('Connect with'), findsNothing);
  });

  testWidgets('not connected friend page offers an invite', (tester) async {
    await pump(tester, FriendDetailScreen(data: sample(), person: 'Priya Desai'));
    expect(find.textContaining('Invite sent · code xyz'), findsOneWidget);
  });

  test('no OK: a changed amount counts at once; a removal asked for under the old rules counts as removed', () {
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
    expect(sharedBalance([changed], 'L', me), -900);
    expect(changed.waiting, isFalse);
    final asked = SharedEntry(
      id: 'r',
      linkId: 'L',
      creditor: me,
      debtor: 'x',
      amount: 50,
      kind: 'payment',
      at: DateTime(2026),
      createdBy: me,
      removeRequestedBy: 'x',
    );
    expect(sharedBalance([changed, asked], 'L', me), -900);
  });

  testWidgets('nothing waits for an OK; tapping an entry opens it to edit', (tester) async {
    final d = sample();
    expect(d.waitingForMe, isEmpty);
    await pump(tester, FriendsScreen(data: d));
    expect(find.textContaining('waiting for your OK'), findsNothing);
    await pump(tester, FriendDetailScreen(data: d, person: 'Ravi Kumar'));
    expect(find.text('I gave'), findsOneWidget);
    expect(find.text('I got'), findsOneWidget);
    await tester.scrollUntilVisible(find.textContaining('Chai'), 200, scrollable: find.byType(Scrollable).first);
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -150));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Chai'));
    await tester.pumpAndSettle();
    expect(find.text('Entry with Ravi'), findsOneWidget);
    expect(find.text('Ravi paid'), findsOneWidget);
    expect(find.text('Save'), findsOneWidget);
  });

  test('in my bank? same money, the right way, a week either side, this friend first', () {
    final at = DateTime(2026, 11, 15, 12);
    final e = SharedEntry(
      id: 'x',
      linkId: 'L',
      creditor: me,
      debtor: ravi,
      amount: 125,
      kind: 'payment',
      at: at,
      createdBy: ravi,
      debtorTxn: 'his',
    );
    Txn t(String id, double a, int dayOff, {bool debit = true, String m = 'Someone', String? loanRole}) => Txn(
      id: id,
      amount: a,
      isDebit: debit,
      txnAt: at.add(Duration(days: dayOff)),
      merchant: m,
      loanRole: loanRole,
    );
    final txns = [
      t('near', 125, 1),
      t('friend', 125, -3, m: 'Ravi Kumar'),
      t('far', 125, 20),
      t('in', 125, 0, debit: false),
      t('other', 120, 0),
      t('loan', 125, 0, loanRole: 'repay'),
    ];
    bool friend(Txn x) => x.merchant == 'Ravi Kumar';
    expect(bankMatchesFor(e, me, txns, [e], isFriend: friend).map((x) => x.id), ['friend', 'near']);
    expect(bankMatchesFor(e, me, txns, [e], isFriend: friend, anyDate: true).map((x) => x.id), [
      'friend',
      'near',
      'far',
    ]);
    // Already one both banks agree on: not offered again.
    final done = SharedEntry(
      id: 'y',
      linkId: 'L',
      creditor: me,
      debtor: ravi,
      amount: 125,
      kind: 'payment',
      at: at,
      createdBy: me,
      creditorTxn: 'near',
      debtorTxn: 'his2',
    );
    expect(bankMatchesFor(e, me, txns, [e, done], isFriend: friend).map((x) => x.id), ['friend']);
  });

  testWidgets('an entry from their bank: "Is it in your bank?" with the payment to pick', (tester) async {
    final d = sample();
    final now = DateTime.now();
    final e = SharedEntry(
      id: 'x',
      linkId: 'L',
      creditor: me,
      debtor: ravi,
      amount: 125,
      kind: 'payment',
      at: now,
      createdBy: ravi,
      debtorTxn: 'his',
    );
    d.transactions = [
      ...d.transactions,
      Txn(id: 'mine', amount: 125, isDebit: true, txnAt: now, merchant: '9800000000@ibl', source: 'email'),
    ];
    await pump(
      tester,
      Scaffold(
        body: Builder(
          builder: (c) => TextButton(onPressed: () => openSharedEntry(c, d, e, 'Ravi Kumar'), child: const Text('go')),
        ),
      ),
    );
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    expect(find.textContaining("From Ravi's bank"), findsOneWidget);
    expect(find.text('Is it in your bank?'), findsOneWidget);
    expect(find.text('9800000000@ibl'), findsOneWidget);
    expect(find.text('This one'), findsOneWidget);
    expect(find.text('Change this entry'), findsOneWidget);
  });

  test('answering "same payment?" removes the card at once; if saving fails it comes back', () async {
    final d = sample();
    expect(d.questions, hasLength(1));
    final seen = <int>[];
    d.addListener(() => seen.add(d.questions.length));
    await expectLater(d.answerMatch('q', false), throwsA(anything)); // no server in tests: the save fails…
    expect(seen.first, 0); // …but the card went away at once, before any server answer
    expect(d.questions, hasLength(1)); // and on failure it is back, nothing lost
  });
}
