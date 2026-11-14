import 'package:material_ui/material_ui.dart';

import '../data/app_data.dart';
import '../screens/change_history_screen.dart';
import 'format.dart';

/// One payment's own history: every change to it, its splits and its group expense, newest first, who made
/// each one, and Undo for any single change (later changes are kept).
class EntryHistorySection extends StatefulWidget {
  const EntryHistorySection({super.key, required this.data, required this.txnId, this.onUndone, this.loader});

  final AppData data;
  final String txnId;

  /// After an undo: the page should show the payment as it is now.
  final VoidCallback? onUndone;

  /// Where the rows come from (tests pass their own).
  final Future<List<Map<String, dynamic>>> Function()? loader;

  @override
  State<EntryHistorySection> createState() => _EntryHistorySectionState();
}

class _EntryHistorySectionState extends State<EntryHistorySection> {
  List<Map<String, dynamic>>? _rows;
  String? _error;
  late final fmt = HistoryFormat(widget.data);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final rows = await (widget.loader ?? () => widget.data.loadEntryHistory(widget.txnId))();
      if (mounted) setState(() => _rows = rows);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  String _who(Map<String, dynamic> r) {
    if (r['actor'] != null && r['actor'] != widget.data.me) return 'Your friend';
    if (r['by_user'] == true) return 'You';
    final source = ((r['context'] as Map?) ?? const {})['source'];
    return switch (source) {
      'email' => 'Bank email',
      'statement' => 'Statement import',
      _ => 'Automatic',
    };
  }

  String _headline(Map<String, dynamic> r) {
    if (r['tbl'] == 'transactions') {
      return switch (r['op']) {
        'insert' => 'Added',
        'delete' => 'Deleted',
        _ => 'Changed',
      };
    }
    return fmt.title(r);
  }

  Future<void> _undo(Map<String, dynamic> r) async {
    final lines = fmt.changes(r);
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Put this back?'),
        content: Text(
          '${_headline(r)}${lines.isEmpty ? '' : '\n${lines.join('\n')}'}\n\n'
          'Only this change goes back. Other payments changed at the same time stay as they are, and anything '
          'changed later is kept.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Put back')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final n = await widget.data.undoChangeRows([(r['id'] as num).toInt()]);
      messenger.showSnackBar(SnackBar(content: Text(n == 0 ? 'Already as it was' : 'Put back')));
      await _load();
      widget.onUndone?.call();
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Could not put it back: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final rows = _rows;
    return Card.outlined(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.history, size: 20),
                const SizedBox(width: 8),
                Expanded(child: Text('History of this entry', style: text.titleSmall)),
              ],
            ),
            if (_error != null)
              Padding(padding: const EdgeInsets.only(top: 8), child: Text('Could not load: $_error'))
            else if (rows == null)
              const Padding(
                padding: EdgeInsets.all(12),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (rows.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6, bottom: 4),
                child: Text(
                  'No changes since it was added (history is kept from 13 Nov 2026).',
                  style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ),
            for (final r in rows ?? const <Map<String, dynamic>>[])
              Builder(
                builder: (context) {
                  final at = DateTime.parse(r['at'] as String).toLocal();
                  final undone = r['undone'] == true;
                  final lines = fmt.changes(r);
                  final canUndo = !undone && !(r['tbl'] == 'transactions' && r['op'] == 'insert');
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _headline(r),
                                style: text.bodyMedium?.copyWith(
                                  fontWeight: FontWeight.w600,
                                  decoration: undone ? TextDecoration.lineThrough : null,
                                ),
                              ),
                              for (final l in lines)
                                Text(
                                  l,
                                  style: text.bodySmall?.copyWith(
                                    decoration: undone ? TextDecoration.lineThrough : null,
                                  ),
                                ),
                              Text(
                                '${dayLabel(at)}, ${timeLabel(at)} · ${_who(r)}${undone ? ' · put back' : ''}',
                                style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                              ),
                            ],
                          ),
                        ),
                        if (canUndo) TextButton(onPressed: () => _undo(r), child: const Text('Undo')),
                      ],
                    ),
                  );
                },
              ),
          ],
        ),
      ),
    );
  }
}
