import 'package:material_ui/material_ui.dart';

import '../data/app_data.dart';
import '../ui/format.dart';

/// Every change to payments and rules, with before and after, grouped by action; any action can be undone.
class ChangeHistoryScreen extends StatefulWidget {
  const ChangeHistoryScreen({super.key, required this.data, this.loader});

  final AppData data;

  /// Where the rows come from (tests pass their own).
  final Future<List<Map<String, dynamic>>> Function()? loader;

  @override
  State<ChangeHistoryScreen> createState() => _ChangeHistoryScreenState();
}

class _Batch {
  _Batch(this.id);

  final int id;
  final List<Map<String, dynamic>> rows = [];

  DateTime get at => DateTime.parse(rows.first['at'] as String).toLocal();
  bool get byUser => rows.any((r) => r['by_user'] == true);
  bool get undone => rows.every((r) => r['undone'] == true);
}

const _fieldNames = {
  'category_id': 'Category',
  'merchant': 'Name',
  'note': 'Note',
  'amount': 'Amount',
  'direction': 'Direction',
  'txn_at': 'Date',
  'account_id': 'Account',
  'counter_account_id': 'Moved to/from',
  'excluded': 'Counted',
  'paid_by': 'Paid by',
  'loan_id': 'Loan',
  'loan_role': 'Loan role',
  'bank_name': 'Bank name',
  'payee_vpa': 'UPI ID',
};

class _ChangeHistoryScreenState extends State<ChangeHistoryScreen> {
  List<_Batch>? _batches;
  String? _error;
  var _mineOnly = true;

  AppData get data => widget.data;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final rows = await (widget.loader ?? data.loadHistory)();
      final byId = <int, _Batch>{};
      final order = <_Batch>[];
      for (final r in rows) {
        final id = (r['batch'] as num).toInt();
        final b = byId.putIfAbsent(id, () {
          final nb = _Batch(id);
          order.add(nb);
          return nb;
        });
        b.rows.add(r);
      }
      if (mounted) setState(() => _batches = order);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  String _value(String field, Object? v) {
    if (v == null || v == '') return '—';
    switch (field) {
      case 'category_id':
        return data.category(v as String)?.name ?? 'a deleted category';
      case 'account_id' || 'counter_account_id':
        return data.account(v as String)?.name ?? 'an account';
      case 'amount':
        return money((v as num).toDouble());
      case 'txn_at':
        final d = DateTime.parse(v as String).toLocal();
        return '${dayLabel(d)}, ${timeLabel(d)}';
      case 'excluded':
        return v == true ? 'No (a move between your accounts)' : 'Yes';
      case 'direction':
        return v == 'debit' ? 'Spent' : 'Received';
      default:
        return '$v';
    }
  }

  /// "Category → Stuff · 7 payments".
  String _summary(_Batch b) {
    final parts = <String>[];
    final txUpdates = b.rows.where((r) => r['tbl'] == 'transactions' && r['op'] == 'update').toList();
    if (txUpdates.isNotEmpty) {
      final fields = <String>{
        for (final r in txUpdates) ...((r['after'] as Map?)?.keys.cast<String>() ?? const <String>[]),
      };
      final described = [
        for (final f in fields.take(3))
          () {
            final values = {for (final r in txUpdates) (r['after'] as Map?)?[f]};
            final name = _fieldNames[f] ?? f;
            return values.length == 1 ? '$name → ${_value(f, values.first)}' : '$name changed';
          }(),
      ];
      parts.add('${described.join(', ')} · ${txUpdates.length} payment${txUpdates.length == 1 ? '' : 's'}');
    }
    final added = b.rows.where((r) => r['tbl'] == 'transactions' && r['op'] == 'insert').length;
    if (added > 0) parts.add('Added $added payment${added == 1 ? '' : 's'}');
    final deleted = b.rows.where((r) => r['tbl'] == 'transactions' && r['op'] == 'delete').length;
    if (deleted > 0) parts.add('Deleted $deleted payment${deleted == 1 ? '' : 's'}');
    final rules = b.rows.where((r) => r['tbl'] != 'transactions').length;
    if (rules > 0) parts.add('$rules rule${rules == 1 ? '' : 's'} (${_ruleKinds(b)})');
    return parts.join(' · ');
  }

  String _ruleKinds(_Batch b) {
    const names = {
      'merchant_rules': 'category by name',
      'vpa_rules': 'category by UPI ID',
      'friend_aliases': 'also known as',
      'people': 'who is this',
      'payee_names': 'renamed place',
    };
    return {
      for (final r in b.rows)
        if (r['tbl'] != 'transactions') names[r['tbl']] ?? r['tbl'],
    }.join(', ');
  }

