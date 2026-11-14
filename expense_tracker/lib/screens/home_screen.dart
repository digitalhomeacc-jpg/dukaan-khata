import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';

import '../data/app_data.dart';
import '../logic/home.dart';
import '../logic/recurring.dart';
import '../logic/summary.dart';
import '../ui/category_style.dart';
import '../ui/format.dart';
import 'budgets_screen.dart';
import 'goals_screen.dart';
import 'quick_add.dart';
import 'quick_sort_screen.dart';
import 'recurring_screen.dart';
import 'transactions_screen.dart';
import 'txn_editor.dart';

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

/// Home: today and this week at a glance, budget left, streak, what is due, one-tap entries, goals, latest
/// payments. Every number opens the list behind it.
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
    final total = data.budgets.where((b) => b.categoryId == null).firstOrNull;
    final s = homeStats(
      data.transactions,
      at,
      notSpendingIds: data.notSpendingCategoryIds,
      shares: data.shareTotalsNow,
      monthlyBudget: total?.amount,
    );
    final plan = data.recurringPlan;
    final soon = plan.due.where((d) => d.due.difference(DateTime(at.year, at.month, at.day)).inDays <= 7).toList();
    final loanDues = upcomingDues(
      data.loans,
      data.loanEvents,
      months: 1,
      now: at,
    ).where((d) => d.date.difference(at).inDays <= 7 && !d.date.isBefore(DateTime(at.year, at.month, at.day))).toList();
    final frequent = frequentEntries(data.transactions).take(6).toList();
    final toSort = data.transactions.where((t) => t.categoryId == null && !t.excluded && !t.isLoanTransfer).length;
    final waiting = data.waitingForMe.length;
    final late = plan.due.where((d) => d.state == DueState.overdue).length;
    final goals = data.goals.where((g) => !g.archived).toList();
    final recent = data.transactions.take(6).toList();
    final name = data.displayName.split(RegExp(r'[\s@]')).first;
    final hello = at.hour < 12 ? 'Good morning' : (at.hour < 17 ? 'Good afternoon' : 'Good evening');
    final weekDiff = s.week - s.lastWeekSoFar;

    Widget section(String title, {String? action, VoidCallback? onAction}) => Padding(
      padding: const EdgeInsets.fromLTRB(16, 18, 8, 4),
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
          Text(label, style: text.labelMedium?.copyWith(color: scheme.onPrimaryContainer)),
          Text(
            money(v.roundToDouble()),
            style: text.titleLarge?.copyWith(fontWeight: FontWeight.w800, color: scheme.onPrimaryContainer),
          ),
          if (note != null) Text(note, style: text.labelSmall?.copyWith(color: noteColor)),
        ],
      ),
    );

    final topDay = s.last7.fold(0.0, (m, d) => d.spent > m ? d.spent : m);

    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.only(bottom: 96),
          children: [
            // Greeting
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          name.isEmpty ? hello : '$hello, $name',
                          style: text.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        Text(DateFormat('EEEE, d MMMM').format(at), style: text.bodyMedium),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'All payments',
                    icon: const Icon(Icons.receipt_long_outlined),
                    onPressed: () => openAllPayments(context, data),
                  ),
                ],
              ),
            ),

            // Today, week, month
            InkWell(
              onTap: () => openAllPayments(context, data),
              borderRadius: BorderRadius.circular(24),
              child: Container(
                margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(color: scheme.primaryContainer, borderRadius: BorderRadius.circular(24)),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Spent today', style: text.labelLarge?.copyWith(color: scheme.onPrimaryContainer)),
                    Text(
                      money(s.today),
                      style: text.displaySmall?.copyWith(fontWeight: FontWeight.w800, color: scheme.onPrimaryContainer),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        stat(
                          'This week',
                          s.week,
                          note: s.lastWeekSoFar == 0 && s.week == 0
                              ? null
                              : weekDiff.abs() < 1
                              ? 'same as last week'
                              : '${money(weekDiff.abs().roundToDouble())} ${weekDiff > 0 ? 'more' : 'less'} than last week',
                          noteColor: weekDiff > 0 ? scheme.error : Colors.green.shade800,
                        ),
                        stat(
                          DateFormat('MMMM').format(at),
                          s.month,
                          note: 'in ${money(s.monthReceived.roundToDouble())}',
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    // The last 7 days
                    SizedBox(
                      height: 54,
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          for (final d in s.last7)
                            Expanded(
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 3),
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.end,
                                  children: [
                                    Container(
                                      height: topDay <= 0 ? 3 : (30 * d.spent / topDay).clamp(3, 30).toDouble(),
                                      decoration: BoxDecoration(
                                        color: s.dailyLimit != null && d.spent > s.dailyLimit!
                                            ? scheme.error
                                            : scheme.primary,
                                        borderRadius: BorderRadius.circular(3),
                                      ),
                                    ),
                                    const SizedBox(height: 3),
                                    Text(
                                      DateFormat('E').format(d.day).substring(0, 1),
                                      style: text.labelSmall?.copyWith(color: scheme.onPrimaryContainer),
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

            // Budget left and streak
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Card.outlined(
                      margin: EdgeInsets.zero,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => ListenableBuilder(
                              listenable: data,
                              builder: (_, _) => BudgetsScreen(data: data),
                            ),
                          ),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: s.budget == null
                              ? Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text('Budget', style: text.labelMedium),
                                    Text('Set one', style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                                    Text('See what is left each day', style: text.labelSmall),
                                  ],
                                )
                              : Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(s.budgetLeft! >= 0 ? 'Budget left' : 'Over budget', style: text.labelMedium),
                                    Text(
                                      money(s.budgetLeft!.abs().roundToDouble()),
                                      style: text.titleMedium?.copyWith(
                                        fontWeight: FontWeight.w800,
                                        color: s.budgetLeft! < 0 ? scheme.error : null,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    ClipRRect(
                                      borderRadius: BorderRadius.circular(4),
                                      child: LinearProgressIndicator(
                                        value: (s.month / s.budget!).clamp(0, 1).toDouble(),
                                        minHeight: 6,
                                        color: s.month > s.budget! ? scheme.error : null,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      '${money(s.perDayLeft(at)!.roundToDouble())}/day for ${s.daysLeftIn(at)} days',
                                      style: text.labelSmall,
                                    ),
                                  ],
                                ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Card.outlined(
                      margin: EdgeInsets.zero,
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Streak', style: text.labelMedium),
                            Text(
                              '${s.streak > 0 ? '🔥 ' : ''}${s.streak} day${s.streak == 1 ? '' : 's'}',
                              style: text.titleMedium?.copyWith(fontWeight: FontWeight.w800),
                            ),
                            const SizedBox(height: 4),
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
                              style: text.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),

            // Things that need you
            if (waiting > 0 || toSort > 0 || late > 0)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    if (waiting > 0)
                      ActionChip(
                        avatar: const Icon(Icons.people_outline, size: 18),
                        label: Text('$waiting waiting for your OK'),
                        onPressed: () => onOpenTab?.call(2),
                      ),
                    if (late > 0)
                      ActionChip(
                        avatar: Icon(Icons.event_busy_outlined, size: 18, color: scheme.error),
                        label: Text('$late due, not seen yet'),
                        onPressed: () => openRecurring(context, data),
                      ),
                    if (toSort > 0)
                      ActionChip(
                        avatar: const Icon(Icons.sort, size: 18),
                        label: Text('$toSort to sort'),
                        onPressed: () => openQuickSort(context, data),
                      ),
                  ],
                ),
              ),

            // Quick entry
            section('Add'),
            SizedBox(
              height: 44,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                children: [
                  FilledButton.icon(
                    onPressed: () => openTxnEditor(context, data),
                    icon: const Icon(Icons.arrow_upward, size: 18),
                    label: const Text('Spent'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.tonalIcon(
                    onPressed: () => openAddSheet(context, data),
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('More'),
                  ),
                  for (final f in frequent) ...[
                    const SizedBox(width: 8),
                    ActionChip(
                      avatar: CategoryAvatar(data.category(f.categoryId), size: 22),
                      label: Text(
                        '${money(f.amount)} ${data.category(f.categoryId)?.name ?? f.usualPayee ?? ''}'.trim(),
                      ),
                      onPressed: () => addLike(context, data, f),
                    ),
                  ],
                ],
              ),
            ),

            // Due soon
            section('Coming up', action: 'Repeats and dues', onAction: () => openRecurring(context, data)),
            if (soon.isEmpty && loanDues.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  data.recurring.isEmpty
                      ? 'Add rent, bills and subscriptions to see them coming and never pay late.'
                      : 'Nothing due in the next 7 days.',
                  style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ),
            for (final d in soon.take(5)) DueTile(data: data, item: d, dense: true),
            for (final d in loanDues.take(3))
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

            // Goals
            section(
              'Goals',
              action: goals.isEmpty ? 'Set a goal' : 'All goals',
              onAction: () => openGoals(context, data),
            ),
            if (goals.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  'Save for something by a date, or spend less on something: progress updates by itself.',
                  style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ),
            for (final g in goals.take(3))
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: GoalCard(data: data, goal: g, compact: true),
              ),

            // Latest
            section('Latest', action: 'All payments', onAction: () => openAllPayments(context, data)),
            for (final t in recent) TxnTileLite(data: data, txn: t),
          ],
        ),
      ),
    );
  }
}
