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

  /// Someone else changed an entry between the two of you (in their app).
  String? friendActor(String? me) => rows
      .where((r) => r['tbl'] == 'shared_entries' && r['actor'] != null && r['actor'] != me)
      .map((r) => r['actor'] as String)
      .firstOrNull;
  bool get undone => rows.every((r) => r['undone'] == true);
}

const historyFieldNames = {
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
  'details': 'Bank details',
  'method': 'Paid by (method)',
  'person': 'Friend',
  'paid_at': 'Paid back',
  'name': 'Name',
  'parent_id': 'Group',
  'opening_balance': 'Starting balance',
  'opening_date': 'Starting date',
  'archived': 'Hidden',
  'outstanding': 'Still owed',
  'closed': 'Closed',
  'description': 'What',
  'at': 'Date',
  'deleted_at': 'Removed',
  'deleted_by': 'Removed by',
  'creditor_txn': 'Your payment (owed to you)',
  'debtor_txn': 'Your payment (you owe)',
};

class _ChangeHistoryScreenState extends State<ChangeHistoryScreen> {
  late final fmt = HistoryFormat(data);
  List<_Batch>? _batches;
  String? _error;
  var _mineOnly = true;

  AppData get data => widget.data;

  @override
  void initState() {
    super.initState();
    _load();
  }

  List<Map<String, dynamic>> _rows = [];
  var _more = false;
  var _loadingMore = false;
  static const _page = 800;

  /// Loads the newest page again ([more]: the next older page, added below).
  Future<void> _load({bool more = false}) async {
    try {
      final before = more && _rows.isNotEmpty ? (_rows.last['id'] as num).toInt() : null;
      final rows = widget.loader != null
          ? (more ? <Map<String, dynamic>>[] : await widget.loader!())
          : await data.loadHistory(limit: _page, beforeId: before, mineOnly: _mineOnly);
      _rows = more ? [..._rows, ...rows] : rows;
      _more = widget.loader == null && rows.length == _page;
      final byId = <int, _Batch>{};
      final order = <_Batch>[];
      for (final r in _rows) {
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

  String _who(_Batch b) {
    final f = b.friendActor(data.me);
    if (f != null) return '${fmt.friendName(b.rows.first)} (in their app)';
    return b.byUser ? 'You' : 'Automatic (bank email, import)';
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
            final name = historyFieldNames[f] ?? f;
            return values.length == 1 ? '$name → ${fmt.value(f, values.first)}' : '$name changed';
          }(),
      ];
      parts.add('${described.join(', ')} · ${txUpdates.length} payment${txUpdates.length == 1 ? '' : 's'}');
    }
    final added = b.rows.where((r) => r['tbl'] == 'transactions' && r['op'] == 'insert').length;
    if (added > 0) parts.add('Added $added payment${added == 1 ? '' : 's'}');
    final deleted = b.rows.where((r) => r['tbl'] == 'transactions' && r['op'] == 'delete').length;
    if (deleted > 0) parts.add('Deleted $deleted payment${deleted == 1 ? '' : 's'}');
    for (final r in b.rows.where((r) => r['tbl'] == 'shared_entries')) {
      parts.add(fmt.sharedLine(r));
    }
    final rules = b.rows.where((r) => r['tbl'] != 'transactions' && r['tbl'] != 'shared_entries').length;
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
      'txn_parts': 'split into categories',
      'txn_shares': 'split with friends',
      'categories': 'categories',
      'accounts': 'accounts',
      'budgets': 'budgets',
      'loans': 'loans',
      'groups': 'groups',
      'group_expenses': 'group expenses',
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
            Text(fmt.title(r), style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
            for (final line in fmt.changes(r))
              Text(line, style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
          ],
        ),
      ),
    if (b.rows.length > 200)
      Padding(padding: const EdgeInsets.all(16), child: Text('…and ${b.rows.length - 200} more')),
  ];

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
    final batches = (_batches ?? const <_Batch>[])
        .where((b) => !_mineOnly || b.byUser || b.friendActor(data.me) != null)
        .toList();
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
                    onSelectionChanged: (s) {
                      setState(() {
                        _mineOnly = s.first;
                        _batches = null;
                      });
                      _load();
                    },
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
                      b.undone
                          ? Icons.undo
                          : (b.friendActor(data.me) != null
                                ? Icons.people_outline
                                : (b.byUser ? Icons.person_outline : Icons.sync)),
                      color: b.undone ? scheme.outline : null,
                    ),
                    title: Text(
                      _summary(b),
                      style: TextStyle(decoration: b.undone ? TextDecoration.lineThrough : null),
                    ),
                    subtitle: Text(
                      '${dayLabel(b.at)}, ${timeLabel(b.at)} · ${_who(b)}'
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
                if (_more)
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: OutlinedButton(
                      onPressed: _loadingMore
                          ? null
                          : () async {
                              setState(() => _loadingMore = true);
                              await _load(more: true);
                              if (mounted) setState(() => _loadingMore = false);
                            },
                      child: Text(_loadingMore ? 'Loading…' : 'Show older changes'),
                    ),
                  ),
              ],
            ),
    );
  }
}

