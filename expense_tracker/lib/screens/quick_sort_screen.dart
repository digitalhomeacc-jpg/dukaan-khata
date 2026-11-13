import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';

import '../data/app_data.dart';
import '../logic/summary.dart';
import '../models.dart';
import '../ui/category_style.dart';
import '../ui/format.dart';
import 'categories_screen.dart';

Future<void> openQuickSort(BuildContext context, AppData data) => Navigator.of(context).push(
  MaterialPageRoute<void>(
    builder: (_) => ListenableBuilder(
      listenable: data,
      builder: (_, _) => QuickSortScreen(data: data),
    ),
  ),
);

/// Sort payments with no category fast: one payee at a time, all at once or one by one.
class QuickSortScreen extends StatefulWidget {
  const QuickSortScreen({super.key, required this.data});

  final AppData data;

  @override
  State<QuickSortScreen> createState() => _QuickSortScreenState();
}

class _QuickSortScreenState extends State<QuickSortScreen> {
  final _skippedPayees = <String>{};
  final _skippedTxns = <String>{};
  var _oneByOne = false;
  var _done = 0;

  AppData get data => widget.data;

  Future<void> _apply(List<Txn> txns, String? categoryId, {required bool remember}) async {
    setState(() => _done += txns.length);
    if (remember) {
      final keys = {
        for (final t in txns)
          if (t.merchant != null) AppData.keyOf(t.merchant!),
      };
      await data.categorizePlace(keys, categoryId);
    } else {
      await data.categorizeTxns(txns.map((t) => t.id), categoryId);
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final all = unsortedByPayee(data.transactions, data.notSpendingCategoryIds);
    final queue = [
      ...all.where((g) => !_skippedPayees.contains(g.name)),
      ...all.where((g) => _skippedPayees.contains(g.name)),
    ];
    final left = all.fold(0, (s, g) => s + g.txns.length);
    final g = queue.firstOrNull;

    if (g == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Quick sort')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.celebration_outlined, size: 64, color: scheme.primary),
                const SizedBox(height: 12),
                Text('All sorted', style: text.headlineSmall),
                const SizedBox(height: 4),
                Text(
                  _done == 0
                      ? 'Every payment has a category.'
                      : '$_done payments sorted. Your reports are now precise.',
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      );
    }

    final isPerson = looksLikePerson(g.name);
    final role = data.people[AppData.keyOf(g.name)];
    final txnsLeft = g.txns.where((t) => !_skippedTxns.contains(t.id)).toList();
    final current = _oneByOne ? (txnsLeft.firstOrNull ?? g.txns.first) : null;
    final friends = data.loanCategory;

    Widget categoryGrid(void Function(String? id) pick) => Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final (:cat, :inGroup) in groupedCategories(data.categories.where((c) => !c.isLoan)))
          ActionChip(
            avatar: Icon(iconFor(cat), size: inGroup ? 16 : 18, color: colorFor(cat)),
            label: Text(cat.name),
            onPressed: () => pick(cat.id),
          ),
        if (friends != null && isPerson)
          ActionChip(
            avatar: const Icon(Icons.handshake_outlined, size: 18),
            label: const Text('Friends ledger'),
            onPressed: () => pick(friends.id),
          ),
        ActionChip(
          avatar: const Icon(Icons.add, size: 18),
          label: const Text('New category'),
          onPressed: () async {
            final id = await openCategoryForm(context, data);
            if (id != null) pick(id);
          },
        ),
      ],
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('Quick sort'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(28),
          child: Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              '$left payments left · ${all.length} payees${_done > 0 ? ' · $_done sorted' : ''}',
              style: text.bodySmall,
            ),
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              gradient: LinearGradient(colors: [scheme.primaryContainer, scheme.tertiaryContainer]),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    CircleAvatar(radius: 22, child: Text(g.name.isEmpty ? '?' : g.name[0].toUpperCase())),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(g.name, style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                          Text(
                            '${g.txns.length} payments · ${money(g.total)} · '
                            '${DateFormat('MMM yy').format(g.txns.last.txnAt)} – ${DateFormat('MMM yy').format(g.txns.first.txnAt)}',
                            style: text.bodySmall,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                if (isPerson) ...[
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    children: [
                      for (final r in const [
                        ('shop', 'Shop / service'),
                        ('friend', 'Friend'),
                        ('family', 'Family'),
                        ('me', 'Me'),
                      ])
                        ChoiceChip(
                          label: Text(r.$2),
                          selected: role == r.$1,
                          onSelected: (_) async {
                            await data.setPersonRole(g.name, r.$1);
                            if (r.$1 == 'me') await data.markOwnAccount({AppData.keyOf(g.name)});
                          },
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 16),
          SegmentedButton<bool>(
            showSelectedIcon: false,
            segments: [
              ButtonSegment(value: false, label: Text('All ${g.txns.length} at once')),
              const ButtonSegment(value: true, label: Text('One by one')),
            ],
            selected: {_oneByOne},
            onSelectionChanged: (s) => setState(() => _oneByOne = s.first),
          ),
          const SizedBox(height: 16),
          if (current != null) ...[
            Card.outlined(
              child: ListTile(
                title: Text(
                  '${current.isDebit ? '−' : '+'}${money(current.amount)}',
                  style: text.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: current.isDebit ? null : Colors.green.shade700,
                  ),
                ),
                subtitle: Text(
                  [
                    DateFormat('EEE d MMM yyyy, h:mm a').format(current.txnAt),
                    if (data.account(current.accountId) != null) data.account(current.accountId)!.name,
                    if ((current.details ?? '').isNotEmpty) current.details!,
                    if ((current.note ?? '').isNotEmpty) current.note!,
                  ].join('\n'),
                ),
                trailing: Text('${txnsLeft.length} left', style: text.bodySmall),
              ),
            ),
            const SizedBox(height: 12),
            Text('What was it?', style: text.titleSmall),
            const SizedBox(height: 8),
            categoryGrid((id) => _apply([current], id, remember: false)),
            const SizedBox(height: 12),
            TextButton(
              onPressed: () => setState(() => _skippedTxns.add(current.id)),
              child: const Text('Skip this payment'),
            ),
          ] else ...[
            Text(
              isPerson ? 'All ${g.txns.length} payments were…' : 'Everything at ${g.name} is…',
              style: text.titleSmall,
            ),
            const SizedBox(height: 8),
            categoryGrid((id) => _apply(g.txns, id, remember: !isPerson || role == 'shop')),
            const SizedBox(height: 8),
            Text(
              !isPerson || role == 'shop'
                  ? 'New payments here get the same category by themselves.'
                  : 'Only these payments: new ones from a person are asked again.',
              style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: () => setState(() => _skippedPayees.add(g.name)),
            icon: const Icon(Icons.skip_next),
            label: const Text('Skip this payee for now'),
          ),
        ],
      ),
    );
  }
}
