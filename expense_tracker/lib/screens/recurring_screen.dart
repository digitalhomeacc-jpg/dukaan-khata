import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';

import '../data/app_data.dart';
import '../logic/recurring.dart';
import '../logic/summary.dart';
import '../models.dart';
import '../ui/category_picker.dart';
import '../ui/category_style.dart';
import '../ui/format.dart';
import 'txn_editor.dart';

/// "Tomorrow", "Today", "in 3 days", "2 days late".
String dueWhen(DateTime due, {DateTime? now}) {
  final n = now ?? DateTime.now();
  final days = DateTime(due.year, due.month, due.day).difference(DateTime(n.year, n.month, n.day)).inDays;
  return switch (days) {
    0 => 'Today',
    1 => 'Tomorrow',
    -1 => 'Yesterday · not seen yet',
    < 0 => '${-days} days late · not seen yet',
    < 7 => 'In $days days · ${DateFormat('EEE').format(due)}',
    _ => DateFormat('d MMM').format(due),
  };
}

Future<void> openRecurring(BuildContext context, AppData data) => Navigator.of(context).push(
  MaterialPageRoute<void>(
    builder: (_) => ListenableBuilder(
      listenable: data,
      builder: (_, _) => RecurringScreen(data: data),
    ),
  ),
);

/// One due date, as a list row: tap for what happened (paid in cash, it was this payment, skip).
class DueTile extends StatelessWidget {
  const DueTile({super.key, required this.data, required this.item, this.dense = false});

  final AppData data;
  final DueItem item;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final r = item.recurring;
    final scheme = Theme.of(context).colorScheme;
    final late = item.state == DueState.overdue;
    return ListTile(
      dense: dense,
      leading: CategoryAvatar(data.category(r.categoryId), size: dense ? 32 : 40),
      title: Text(r.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        dueWhen(item.due),
        style: TextStyle(color: late ? scheme.error : null, fontWeight: late ? FontWeight.w600 : null),
      ),
      trailing: Text(
        '${r.isDebit ? '' : '+'}${r.varies ? '~' : ''}${money(r.amount)}',
        style: TextStyle(fontWeight: FontWeight.w700, color: r.isDebit ? null : Colors.green.shade700),
      ),
      onTap: () => showDueActions(context, data, item),
    );
  }
}

/// What happened with a due date: paid (in cash or another way), it was one of these payments, or skip it.
Future<void> showDueActions(BuildContext context, AppData data, DueItem item) async {
  final r = item.recurring;
  final used = {for (final x in data.recurringRuns) ?x.txnId};
  final options = candidatesFor(r, item.due, data.transactions, used);
  final messenger = ScaffoldMessenger.of(context);
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (c) {
      Future<void> act(Future<bool> Function() f, String done) async {
        Navigator.pop(c);
        try {
          final ok = await f();
          messenger.showSnackBar(SnackBar(content: Text(ok ? done : 'Already done on another phone')));
        } catch (e) {
          messenger.showSnackBar(SnackBar(content: Text('Could not save: $e')));
        }
      }

      final text = Theme.of(c).textTheme;
      return SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('${r.name} · ${money(r.amount)}', style: text.titleLarge),
            Text('Due ${DateFormat('EEE, d MMM').format(item.due)} · ${r.everyLabel}', style: text.bodyMedium),
            const SizedBox(height: 16),
            if (options.isNotEmpty) ...[
              Text(
                r.isDebit ? 'Already paid? Is it one of these?' : 'Already came in? Is it one of these?',
                style: text.titleSmall,
              ),
              for (final t in options)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.link),
                  title: Text('${t.title} · ${money(t.amount)}'),
                  subtitle: Text('${dayLabel(t.txnAt)} · ${data.account(t.accountId)?.name ?? ''}'),
                  onTap: () => act(
                    () => data.settleDue(r, item.due, kind: 'matched', txn: t),
                    'Linked. Payments to ${t.title} count as ${r.name} from now on.',
                  ),
                ),
              const Divider(),
            ],
            FilledButton.icon(
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
              onPressed: () => act(
                () => data.settleDue(r, item.due, kind: 'added', accountId: data.cashAccount?.id),
                'Added: ${r.name} ${money(r.amount)} in cash',
              ),
              icon: const Icon(Icons.payments_outlined),
              label: Text(r.isDebit ? 'Paid in cash: add it' : 'Got it in cash: add it'),
            ),
            const SizedBox(height: 8),
            Text(
              r.isDebit
                  ? 'Paid by UPI or card? It is filed here by itself when the bank email or statement comes in.'
                  : 'Came into the bank? It is filed here by itself when the bank email or statement comes in.',
              style: text.bodySmall,
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(44)),
              onPressed: () => act(() => data.settleDue(r, item.due, kind: 'skipped'), 'Skipped this time'),
              icon: const Icon(Icons.skip_next_outlined),
              label: const Text('Skip this time (not paid)'),
            ),
            TextButton(
              onPressed: () {
                Navigator.pop(c);
                editRecurring(context, data, existing: r);
              },
              child: const Text('Change this repeat'),
            ),
          ],
        ),
      );
    },
  );
}

