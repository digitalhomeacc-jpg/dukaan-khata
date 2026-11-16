import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';

import '../data/app_data.dart';
import '../logic/home.dart';
import '../logic/reports.dart';
import '../logic/summary.dart';
import '../logic/tools.dart';
import '../ui/category_style.dart';
import '../ui/format.dart';
import 'duplicates_screen.dart';
import 'goals_screen.dart';
import 'groups_screen.dart';
import 'quick_add.dart';
import 'recurring_screen.dart';
import 'reports_screen.dart';

Future<void> _push(BuildContext context, AppData data, Widget Function() page) => Navigator.of(context).push(
  MaterialPageRoute<void>(
    builder: (_) => ListenableBuilder(listenable: data, builder: (_, _) => page()),
  ),
);

/// Shared look for the tool pages: a big headline number and sections.
class _Hero extends StatelessWidget {
  const _Hero({required this.label, required this.value, this.note, this.color});

  final String label;
  final String value;
  final String? note;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [scheme.primaryContainer, scheme.tertiaryContainer],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(24),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: text.labelLarge?.copyWith(color: scheme.onPrimaryContainer)),
          const SizedBox(height: 4),
          Text(
            value,
            style: text.displaySmall?.copyWith(fontWeight: FontWeight.w800, color: color ?? scheme.onPrimaryContainer),
          ),
          if (note != null) ...[
            const SizedBox(height: 4),
            Text(note!, style: text.bodyMedium?.copyWith(color: scheme.onPrimaryContainer)),
          ],
        ],
      ),
    );
  }
}

Widget _section(BuildContext context, String title, List<Widget> children, {String? note}) {
  final text = Theme.of(context).textTheme;
  return Card.outlined(
    margin: const EdgeInsets.fromLTRB(16, 6, 16, 6),
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
          if (note != null) Text(note, style: text.bodySmall?.copyWith(color: Theme.of(context).colorScheme.outline)),
          const SizedBox(height: 8),
          ...children,
        ],
      ),
    ),
  );
}

Widget _row(String label, String value, {Color? color, bool bold = false}) => Padding(
  padding: const EdgeInsets.symmetric(vertical: 3),
  child: Row(
    children: [
      Expanded(child: Text(label)),
      Text(
        value,
        style: TextStyle(color: color, fontWeight: bold ? FontWeight.w800 : FontWeight.w600),
      ),
    ],
  ),
);

// =================================================================== hub

/// Every tool, one tap away from Home.
Future<void> openTools(BuildContext context, AppData data) => _push(context, data, () => ToolsScreen(data: data));

class ToolsScreen extends StatelessWidget {
  const ToolsScreen({super.key, required this.data});

  final AppData data;

