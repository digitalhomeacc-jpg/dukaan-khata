import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';

import '../data/app_data.dart';
import '../logic/summary.dart';
import '../models.dart';
import '../ui/category_style.dart';
import '../ui/format.dart';
import '../ui/selection.dart';
import 'txn_editor.dart';

/// The Add button: a new entry, or one tap on something you pay again and again.
Future<void> openAddSheet(BuildContext context, AppData data) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  useSafeArea: true,
  builder: (sheet) => _AddSheet(data: data, outer: context),
);

/// Opens the editor filled in like [f]: amount, category, the usual person and account. You check and save.
Future<void> addLike(BuildContext context, AppData data, FrequentEntry f) => openTxnEditor(
  context,
  data,
  prefill: Txn(
    id: '',
    amount: f.amount,
    isDebit: f.isDebit,
    txnAt: DateTime.now(),
    merchant: f.usualPayee,
    categoryId: f.categoryId,
    accountId: f.usualAccountId,
    method: f.usualMethod,
  ),
);

class _AddSheet extends StatelessWidget {
  const _AddSheet({required this.data, required this.outer});

  final AppData data;

  /// The page under the sheet: the editor opens there once the sheet is closed.
  final BuildContext outer;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final frequent = frequentEntries(data.transactions);
    void then(void Function() open) {
      Navigator.pop(context);
      open();
    }

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: frequent.isEmpty ? 0.35 : 0.7,
      maxChildSize: 0.95,
      builder: (context, scroll) => ListView(
        controller: scroll,
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        children: [
          Text('Add', style: text.titleLarge),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                  onPressed: () => then(() => openTxnEditor(outer, data)),
                  icon: const Icon(Icons.arrow_upward),
                  label: const Text('Spent'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.tonalIcon(
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                  onPressed: () => then(
                    () => openTxnEditor(
                      outer,
                      data,
                      prefill: Txn(id: '', amount: 0, isDebit: false, txnAt: DateTime.now(), method: 'upi'),
                    ),
                  ),
                  icon: const Icon(Icons.arrow_downward),
                  label: const Text('Received'),
                ),
              ),
            ],
          ),
          if (frequent.isNotEmpty) ...[
            const SizedBox(height: 20),
            Text('Again?', style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
            Text(
              'What you pay again and again. Tap to add it once more; the list icon shows all of them.',
              style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 8),
            for (final f in frequent)
              Card.outlined(
                margin: const EdgeInsets.symmetric(vertical: 4),
                child: ListTile(
                  leading: CategoryAvatar(data.category(f.categoryId), size: 40),
                  title: Text(
                    '${f.isDebit ? '' : '+'}${money(f.amount)} · ${data.category(f.categoryId)?.name ?? 'No category'}',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  subtitle: Text(
                    [
                      if (f.usualPayee != null) '${f.isDebit ? 'to' : 'from'} ${f.payees.take(2).join(', ')}',
                      '${f.count}× · last ${dayLabel(f.last!)}',
                    ].join(' · '),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: IconButton(
                    tooltip: 'All ${money(f.amount)} payments',
                    icon: const Icon(Icons.view_list_outlined),
                    onPressed: () => then(() => openSameAmount(outer, data, f.amount)),
                  ),
                  onTap: () => then(() => addLike(outer, data, f)),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

/// Every payment of exactly this amount, at a glance: ₹800 thalis, ₹20 chais.
Future<void> openSameAmount(BuildContext context, AppData data, double amount) => Navigator.of(context).push(
  MaterialPageRoute<void>(
    builder: (_) => ListenableBuilder(
      listenable: data,
      builder: (_, _) => SameAmountScreen(data: data, amount: amount),
    ),
  ),
);

class SameAmountScreen extends StatelessWidget {
  const SameAmountScreen({super.key, required this.data, required this.amount});

  final AppData data;
  final double amount;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final txns = data.transactions.where((t) => (t.amount - amount).abs() < 0.005).toList()
      ..sort((a, b) => b.txnAt.compareTo(a.txnAt));
    final out = txns.where((t) => t.isDebit).length, into = txns.length - out;
    final byPayee = <String, int>{};
    for (final t in txns) {
      byPayee[t.title] = (byPayee[t.title] ?? 0) + 1;
    }
    final payees = byPayee.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    final frequent = frequentEntries(data.transactions).where((f) => (f.amount - amount).abs() < 0.005).firstOrNull;

    return SelectionHost(
      data: data,
      builder: (context, bar) => Scaffold(
        appBar: bar(txns.map((t) => t.id)) ?? AppBar(title: Text('All ${money(amount)} payments')),
        floatingActionButton: frequent == null
            ? null
            : FloatingActionButton.extended(
                onPressed: () => addLike(context, data, frequent),
                icon: const Icon(Icons.add),
                label: Text('Add another ${money(amount)}'),
              ),
        body: ListView(
          padding: const EdgeInsets.only(bottom: 96),
          children: [
            Container(
              margin: const EdgeInsets.all(16),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(color: scheme.primaryContainer, borderRadius: BorderRadius.circular(20)),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${txns.length} times', style: text.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
                  Text(
                    [
                      if (out > 0) '$out paid · ${money(out * amount)}',
                      if (into > 0) '$into received · ${money(into * amount)}',
                    ].join(' · '),
                  ),
                  if (payees.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(payees.take(4).map((e) => '${e.key} ${e.value}×').join(' · '), style: text.bodySmall),
                    ),
                ],
              ),
            ),
            if (txns.isEmpty) const Center(child: Text('No payments of this amount.')),
            for (final (i, t) in txns.indexed) ...[
              if (i == 0 || txns[i - 1].txnAt.month != t.txnAt.month || txns[i - 1].txnAt.year != t.txnAt.year)
                Container(
                  width: double.infinity,
                  color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: Text(DateFormat('MMMM yyyy').format(t.txnAt), style: text.labelMedium),
                ),
              TxnTileLite(data: data, txn: t),
            ],
          ],
        ),
      ),
    );
  }
}

/// A payment row that supports selecting several (long-press) and opens the payment on tap.
class TxnTileLite extends StatelessWidget {
  const TxnTileLite({super.key, required this.data, required this.txn});

  final AppData data;
  final Txn txn;

  @override
  Widget build(BuildContext context) {
    final sel = TxnSelection.maybeOf(context);
    final picked = sel?.ids.contains(txn.id) ?? false;
    final cat = data.category(txn.categoryId);
    return ListTile(
      selected: picked,
      leading: sel?.active == true ? SelectTick(selected: picked) : CategoryAvatar(cat),
      title: Text(txn.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        [dayLabel(txn.txnAt), cat?.name ?? 'No category', ?data.account(txn.accountId)?.name].join(' · '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Text(
        '${txn.isDebit ? '−' : '+'}${money(txn.amount)}',
        style: TextStyle(fontWeight: FontWeight.w600, color: txn.isDebit ? null : Colors.green.shade700),
      ),
      onTap: () => sel?.active == true ? sel!.toggle(txn.id) : openTxnEditor(context, data, existing: txn),
      onLongPress: sel == null ? null : () => sel.toggle(txn.id),
    );
  }
}