class RecurringScreen extends StatelessWidget {
  const RecurringScreen({super.key, required this.data});

  final AppData data;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final plan = data.recurringPlan;
    final active = data.recurring.where((r) => r.active).toList()..sort((a, b) => a.name.compareTo(b.name));
    final stopped = data.recurring.where((r) => !r.active).toList();
    final suggestions = suggestRecurring(data.transactions, data.recurring, DateTime.now());
    final loanDues = upcomingDues(
      data.loans,
      data.loanEvents,
      months: 1,
    ).where((d) => d.date.difference(DateTime.now()).inDays <= 30).toList();
    final monthly = active.fold(0.0, (v, r) {
      final m = switch (r.every) {
        'week' => r.amount * 52 / 12,
        'year' => r.amount / 12,
        _ => r.amount,
      };
      return v + (r.isDebit ? m : 0);
    });

    Widget heading(String t, [String? note]) => Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(t, style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
          if (note != null) Text(note, style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
        ],
      ),
    );

    return Scaffold(
      appBar: AppBar(title: const Text('Repeats and dues')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => editRecurring(context, data),
        icon: const Icon(Icons.add),
        label: const Text('New repeat'),
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 96),
        children: [
          if (active.isNotEmpty)
            Container(
              margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(color: scheme.primaryContainer, borderRadius: BorderRadius.circular(20)),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${money(monthly.roundToDouble())} a month',
                    style: text.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  Text('goes out in ${active.where((r) => r.isDebit).length} repeats (rent, bills, subscriptions)'),
                ],
              ),
            ),
          heading('Due', 'Late ones first. Tap one to say what happened.'),
          if (plan.due.isEmpty && loanDues.isEmpty)
            const Padding(padding: EdgeInsets.all(16), child: Text('Nothing due in the next 30 days.')),
          for (final d in plan.due) DueTile(data: data, item: d),
          for (final d in loanDues)
            ListTile(
              leading: const CircleAvatar(child: Icon(Icons.account_balance_outlined)),
              title: Text('${d.loan.name} EMI'),
              subtitle: Text(dueWhen(d.date)),
              trailing: Text(
                '${d.estimate ? '~' : ''}${money(d.amount)}',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
          if (suggestions.isNotEmpty) ...[
            heading('Looks like a repeat', 'Paid the same amount, month after month. Add it to see it coming.'),
            for (final s in suggestions)
              ListTile(
                leading: CategoryAvatar(data.category(s.categoryId), size: 36),
                title: Text('${s.name} · ${money(s.amount)}'),
                subtitle: Text('${s.months} of the last 6 months · last ${dayLabel(s.last)}'),
                trailing: FilledButton.tonal(
                  onPressed: () => editRecurring(
                    context,
                    data,
                    prefill: Recurring(
                      id: '',
                      name: s.name,
                      amount: s.amount,
                      isDebit: s.isDebit,
                      startsOn: DateTime(s.last.year, s.last.month + 1, s.last.day),
                      categoryId: s.categoryId,
                      accountId: s.accountId,
                    ),
                  ),
                  child: const Text('Add'),
                ),
              ),
          ],
          heading('Your repeats'),
          if (active.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Text('Rent, subscriptions, phone, salary: add them to see what is coming and never pay late.'),
            ),
          for (final r in active) _RecurringTile(data: data, r: r),
          if (stopped.isNotEmpty)
            ExpansionTile(
              title: Text('Stopped (${stopped.length})'),
              children: [for (final r in stopped) _RecurringTile(data: data, r: r)],
            ),
        ],
      ),
    );
  }
}

class _RecurringTile extends StatelessWidget {
  const _RecurringTile({required this.data, required this.r});

  final AppData data;
  final Recurring r;

  @override
  Widget build(BuildContext context) {
    final next = nextDueFrom(r, DateTime.now());
    return ListTile(
      leading: CategoryAvatar(data.category(r.categoryId), size: 40),
      title: Text(r.name),
      subtitle: Text(
        [
          r.everyLabel,
          if (r.active) 'next ${DateFormat('d MMM').format(next)}',
          if (r.autoAdd) 'added by itself',
          if (r.groupId != null) 'split in ${data.group(r.groupId)?.name ?? 'a group'}',
        ].join(' · '),
      ),
      trailing: Text('${r.isDebit ? '' : '+'}${money(r.amount)}', style: const TextStyle(fontWeight: FontWeight.w700)),
      onTap: () => editRecurring(context, data, existing: r),
    );
  }
}