  @override
  Widget build(BuildContext context) {
    final tools = <(IconData, String, String, VoidCallback)>[
      (Icons.search, 'Search', 'Any amount, name, note, #tag', () => openSearch(context, data)),
      (Icons.calendar_month, 'Month in review', 'Report card and calendar', () => openMonthReview(context, data)),
      (Icons.help_outline, 'Can I afford it?', 'Before you buy', () => openAfford(context, data)),
      (Icons.trending_up, 'Month-end forecast', 'Money left by the 30th', () => openForecast(context, data)),
      (
        Icons.subscriptions_outlined,
        'Subscriptions',
        'Yearly cost, price rises',
        () => openSubscriptions(context, data),
      ),
      (Icons.warning_amber_rounded, 'Unusual spends', 'Far above your usual', () => openUnusual(context, data)),
      (Icons.event_repeat, 'Repeats & dues', 'Rent, bills, EMIs', () => openRecurring(context, data)),
      (Icons.flag_outlined, 'Goals', 'Save up, spend less', () => openGoals(context, data)),
      (Icons.groups_outlined, 'Groups', 'Trips, flat, office', () => editGroup(context, data)),
      (Icons.sell_outlined, 'Tags', '#trip totals', () => openTags(context, data)),
      (
        Icons.content_copy_outlined,
        'Duplicates',
        '${data.duplicates.length} to check',
        () => openDuplicates(context, data),
      ),
      (Icons.summarize_outlined, 'Year & tax', 'Interest, investments, Excel', () => openYear(context, data)),
      (Icons.table_view_outlined, 'Reports', 'Statements, Excel', () => openReports(context, data)),
      (Icons.qr_code_2, 'Your UPI ID', data.upiId ?? 'For "pay me" links', () => editUpiId(context, data)),
    ];
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Tools')),
      body: GridView.builder(
        padding: const EdgeInsets.all(16),
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 220,
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          childAspectRatio: 1.25,
        ),
        itemCount: tools.length,
        itemBuilder: (context, i) {
          final (icon, title, sub, onTap) = tools[i];
          return Card.filled(
            margin: EdgeInsets.zero,
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: onTap,
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    CircleAvatar(
                      backgroundColor: scheme.primary.withValues(alpha: 0.12),
                      child: Icon(icon, color: scheme.primary),
                    ),
                    const Spacer(),
                    Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
                    Text(
                      sub,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

// =================================================================== 1. search

Future<void> openSearch(BuildContext context, AppData data) => _push(context, data, () => SearchScreen(data: data));

class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key, required this.data});

  final AppData data;

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final _q = TextEditingController();

  @override
  Widget build(BuildContext context) {
    final data = widget.data;
    final found = searchTxns(
      data.transactions,
      _q.text,
      categoryName: (id) => data.category(id)?.name,
      accountName: (id) => data.account(id)?.name,
    );
    final out = found.where((t) => t.isDebit).fold(0.0, (v, t) => v + t.amount);
    final into = found.where((t) => !t.isDebit).fold(0.0, (v, t) => v + t.amount);
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _q,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: '800, zomato, #goa, rent…',
            border: InputBorder.none,
            filled: false,
          ),
          onChanged: (_) => setState(() {}),
        ),
        actions: [
          if (_q.text.isNotEmpty) IconButton(icon: const Icon(Icons.close), onPressed: () => setState(_q.clear)),
        ],
      ),
      body: _q.text.trim().isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Text(
                  'Search every payment by amount, name, note, #tag, UPI ID, bank text, category or account. '
                  'Several words narrow it down.',
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : ListView(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                  child: Text(
                    '${found.length} found · out ${money(out)} · in ${money(into)}',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                for (final t in found.take(300)) TxnTileLite(data: data, txn: t),
              ],
            ),
    );
  }
}

// =================================================================== 2. month in review

Future<void> openMonthReview(BuildContext context, AppData data) =>
    _push(context, data, () => MonthReviewScreen(data: data));

class MonthReviewScreen extends StatefulWidget {
  const MonthReviewScreen({super.key, required this.data});

  final AppData data;

  @override
  State<MonthReviewScreen> createState() => _MonthReviewScreenState();
}

class _MonthReviewScreenState extends State<MonthReviewScreen> {
  var _month = DateTime(DateTime.now().year, DateTime.now().month);

