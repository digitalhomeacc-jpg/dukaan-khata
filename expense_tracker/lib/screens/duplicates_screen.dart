import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';

import '../data/app_data.dart';
import '../logic/duplicates.dart';
import '../models.dart';
import '../ui/format.dart';
import 'txn_editor.dart';

Future<void> openDuplicates(BuildContext context, AppData data) => Navigator.of(context).push(
  MaterialPageRoute<void>(
    builder: (_) => ListenableBuilder(
      listenable: data,
      builder: (_, _) => DuplicatesScreen(data: data),
    ),
  ),
);

/// Payments that may be one entered twice, side by side with everything the bank said, to keep both, delete
/// one, or open either to check and edit.
class DuplicatesScreen extends StatelessWidget {
  const DuplicatesScreen({super.key, required this.data});

  final AppData data;

  String _source(Txn t) => switch (t.source) {
    'email' => 'Bank email',
    'statement' => 'Statement',
    _ => 'Added by hand',
  };

  Future<void> _delete(BuildContext context, Txn t) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Delete ${t.title} ${money(t.amount)}?'),
        content: Text(
          '${_source(t)}, ${DateFormat('d MMM yyyy, h:mm a').format(t.txnAt)}. The other one stays. '
          'Undo is in Change history.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await data.deleteTxn(t.id);
      messenger.showSnackBar(const SnackBar(content: Text('Deleted. The other one stays.')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Could not delete: $e')));
    }
  }

  /// The pair and every payment linked to it by other suspected pairs (three identical entries: one answer).
  List<String> _cluster(List<DuplicatePair> pairs, DuplicatePair p) {
    final ids = {p.a.id, p.b.id};
    var grew = true;
    while (grew) {
      grew = false;
      for (final q in pairs) {
        if ((ids.contains(q.a.id) || ids.contains(q.b.id)) && !(ids.contains(q.a.id) && ids.contains(q.b.id))) {
          ids.addAll([q.a.id, q.b.id]);
          grew = true;
        }
      }
    }
    return ids.toList();
  }

  Future<void> _allReal(BuildContext context, List<String> ids) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await data.markNotDuplicates(ids);
    } catch (e) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Remembered on this phone. To keep it for good, run RUN_IN_SUPABASE.sql in Supabase.'),
        ),
      );
    }
  }

  Widget _side(BuildContext context, Txn t) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final cat = data.category(t.categoryId);
    return Expanded(
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => openTxnEditor(context, data, existing: t),
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _source(t),
                style: text.labelMedium?.copyWith(color: scheme.primary, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 4),
              Text(
                t.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              Text(DateFormat('d MMM, h:mm a').format(t.txnAt), style: text.bodySmall),
              Text(data.account(t.accountId)?.name ?? 'No account', style: text.bodySmall),
              Text(cat?.name ?? 'No category', style: text.bodySmall),
              if ((t.note ?? '').isNotEmpty) Text('Note: ${t.note}', style: text.bodySmall),
              if ((t.details ?? '').isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    t.details!,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant, fontFamily: 'monospace'),
                  ),
                ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Icon(Icons.edit_outlined, size: 14, color: scheme.primary),
                  const SizedBox(width: 4),
                  Text('Open', style: text.labelSmall?.copyWith(color: scheme.primary)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final pairs = data.duplicates;
    return Scaffold(
      appBar: AppBar(title: const Text('Possible duplicates')),
      body: pairs.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Text('Nothing looks entered twice.', textAlign: TextAlign.center),
              ),
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 32),
              children: [
                Text(
                  'Same amount, same account, close in time. Open either to check what the bank said, then keep both or '
                  'delete the extra one.',
                  style: text.bodySmall,
                ),
                const SizedBox(height: 8),
                for (final DuplicatePair p in pairs)
                  Card.outlined(
                    margin: const EdgeInsets.symmetric(vertical: 6),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  '${p.a.isDebit ? '−' : '+'}${money(p.a.amount)}',
                                  style: text.titleLarge?.copyWith(fontWeight: FontWeight.w800),
                                ),
                              ),
                              if (p.sameRef)
                                Chip(
                                  visualDensity: VisualDensity.compact,
                                  avatar: const Icon(Icons.priority_high, size: 16),
                                  label: const Text('Same bank reference'),
                                )
                              else
                                Text(
                                  p.days == 0 ? 'same day' : '${p.days} day${p.days == 1 ? '' : 's'} apart',
                                  style: text.bodySmall,
                                ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [_side(context, p.a), const SizedBox(width: 8), _side(context, p.b)],
                          ),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 8,
                            runSpacing: 4,
                            children: [
                              OutlinedButton.icon(
                                onPressed: () => _allReal(context, _cluster(pairs, p)),
                                icon: const Icon(Icons.done_all, size: 18),
                                label: Text(
                                  _cluster(pairs, p).length > 2
                                      ? 'All ${_cluster(pairs, p).length} are real'
                                      : 'Both are real',
                                ),
                              ),
                              TextButton(onPressed: () => _delete(context, p.a), child: const Text('Delete left')),
                              TextButton(onPressed: () => _delete(context, p.b), child: const Text('Delete right')),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}
