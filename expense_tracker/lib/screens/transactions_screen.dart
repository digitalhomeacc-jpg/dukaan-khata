import 'package:material_ui/material_ui.dart';

import '../data/app_data.dart';
import '../logic/summary.dart';
import '../models.dart';
import '../ui/category_style.dart';
import '../ui/format.dart';
import 'month_bar.dart';
import 'txn_editor.dart';

enum _Filter { all, spent, received, uncategorised }

class TransactionsScreen extends StatefulWidget {
  const TransactionsScreen({super.key, required this.data});

  final AppData data;

  @override
  State<TransactionsScreen> createState() => _TransactionsScreenState();
}

class _TransactionsScreenState extends State<TransactionsScreen> {
  var _month = monthStart(DateTime.now());
  var _filter = _Filter.all;
  var _query = '';

  bool _keep(Txn t) {
    if (!inMonth(t.txnAt, _month)) return false;
    final ok = switch (_filter) {
      _Filter.all => true,
      _Filter.spent => t.isDebit,
      _Filter.received => !t.isDebit,
      _Filter.uncategorised => t.categoryId == null && !t.excluded,
    };
    if (!ok) return false;
    if (_query.isEmpty) return true;
    final q = _query.toLowerCase();
    return t.title.toLowerCase().contains(q) ||
        (t.note ?? '').toLowerCase().contains(q) ||
        (widget.data.category(t.categoryId)?.name.toLowerCase().contains(q) ?? false);
  }

  @override
  Widget build(BuildContext context) {
    final data = widget.data;
    final summary = summarize(data.transactions, _month);
    final shown = data.transactions.where(_keep).toList();
    final days = groupByDay(shown);
    final uncategorised =
        data.transactions.where((t) => inMonth(t.txnAt, _month) && t.categoryId == null && !t.excluded && t.isDebit).length;

    return Scaffold(
      appBar: AppBar(
        title: MonthBar(month: _month, onChanged: (m) => setState(() => _month = m)),
        centerTitle: true,
      ),
      body: !data.loaded
          ? Center(
              child: data.error == null
                  ? const CircularProgressIndicator()
                  : Padding(padding: const EdgeInsets.all(24), child: Text('Could not load: ${data.error}')),
            )
          : CustomScrollView(
              slivers: [
                SliverToBoxAdapter(child: _SummaryCard(summary: summary)),
                if (uncategorised > 0 && _filter != _Filter.uncategorised)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                      child: Card.filled(
                        child: ListTile(
                          leading: const Icon(Icons.label_off_outlined),
                          title: Text('$uncategorised ${uncategorised == 1 ? 'payment needs' : 'payments need'} a category'),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => setState(() => _filter = _Filter.uncategorised),
                        ),
                      ),
                    ),
                  ),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                    child: TextField(
                      decoration: const InputDecoration(
                        prefixIcon: Icon(Icons.search),
                        hintText: 'Search merchant, note or category',
                        isDense: true,
                      ),
                      onChanged: (v) => setState(() => _query = v.trim()),
                    ),
                  ),
                ),
                SliverToBoxAdapter(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                    child: Row(
                      children: [
                        for (final f in _Filter.values)
                          Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: ChoiceChip(
                              label: Text(switch (f) {
                                _Filter.all => 'All',
                                _Filter.spent => 'Spent',
                                _Filter.received => 'Received',
                                _Filter.uncategorised => 'No category',
                              }),
                              selected: _filter == f,
                              onSelected: (_) => setState(() => _filter = f),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                if (days.isEmpty)
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: _EmptyState(hasAny: data.transactions.isNotEmpty),
                  ),
                for (final day in days) ...[
                  SliverToBoxAdapter(child: _DayHeader(day: day.key, txns: day.value)),
                  SliverList.builder(
                    itemCount: day.value.length,
                    itemBuilder: (context, i) => TxnTile(txn: day.value[i], data: data),
                  ),
                ],
                const SliverToBoxAdapter(child: SizedBox(height: 96)),
              ],
            ),
    );
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.summary});

  final MonthSummary summary;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget cell(String label, String value, Color color) => Expanded(
          child: Column(
            children: [
              Text(label, style: TextStyle(color: scheme.onPrimaryContainer.withValues(alpha: 0.8))),
              const SizedBox(height: 4),
              FittedBox(
                child: Text(value, style: Theme.of(context).textTheme.titleLarge?.copyWith(color: color, fontWeight: FontWeight.w600)),
              ),
            ],
          ),
        );
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Card(
        color: scheme.primaryContainer,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 8),
          child: Row(
            children: [
              cell('Spent', money(summary.spent), scheme.onPrimaryContainer),
              cell('Received', money(summary.received), scheme.onPrimaryContainer),
              cell('Net', '${summary.net < 0 ? '−' : ''}${money(summary.net.abs())}', scheme.onPrimaryContainer),
            ],
          ),
        ),
      ),
    );
  }
}

class _DayHeader extends StatelessWidget {
  const _DayHeader({required this.day, required this.txns});

  final DateTime day;
  final List<Txn> txns;

  @override
  Widget build(BuildContext context) {
    final spent = txns.where((t) => t.isDebit && !t.excluded).fold(0.0, (s, t) => s + t.amount);
    final style = Theme.of(context).textTheme.labelLarge?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Row(
        children: [
          Expanded(child: Text(dayLabel(day), style: style)),
          if (spent > 0) Text('Spent ${money(spent)}', style: style),
        ],
      ),
    );
  }
}

class TxnTile extends StatelessWidget {
  const TxnTile({super.key, required this.txn, required this.data});

  final Txn txn;
  final AppData data;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final cat = data.category(txn.categoryId);
    final details = [
      cat?.name ?? (txn.isDebit ? 'No category' : null),
      if (txn.bank != null) '${txn.bank}${txn.accountLast4 != null ? ' ••${txn.accountLast4}' : ''}',
      timeLabel(txn.txnAt),
    ].whereType<String>().join(' · ');
    final amountColor = txn.excluded ? scheme.outline : (txn.isDebit ? scheme.onSurface : Colors.green.shade700);
    return ListTile(
      leading: CategoryAvatar(cat),
      title: Text(txn.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        txn.excluded ? 'Not counted · $details' : details,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (txn.fromEmail) Icon(Icons.mail_outline, size: 14, color: scheme.outline),
          const SizedBox(width: 4),
          Text(
            signedMoney(txn.amount, isDebit: txn.isDebit),
            style: TextStyle(
              color: amountColor,
              fontWeight: FontWeight.w600,
              decoration: txn.excluded ? TextDecoration.lineThrough : null,
            ),
          ),
        ],
      ),
      onTap: () => openTxnEditor(context, data, existing: txn),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.hasAny});

  final bool hasAny;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.inbox_outlined, size: 56, color: Theme.of(context).colorScheme.outline),
            const SizedBox(height: 12),
            Text(
              hasAny
                  ? 'Nothing here for this month.'
                  : 'No transactions yet.\nTap Add, or connect Gmail in Settings so bank alerts arrive here automatically.',
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
}
