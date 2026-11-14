// ignore_for_file: invalid_use_of_visible_for_testing_member
import 'package:expense_tracker/data/app_data.dart';
import 'package:expense_tracker/models.dart';
import 'package:expense_tracker/screens/friends_screen.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const me = 'me-id', ravi = 'ravi-id';
  AppData build(Map<String, String> aliases) {
    final d = AppData.preview(
      myId: me,
      categories: const [],
      transactions: [
        Txn(id: '1', amount: 500, isDebit: true, txnAt: DateTime(2026, 11, 1), merchant: 'Ravi Shankar Kumar'),
      ],
      links: const [FriendLink(id: 'L', a: me, b: ravi, aNameForB: 'Ravi Kumar', bNameForA: 'Asha', code: 'abc')],
      aliases: aliases,
    );
    // Marked as a friend under the bank's full name (the second row before the fix).
    d.people = {'ravi shankar kumar': 'friend', 'ravi kumar': 'friend'};
    d.personNames = {'ravi shankar kumar': 'Ravi Shankar Kumar', 'ravi kumar': 'Ravi Kumar'};
    return d;
  }

  test('"also known as" makes one row, whichever name is the main one', () {
    final a = friendRows(build({'ravi shankar kumar': 'Ravi Kumar'}));
    expect(a.map((r) => r.person), ['Ravi Kumar']);
    expect(a.single.link?.id, 'L');

    final b = friendRows(build({'ravi kumar': 'Ravi Shankar Kumar'}));
    expect(b.map((r) => r.person), ['Ravi Shankar Kumar']);
    expect(b.single.link?.id, 'L'); // still the connected friend
  });

  test('without "also known as" they stay two people', () {
    expect(friendRows(build(const {})).length, 2);
  });
}