  List<Widget> _details(_Batch b, TextTheme text, ColorScheme scheme) => [
    for (final r in b.rows.take(200))
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_title(r), style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
            for (final line in _changes(r)) Text(line, style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
          ],
        ),
      ),
    if (b.rows.length > 200)
      Padding(padding: const EdgeInsets.all(16), child: Text('…and ${b.rows.length - 200} more')),
  ];

  String _title(Map<String, dynamic> r) {
    final c = (r['context'] as Map?) ?? const {};
    final op = switch (r['op']) {
      'insert' => 'Added',
      'delete' => 'Deleted',
      _ => 'Changed',
    };
    if (r['tbl'] == 'transactions') {
      final amount = c['amount'] == null ? '' : ' · ${money((c['amount'] as num).toDouble())}';
      final date = c['txn_at'] == null ? '' : ' · ${dayLabel(DateTime.parse(c['txn_at'] as String).toLocal())}';
      return '$op: ${c['merchant'] ?? 'Payment'}$amount$date';
    }
    final key = (r['row_key'] as Map).entries.where((e) => e.key != 'user_id').map((e) => e.value).join(' ');
    final kind = switch (r['tbl']) {
      'merchant_rules' => 'Category rule for “$key”',
      'vpa_rules' => 'Category rule for UPI ••$key',
      'friend_aliases' => 'Also known as: “$key”',
      'people' => 'Who is “$key”',
      'payee_names' => 'Place name for ${key.replaceFirst('vpa:', 'UPI ••').replaceFirst('name:', '')}',
      _ => '${r['tbl']} $key',
    };
    return '$op: $kind';
  }

  List<String> _changes(Map<String, dynamic> r) {
    final before = (r['before'] as Map?) ?? const {};
    final after = (r['after'] as Map?) ?? const {};
    String show(String f, Object? v) => f == 'category_id' && v == null ? 'No category' : _value(f, v);
    if (r['op'] == 'update') {
      return [
        for (final f in after.keys.cast<String>())
          '${_fieldNames[f] ?? f}: ${show(f, before[f])} → ${show(f, after[f])}',
      ];
    }
    final row = r['op'] == 'insert' ? after : before;
    if (r['tbl'] == 'transactions') return [];
    return [
      for (final f in row.keys.cast<String>())
        if (f != 'user_id') '${_fieldNames[f] ?? f.replaceAll('_', ' ')}: ${show(f, row[f])}',
    ];
  }

  Future<void> _undo(_Batch b) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Undo this?'),
        content: Text(
          '${_summary(b)}\n\nEverything it changed goes back to how it was. Anything you changed again '
          'afterwards is kept.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Undo')),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final n = await data.undoChange(b.id);
      messenger.showSnackBar(SnackBar(content: Text('Undone: $n change${n == 1 ? '' : 's'} put back')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Could not undo: $e')));
    }
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final batches = (_batches ?? const <_Batch>[]).where((b) => !_mineOnly || b.byUser).toList();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Change history'),
        actions: [IconButton(tooltip: 'Refresh', icon: const Icon(Icons.refresh), onPressed: _load)],
      ),
      body: _error != null
          ? Center(
              child: Padding(padding: const EdgeInsets.all(24), child: Text('Could not load: $_error')),
            )
          : _batches == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.only(bottom: 32),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                  child: SegmentedButton<bool>(
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(value: true, label: Text('My changes')),
                      ButtonSegment(value: false, label: Text('All, incl. automatic')),
                    ],
                    selected: {_mineOnly},
                    onSelectionChanged: (s) => setState(() => _mineOnly = s.first),
                  ),
                ),
                if (batches.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(32),
                    child: Center(child: Text('No changes recorded yet.')),
                  ),
                for (final b in batches)
                  ExpansionTile(
                    tilePadding: const EdgeInsets.symmetric(horizontal: 16),
                    leading: Icon(
                      b.undone ? Icons.undo : (b.byUser ? Icons.person_outline : Icons.sync),
                      color: b.undone ? scheme.outline : null,
                    ),
                    title: Text(
                      _summary(b),
                      style: TextStyle(decoration: b.undone ? TextDecoration.lineThrough : null),
                    ),
                    subtitle: Text(
                      '${dayLabel(b.at)}, ${timeLabel(b.at)} · ${b.byUser ? 'You' : 'Automatic (bank email, import)'}'
                      '${b.undone ? ' · undone' : ''}',
                      style: text.bodySmall,
                    ),
                    children: [
                      if (!b.undone)
                        Align(
                          alignment: Alignment.centerLeft,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            child: OutlinedButton.icon(
                              onPressed: () => _undo(b),
                              icon: const Icon(Icons.undo),
                              label: const Text('Undo this'),
                            ),
                          ),
                        ),
                      ..._details(b, text, scheme),
                    ],
                  ),
              ],
            ),
    );
  }
}