  @override
  Widget build(BuildContext context) {
    final data = widget.data;
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final r = monthReview(
      data.transactions,
      _month,
      notSpendingIds: data.notSpendingCategoryIds,
      shares: data.shareTotalsNow,
    );
    final change = r.prevSpent == 0 ? null : (r.spent - r.prevSpent) / r.prevSpent;
    final top = r.byDay.fold(0.0, (m, v) => v > m ? v : m);
    final firstWeekday = DateTime(_month.year, _month.month).weekday; // Monday = 1
    final isNow = _month.year == DateTime.now().year && _month.month == DateTime.now().month;

    return Scaffold(
      appBar: AppBar(
        title: Text(DateFormat('MMMM yyyy').format(_month)),
        actions: [
          IconButton(
            icon: const Icon(Icons.chevron_left),
            onPressed: () => setState(() => _month = DateTime(_month.year, _month.month - 1)),
          ),
          IconButton(
            icon: const Icon(Icons.chevron_right),
            onPressed: isNow ? null : () => setState(() => _month = DateTime(_month.year, _month.month + 1)),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          _Hero(
            label: r.kept >= 0 ? 'Kept this month' : 'Spent more than came in',
            value: money(r.kept.abs().roundToDouble()),
            note:
                'In ${money(r.received.roundToDouble())} · out ${money(r.spent.roundToDouble())}'
                '${change == null ? '' : ' · ${change <= 0 ? '↓' : '↑'}${(change.abs() * 100).round()}% vs last month'}',
          ),
          _section(context, 'Every day', [
            Row(
              children: [
                for (final d in ['M', 'T', 'W', 'T', 'F', 'S', 'S'])
                  Expanded(
                    child: Center(child: Text(d, style: text.labelSmall)),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            GridView.count(
              crossAxisCount: 7,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: 4,
              crossAxisSpacing: 4,
              children: [
                for (var i = 1; i < firstWeekday; i++) const SizedBox.shrink(),
                for (var d = 0; d < r.byDay.length; d++)
                  Tooltip(
                    message: '${d + 1} ${DateFormat('MMM').format(_month)}: ${money(r.byDay[d].roundToDouble())}',
                    child: Container(
                      decoration: BoxDecoration(
                        color: r.byDay[d] < 0.005
                            ? Colors.green.withValues(alpha: 0.18)
                            : scheme.error.withValues(alpha: 0.12 + 0.75 * (r.byDay[d] / (top == 0 ? 1 : top))),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      alignment: Alignment.center,
                      child: Text('${d + 1}', style: text.labelMedium),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Text('${r.noSpendDays} days with no spending. Darker = more spent.', style: text.bodySmall),
          ]),
          _section(context, 'What changed', [
            for (final c in r.changes)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: CategoryAvatar(data.category(c.categoryId), size: 28),
                title: Text(data.category(c.categoryId)?.name ?? 'No category'),
                subtitle: Text('${money(c.before.roundToDouble())} → ${money(c.now.roundToDouble())}'),
                trailing: Text(
                  '${c.now >= c.before ? '+' : '−'}${money((c.now - c.before).abs().roundToDouble())}',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: c.now > c.before ? scheme.error : Colors.green.shade700,
                  ),
                ),
              ),
          ], note: 'Against the month before'),
          _section(context, 'Where it went', [
            for (final e in r.byCategory.take(6))
              _row(data.category(e.key)?.name ?? 'No category', money(e.value.roundToDouble())),
            if (r.biggest != null) ...[
              const Divider(),
              _row('Biggest: ${r.biggest!.title}', money(data.shareTotalsNow.own(r.biggest!)), bold: true),
            ],
          ]),
        ],
      ),
    );
  }
}

// =================================================================== 3. can I afford it

Future<void> openAfford(BuildContext context, AppData data) => _push(context, data, () => AffordScreen(data: data));

class AffordScreen extends StatefulWidget {
  const AffordScreen({super.key, required this.data});

  final AppData data;

  @override
  State<AffordScreen> createState() => _AffordScreenState();
}

class _AffordScreenState extends State<AffordScreen> {
  final _amount = TextEditingController();

  @override
  Widget build(BuildContext context) {
    final data = widget.data;
    final scheme = Theme.of(context).colorScheme;
    final now = DateTime.now();
    final v = double.tryParse(_amount.text.replaceAll(',', '')) ?? 0;
    final budget = data.budgets.where((b) => b.categoryId == null).firstOrNull?.amount;
    final s = homeStats(
      data.transactions,
      now,
      notSpendingIds: data.notSpendingCategoryIds,
      shares: data.shareTotalsNow,
      monthlyBudget: budget,
    );
    final f = _forecastNow(data);
    final endAfter = f.end - v;
    final saveGoals = data.goals.where((g) => !g.archived && g.isSave).toList();
    final verdict = v <= 0
        ? null
        : endAfter < 0
        ? ('Not this month', 'You would end the month ${money((-endAfter).roundToDouble())} short.', scheme.error)
        : (budget != null && s.budgetLeft! - v < 0)
        ? (
            'Over budget',
            'You can pay, but it breaks this month\'s budget by ${money((v - s.budgetLeft!).roundToDouble())}.',
            Colors.orange.shade800,
          )
        : (
            'Yes',
            'You can, and still end the month with about ${money(endAfter.roundToDouble())}.',
            Colors.green.shade700,
          );

    return Scaffold(
      appBar: AppBar(title: const Text('Can I afford it?')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              controller: _amount,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))],
              style: Theme.of(context).textTheme.headlineMedium,
              decoration: const InputDecoration(labelText: 'How much?', prefixText: '₹ '),
              onChanged: (_) => setState(() {}),
            ),
          ),
          if (verdict != null) _Hero(label: verdict.$1, value: money(v), note: verdict.$2, color: verdict.$3),
          if (v > 0) ...[
            _section(context, 'This month', [
              if (budget != null) ...[
                _row('Budget left now', money(s.budgetLeft!.roundToDouble())),
                _row('After this', money((s.budgetLeft! - v).roundToDouble()), bold: true),
                _row(
                  'Per day after this',
                  money(((s.budgetLeft! - v) / s.daysLeftIn(now)).clamp(0, double.infinity).roundToDouble()),
                ),
              ] else
                const Text('Set a monthly budget to see what it does to it.'),
            ]),
            _section(context, 'By the end of the month', [
              _row('Money now (bank, wallet, cash)', money(f.now.roundToDouble())),
              _row('Still due (repeats, EMIs)', '−${money(f.dues.roundToDouble())}'),
              _row('Usual spending, ${f.daysLeft} days', '−${money(f.everyday.roundToDouble())}'),
              _row('This', '−${money(v)}'),
              const Divider(),
              _row('Left', money(endAfter.roundToDouble()), bold: true, color: endAfter < 0 ? scheme.error : null),
            ]),
            if (saveGoals.isNotEmpty)
              _section(context, 'Your goals', [
                for (final g in saveGoals)
                  () {
                    final p = data.progressOf(g);
                    final weeks = (p.daysLeft ?? 0) / 7;
                    return _row(
                      g.name,
                      weeks <= 0 ? 'ends soon' : '+${money((v / weeks).roundToDouble())}/week to stay on track',
                    );
                  }(),
              ]),
          ],
        ],
      ),
    );
  }
}

Forecast _forecastNow(AppData data) {
  final now = DateTime.now();
  final end = DateTime(now.year, now.month + 1);
  final plan = data.recurringPlan;
  var dues = 0.0, incoming = 0.0;
  for (final d in plan.due) {
    if (!d.due.isBefore(end)) continue;
    if (d.recurring.isDebit) {
      dues += d.recurring.amount;
    } else {
      incoming += d.recurring.amount;
    }
  }
  for (final d in upcomingDues(data.loans, data.loanEvents, months: 1)) {
    if (d.date.isBefore(end) && !d.date.isBefore(DateTime(now.year, now.month, now.day))) dues += d.amount;
  }
  return monthEndForecast(
    balanceNow: data.spendableNow,
    dues: dues,
    incoming: incoming,
    txns: data.transactions,
    notSpendingIds: data.notSpendingCategoryIds,
    shares: data.shareTotalsNow,
  );
}

// =================================================================== 7. forecast

Future<void> openForecast(BuildContext context, AppData data) => _push(context, data, () => ForecastScreen(data: data));

class ForecastScreen extends StatelessWidget {
  const ForecastScreen({super.key, required this.data});

