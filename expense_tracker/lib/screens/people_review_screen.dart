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
              'Friend: payments stay spending/income (things they bought for you); only what you mark '
              'as lent / borrowed / settle goes to your balance with them. Family: money from them is income. '
              'Me: your own account, not counted. Shop: a business on a personal UPI ID.',
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
              trailing: PopupMenuButton<String>(
                tooltip: 'Who is this?',
                onSelected: (role) => data.setPersonRole(p.name, role),
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'friend', child: Text('Friend')),
                  PopupMenuItem(value: 'family', child: Text('Family (money from them is income)')),
                  PopupMenuItem(value: 'me', child: Text('Me (my own account)')),
                  PopupMenuItem(value: 'shop', child: Text('Shop / service')),
                ],
                child: const Chip(label: Text('Who is this?')),
              ),
            ),
        ],
      ),
    );
  }
}
