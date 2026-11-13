import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';

import '../data/app_data.dart';
import '../logic/summary.dart';
import '../ui/category_style.dart';
import '../ui/format.dart';
import 'txn_editor.dart';

enum _Period { month, three, year, all }

/// Where your money goes, grouped by place: visits, total, average, last visit.
class PlacesView extends StatefulWidget {
  const PlacesView({super.key, required this.data});

  final AppData data;

  @override
  State<PlacesView> createState() => _PlacesViewState();
}

class _PlacesViewState extends State<PlacesView> {
  var _period = _Period.three;
  var _byAmount = false;
  var _query = '';

  DateTime? get _from {
    final now = DateTime.now();
    return switch (_period) {
      _Period.month => DateTime(now.year, now.month),
      _Period.three => DateTime(now.year, now.month - 2),
      _Period.year => DateTime(now.year - 1, now.month, now.day),
      _Period.all => null,
    };
  }

  @override
  Widget build(BuildContext context) {
    final data = widget.data;
    var groups = payeeGroups(data.transactions,
        from: _from, loanCategoryIds: data.loanCategoryIds, shares: data.shareTotalsNow, aliases: data.aliases);
    if (_byAmount) groups.sort((a, b) => b.total.compareTo(a.total));
    if (_query.isNotEmpty) {
      final q = _query.toLowerCase();
      groups = groups.where((g) => g.name.toLowerCase().contains(q) || (data.category(g.categoryId)?.name.toLowerCase().contains(q) ?? false)).toList();
    }
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.only(bottom: 96),
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Row(
            children: [
              for (final p in _Period.values)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(switch (p) {
                      _Period.month => 'This month',
                      _Period.three => '3 months',
                      _Period.year => '12 months',
                      _Period.all => 'All time',
                    }),
                    selected: _period == p,
                    onSelected: (_) => setState(() => _period = p),
                  ),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 8, 0),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search places', isDense: true),
                  onChanged: (v) => setState(() => _query = v.trim()),
                ),
              ),
              const SizedBox(width: 4),
              TextButton.icon(
                onPressed: () => setState(() => _byAmount = !_byAmount),
                icon: const Icon(Icons.sort, size: 18),
                label: Text(_byAmount ? 'By amount' : 'By visits'),
              ),
            ],
          ),
        ),
        if (groups.isEmpty)
          const Padding(padding: EdgeInsets.all(32), child: Text('No spending in this period.', textAlign: TextAlign.center)),
        for (final (i, g) in groups.take(150).indexed)
          ListTile(
            leading: CategoryAvatar(data.category(g.categoryId)),
            title: Text(g.name, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(
              '${g.count}× · avg ${money(g.average)} · last ${dayLabel(g.lastPaid)}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text('−${money(g.total)}', style: const TextStyle(fontWeight: FontWeight.w600)),
                if (g.received > 0)
                  Text('+${money(g.received)}', style: TextStyle(fontSize: 12, color: Colors.green.shade700))
                else if (i < 3 && !_byAmount)
                  Text(['Most frequent', '2nd', '3rd'][i], style: TextStyle(fontSize: 11, color: scheme.primary)),
              ],
            ),
            onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
              builder: (_) => ListenableBuilder(listenable: data, builder: (_, _) => PlaceDetailScreen(data: data, keys: g.keys)),
            )),
          ),
      ],
    );
  }
}

/// One place: how often, how much, by month, every visit; set its category for all of them.
class PlaceDetailScreen extends StatelessWidget {
  const PlaceDetailScreen({super.key, required this.data, required this.keys});

  final AppData data;
  final Set<String> keys;

  @override
  Widget build(BuildContext context) {
    final g = payeeGroups(data.transactions, loanCategoryIds: data.loanCategoryIds, shares: data.shareTotalsNow, aliases: data.aliases)
        .where((x) => x.keys.any(keys.contains))
        .firstOrNull;
    if (g == null) return const Scaffold(body: Center(child: Text('No spending here any more.')));
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final months = g.byMonth.reversed.take(12).toList();
    final maxMonth = months.fold(0.0, (m, e) => e.value > m ? e.value : m);
    Widget stat(String label, String value) => Expanded(
          child: Column(children: [
            Text(value, style: text.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
            Text(label, style: text.bodySmall),
          ]),
        );

    return Scaffold(
      appBar: AppBar(title: Text(g.name)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          Card.filled(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Row(children: [
                stat('paid', money(g.total)),
                if (g.received > 0) stat('came back', money(g.received)),
                if (g.received > 0)
                  stat(g.net >= 0 ? 'net in' : 'net out', money(g.net.abs()))
                else ...[
                  stat('payments', '${g.count}'),
                  stat('average', money(g.average)),
                ],
              ]),
            ),
          ),
          if (g.received > 0)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text('${g.count} payments out (avg ${money(g.average)}), ${g.receivedCount} back',
                  style: TextStyle(color: scheme.onSurfaceVariant)),
            ),
          const SizedBox(height: 8),
          Text(
            'About ${g.perMonth >= 1 ? g.perMonth.toStringAsFixed(g.perMonth >= 10 ? 0 : 1) : '<1'} times a month · '
            'first ${DateFormat('d MMM yyyy').format(g.first)} · last ${dayLabel(g.lastPaid)}',
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
          if (g.spellings.length > 1) ...[
            const SizedBox(height: 4),
            Text('Written ${g.spellings.length} ways in your bank: ${g.spellings.take(4).join(' · ')}', style: text.bodySmall),
          ],
          const SizedBox(height: 16),
          Text('Category for all its payments', style: text.titleSmall),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final c in data.categories.where((c) => !c.isLoan))
                ChoiceChip(
                  avatar: Icon(iconFor(c), size: 18, color: colorFor(c)),
                  label: Text(c.name),
                  selected: g.categoryId == c.id,
                  onSelected: (_) => data.categorizePlace(g.keys, c.id),
                ),
            ],
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            icon: const Icon(Icons.swap_horiz),
            label: const Text('Not spending: it\'s my own account'),
            onPressed: () async {
              final yes = await showDialog<bool>(
                context: context,
                builder: (c) => AlertDialog(
                  title: Text('Is ${g.name} your own account?'),
                  content: const Text('Then money to and from it is a move between your accounts: not counted as spending or income.'),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
                    FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Yes, my account')),
                  ],
                ),
              );
              if (yes == true) {
                await data.markOwnAccount(g.keys);
                if (context.mounted) Navigator.pop(context);
              }
            },
          ),
          const SizedBox(height: 20),
          Text('By month', style: text.titleSmall),
          const SizedBox(height: 8),
          for (final m in months)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                children: [
                  SizedBox(width: 72, child: Text(DateFormat('MMM yy').format(m.key))),
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(value: maxMonth == 0 ? 0 : m.value / maxMonth, minHeight: 10),
                    ),
                  ),
                  SizedBox(width: 84, child: Text(money(m.value), textAlign: TextAlign.end)),
                ],
              ),
            ),
          const SizedBox(height: 20),
          Text('Visits', style: text.titleSmall),
          for (final t in g.txns.take(200))
            ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: Text('${dayLabel(t.txnAt)}, ${timeLabel(t.txnAt)}'),
              subtitle: data.account(t.accountId) == null ? null : Text(data.account(t.accountId)!.name),
              trailing: Text(signedMoney(data.shareTotalsNow.own(t), isDebit: t.isDebit),
                  style: TextStyle(fontWeight: FontWeight.w600, color: t.isDebit ? null : Colors.green.shade700)),
              onTap: () => openTxnEditor(context, data, existing: t),
            ),
        ],
      ),
    );
  }
}