/// How a change-log row reads: "Changed: Zomato · ₹240 · 12 Nov", "Category: Food → Stuff".
class HistoryFormat {
  HistoryFormat(this.data);

  final AppData data;

  String value(String field, Object? v) {
    if (v == null || v == '') return '—';
    switch (field) {
      case 'category_id':
        return data.category(v as String)?.name ?? 'a deleted category';
      case 'account_id' || 'counter_account_id':
        return data.account(v as String)?.name ?? 'an account';
      case 'amount':
        return money((v as num).toDouble());
      case 'deleted_by' || 'created_by':
        return v == data.me ? 'You' : 'Your friend';
      case 'creditor_txn' || 'debtor_txn':
        return 'linked to a bank payment';
      case 'txn_at' || 'at' || 'deleted_at':
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

  String friendName(Map<String, dynamic> r) {
    final link = data.links.where((l) => l.id == ((r['context'] as Map?)?['link_id'])).firstOrNull;
    return link == null || data.me == null ? 'your friend' : link.nameFor(data.me!);
  }

  /// "Ravi added: Pizza ₹600 (you owe ₹300)".
  String sharedLine(Map<String, dynamic> r) {
    final c = (r['context'] as Map?) ?? const {};
    final amount = money(((c['amount'] as num?) ?? 0).toDouble());
    final what = (c['description'] as String?)?.isNotEmpty == true ? ' “${c['description']}”' : '';
    final iAmOwed = c['creditor'] == data.me;
    final kind = switch (c['kind']) {
      'expense' => 'Shared expense',
      'settle' => 'Settle up',
      _ => 'Payment',
    };
    final verb = switch (r['op']) {
      'insert' => 'Added',
      'delete' => 'Deleted',
      _ => ((r['after'] as Map?)?['deleted_at'] != null) ? 'Removed' : 'Changed',
    };
    return '$verb with ${friendName(r)}: $kind$what $amount · ${iAmOwed ? 'owed to you' : 'you owe'}';
  }

  String title(Map<String, dynamic> r) {
    final c = (r['context'] as Map?) ?? const {};
    final op = switch (r['op']) {
      'insert' => 'Added',
      'delete' => 'Deleted',
      _ => 'Changed',
    };
    if (r['tbl'] == 'shared_entries') return sharedLine(r);
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
      'txn_parts' => () {
        final c = (r['context'] as Map?) ?? const {};
        return 'Split part of ${c['merchant'] ?? 'a payment'}'
            '${c['amount'] == null ? '' : ' (${money((c['amount'] as num).toDouble())})'}';
      }(),
      'txn_shares' => () {
        final c = (r['context'] as Map?) ?? const {};
        final who = (r['after'] as Map?)?['person'] ?? (r['before'] as Map?)?['person'] ?? c['person'] ?? 'a friend';
        return '$who’s part of ${c['merchant'] ?? 'a payment'}';
      }(),
      'categories' => 'Category “${(r['context'] as Map?)?['name'] ?? ''}”',
      'accounts' => 'Account “${(r['context'] as Map?)?['name'] ?? ''}”',
      'loans' => 'Loan “${(r['context'] as Map?)?['name'] ?? ''}”',
      'budgets' => 'Budget for ${(r['context'] as Map?)?['name'] ?? 'a category'}',
      'groups' => 'Group',
      'group_expenses' => 'Group expense',
      _ => '${r['tbl']} $key',
    };
    return '$op: $kind';
  }

  List<String> changes(Map<String, dynamic> r) {
    final before = (r['before'] as Map?) ?? const {};
    final after = (r['after'] as Map?) ?? const {};
    String show(String f, Object? v) => f == 'category_id' && v == null ? 'No category' : value(f, v);
    if (r['op'] == 'update') {
      return [
        for (final f in after.keys.cast<String>())
          '${historyFieldNames[f] ?? f}: ${show(f, before[f])} → ${show(f, after[f])}',
      ];
    }
    final row = r['op'] == 'insert' ? after : before;
    if (r['tbl'] == 'transactions' || r['tbl'] == 'shared_entries') return [];
    return [
      for (final f in row.keys.cast<String>())
        if (!const {'user_id', 'id', 'txn_id', 'created_at', 'paid_txn_id', 'icon', 'color'}.contains(f))
          '${historyFieldNames[f] ?? f.replaceAll('_', ' ')}: ${show(f, row[f])}',
    ];
  }
}
