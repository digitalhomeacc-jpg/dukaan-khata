import 'package:material_ui/material_ui.dart';

import '../data/app_data.dart';
import '../logic/analysis.dart';
import '../ui/category_style.dart';
import '../ui/format.dart';
import '../ui/paid_with.dart';
import '../ui/range.dart';
import 'goals_screen.dart';
import 'txn_editor.dart';

Future<void> openAnalysis(BuildContext context, AppData data) => Navigator.of(context).push(
  MaterialPageRoute<void>(
    builder: (_) => ListenableBuilder(
      listenable: data,
      builder: (_, _) => AnalysisScreen(data: data),
    ),
  ),
);

/// A look at yourself through your money: what came and went, how it changed, habits, leaks, regular costs.
class AnalysisScreen extends StatefulWidget {
  const AnalysisScreen({super.key, required this.data});

  final AppData data;

  @override
  State<AnalysisScreen> createState() => _AnalysisScreenState();
}

class _AnalysisScreenState extends State<AnalysisScreen> {
  var _range = rangePresets().first.range;
  var _paidWith = const PaidWith.all();

  AppData get data => widget.data;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final txns = _paidWith.isAll ? data.transactions : data.transactions.where(_paidWith.keep).toList();
    final a = analyse(
      txns,
      _range.start,
      _range.end,
      notSpendingIds: data.notSpendingCategoryIds,
      shares: data.shareTotalsNow,
    );
    String signed(double v) => '${v < 0 ? '−' : '+'}${money(v.abs())}';
    String pct(double v) => '${(v * 100).round()}%';

