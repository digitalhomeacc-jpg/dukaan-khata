import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';

import '../data/app_data.dart';
import '../logic/goals.dart';
import '../models.dart';
import '../ui/category_picker.dart';
import '../ui/format.dart';

Future<void> openGoals(BuildContext context, AppData data) => Navigator.of(context).push(
  MaterialPageRoute<void>(
    builder: (_) => ListenableBuilder(
      listenable: data,
      builder: (_, _) => GoalsScreen(data: data),
    ),
  ),
);

/// A goal at a glance: progress bar, on track or not, and what it takes from here.
class GoalCard extends StatelessWidget {
  const GoalCard({super.key, required this.data, required this.goal, this.compact = false, this.showWeeks = false});

  final AppData data;
  final Goal goal;
  final bool compact;

  /// Week-by-week bars (Self analysis).
  final bool showWeeks;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final p = data.progressOf(goal);
    final good = Colors.green.shade700;
    final status = goal.isSave
        ? (p.reached
              ? 'Reached! 🎉'
              : p.onTrack
              ? 'On track · keep ${money(p.perWeekNeeded!.roundToDouble())} a week'
              : 'Behind by ${money((p.expectedNow - p.done).roundToDouble())} · keep ${money(p.perWeekNeeded!.roundToDouble())} a week')
        : (p.onTrack
              ? 'On track · ${money((p.target - p.done).clamp(0, double.infinity).roundToDouble())} left this month'
              : 'Over pace by ${money((p.done - p.expectedNow).roundToDouble())}');
    final color = p.reached || p.onTrack ? good : scheme.error;
    final barValue = goal.isSave ? p.fraction : (p.target <= 0 ? 1.0 : (p.done / p.target).clamp(0, 1).toDouble());

    return Card.outlined(
      margin: compact ? const EdgeInsets.symmetric(vertical: 4) : const EdgeInsets.fromLTRB(16, 6, 16, 6),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => editGoal(context, data, existing: goal),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(goal.emoji ?? (goal.isSave ? '🎯' : '✂️'), style: const TextStyle(fontSize: 20)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(goal.name, style: text.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                  ),
                  Text(
                    goal.isSave
                        ? '${money(p.done.clamp(0, double.infinity).roundToDouble())} / ${money(p.target.roundToDouble())}'
                        : '${money(p.done.roundToDouble())} / ${money(p.target.roundToDouble())}',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: LinearProgressIndicator(
                  value: barValue,
                  minHeight: 10,
                  color: goal.isSave ? color : (p.done > p.target ? scheme.error : color),
                  backgroundColor: scheme.surfaceContainerHighest,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                status,
                style: text.bodySmall?.copyWith(color: color, fontWeight: FontWeight.w600),
              ),
              if (!compact)
                Text(
                  goal.isSave
                      ? [
                          if (p.daysLeft != null && p.daysLeft! >= 0) '${p.daysLeft} days left',
                          'by ${DateFormat('d MMM yyyy').format(goal.deadline!)}',
                          goal.accountId == null
                              ? 'counting money kept (in − spent)'
                              : 'counting ${data.account(goal.accountId)?.name ?? 'the account'} growing',
                        ].join(' · ')
                      : 'Usual month ${money(p.baseline!.roundToDouble())} → limit ${money(p.target.roundToDouble())} '
                            '(−${goal.cutPct!.round()}%) · this week ${money(p.weekSpent!.roundToDouble())} of '
                            '${money(p.weekLimit!.roundToDouble())}',
                  style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                ),
              if (showWeeks && p.weeks.isNotEmpty) ...[const SizedBox(height: 10), _WeekBars(progress: p)],
            ],
          ),
        ),
      ),
    );
  }
}

class _WeekBars extends StatelessWidget {
  const _WeekBars({required this.progress});

