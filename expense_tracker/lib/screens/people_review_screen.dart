import 'package:material_ui/material_ui.dart';

import '../data/app_data.dart';
import '../logic/summary.dart';
import '../ui/format.dart';

/// People (not shops) you paid or got money from: mark which are friends.
class PeopleReviewScreen extends StatelessWidget {
  const PeopleReviewScreen({super.key, required this.data});

  final AppData data;

  @override
  Widget build(BuildContext context) {
    final people = peopleToReview(data.transactions, decided: data.decidedPeople);
    return Scaffold(
      appBar: AppBar(title: const Text('Who are your friends?')),
      body: ListView(
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Text(
              'Money with friends goes to your balance with them, not to spending or income. '
              'A shop or driver paid on a personal UPI ID is not a friend: their payments stay as spending.',
            ),
          ),
          if (people.isEmpty)
            const Padding(padding: EdgeInsets.all(24), child: Text('All done. Nobody left to sort.', textAlign: TextAlign.center)),
          for (final p in people)
            ListTile(
              title: Text(p.name),
              subtitle: Text([
                '${p.count}×',
                if (p.sent > 0) 'sent ${money(p.sent)}',
                if (p.received > 0) 'got ${money(p.received)}',
              ].join(' · ')),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextButton(onPressed: () => data.markNotFriend(p.name), child: const Text('Not friend')),
                  const SizedBox(width: 4),
                  FilledButton.tonal(onPressed: () => data.markFriend(p.name), child: const Text('Friend')),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