    Widget section(String title, List<Widget> children, {String? note}) => Card.outlined(
      margin: const EdgeInsets.fromLTRB(16, 6, 16, 6),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
            if (note != null) Text(note, style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
            const SizedBox(height: 8),
            ...children,
          ],
        ),
      ),
    );

    Widget row(String label, String value, {Color? color, bool bold = false}) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(child: Text(label)),
          Text(
            value,
            style: TextStyle(color: color, fontWeight: bold ? FontWeight.w700 : FontWeight.w600),
          ),
        ],
      ),
    );

    Widget bars(List<String> labels, List<double> values) {
      final top = values.fold(0.0, (m, v) => v > m ? v : m);
      return Column(
        children: [
          for (var i = 0; i < labels.length; i++)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  SizedBox(width: 84, child: Text(labels[i], style: text.bodySmall)),
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(3),
                      child: LinearProgressIndicator(
                        value: top == 0 ? 0 : values[i] / top,
                        minHeight: 10,
                        color: values[i] == top && top > 0 ? scheme.error : scheme.primary,
                        backgroundColor: scheme.surfaceContainerHighest,
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 84,
                    child: Text(money(values[i].roundToDouble()), textAlign: TextAlign.end, style: text.bodySmall),
                  ),
                ],
              ),
            ),
        ],
      );
    }

    final spentChange = a.prevSpent == 0 ? null : (a.spent - a.prevSpent) / a.prevSpent;
    const weekdays = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
    const times = ['Morning', 'Afternoon', 'Evening', 'Late night'];
    final topDay = a.byWeekday.indexOf(a.byWeekday.reduce((x, y) => x > y ? x : y));

    return Scaffold(
      appBar: AppBar(title: const Text('Self analysis')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          Center(
            child: RangeBar(range: _range, onChanged: (r) => setState(() => _range = r)),
          ),
          RangeChips(range: _range, onChanged: (r) => setState(() => _range = r)),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: PaidWithChip(data: data, value: _paidWith, onChanged: (v) => setState(() => _paidWith = v)),
            ),
          ),

          // Goals, week by week
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 8, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text('Goals', style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                ),
                TextButton(
                  onPressed: () => openGoals(context, data),
                  child: Text(data.goals.any((g) => !g.archived) ? 'All goals' : 'Set a goal'),
                ),
              ],
            ),
          ),
          for (final g in data.goals.where((g) => !g.archived)) GoalCard(data: data, goal: g, showWeeks: true),

          // 1. In and out
          section('Money in and out', [
            row('Came in', money(a.received), color: Colors.green.shade700),
            row('Went out', money(a.spent), color: scheme.error),
            row(
              a.saved >= 0 ? 'Kept' : 'Spent more than came in',
              signed(a.saved),
              color: a.saved >= 0 ? Colors.green.shade700 : scheme.error,
              bold: true,
            ),
            if (a.savingsRate case final r?)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  r >= 0.2
                      ? 'You kept ${pct(r)} of what came in. Strong: keep it above 20%.'
                      : r >= 0
                      ? 'You kept ${pct(r)} of what came in. Aim for 20%: that is ${money((a.received * 0.2 - a.saved).clamp(0, double.infinity).roundToDouble())} less spending.'
                      : 'You spent ${pct(-r)} more than came in. Find the biggest change below.',
                  style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
          ], note: 'Transfers between your accounts, friends\' money and investments are left out.'),

          // 2. Against the period before
          section('Against the period before', [
            row('Spent before', money(a.prevSpent)),
            row('Spent now', money(a.spent)),
            if (spentChange != null)
              row(
                spentChange <= 0 ? 'Down' : 'Up',
                '${spentChange <= 0 ? '−' : '+'}${pct(spentChange.abs())}',
                color: spentChange <= 0 ? Colors.green.shade700 : scheme.error,
                bold: true,
              ),
            const SizedBox(height: 8),
            Text('Biggest changes', style: text.titleSmall),
            for (final c in a.changes)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: CategoryAvatar(data.category(c.categoryId), size: 28),
                title: Text(data.category(c.categoryId)?.name ?? 'No category'),
                subtitle: Text('${money(c.before.roundToDouble())} → ${money(c.now.roundToDouble())}'),
                trailing: Text(
                  signed((c.now - c.before).roundToDouble()),
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: c.now > c.before ? scheme.error : Colors.green.shade700,
                  ),
                ),
              ),
          ], note: 'The same number of days just before ${rangeLabel(_range)}.'),

          // 3. Discipline
          section('Discipline', [
            row('Spent per day', money(a.perDay.roundToDouble())),
            row('Days with no spending', '${a.noSpendDays} of ${a.days}'),
            if (a.noSpendStreak > 0)
              row('No-spend streak now', '${a.noSpendStreak} day${a.noSpendStreak == 1 ? '' : 's'}'),
            row(
              'Small payments (under ${money(smallLimit)})',
              '${a.smallCount} · ${money(a.smallTotal.roundToDouble())}',
            ),
            if (a.smallShare >= 0.15)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  'Small payments are ${pct(a.smallShare)} of your spending: chai, snacks, quick buys. They add up.',
                  style: text.bodyMedium?.copyWith(color: scheme.error, fontWeight: FontWeight.w600),
                ),
              ),
          ]),

          // 4. When you spend
          section('When you spend', [
            Text('By day of the week', style: text.titleSmall),
            const SizedBox(height: 4),
            bars(weekdays, a.byWeekday),
            if (a.spent > 0)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text('${weekdays[topDay]} is your biggest spending day.', style: text.bodySmall),
              ),
            const SizedBox(height: 12),
            Text('By time of day', style: text.titleSmall),
            const SizedBox(height: 4),
            if (a.timedCount == 0)
              Text('Needs payments from bank alerts (statements have no time).', style: text.bodySmall)
            else ...[
              bars(times, a.byTimeOfDay),
              if (a.byTimeOfDay[3] > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    'Late night (10 pm – 5 am): ${money(a.byTimeOfDay[3].roundToDouble())}. Late spending is often the '
                    'easiest to cut.',
                    style: text.bodySmall,
                  ),
                ),
            ],
          ], note: 'Morning 5–12, afternoon 12–5, evening 5–10, late night 10–5.'),

          // 5. Regular costs
          section('Regular costs', [
            if (a.recurring.isEmpty) const Text('Nothing paid month after month yet.'),
            for (final r in a.recurring)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: CategoryAvatar(data.category(r.categoryId), size: 28),
                title: Text(r.name),
                subtitle: Text('paid in ${r.months} of the last 6 months'),
                trailing: Text('~${money(r.perMonth.roundToDouble())}/month'),
              ),
          ], note: 'Subscriptions, habits and fixed costs: paid in 3 or more of the last 6 months.'),

          // 6. Where it went
          section('Where most of it went', [
            for (final p in a.topPlaces) row('${p.name} (${p.count}×)', money(p.total.roundToDouble())),
            const SizedBox(height: 8),
            Text('Biggest payments', style: text.titleSmall),
            for (final t in a.biggest)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(t.title),
                subtitle: Text(dayLabel(t.txnAt)),
                trailing: Text(money(data.shareTotalsNow.own(t)), style: const TextStyle(fontWeight: FontWeight.w700)),
                onTap: () => openTxnEditor(context, data, existing: t),
              ),
          ]),
        ],
      ),
    );
  }
}
