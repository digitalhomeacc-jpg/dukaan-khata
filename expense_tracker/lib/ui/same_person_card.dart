import 'package:material_ui/material_ui.dart';

import '../data/app_data.dart';
import 'format.dart';

/// "Is Chetan V Parmar also Vaibhav?": the bank shows the name of the account behind a UPI ID, which
/// can be a parent's. One tap joins them; their payments then count as this person's.
class SamePersonCard extends StatelessWidget {
  const SamePersonCard({super.key, required this.data, required this.person});

  final AppData data;
  final String person;

  @override
  Widget build(BuildContext context) {
    final list = data.otherNamesOf(person);
    if (list.isEmpty) return const SizedBox.shrink();
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final first = person.split(' ').first;
    return Card.outlined(
      margin: const EdgeInsets.symmetric(vertical: 8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.person_search, color: scheme.primary, size: 20),
                const SizedBox(width: 8),
                Expanded(child: Text('Also $first?', style: text.titleSmall)),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'The bank shows the name on the account behind a UPI ID, which can be a parent\'s.',
              style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
            for (final c in list)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(c.name, style: text.bodyLarge?.copyWith(fontWeight: FontWeight.w600)),
                    Text(
                      [
                        c.why,
                        '${c.count} payments',
                        if (c.out > 0) 'sent ${money(c.out)}',
                        if (c.into > 0) 'got ${money(c.into)}',
                      ].join(' · '),
                      style: text.bodySmall,
                    ),
                    Row(
                      children: [
                        FilledButton.tonal(onPressed: () => data.addAlias(c.name, person), child: Text('Yes, $first')),
                        const SizedBox(width: 8),
                        TextButton(onPressed: () => data.markNotSame(c.name), child: const Text('No')),
                      ],
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