  final AppData data;

  @override
  Widget build(BuildContext context) {
    final f = _forecastNow(data);
    final scheme = Theme.of(context).colorScheme;
    final plan = data.recurringPlan;
    final now = DateTime.now();
    final end = DateTime(now.year, now.month + 1);
    return Scaffold(
      appBar: AppBar(title: const Text('Month-end forecast')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          _Hero(
            label: 'Likely left on ${DateFormat('d MMM').format(end.subtract(const Duration(days: 1)))}',
            value: money(f.end.roundToDouble()),
            color: f.end < 0 ? scheme.error : null,
            note: 'Spending about ${money(f.perDay.roundToDouble())} a day, as in the last 30 days',
          ),
          _section(context, 'How', [
            _row('Now in bank, wallets and cash', money(f.now.roundToDouble())),
            _row('Still due', '−${money(f.dues.roundToDouble())}'),
            _row('Coming in', '+${money(f.incoming.roundToDouble())}'),
            _row('Everyday spending, ${f.daysLeft} days', '−${money(f.everyday.roundToDouble())}'),
            const Divider(),
            _row('Left', money(f.end.roundToDouble()), bold: true),
          ], note: 'One-off payments of ₹5,000 or more are left out of "everyday".'),
          _section(context, 'Due before then', [
            for (final d in plan.due.where((d) => d.due.isBefore(end)))
              _row(
                '${d.recurring.name} · ${dueWhen(d.due)}',
                '${d.recurring.isDebit ? '−' : '+'}${money(d.recurring.amount)}',
              ),
            for (final d in upcomingDues(data.loans, data.loanEvents, months: 1))
              if (d.date.isBefore(end) && !d.date.isBefore(DateTime(now.year, now.month, now.day)))
                _row('${d.loan.name} EMI · ${dueWhen(d.date)}', '−${money(d.amount)}'),
            if (plan.due.isEmpty) const Text('Add repeats (rent, bills, salary) to make this exact.'),
          ]),
        ],
      ),
    );
  }
}

// =================================================================== 4. subscriptions

Future<void> openSubscriptions(BuildContext context, AppData data) =>
    _push(context, data, () => SubscriptionsScreen(data: data));

class SubscriptionsScreen extends StatelessWidget {
  const SubscriptionsScreen({super.key, required this.data});

  final AppData data;

