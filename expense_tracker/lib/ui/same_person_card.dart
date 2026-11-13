import 'package:material_ui/material_ui.dart';

import '../data/app_data.dart';
import '../logic/summary.dart';
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

/// Pick another name the bank uses for [person] (e.g. a parent's account): its payments then count as theirs.
Future<void> showAlsoKnownAs(BuildContext context, AppData data, String person) async {
  final suggested = [for (final c in data.otherNamesOf(person)) c.name];
  final counts = <String, int>{};
  for (final t in data.transactions) {
    final n = t.merchant?.trim();
    if (n == null || !looksLikePerson(n) || AppData.keyOf(n) == AppData.keyOf(person)) continue;
    if (data.aliases.containsKey(AppData.keyOf(n))) continue;
    counts[n] = (counts[n] ?? 0) + 1;
  }
  final all = counts.keys.toList()..sort();
  final ctl = TextEditingController();
  final first = person.split(' ').first;
  final picked = await showDialog<String>(
    context: context,
    builder: (c) => StatefulBuilder(
      builder: (c, setState) {
        final q = ctl.text.trim().toLowerCase();
        final list = q.isEmpty
            ? [...suggested, ...all.where((n) => !suggested.contains(n))]
            : all.where((n) => n.toLowerCase().contains(q)).toList();
        return AlertDialog(
          title: Text('$first is also…'),
          content: SizedBox(
            width: 380,
            height: 420,
            child: Column(
              children: [
                Text(
                  'Pick the name the bank shows when you pay $first or $first pays you from another account '
                  '(a parent\'s, a second bank). Those payments then count as $first.',
                  style: Theme.of(c).textTheme.bodySmall,
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: ctl,
                  autofocus: suggested.isEmpty,
                  decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search names'),
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: 4),
                Expanded(
                  child: ListView(
                    children: [
                      for (final n in list.take(80))
                        ListTile(
                          dense: true,
                          leading: suggested.contains(n) ? const Icon(Icons.auto_awesome, size: 18) : null,
                          title: Text(n),
                          subtitle: Text(
                            '${counts[n] ?? 0} payments${suggested.contains(n) ? ' · likely $first' : ''}',
                          ),
                          onTap: () => Navigator.pop(c, n),
                        ),
                      if (list.isEmpty && q.isNotEmpty)
                        ListTile(
                          leading: const Icon(Icons.add),
                          title: Text('Use “${ctl.text.trim()}”'),
                          onTap: () => Navigator.pop(c, ctl.text.trim()),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel'))],
        );
      },
    ),
  );
  if (picked != null && picked.isNotEmpty) await data.addAlias(picked, person);
}