/// New repeat, or change one (and see each due date it settled, with undo).
Future<void> editRecurring(BuildContext context, AppData data, {Recurring? existing, Recurring? prefill}) =>
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => ListenableBuilder(
          listenable: data,
          builder: (_, _) => RecurringEditor(data: data, existing: existing, prefill: prefill),
        ),
      ),
    );

class RecurringEditor extends StatefulWidget {
  const RecurringEditor({super.key, required this.data, this.existing, this.prefill});

  final AppData data;
  final Recurring? existing;
  final Recurring? prefill;

  @override
  State<RecurringEditor> createState() => _RecurringEditorState();
}

class _RecurringEditorState extends State<RecurringEditor> {
  late final Recurring? _start = widget.existing ?? widget.prefill;
  late final _name = TextEditingController(text: _start?.name ?? '');
  late final _amount = TextEditingController(
    text: _start == null ? '' : _start.amount.toStringAsFixed(_start.amount == _start.amount.roundToDouble() ? 0 : 2),
  );
  late var _isDebit = _start?.isDebit ?? true;
  late var _every = _start?.every ?? 'month';
  late var _startsOn = _start?.startsOn ?? DateTime(DateTime.now().year, DateTime.now().month, DateTime.now().day + 1);
  late var _varies = _start?.varies ?? false;
  late var _autoAdd = _start?.autoAdd ?? false;
  late String? _categoryId = _start?.categoryId;
  late String? _accountId = _start?.accountId;
  late String? _groupId = _start?.groupId;
  var _busy = false;
  String? _error;

  AppData get data => widget.data;
  bool get _cash => _accountId != null && _accountId == data.cashAccount?.id;