  @override
  Widget build(BuildContext context) {
    final subs = findSubscriptions(data.transactions, notSpendingIds: data.notSpendingCategoryIds);
    final active = subs.where((s) => !s.quiet).toList();
    final total = active.fold(0.0, (v, s) => v + s.perYear);
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Subscriptions & regulars')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          _Hero(
            label: 'A year of these',
            value: money(total.roundToDouble()),
            note: '${active.length} paid every month · ${money((total / 12).roundToDouble())} a month',
          ),
          if (subs.isEmpty)
            const Padding(padding: EdgeInsets.all(24), child: Text('Nothing paid month after month yet.')),
          for (final s in subs)
            ListTile(
              leading: CategoryAvatar(data.category(s.categoryId), size: 40),
              title: Text(s.name),
              subtitle: Text(
                [
                  '${s.months} of the last 6 months',
                  'last ${dayLabel(s.last)}',
                  if (s.previousAmount != null) 'was ${money(s.previousAmount!)}',
                  if (s.quiet) 'gone quiet: cancelled?',
                ].join(' · '),
              ),
              trailing: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(money(s.lastAmount), style: const TextStyle(fontWeight: FontWeight.w700)),
                  Text(
                    '${money(s.perYear.roundToDouble())}/yr',
                    style: TextStyle(
                      fontSize: 12,
                      color: s.previousAmount != null && s.previousAmount! < s.lastAmount ? scheme.error : null,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

// =================================================================== 5. unusual spends

Future<void> openUnusual(BuildContext context, AppData data) => _push(context, data, () => UnusualScreen(data: data));

class UnusualScreen extends StatelessWidget {
  const UnusualScreen({super.key, required this.data});

  final AppData data;

  @override
  Widget build(BuildContext context) {
    final list = unusualSpends(data.transactions, recentDays: 30, notSpendingIds: data.notSpendingCategoryIds);
    return Scaffold(
      appBar: AppBar(title: const Text('Unusual spends')),
      body: list.isEmpty
          ? const Center(child: Text('Nothing unusual in the last 30 days.'))
          : ListView(
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Text('Payments far above what you usually pay at the same place: check they are right.'),
                ),
                for (final u in list)
                  Card.outlined(
                    margin: const EdgeInsets.fromLTRB(12, 6, 12, 0),
                    child: Column(
                      children: [
                        TxnTileLite(data: data, txn: u.txn),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                          child: Text(
                            'You usually pay ${money(u.usual)} here: this is ${(u.txn.amount / u.usual).toStringAsFixed(1)}×.',
                            style: TextStyle(color: Theme.of(context).colorScheme.error),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
    );
  }
}

// =================================================================== 9. tags

Future<void> openTags(BuildContext context, AppData data) => _push(context, data, () => TagsScreen(data: data));

class TagsScreen extends StatelessWidget {
  const TagsScreen({super.key, required this.data});

  final AppData data;

  @override
  Widget build(BuildContext context) {
    final tags = tagTotals(data.transactions, shares: data.shareTotalsNow);
    return Scaffold(
      appBar: AppBar(title: const Text('Tags')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              'Write #words in a payment\'s note (#goa, #wedding, #bike) to see totals across categories and months.',
            ),
          ),
          for (final t in tags)
            ListTile(
              leading: const CircleAvatar(child: Icon(Icons.sell_outlined)),
              title: Text('#${t.tag}'),
              subtitle: Text(
                '${t.count} payment${t.count == 1 ? '' : 's'}${t.into > 0 ? ' · in ${money(t.into)}' : ''}',
              ),
              trailing: Text(money(t.out.roundToDouble()), style: const TextStyle(fontWeight: FontWeight.w700)),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => Scaffold(
                    appBar: AppBar(title: Text('#${t.tag}')),
                    body: ListView(
                      children: [
                        for (final x in data.transactions.where((x) => tagsOf(x).contains(t.tag)))
                          TxnTileLite(data: data, txn: x),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// =================================================================== 10. year & tax

Future<void> openYear(BuildContext context, AppData data) => _push(context, data, () => YearScreen(data: data));

class YearScreen extends StatefulWidget {
  const YearScreen({super.key, required this.data});

  final AppData data;

  @override
  State<YearScreen> createState() => _YearScreenState();
}

class _YearScreenState extends State<YearScreen> {
  var _from = financialYearOf(DateTime.now());

  Future<void> _download(YearReview y) async {
    final data = widget.data;
    final csv = toCsv([
      [
        'Year',
        '${DateFormat('MMM yyyy').format(y.from)} – ${DateFormat('MMM yyyy').format(y.to.subtract(const Duration(days: 1)))}',
      ],
      [],
      ['Money in', y.received.toStringAsFixed(2)],
      ['Spent', y.spent.toStringAsFixed(2)],
      ['Bank interest earned', y.interest.toStringAsFixed(2)],
      ['Put into investments', y.invested.toStringAsFixed(2)],
      [],
      ['Month', 'In', 'Out'],
      for (final m in y.byMonth)
        [DateFormat('MMM yyyy').format(m.month), m.received.toStringAsFixed(2), m.spent.toStringAsFixed(2)],
      [],
      ['Category', 'Spent'],
      for (final c in y.byCategory) [data.category(c.key)?.name ?? 'No category', c.value.toStringAsFixed(2)],
    ]);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await FilePicker.saveFile(
        fileName: 'year_${y.from.year}-${y.from.year + 1}.csv',
        bytes: Uint8List.fromList(utf8.encode(csv)),
        mimeType: 'text/csv',
      );
      messenger.showSnackBar(const SnackBar(content: Text('Saved: open it in Excel or Google Sheets')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Could not save: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = widget.data;
    final y = yearReview(
      data.transactions,
      _from,
      notSpendingIds: data.notSpendingCategoryIds,
      investmentIds: data.investmentCategoryIds,
      shares: data.shareTotalsNow,
    );
    final top = y.byMonth.fold(0.0, (m, x) => x.spent > m ? x.spent : m);
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text('FY ${_from.year}–${(_from.year + 1) % 100}'),
        actions: [
          IconButton(
            icon: const Icon(Icons.chevron_left),
            onPressed: () => setState(() => _from = DateTime(_from.year - 1, 4)),
          ),
          IconButton(
            icon: const Icon(Icons.chevron_right),
            onPressed: _from.year >= DateTime.now().year
                ? null
                : () => setState(() => _from = DateTime(_from.year + 1, 4)),
          ),
          IconButton(tooltip: 'Download for Excel', icon: const Icon(Icons.download), onPressed: () => _download(y)),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          _Hero(
            label: 'Kept this year',
            value: money((y.received - y.spent).roundToDouble()),
            note: 'In ${money(y.received.roundToDouble())} · out ${money(y.spent.roundToDouble())}',
          ),
          _section(context, 'For your tax return', [
            _row('Savings bank interest earned', money(y.interest)),
            _row('Put into investments', money(y.invested)),
          ], note: 'Interest is from payments named "interest"; check it against your bank\'s certificate.'),
          _section(context, 'Month by month', [
            SizedBox(
              height: 120,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  for (final m in y.byMonth)
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 2),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            Container(
                              height: top == 0 ? 2 : (90 * m.spent / top).clamp(2, 90).toDouble(),
                              decoration: BoxDecoration(color: scheme.primary, borderRadius: BorderRadius.circular(4)),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              DateFormat('MMM').format(m.month).substring(0, 1),
                              style: const TextStyle(fontSize: 11),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ]),
          _section(context, 'By category', [
            for (final c in y.byCategory.take(12))
              _row(data.category(c.key)?.name ?? 'No category', money(c.value.roundToDouble())),
          ]),
          _section(context, 'Most paid to', [for (final p in y.topPlaces) _row(p.key, money(p.value.roundToDouble()))]),
        ],
      ),
    );
  }
}

// =================================================================== 6. UPI ID

Future<void> editUpiId(BuildContext context, AppData data) async {
  final c = TextEditingController(text: data.upiId ?? '');
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Your UPI ID'),
      content: TextField(
        controller: c,
        autofocus: true,
        decoration: const InputDecoration(
          hintText: 'name@okhdfcbank',
          helperText: 'Reminders to friends get a tap-to-pay link',
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
      ],
    ),
  );
  if (ok != true || !context.mounted) return;
  final messenger = ScaffoldMessenger.of(context);
  try {
    await data.setUpiId(c.text);
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('Not saved: the database needs the 0041 update ($e)')));
  }
}

/// "upi://pay?…" for a friend to pay you this amount in one tap.
String? upiPayLink(AppData data, double amount, {String note = 'Settle up'}) {
  final id = data.upiId;
  if (id == null || amount <= 0) return null;
  final q = {
    'pa': id,
    'pn': data.displayName,
    'am': amount.toStringAsFixed(2),
    'cu': 'INR',
    'tn': note,
  }.entries.map((e) => '${e.key}=${Uri.encodeComponent(e.value)}').join('&');
  return 'upi://pay?$q';
}