  final GoalProgress progress;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final p = progress;
    final save = p.goal.isSave;
    final limit = save ? p.target : (p.weekLimit ?? 0);
    final top = [limit, ...p.weeks.map((w) => w.value)].fold(0.0, (m, v) => v > m ? v : m);
    return SizedBox(
      height: 70,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (final w in p.weeks)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Container(
                      height: top <= 0 ? 2 : (48 * (w.value.clamp(0, top) / top)).clamp(2, 48).toDouble(),
                      decoration: BoxDecoration(
                        color: save ? scheme.primary : (w.value > limit + 0.5 ? scheme.error : Colors.green.shade600),
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(DateFormat('d/M').format(w.start), style: const TextStyle(fontSize: 10)),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class GoalsScreen extends StatelessWidget {
  const GoalsScreen({super.key, required this.data});

  final AppData data;

  @override
  Widget build(BuildContext context) {
    final active = data.goals.where((g) => !g.archived).toList();
    final done = data.goals.where((g) => g.archived).toList();
    return Scaffold(
      appBar: AppBar(title: const Text('Goals')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => editGoal(context, data),
        icon: const Icon(Icons.add),
        label: const Text('New goal'),
      ),
      body: ListView(
        padding: const EdgeInsets.only(top: 8, bottom: 96),
        children: [
          if (active.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'Save for something by a date, or spend less on something. Progress updates by itself from your '
                'payments, week by week.',
              ),
            ),
          for (final g in active) GoalCard(data: data, goal: g, showWeeks: true),
          if (done.isNotEmpty)
            ExpansionTile(
              title: Text('Finished or put away (${done.length})'),
              children: [for (final g in done) GoalCard(data: data, goal: g)],
            ),
        ],
      ),
    );
  }
}

Future<void> editGoal(BuildContext context, AppData data, {Goal? existing}) => Navigator.of(context).push(
  MaterialPageRoute<void>(
    fullscreenDialog: true,
    builder: (_) => GoalEditor(data: data, existing: existing),
  ),
);

class GoalEditor extends StatefulWidget {
  const GoalEditor({super.key, required this.data, this.existing});

  final AppData data;
  final Goal? existing;

  @override
  State<GoalEditor> createState() => _GoalEditorState();
}

class _GoalEditorState extends State<GoalEditor> {
  late final Goal? _g = widget.existing;
  late var _kind = _g?.kind ?? 'save';
  late final _name = TextEditingController(text: _g?.name ?? '');
  late final _emoji = TextEditingController(text: _g?.emoji ?? '');
  late final _target = TextEditingController(text: _g?.targetAmount?.round().toString() ?? '');
  late final _pct = TextEditingController(text: _g?.cutPct?.round().toString() ?? '20');
  late var _deadline = _g?.deadline ?? DateTime(DateTime.now().year, DateTime.now().month + 3, DateTime.now().day);
  late final _startsOn = _g?.startsOn ?? DateTime.now();
  late String? _accountId = _g?.accountId;
  late String? _categoryId = _g?.categoryId;
  String? _error;

  AppData get data => widget.data;

  Future<void> _save() async {
    final target = double.tryParse(_target.text.replaceAll(',', ''));
    final pct = double.tryParse(_pct.text);
    if (_name.text.trim().isEmpty) return setState(() => _error = 'Give it a name');
    if (_kind == 'save' && (target == null || target <= 0)) return setState(() => _error = 'Enter the amount');
    if (_kind == 'cut' && (_categoryId == null || pct == null || pct <= 0 || pct > 100)) {
      return setState(() => _error = 'Pick the category and how much less (1–100%)');
    }
    try {
      await data.saveGoal(
        id: _g?.id,
        kind: _kind,
        name: _name.text,
        emoji: _emoji.text.trim().isEmpty ? null : _emoji.text.trim(),
        startsOn: _startsOn,
        targetAmount: target,
        deadline: _deadline,
        accountId: _accountId,
        categoryId: _categoryId,
        cutPct: pct,
      );
      if (mounted) Navigator.pop(context);
    } catch (e) {
      setState(() => _error = 'Could not save: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final cat = data.category(_categoryId);
    return Scaffold(
      appBar: AppBar(
        title: Text(_g == null ? 'New goal' : 'Goal'),
        actions: [
          if (_g != null)
            IconButton(
              tooltip: _g.archived ? 'Bring back' : 'Finished / put away',
              icon: Icon(_g.archived ? Icons.unarchive_outlined : Icons.archive_outlined),
              onPressed: () async {
                await data.archiveGoal(_g.id, archived: !_g.archived);
                if (context.mounted) Navigator.pop(context);
              },
            ),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton(onPressed: _save, child: const Text('Save')),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SegmentedButton<String>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: 'save', label: Text('Save up'), icon: Icon(Icons.savings_outlined)),
              ButtonSegment(value: 'cut', label: Text('Spend less'), icon: Icon(Icons.content_cut)),
            ],
            selected: {_kind},
            onSelectionChanged: _g == null ? (s) => setState(() => _kind = s.first) : null,
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              SizedBox(
                width: 64,
                child: TextField(
                  controller: _emoji,
                  textAlign: TextAlign.center,
                  decoration: InputDecoration(hintText: _kind == 'save' ? '🏍️' : '🚬'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _name,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: InputDecoration(
                    labelText: 'Name',
                    hintText: _kind == 'save' ? 'Goa trip, new phone, emergency fund' : 'Fewer cigarettes, less Swiggy',
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (_kind == 'save') ...[
            TextField(
              controller: _target,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9,]'))],
              style: text.headlineSmall,
              decoration: const InputDecoration(labelText: 'Save', prefixText: '₹ '),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.flag_outlined),
              title: const Text('By'),
              subtitle: Text(DateFormat('EEE, d MMM yyyy').format(_deadline)),
              onTap: () async {
                final d = await showDatePicker(
                  context: context,
                  initialDate: _deadline,
                  firstDate: DateTime.now(),
                  lastDate: DateTime(2100),
                );
                if (d != null) setState(() => _deadline = d);
              },
            ),
            Text('Count it as', style: text.titleSmall),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                ChoiceChip(
                  label: const Text('Money I keep (in − spent)'),
                  selected: _accountId == null,
                  onSelected: (_) => setState(() => _accountId = null),
                ),
                for (final a in data.accounts.where((a) => !a.archived && a.kind != AccountKind.card))
                  ChoiceChip(
                    label: Text('${a.name} growing'),
                    selected: _accountId == a.id,
                    onSelected: (v) => setState(() => _accountId = v ? a.id : null),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'Counted from ${DateFormat('d MMM yyyy').format(_startsOn)}. Moves between your accounts, loans and '
              'friends\' money never count as spending.',
              style: text.bodySmall,
            ),
          ] else ...[
            CategoryField(
              data: data,
              categoryId: _categoryId,
              hint: 'Which category?',
              onTap: () async {
                final pick = await pickCategory(context, data, selected: _categoryId, allowNone: false);
                if (pick != null) setState(() => _categoryId = pick.id);
              },
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _pct,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(labelText: 'Spend less by', suffixText: '%'),
            ),
            const SizedBox(height: 6),
            Text(
              'Compared with your usual month: the average of the 3 months before ${DateFormat('MMMM').format(_startsOn)}'
              '${cat == null ? '' : ' in ${cat.name} and its sub-categories'}. You get a monthly limit and a weekly pace.',
              style: text.bodySmall,
            ),
          ],
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ),
          if (_g != null) ...[
            const SizedBox(height: 16),
            GoalCard(data: data, goal: _g, compact: false, showWeeks: true),
          ],
        ],
      ),
    );
  }
}