  Future<void> _save() async {
    final amount = double.tryParse(_amount.text.replaceAll(',', ''));
    if (_name.text.trim().isEmpty || amount == null || amount <= 0) {
      return setState(() => _error = 'Enter a name and the amount');
    }
    setState(() => _busy = true);
    try {
      await data.saveRecurring(
        id: widget.existing?.id,
        name: _name.text,
        amount: amount,
        isDebit: _isDebit,
        every: _every,
        startsOn: _startsOn,
        varies: _varies,
        autoAdd: _autoAdd && _cash,
        categoryId: _categoryId,
        accountId: _accountId,
        groupId: _isDebit ? _groupId : null,
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
    final existing = widget.existing;
    final runs = existing == null
        ? const <RecurringRun>[]
        : (data.recurringRuns.where((r) => r.recurringId == existing.id).toList()
            ..sort((a, b) => b.dueOn.compareTo(a.dueOn)));
    final groups = data.groups.where((g) => !g.archived).toList();
    return Scaffold(
      appBar: AppBar(
        title: Text(existing == null ? 'New repeat' : 'Repeat'),
        actions: [
          if (existing != null && existing.active)
            IconButton(
              tooltip: 'Stop',
              icon: const Icon(Icons.stop_circle_outlined),
              onPressed: () async {
                await data.stopRecurring(existing.id);
                if (context.mounted) Navigator.pop(context);
              },
            ),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton(onPressed: _busy ? null : _save, child: const Text('Save')),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SegmentedButton<bool>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: true, label: Text('I pay'), icon: Icon(Icons.arrow_upward)),
              ButtonSegment(value: false, label: Text('I get'), icon: Icon(Icons.arrow_downward)),
            ],
            selected: {_isDebit},
            onSelectionChanged: (s) => setState(() => _isDebit = s.first),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _name,
            textCapitalization: TextCapitalization.words,
            decoration: InputDecoration(
              labelText: 'Name',
              hintText: _isDebit ? 'Rent, Netflix, Jio, maid' : 'Salary, rent from tenant',
              helperText: 'Payments with this name are filed here by themselves',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _amount,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))],
            style: text.headlineSmall,
            decoration: const InputDecoration(labelText: 'Amount', prefixText: '₹ '),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _varies,
            onChanged: (v) => setState(() => _varies = v),
            title: const Text('The amount changes each time'),
            subtitle: const Text('Electricity, credit card bill: matched by name, roughly this amount'),
          ),
          const SizedBox(height: 8),
          Text('How often', style: text.titleSmall),
          const SizedBox(height: 6),
          SegmentedButton<String>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: 'week', label: Text('Weekly')),
              ButtonSegment(value: 'month', label: Text('Monthly')),
              ButtonSegment(value: 'year', label: Text('Yearly')),
            ],
            selected: {_every},
            onSelectionChanged: (s) => setState(() => _every = s.first),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.event_outlined),
            title: Text(existing == null ? 'First due date' : 'Due dates start from'),
            subtitle: Text(
              '${DateFormat('EEE, d MMM yyyy').format(_startsOn)} · then ${switch (_every) {
                'week' => 'every ${DateFormat('EEEE').format(_startsOn)}',
                'year' => 'every ${DateFormat('d MMMM').format(_startsOn)}',
                _ => 'the ${_startsOn.day}${_ordinal(_startsOn.day)} of each month',
              }}',
            ),
            onTap: () async {
              final d = await showDatePicker(
                context: context,
                initialDate: _startsOn,
                firstDate: DateTime(2020),
                lastDate: DateTime(2100),
              );
              if (d != null) setState(() => _startsOn = d);
            },
          ),
          const SizedBox(height: 8),
          CategoryField(
            data: data,
            categoryId: _categoryId,
            onTap: () async {
              final pick = await pickCategory(context, data, selected: _categoryId);
              if (pick != null) setState(() => _categoryId = pick.id);
            },
          ),
          const SizedBox(height: 16),
          Text(_isDebit ? 'Paid from' : 'Comes into', style: text.titleSmall),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              ChoiceChip(
                label: const Text('Any account'),
                selected: _accountId == null,
                onSelected: (_) => setState(() => _accountId = null),
              ),
              for (final a in data.accounts.where((a) => !a.archived && a.kind != AccountKind.card))
                ChoiceChip(
                  label: Text(a.name),
                  selected: _accountId == a.id,
                  onSelected: (v) => setState(() => _accountId = v ? a.id : null),
                ),
            ],
          ),
          if (_cash)
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _autoAdd,
              onChanged: (v) => setState(() => _autoAdd = v),
              title: const Text('Add it by itself on the day'),
              subtitle: const Text('Cash has no bank email. Undo any time from this page or the entry.'),
            )
          else
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                'Bank payments are never added twice: when the bank email or statement brings it in, it is filed '
                'here. Not seen a few days after the date? It shows as late, to mark paid in cash or skip.',
                style: text.bodySmall,
              ),
            ),
          if (_isDebit && groups.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text('Shared bill? Split it in a group each time', style: text.titleSmall),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                ChoiceChip(
                  label: const Text('Just me'),
                  selected: _groupId == null,
                  onSelected: (_) => setState(() => _groupId = null),
                ),
                for (final g in groups)
                  ChoiceChip(
                    label: Text('${g.emoji ?? '👥'} ${g.name}'),
                    selected: _groupId == g.id,
                    onSelected: (v) => setState(() => _groupId = v ? g.id : null),
                  ),
              ],
            ),
            if (_groupId != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  'Each time: split equally between you and ${data.group(_groupId)?.members.join(', ')}. '
                  'Only your part counts as your spending; they owe you theirs.',
                  style: text.bodySmall,
                ),
              ),
          ],
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ),
          if (runs.isNotEmpty) ...[
            const SizedBox(height: 24),
            Text('Each time', style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
            for (final run in runs)
              Builder(
                builder: (context) {
                  final t = data.txn(run.txnId);
                  return ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(switch (run.kind) {
                      'matched' => Icons.link,
                      'added' => Icons.payments_outlined,
                      _ => Icons.skip_next_outlined,
                    }),
                    title: Text(DateFormat('d MMM yyyy').format(run.dueOn)),
                    subtitle: Text(switch (run.kind) {
                      'matched' => 'Paid: ${t?.title ?? 'a payment'} ${t == null ? '' : '· ${dayLabel(t.txnAt)}'}',
                      'added' => 'Added by the app',
                      _ => 'Skipped',
                    }),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (t != null) Text(money(t.amount)),
                        IconButton(
                          tooltip: 'Undo',
                          icon: const Icon(Icons.undo),
                          onPressed: () async {
                            final ok = await showDialog<bool>(
                              context: context,
                              builder: (c) => AlertDialog(
                                title: const Text('Undo this?'),
                                content: Text(
                                  run.kind == 'added'
                                      ? 'The entry the app added is removed, and the date is due again.'
                                      : 'The date is due again. ${run.kind == 'matched' ? 'The payment stays as it is.' : ''}',
                                ),
                                actions: [
                                  TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
                                  FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Undo')),
                                ],
                              ),
                            );
                            if (ok == true) await data.unsettle(run);
                          },
                        ),
                      ],
                    ),
                    onTap: t == null ? null : () => openTxnEditor(context, data, existing: t),
                  );
                },
              ),
          ],
        ],
      ),
    );
  }
}

String _ordinal(int d) {
  if (d >= 11 && d <= 13) return 'th';
  return switch (d % 10) {
    1 => 'st',
    2 => 'nd',
    3 => 'rd',
    _ => 'th',
  };
}
