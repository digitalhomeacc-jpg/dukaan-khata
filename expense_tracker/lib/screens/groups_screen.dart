import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../data/app_data.dart';
import '../logic/summary.dart';
import '../models.dart';
import '../ui/save_button.dart';
import '../ui/category_picker.dart';
import '../ui/category_style.dart';
import '../ui/format.dart';

String _who(String m) => m == 'me' ? 'You' : m;

/// On the Friends tab: your groups with where you stand in each.
class GroupsSection extends StatelessWidget {
  const GroupsSection({super.key, required this.data});

  final AppData data;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final groups = data.groups.where((g) => !g.archived).toList();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text('Groups', style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
              ),
              TextButton.icon(
                onPressed: () => editGroup(context, data),
                icon: const Icon(Icons.group_add_outlined, size: 18),
                label: const Text('New group'),
              ),
            ],
          ),
          if (groups.isEmpty)
            Text(
              'A trip, the flat, office lunches: add what everyone paid, see who owes whom in the fewest payments.',
              style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          SizedBox(
            height: groups.isEmpty ? 0 : 108,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                for (final g in groups)
                  Builder(
                    builder: (context) {
                      final me = groupBalances(data.expensesOf(g.id), g.members)['me'] ?? 0;
                      return SizedBox(
                        width: 170,
                        child: Card.filled(
                          child: InkWell(
                            borderRadius: BorderRadius.circular(12),
                            onTap: () => openGroup(context, data, g.id),
                            child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '${g.emoji ?? '👥'} ${g.name}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: text.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                                  ),
                                  Text('${g.members.length + 1} people', style: text.bodySmall),
                                  const Spacer(),
                                  Text(
                                    me.abs() < 0.005
                                        ? 'Settled'
                                        : (me > 0 ? 'You get ${money(me)}' : 'You owe ${money(-me)}'),
                                    style: TextStyle(
                                      fontWeight: FontWeight.w700,
                                      color: me.abs() < 0.005 ? null : (me > 0 ? Colors.green.shade700 : scheme.error),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

Future<void> openGroup(BuildContext context, AppData data, String id) => Navigator.of(context).push(
  MaterialPageRoute<void>(
    builder: (_) => ListenableBuilder(
      listenable: data,
      builder: (_, _) => GroupScreen(data: data, groupId: id),
    ),
  ),
);

/// New group, or change its name and members.
Future<void> editGroup(BuildContext context, AppData data, {Group? group}) async {
  final name = TextEditingController(text: group?.name ?? '');
  final emoji = TextEditingController(text: group?.emoji ?? '');
  final add = TextEditingController();
  final members = <String>{...?group?.members};
  final friends = {
    ...data.personNames.entries.where((e) => data.people[e.key] == 'friend').map((e) => e.value),
    ...data.friendBalances.map((l) => l.person),
  }.toList()..sort();
  final ok = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    useSafeArea: true,
    builder: (c) => StatefulBuilder(
      builder: (c, setState) => Padding(
        padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + MediaQuery.viewInsetsOf(c).bottom),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(group == null ? 'New group' : 'Edit group', style: Theme.of(c).textTheme.titleLarge),
                  ),
                  FilledButton(
                    onPressed: () => name.text.trim().isEmpty || members.isEmpty ? null : Navigator.pop(c, true),
                    child: const Text('Save'),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  SizedBox(
                    width: 64,
                    child: TextField(
                      controller: emoji,
                      textAlign: TextAlign.center,
                      decoration: const InputDecoration(hintText: '🏖️'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: name,
                      autofocus: group == null,
                      textCapitalization: TextCapitalization.sentences,
                      decoration: const InputDecoration(labelText: 'Name', hintText: 'Goa trip, Flat 302, Lunch'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Text('Who is in it (you always are)', style: Theme.of(c).textTheme.titleSmall),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final f in {...friends, ...members})
                    FilterChip(
                      label: Text(f),
                      selected: members.contains(f),
                      onSelected: (v) => setState(() => v ? members.add(f) : members.remove(f)),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              TextField(
                controller: add,
                textCapitalization: TextCapitalization.words,
                decoration: InputDecoration(
                  labelText: 'Someone else',
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.add),
                    onPressed: () => setState(() {
                      if (add.text.trim().isNotEmpty) members.add(add.text.trim());
                      add.clear();
                    }),
                  ),
                ),
                onSubmitted: (_) => setState(() {
                  if (add.text.trim().isNotEmpty) members.add(add.text.trim());
                  add.clear();
                }),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  if (ok != true) return;
  final e = emoji.text.trim();
  await data.saveGroup(id: group?.id, name: name.text, emoji: e.isEmpty ? null : e, members: members.toList());
}

class GroupScreen extends StatelessWidget {
  const GroupScreen({super.key, required this.data, required this.groupId});

  final AppData data;
  final String groupId;

  Future<void> _settle(BuildContext context, Group g, ({String from, String to, double amount}) p) async {
    final ctl = TextEditingController(text: p.amount.toStringAsFixed(p.amount == p.amount.roundToDouble() ? 0 : 2));
    var cash = false;
    final mine = p.from == 'me' || p.to == 'me';
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, setState) => AlertDialog(
          title: Text('${_who(p.from)} paid ${_who(p.to)}'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: ctl,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))],
                decoration: const InputDecoration(prefixText: '₹ '),
              ),
              if (mine) ...[
                const SizedBox(height: 12),
                SegmentedButton<bool>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(value: false, label: Text('UPI / bank')),
                    ButtonSegment(value: true, label: Text('Cash')),
                  ],
                  selected: {cash},
                  onSelectionChanged: (s) => setState(() => cash = s.first),
                ),
                const SizedBox(height: 8),
                Text(
                  cash
                      ? 'Your cash changes by this amount.'
                      : 'The bank payment comes in by itself from the bank email, so it is not added twice.',
                  style: Theme.of(c).textTheme.bodySmall,
                ),
              ],
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Record')),
          ],
        ),
      ),
    );
    final v = double.tryParse(ctl.text.replaceAll(',', ''));
    if (ok == true && v != null && v > 0) {
      await data.addGroupSettle(group: g, from: p.from, to: p.to, amount: v, at: DateTime.now(), byCash: cash);
    }
  }

  @override
  Widget build(BuildContext context) {
    final g = data.group(groupId);
    if (g == null) return const Scaffold(body: Center(child: Text('This group is gone.')));
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final items = data.expensesOf(g.id);
    final bal = groupBalances(items, g.members);
    final plan = simplifyDebts(bal);
    final spent = items.where((e) => !e.isSettle).fold(0.0, (v, e) => v + e.amount);
    final mine = items.where((e) => !e.isSettle).fold(0.0, (v, e) => v + (e.shares['me'] ?? 0));
    final me = bal['me'] ?? 0;

    return Scaffold(
      appBar: AppBar(
        title: Text('${g.emoji ?? '👥'} ${g.name}'),
        actions: [
          IconButton(
            tooltip: 'Edit',
            icon: const Icon(Icons.edit_outlined),
            onPressed: () => editGroup(context, data, group: g),
          ),
          PopupMenuButton<String>(
            onSelected: (v) async {
              await data.archiveGroup(g.id);
              if (context.mounted) Navigator.pop(context);
            },
            itemBuilder: (_) => const [PopupMenuItem(value: 'archive', child: Text('Archive group'))],
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            fullscreenDialog: true,
            builder: (_) => GroupExpenseEditor(data: data, group: g),
          ),
        ),
        icon: const Icon(Icons.add),
        label: const Text('Add expense'),
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 96),
        children: [
          Container(
            margin: const EdgeInsets.all(16),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(color: scheme.primaryContainer, borderRadius: BorderRadius.circular(20)),
            child: Column(
              children: [
                Text(
                  me.abs() < 0.005
                      ? 'You are settled'
                      : (me > 0 ? 'You get back ${money(me)}' : 'You owe ${money(-me)}'),
                  style: text.titleLarge?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 4),
                Text('Group spent ${money(spent)} · your share ${money(mine)}'),
              ],
            ),
          ),
          if (plan.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                'Settle in ${plan.length} payment${plan.length == 1 ? '' : 's'}',
                style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
            ),
            for (final p in plan)
              ListTile(
                leading: const Icon(Icons.east),
                title: Text('${_who(p.from)} → ${_who(p.to)}'),
                subtitle: Text(money(p.amount), style: const TextStyle(fontWeight: FontWeight.w700)),
                trailing: OutlinedButton(onPressed: () => _settle(context, g, p), child: const Text('Paid')),
              ),
          ],
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text('Everyone', style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
          ),
          for (final m in ['me', ...g.members])
            ListTile(
              dense: true,
              leading: CircleAvatar(radius: 14, child: Text(_who(m)[0])),
              title: Text(_who(m)),
              trailing: Text(
                (bal[m] ?? 0).abs() < 0.005
                    ? 'settled'
                    : ((bal[m] ?? 0) > 0 ? 'gets ${money(bal[m]!)}' : 'owes ${money(-bal[m]!)}'),
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: (bal[m] ?? 0).abs() < 0.005
                      ? null
                      : ((bal[m] ?? 0) > 0 ? Colors.green.shade700 : scheme.error),
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text('Expenses', style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
          ),
          if (items.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: Text('Nothing added yet.')),
            ),
          for (final e in items)
            ListTile(
              leading: e.isSettle
                  ? const Icon(Icons.handshake_outlined)
                  : CategoryAvatar(data.category(e.categoryId), size: 36),
              title: Text(
                e.isSettle ? '${_who(e.paidBy)} paid ${_who(e.paidTo ?? '?')}' : (e.description ?? 'Expense'),
              ),
              subtitle: Text(
                [
                  dayLabel(e.at),
                  if (!e.isSettle) '${_who(e.paidBy)} paid',
                  if (!e.isSettle && (e.shares['me'] ?? 0) > 0) 'your share ${money(e.shares['me']!)}',
                ].join(' · '),
              ),
              trailing: Text(money(e.amount), style: const TextStyle(fontWeight: FontWeight.w700)),
              onLongPress: () async {
                final yes = await showDialog<bool>(
                  context: context,
                  builder: (c) => AlertDialog(
                    title: const Text('Remove this?'),
                    content: const Text(
                      'It is removed from the group and from your records (a bank payment it was linked to stays). '
                      'Undo in Settings → Change history.',
                    ),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
                      FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Remove')),
                    ],
                  ),
                );
                if (yes == true) await data.deleteGroupExpense(e);
              },
            ),
        ],
      ),
    );
  }
}

/// Add an expense to a group: who paid, how it splits, and (if you paid) where from, or link the bank payment.
class GroupExpenseEditor extends StatefulWidget {
  const GroupExpenseEditor({super.key, required this.data, required this.group});

  final AppData data;
  final Group group;

  @override
  State<GroupExpenseEditor> createState() => _GroupExpenseEditorState();
}

class _GroupExpenseEditorState extends State<GroupExpenseEditor> {
  final _what = TextEditingController();
  final _amount = TextEditingController();
  var _paidBy = 'me';
  late final _in = <String>{'me', ...widget.group.members};
  var _exact = false;
  final _exactCtl = <String, TextEditingController>{};
  String? _categoryId;
  String? _accountId;
  String? _linkTxnId;
  final _at = DateTime.now();
  var _busy = false;
  String? _error;

  AppData get data => widget.data;
  double get _total => double.tryParse(_amount.text.replaceAll(',', '')) ?? 0;

  Map<String, double> get _shares {
    final people = ['me', ...widget.group.members].where(_in.contains).toList();
    if (!_exact) return splitEqually(_total, people);
    return {for (final p in people) p: double.tryParse((_exactCtl[p]?.text ?? '').replaceAll(',', '')) ?? 0};
  }

  /// Your bank payments of this amount around now, not yet in a group: probably this very expense.
  List<Txn> get _candidates {
    final linked = {for (final e in data.groupExpenses) ?e.txnId};
    return data.transactions
        .where(
          (t) =>
              t.isDebit &&
              (t.amount - _total).abs() < 0.005 &&
              t.source != 'manual' &&
              !linked.contains(t.id) &&
              t.txnAt.difference(_at).inDays.abs() <= 3,
        )
        .take(3)
        .toList();
  }

  Future<void> _save() async {
    if (_busy) return;
    final shares = _shares;
    final sum = shares.values.fold(0.0, (v, x) => v + x);
    if (_what.text.trim().isEmpty || _total <= 0) return setState(() => _error = 'Enter what it was and the amount');
    if ((sum - _total).abs() > 0.05) {
      return setState(() => _error = 'The parts add up to ${money(sum)}, not ${money(_total)}');
    }
    setState(() => _busy = true);
    try {
      await data.addGroupExpense(
        group: widget.group,
        description: _what.text.trim(),
        amount: _total,
        paidBy: _paidBy,
        shares: shares,
        at: _at,
        categoryId: _categoryId,
        accountId: _paidBy == 'me' && _linkTxnId == null ? _accountId : null,
        linkTxnId: _paidBy == 'me' ? _linkTxnId : null,
      );
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = 'Could not save: $e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final people = ['me', ...widget.group.members];
    final shares = _shares;
    return Scaffold(
      appBar: AppBar(
        title: Text('Add to ${widget.group.name}'),
        actions: [SaveButton(onSave: _save)],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _what,
            autofocus: true,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(labelText: 'What was it?', hintText: 'Dinner, cab, groceries'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _amount,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))],
            style: text.headlineSmall,
            decoration: const InputDecoration(labelText: 'Amount', prefixText: '₹ '),
            onChanged: (_) => setState(() => _linkTxnId = null),
          ),
          const SizedBox(height: 16),
          Text('Who paid?', style: text.titleSmall),
          Wrap(
            spacing: 6,
            children: [
              for (final p in people)
                ChoiceChip(
                  label: Text(_who(p)),
                  selected: _paidBy == p,
                  onSelected: (_) => setState(() => _paidBy = p),
                ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(child: Text('Split between', style: text.titleSmall)),
              SegmentedButton<bool>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: false, label: Text('Equally')),
                  ButtonSegment(value: true, label: Text('Exact')),
                ],
                selected: {_exact},
                onSelectionChanged: (s) => setState(() => _exact = s.first),
              ),
            ],
          ),
          for (final p in people)
            Row(
              children: [
                Checkbox(
                  value: _in.contains(p),
                  onChanged: (v) => setState(() => v == true ? _in.add(p) : _in.remove(p)),
                ),
                Expanded(child: Text(_who(p))),
                if (_in.contains(p))
                  _exact
                      ? SizedBox(
                          width: 110,
                          child: TextField(
                            controller: _exactCtl.putIfAbsent(p, TextEditingController.new),
                            keyboardType: const TextInputType.numberWithOptions(decimal: true),
                            decoration: const InputDecoration(prefixText: '₹ ', isDense: true),
                            onChanged: (_) => setState(() {}),
                          ),
                        )
                      : Text(money(shares[p] ?? 0)),
              ],
            ),
          if (_exact)
            Builder(
              builder: (_) {
                final left = _total - shares.values.fold(0.0, (v, x) => v + x);
                return Text(
                  left.abs() < 0.005 ? 'Adds up ✓' : '${money(left.abs())} ${left > 0 ? 'still to share' : 'too much'}',
                  style: TextStyle(
                    color: left.abs() < 0.005 ? Colors.green.shade700 : Theme.of(context).colorScheme.error,
                  ),
                );
              },
            ),
          const SizedBox(height: 16),
          Text('Your part is', style: text.titleSmall),
          const SizedBox(height: 6),
          CategoryField(
            data: data,
            categoryId: _categoryId,
            onTap: () async {
              final pick = await pickCategory(context, data, selected: _categoryId, allowNone: false);
              if (pick != null) setState(() => _categoryId = pick.id);
            },
          ),
          if (_paidBy == 'me') ...[
            if (_total > 0 && _candidates.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text('Already in your bank? Link it so it is not counted twice', style: text.titleSmall),
              for (final t in _candidates)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(_linkTxnId == t.id ? Icons.radio_button_checked : Icons.radio_button_off),
                  onTap: () => setState(() => _linkTxnId = _linkTxnId == t.id ? null : t.id),
                  title: Text('${t.title} · ${money(t.amount)}'),
                  subtitle: Text('${dayLabel(t.txnAt)} · ${data.account(t.accountId)?.name ?? ''}'),
                ),
            ],
            if (_linkTxnId == null) ...[
              const SizedBox(height: 16),
              Text('Paid from', style: text.titleSmall),
              Wrap(
                spacing: 6,
                children: [
                  for (final a in data.accounts.where((a) => !a.archived))
                    ChoiceChip(
                      label: Text(a.name),
                      selected: _accountId == a.id,
                      onSelected: (v) => setState(() => _accountId = v ? a.id : null),
                    ),
                ],
              ),
            ],
          ],
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ),
        ],
      ),
    );
  }
}
