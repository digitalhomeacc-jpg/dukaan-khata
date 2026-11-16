import 'dart:convert';

import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';

import '../data/app_data.dart';
import '../ui/format.dart';

/// Change history: every change on its own card — what, who, exactly when, before → after — with what happened
/// to that record later, search, filters, Undo for each change, and a tap for the record's whole story.
class ChangeHistoryScreen extends StatefulWidget {
  const ChangeHistoryScreen({super.key, required this.data, this.loader, this.recordKey, this.title});

  final AppData data;

  /// Where the rows come from (tests pass their own).
  final Future<List<Map<String, dynamic>>> Function()? loader;

  /// One record's whole story (from tapping a card).
  final String? recordKey;
  final String? title;

  @override
  State<ChangeHistoryScreen> createState() => _ChangeHistoryScreenState();
}

/// Which record a change-log row is about: a payment (its splits and group expense count as the payment), or
/// any other row by its key.
String historyRecordKey(Map<String, dynamic> r) =>
    (r['txn_id'] as String?) ??
    (r['tbl'] == 'transactions' ? ((r['row_key'] as Map?)?['id'] as String?) : null) ??
    '${r['tbl']}:${jsonEncode(r['row_key'])}';

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
  List<Map<String, dynamic>> _rows = [];
  var _loaded = false;
  String? _error;
  var _mineOnly = true;
  var _group = 'all';
  var _onlyChangedLater = false;
  final _q = TextEditingController();
  var _more = false;
  var _loadingMore = false;
  static const _page = 800;

  AppData get data => widget.data;
  bool get _single => widget.recordKey != null;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool more = false}) async {
    try {
      final before = more && _rows.isNotEmpty ? (_rows.last['id'] as num).toInt() : null;
      final rows = widget.loader != null
          ? (more ? <Map<String, dynamic>>[] : await widget.loader!())
          : _single && widget.recordKey!.length == 36
          ? await data.loadEntryHistory(widget.recordKey!)
          : await data.loadHistory(limit: _page, beforeId: before, mineOnly: _mineOnly && !_single);
      if (!mounted) return;
      setState(() {
        _rows = more ? [..._rows, ...rows] : rows;
        _more = widget.loader == null && !_single && rows.length == _page;
        _loaded = true;
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  String _groupOf(Map<String, dynamic> r) => switch (r['tbl']) {
    'transactions' || 'txn_parts' || 'recurring_runs' => 'payments',
    'txn_shares' || 'shared_entries' || 'friend_aliases' || 'people' || 'groups' || 'group_expenses' => 'friends',
    'merchant_rules' || 'vpa_rules' || 'payee_names' => 'rules',
    _ => 'other',
  };

  String _who(Map<String, dynamic> r) {
    final actor = r['actor'] as String?;
    if (r['tbl'] == 'shared_entries' && actor != null && actor != data.me) return fmt.friendName(r);
    if (r['by_user'] == true) return 'You';
    return switch (((r['context'] as Map?) ?? const {})['source']) {
      'email' => 'Bank email',
      'statement' => 'Statement import',
      _ => 'Automatic',
    };
  }

  /// "Zomato · ₹1,799.71 · 15 Nov" for a payment; the rule / friend / account line otherwise.
  String _title(Map<String, dynamic> r) {
    final c = (r['context'] as Map?) ?? const {};
    if (r['tbl'] == 'transactions') {
      final amount = c['amount'] == null ? '' : ' · ${money((c['amount'] as num).toDouble())}';
      final date = c['txn_at'] == null ? '' : ' · ${dayLabel(DateTime.parse(c['txn_at'] as String).toLocal())}';
      return '${c['merchant'] ?? 'Payment'}$amount$date';
    }
    return fmt.title(r).replaceFirst(RegExp(r'^(Added|Changed|Deleted): '), '');
  }

  static const _txnFields = [
    'txn_at',
    'merchant',
    'amount',
    'direction',
    'category_id',
    'account_id',
    'note',
    'paid_by',
  ];

  Future<void> _undo(Map<String, dynamic> r, {bool wholeAction = false}) async {
    final messenger = ScaffoldMessenger.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(wholeAction ? 'Undo the whole action?' : 'Undo this change?'),
        content: Text(
          wholeAction
              ? 'Every change made in the same action goes back. Anything changed again later is kept.'
              : 'Only this change goes back. Anything changed again later is kept.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Undo')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      final n = wholeAction
          ? await data.undoChange((r['batch'] as num).toInt())
          : await data.undoChangeRows([(r['id'] as num).toInt()]);
      messenger.showSnackBar(SnackBar(content: Text(n == 0 ? 'Already as it was' : 'Undone')));
      await _load();
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Could not undo: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Each record's changes, oldest first: for "changed 2× later" / "deleted later".
    final story = <String, List<Map<String, dynamic>>>{};
    for (final r in _rows) {
      (story[historyRecordKey(r)] ??= []).add(r);
    }
    for (final l in story.values) {
      l.sort((a, b) => (a['id'] as num).compareTo(b['id'] as num));
    }
    final q = _q.text.trim().toLowerCase();
    var list = _rows.where((r) {
      if (_single && widget.loader != null && historyRecordKey(r) != widget.recordKey) return false;
      if (!_single && _mineOnly && widget.loader != null && r['by_user'] != true && r['actor'] == null) return false;
      if (_group != 'all' && _groupOf(r) != _group) return false;
      if (_onlyChangedLater) {
        final later = story[historyRecordKey(r)]!.where((x) => (x['id'] as num) > (r['id'] as num));
        if (!later.any((x) => x['op'] != 'insert')) return false;
      }
      if (q.isEmpty) return true;
      return '${_who(r)} ${_title(r)} ${fmt.changes(r).join(' ')} ${jsonEncode(r['context'])}'.toLowerCase().contains(
        q,
      );
    }).toList();
    if (_single) list = list.reversed.toList(); // a record's story reads oldest first

    return Scaffold(
      appBar: AppBar(
        title: Text(_single ? (widget.title ?? 'This entry\'s history') : 'Change history'),
        actions: [IconButton(tooltip: 'Refresh', icon: const Icon(Icons.refresh), onPressed: _load)],
      ),
      body: _error != null
          ? Center(
              child: Padding(padding: const EdgeInsets.all(24), child: Text('Could not load: $_error')),
            )
          : !_loaded
          ? const Center(child: CircularProgressIndicator())
          : CustomScrollView(
              slivers: [
                if (!_single)
                  SliverToBoxAdapter(
                    child: Column(
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                          child: SearchBar(
                            controller: _q,
                            hintText: 'Search: name, amount, who…',
                            leading: const Icon(Icons.search),
                            elevation: const WidgetStatePropertyAll(0),
                            onChanged: (_) => setState(() {}),
                          ),
                        ),
                        SizedBox(
                          height: 52,
                          child: ListView(
                            scrollDirection: Axis.horizontal,
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            children: [
                              FilterChip(
                                label: Text(_mineOnly ? 'My & friends\' changes' : 'Everything, incl. automatic'),
                                selected: !_mineOnly,
                                onSelected: (v) {
                                  setState(() {
                                    _mineOnly = !v;
                                    _loaded = false;
                                  });
                                  _load();
                                },
                              ),
                              const SizedBox(width: 6),
                              FilterChip(
                                avatar: const Icon(Icons.warning_amber_rounded, size: 16),
                                label: const Text('Changed later'),
                                selected: _onlyChangedLater,
                                onSelected: (v) => setState(() => _onlyChangedLater = v),
                              ),
                              for (final (k, l) in [
                                ('all', 'All'),
                                ('payments', 'Payments'),
                                ('friends', 'Friends'),
                                ('rules', 'Rules'),
                                ('other', 'Accounts & more'),
                              ]) ...[
                                const SizedBox(width: 6),
                                ChoiceChip(
                                  label: Text(l),
                                  selected: _group == k,
                                  onSelected: (_) => setState(() => _group = k),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                if (list.isEmpty)
                  const SliverFillRemaining(
                    hasScrollBody: false,
                    child: Center(child: Text('No changes recorded here.')),
                  ),
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
                  sliver: SliverList.builder(
                    itemCount: list.length,
                    itemBuilder: (context, i) => _card(list[i], story[historyRecordKey(list[i])]!, scheme),
                  ),
                ),
                if (_more)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
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
                  ),
              ],
            ),
    );
  }

  Widget _card(Map<String, dynamic> r, List<Map<String, dynamic>> story, ColorScheme scheme) {
    final text = Theme.of(context).textTheme;
    final op = r['op'] as String;
    final removedShared = r['tbl'] == 'shared_entries' && ((r['after'] as Map?)?['deleted_at'] != null);
    final (Color color, IconData icon, String action) = switch (op) {
      'insert' => (Colors.green.shade600, Icons.add_circle, 'Added'),
      'delete' => (scheme.error, Icons.delete, 'Deleted'),
      _ when removedShared => (scheme.error, Icons.remove_circle, 'Removed'),
      _ => (Colors.amber.shade700, Icons.edit, 'Changed'),
    };
    final at = DateTime.parse(r['at'] as String).toLocal();
    final undone = r['undone'] == true;
    final later = story.where((x) => (x['id'] as num) > (r['id'] as num)).toList();
    final editsLater = later.where((x) => x['op'] == 'update').length;
    final deletedLater = op != 'delete' && later.any((x) => x['op'] == 'delete');
    final before = ((r['before'] as Map?) ?? const {}).cast<String, dynamic>();
    final after = ((r['after'] as Map?) ?? const {}).cast<String, dynamic>();
    String show(String f, Object? v) => f == 'category_id' && v == null ? 'No category' : fmt.value(f, v);
    String label(String f) => historyFieldNames[f] ?? f.replaceAll('_', ' ');
    final small = text.bodySmall?.copyWith(color: scheme.onSurfaceVariant);

    // Added / deleted: what it was. Changed: before → after.
    final table = <TableRow>[];
    if (op == 'update') {
      for (final f in after.keys) {
        table.add(
          TableRow(
            children: [
              Padding(
                padding: const EdgeInsets.only(right: 10, bottom: 4),
                child: Text(label(f), style: small),
              ),
              Padding(
                padding: const EdgeInsets.only(right: 8, bottom: 4),
                child: Text(
                  show(f, before[f]),
                  style: TextStyle(color: scheme.error, decoration: TextDecoration.lineThrough),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  show(f, after[f]),
                  style: TextStyle(color: Colors.green.shade700, fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
        );
      }
    } else if (r['tbl'] != 'shared_entries') {
      final m = op == 'delete' ? before : after;
      final keys = r['tbl'] == 'transactions'
          ? _txnFields.where(m.containsKey)
          : m.keys.where(
              (f) => !const {'user_id', 'id', 'txn_id', 'created_at', 'icon', 'color', 'paid_txn_id'}.contains(f),
            );
      for (final f in keys) {
        if (m[f] == null || '${m[f]}'.isEmpty) continue;
        table.add(
          TableRow(
            children: [
              Padding(
                padding: const EdgeInsets.only(right: 10, bottom: 4),
                child: Text(label(f), style: small),
              ),
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  show(f, m[f]),
                  style: op == 'delete'
                      ? TextStyle(decoration: TextDecoration.lineThrough, color: scheme.outline)
                      : null,
                ),
              ),
              const SizedBox.shrink(),
            ],
          ),
        );
      }
    }

    Widget badge(String t, Color c, IconData i) => Container(
      margin: const EdgeInsets.only(top: 8, right: 6),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: c.withValues(alpha: 0.5)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(i, size: 13, color: c),
          const SizedBox(width: 4),
          Text(
            t,
            style: TextStyle(fontSize: 12, color: c, fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );

    return Card.outlined(
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: color.withValues(alpha: 0.35)),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: _single
            ? null
            : () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => ChangeHistoryScreen(
                    data: data,
                    recordKey: historyRecordKey(r),
                    title: _title(r),
                    loader: widget.loader == null && historyRecordKey(r).length == 36
                        ? null
                        : () async => story.reversed.toList(),
                  ),
                ),
              ),
        child: Opacity(
          opacity: undone ? 0.55 : 1,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(icon, size: 18, color: color),
                    const SizedBox(width: 6),
                    Text(
                      action,
                      style: TextStyle(color: color, fontWeight: FontWeight.w800),
                    ),
                    Expanded(
                      child: Text(
                        '  ·  ${_who(r)}',
                        style: const TextStyle(fontWeight: FontWeight.w600),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (!undone)
                      PopupMenuButton<String>(
                        tooltip: 'Undo',
                        icon: const Icon(Icons.more_vert, size: 18),
                        onSelected: (v) => _undo(r, wholeAction: v == 'all'),
                        itemBuilder: (_) => [
                          const PopupMenuItem(value: 'one', child: Text('Undo this change')),
                          if (_rows.where((x) => x['batch'] == r['batch']).length > 1)
                            const PopupMenuItem(value: 'all', child: Text('Undo the whole action')),
                        ],
                      )
                    else
                      const SizedBox(width: 12),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  r['tbl'] == 'shared_entries' ? fmt.sharedLine(r) : _title(r),
                  style: text.titleSmall?.copyWith(fontWeight: FontWeight.w800),
                ),
                Text(DateFormat('EEE d MMM yyyy, h:mm a').format(at), style: small),
                if (table.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Table(
                    columnWidths: const {0: IntrinsicColumnWidth(), 1: FlexColumnWidth(), 2: FlexColumnWidth()},
                    children: table,
                  ),
                ],
                Wrap(
                  children: [
                    if (undone) badge('undone', scheme.outline, Icons.undo),
                    if (editsLater > 0)
                      badge('changed $editsLater× later', Colors.amber.shade800, Icons.warning_amber_rounded),
                    if (deletedLater) badge('deleted later', scheme.error, Icons.delete_outline),
                  ],
                ),
              ],
            ),
          ),
        ),
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
