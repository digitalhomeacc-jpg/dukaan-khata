import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';

import '../data/app_data.dart';
import '../logic/home.dart';
import '../logic/recurring.dart';
import '../logic/summary.dart';
import '../ui/format.dart';
import 'budgets_screen.dart';
import 'duplicates_screen.dart';
import 'goals_screen.dart';
import 'quick_add.dart';
import 'quick_sort_screen.dart';
import 'recurring_screen.dart';
import 'transactions_screen.dart';
import 'tools_screens.dart';

Future<void> openAllPayments(BuildContext context, AppData data) => Navigator.of(context).push(
  MaterialPageRoute<void>(
    builder: (_) => ListenableBuilder(
      listenable: data,
      builder: (context, _) => Scaffold(
        body: TransactionsScreen(data: data),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: () => openAddSheet(context, data),
          icon: const Icon(Icons.add),
          label: const Text('Add'),
        ),
      ),
    ),
  ),
);

/// Home: only what matters today. Today, the week and the month; budget and streak; what needs you; the next
/// dues; shortcuts; the latest payments. Everything else is one tap away (Tools, All payments).
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key, required this.data, this.onOpenTab, this.now});

  final AppData data;

  /// Switches the bottom tab (Friends for answers waiting).
  final ValueChanged<int>? onOpenTab;

  /// Tests set the time.
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final at = now ?? DateTime.now();
    final today = DateTime(at.year, at.month, at.day);
    final total = data.budgets.where((b) => b.categoryId == null).firstOrNull;
    final s = homeStats(
      data.transactions,
      at,
      notSpendingIds: data.notSpendingCategoryIds,
      shares: data.shareTotalsNow,
      monthlyBudget: total?.amount,
    );
    final plan = data.recurringPlan;
    final soon = plan.due.where((d) => d.due.difference(today).inDays <= 7).toList();
    final loanDues = upcomingDues(
      data.loans,
      data.loanEvents,
      months: 1,
      now: at,
    ).where((d) => d.date.difference(at).inDays <= 7 && !d.date.isBefore(today)).toList();
    final toSort = data.transactions.where((t) => t.categoryId == null && !t.excluded && !t.isLoanTransfer).length;
    final waiting = data.waitingForMe.length + data.openingsWaitingForMe.length;
    final late = plan.due.where((d) => d.state == DueState.overdue).length;
    final dupes = data.duplicates.length;
    final goals = data.goals.where((g) => !g.archived).toList();
    final onTrack = goals.where((g) => data.progressOf(g).onTrack).length;
    final recent = data.transactions.take(3).toList();
    final name = data.displayName.split(RegExp(r'[\s@]')).first;
    final hello = at.hour < 12 ? 'Good morning' : (at.hour < 17 ? 'Good afternoon' : 'Good evening');
    final weekDiff = s.week - s.lastWeekSoFar;
    final topDay = s.last7.fold(0.0, (m, d) => d.spent > m ? d.spent : m);

    final needs = <(IconData, String, Color?, VoidCallback)>[
      if (waiting > 0) (Icons.how_to_reg_outlined, '$waiting waiting for your OK', null, () => onOpenTab?.call(2)),
      if (late > 0)
        (Icons.event_busy_outlined, '$late due, not seen yet', scheme.error, () => openRecurring(context, data)),
      if (dupes > 0)
        (
          Icons.content_copy_outlined,
          '$dupes possible duplicate${dupes == 1 ? '' : 's'}',
          null,
          () => openDuplicates(context, data),
        ),
      if (toSort > 0) (Icons.label_outline, '$toSort without a category', null, () => openQuickSort(context, data)),
    ];

    Widget header(String title, {String? action, VoidCallback? onAction}) => Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 8, 6),
      child: Row(
        children: [
          Expanded(
            child: Text(title, style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
          ),
          if (action != null) TextButton(onPressed: onAction, child: Text(action)),
        ],
      ),
    );

    Widget stat(String label, double v, {String? note, Color? noteColor}) => Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: text.labelMedium?.copyWith(color: scheme.onPrimary.withValues(alpha: 0.8))),
          Text(
            money(v.roundToDouble()),
            style: text.titleLarge?.copyWith(fontWeight: FontWeight.w800, color: scheme.onPrimary),
          ),
          if (note != null) Text(note, style: text.labelSmall?.copyWith(color: noteColor ?? scheme.onPrimary)),
        ],
      ),
    );

    final shortcuts = <(IconData, String, VoidCallback)>[
      (Icons.search, 'Search', () => openSearch(context, data)),
      (Icons.calendar_month, 'This month', () => openMonthReview(context, data)),
      (Icons.trending_up, 'Forecast', () => openForecast(context, data)),
      (Icons.help_outline, 'Afford it?', () => openAfford(context, data)),
      (Icons.flag_outlined, 'Goals', () => openGoals(context, data)),
      (Icons.apps, 'All tools', () => openTools(context, data)),
    ];

    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.only(bottom: 100),
          children: [
            // Greeting
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 8, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          DateFormat('EEEE, d MMMM').format(at),
                          style: text.labelLarge?.copyWith(color: scheme.outline),
                        ),
                        Text(name.isEmpty ? hello : '$hello, $name', style: text.headlineSmall),
                      ],
                    ),
                  ),
                  IconButton.filledTonal(
                    tooltip: 'Search',
                    icon: const Icon(Icons.search),
                    onPressed: () => openSearch(context, data),
                  ),
                  const SizedBox(width: 4),
                  IconButton.filledTonal(
                    tooltip: 'All payments',
                    icon: const Icon(Icons.receipt_long_outlined),
                    onPressed: () => openAllPayments(context, data),
                  ),
                ],
              ),
            ),

            // Today, week, month
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: () => openMonthReview(context, data),
                  borderRadius: BorderRadius.circular(28),
                  child: Ink(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [scheme.primary, Color.lerp(scheme.primary, scheme.tertiary, 0.55)!],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      borderRadius: BorderRadius.circular(28),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Spent today',
                          style: text.labelLarge?.copyWith(color: scheme.onPrimary.withValues(alpha: 0.85)),
                        ),
                        Text(money(s.today), style: text.displaySmall?.copyWith(color: scheme.onPrimary)),
                        const SizedBox(height: 14),
                        Row(
                          children: [
                            stat(
                              'This week',
                              s.week,
                              note: s.lastWeekSoFar == 0 && s.week == 0
                                  ? null
                                  : weekDiff.abs() < 1
                                  ? 'same as last week'
                                  : '${weekDiff > 0 ? '▲' : '▼'} ${money(weekDiff.abs().roundToDouble())} vs last week',
                            ),
                            stat(
                              DateFormat('MMMM').format(at),
                              s.month,
                              note: 'in ${money(s.monthReceived.roundToDouble())}',
                            ),
                          ],
                        ),
                        const SizedBox(height: 14),
                        SizedBox(
                          height: 56,
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              for (final d in s.last7)
                                Expanded(
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(horizontal: 4),
                                    child: Column(
                                      mainAxisAlignment: MainAxisAlignment.end,
                                      children: [
                                        Container(
                                          height: topDay <= 0 ? 4 : (34 * d.spent / topDay).clamp(4, 34).toDouble(),
                                          decoration: BoxDecoration(
                                            color: s.dailyLimit != null && d.spent > s.dailyLimit!
                                                ? Colors.orangeAccent
                                                : scheme.onPrimary.withValues(alpha: 0.85),
                                            borderRadius: BorderRadius.circular(6),
                                          ),
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          DateFormat('E').format(d.day).substring(0, 1),
                                          style: text.labelSmall?.copyWith(
                                            color: scheme.onPrimary.withValues(alpha: 0.8),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),

            // Budget and streak
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: _Tile(
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => ListenableBuilder(
                              listenable: data,
                              builder: (_, _) => BudgetsScreen(data: data),
                            ),
                          ),
                        ),
                        child: s.budget == null
                            ? Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text('Budget', style: text.labelMedium),
                                  Text('Set one', style: text.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
                                  Text('See what is left each day', style: text.labelSmall),
                                ],
                              )
                            : Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(s.budgetLeft! >= 0 ? 'Budget left' : 'Over budget', style: text.labelMedium),
                                  Text(
                                    money(s.budgetLeft!.abs().roundToDouble()),
                                    style: text.titleLarge?.copyWith(
                                      fontWeight: FontWeight.w800,
                                      color: s.budgetLeft! < 0 ? scheme.error : null,
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  ClipRRect(
                                    borderRadius: BorderRadius.circular(6),
                                    child: LinearProgressIndicator(
                                      value: (s.month / s.budget!).clamp(0, 1).toDouble(),
                                      minHeight: 6,
                                      color: s.month > s.budget! ? scheme.error : null,
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    '${money(s.perDayLeft(at)!.roundToDouble())}/day · ${s.daysLeftIn(at)} days',
                                    style: text.labelSmall,
                                  ),
                                ],
                              ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _Tile(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Streak', style: text.labelMedium),
                            Text(
                              '${s.streak > 0 ? '🔥 ' : ''}${s.streak} day${s.streak == 1 ? '' : 's'}',
                              style: text.titleLarge?.copyWith(fontWeight: FontWeight.w800),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              s.streakIsNoSpend
                                  ? 'with no spending'
                                  : 'within ${money(s.dailyLimit!.roundToDouble())} a day',
                              style: text.labelSmall,
                            ),
                            Text(
                              s.streakIsNoSpend
                                  ? (s.today > 0 ? 'Tomorrow is a fresh start' : 'Keep today at zero')
                                  : (s.today <= s.dailyLimit!
                                        ? '${money((s.dailyLimit! - s.today).roundToDouble())} left today'
                                        : 'Over today: start again tomorrow'),
                              style: text.labelSmall?.copyWith(color: scheme.outline),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),

            // What needs you
            if (needs.isNotEmpty) ...[
              header('Needs you'),
              Card(
                child: Column(
                  children: [
                    for (final (i, (icon, label, color, onTap)) in needs.indexed) ...[
                      if (i > 0) const Divider(indent: 56),
                      ListTile(
                        leading: Icon(icon, color: color ?? scheme.primary),
                        title: Text(
                          label,
                          style: TextStyle(color: color, fontWeight: FontWeight.w600),
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: onTap,
                      ),
                    ],
                  ],
                ),
              ),
            ],

            // Shortcuts
            const SizedBox(height: 8),
            SizedBox(
              height: 92,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                children: [
                  for (final (icon, label, onTap) in shortcuts)
                    Padding(
                      padding: const EdgeInsets.only(right: 10),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(18),
                        onTap: onTap,
                        child: SizedBox(
                          width: 76,
                          child: Column(
                            children: [
                              const SizedBox(height: 6),
                              Container(
                                width: 52,
                                height: 52,
                                decoration: BoxDecoration(
                                  color: scheme.secondaryContainer,
                                  borderRadius: BorderRadius.circular(18),
                                ),
                                child: Icon(icon, color: scheme.onSecondaryContainer),
                              ),
                              const SizedBox(height: 6),
                              Text(label, style: text.labelSmall, maxLines: 1, overflow: TextOverflow.ellipsis),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),

            // Coming up
            header('Coming up', action: 'Repeats and dues', onAction: () => openRecurring(context, data)),
            if (soon.isEmpty && loanDues.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Text(
                  data.recurring.isEmpty
                      ? 'Add rent, bills and subscriptions to see them coming.'
                      : 'Nothing due in the next 7 days.',
                  style: text.bodyMedium?.copyWith(color: scheme.outline),
                ),
              )
            else
              Card(
                child: Column(
                  children: [
                    for (final d in soon.take(3)) DueTile(data: data, item: d, dense: true),
                    for (final d in loanDues.take(2))
                      ListTile(
                        dense: true,
                        leading: const CircleAvatar(radius: 16, child: Icon(Icons.account_balance_outlined, size: 18)),
                        title: Text('${d.loan.name} EMI'),
                        subtitle: Text(dueWhen(d.date, now: at)),
                        trailing: Text(
                          '${d.estimate ? '~' : ''}${money(d.amount)}',
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ),
                  ],
                ),
              ),

            // Goals in one line
            if (goals.isNotEmpty)
              Card(
                margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: ListTile(
                  leading: const Icon(Icons.flag_outlined),
                  title: Text('${goals.length} goal${goals.length == 1 ? '' : 's'} · $onTrack on track'),
                  subtitle: Text(
                    goals.map((g) => g.name).take(3).join(', '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => openGoals(context, data),
                ),
              ),

            // Latest
            header('Latest', action: 'All payments', onAction: () => openAllPayments(context, data)),
            Card(
              child: Column(
                children: [for (final t in recent) TxnTileLite(data: data, txn: t)],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({required this.child, this.onTap});

  final Widget child;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Card(
    margin: EdgeInsets.zero,
    child: InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: onTap,
      child: Padding(padding: const EdgeInsets.all(14), child: child),
    ),
  );
}
