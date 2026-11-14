import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';

import '../data/app_data.dart';
import '../logic/summary.dart';
import '../models.dart';
import '../ui/category_style.dart';
import '../ui/format.dart';
import '../ui/selection.dart';
import 'transactions_screen.dart';

/// The longest range a report covers.
const _maxDays = 731;

Future<void> openCategoryReport(BuildContext context, AppData data, {DateTimeRange? range}) =>
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ListenableBuilder(
          listenable: data,
          builder: (_, _) => CategoryReportScreen(data: data, initial: range),
        ),
      ),
    );

/// Spending (or money received) by category over any range up to two years.
class CategoryReportScreen extends StatefulWidget {
  const CategoryReportScreen({super.key, required this.data, this.initial});

  final AppData data;
  final DateTimeRange? initial;

  @override
  State<CategoryReportScreen> createState() => _CategoryReportScreenState();
}

/// Days from [start] up to (not including) [end].
DateTimeRange _days(DateTime start, DateTime end) =>
    DateTimeRange(start: DateTime(start.year, start.month, start.day), end: DateTime(end.year, end.month, end.day));

class _CategoryReportScreenState extends State<CategoryReportScreen> {
  late DateTimeRange _range = widget.initial ?? _presets().first.range;
  var _spent = true;

  AppData get data => widget.data;

  /// Ranges end the day after their last day, so a day is "in" when start <= t < end.
  List<({String label, DateTimeRange range})> _presets() {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final tomorrow = today.add(const Duration(days: 1));
    final fyStart = DateTime(now.month >= 4 ? now.year : now.year - 1, 4, 1);
    return [
      (label: 'This month', range: _days(DateTime(now.year, now.month), tomorrow)),
      (label: 'Last month', range: _days(DateTime(now.year, now.month - 1), DateTime(now.year, now.month))),
      (label: '3 months', range: _days(DateTime(now.year, now.month - 2), tomorrow)),
      (label: '6 months', range: _days(DateTime(now.year, now.month - 5), tomorrow)),
      (label: '12 months', range: _days(DateTime(now.year, now.month - 11), tomorrow)),
      (label: 'This FY', range: _days(fyStart, tomorrow)),
      (label: 'Last FY', range: _days(DateTime(fyStart.year - 1, 4, 1), fyStart)),
      (label: '2 years', range: _days(today.subtract(const Duration(days: _maxDays - 1)), tomorrow)),
    ];
  }

  Future<void> _custom() async {
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2015),
      lastDate: now,
      initialDateRange: DateTimeRange(
        start: _range.start,
        end: _range.end.subtract(const Duration(days: 1)).isAfter(now)
            ? now
            : _range.end.subtract(const Duration(days: 1)),
      ),
      helpText: 'Up to 2 years',
    );
    if (picked == null || !mounted) return;
    var start = picked.start;
    final end = picked.end.add(const Duration(days: 1));
    if (end.difference(start).inDays > _maxDays) {
      start = end.subtract(const Duration(days: _maxDays));
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Reports cover up to 2 years: from ${dayLabel(start)}')));
    }
    setState(() => _range = _days(start, end));
  }

  String _rangeLabel(DateTimeRange r) {
    final last = r.end.subtract(const Duration(days: 1));
    final f = DateFormat(r.start.year == last.year ? 'd MMM' : 'd MMM yy');
    return '${f.format(r.start)} – ${DateFormat('d MMM yy').format(last)}';
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    List<CategoryLine> report(bool debits) => categoryReport(
      data.transactions,
      _range.start,
      _range.end,
      debits: debits,
      notSpendingIds: data.notSpendingCategoryIds,
      shares: data.shareTotalsNow,
    );
    final out = report(true), into = report(false);
    final spent = out.fold(0.0, (s, l) => s + l.total), received = into.fold(0.0, (s, l) => s + l.total);
    final lines = _spent ? out : into;
    final total = _spent ? spent : received;
    final months = (_range.end.difference(_range.start).inDays / 30.44).clamp(1, 1000);
    final byId = {for (final l in lines) l.id: l};
    final groups = rollUp([for (final l in lines) MapEntry(l.id, l.total)], data.parentOf);
    final presets = _presets();
    final presetLabel = presets.where((p) => p.range == _range).firstOrNull?.label;

    Widget stat(String label, String value, {Color? color}) => Expanded(
      child: Column(
        children: [
          FittedBox(
            child: Text(
              value,
              style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700, color: color),
            ),
          ),
          Text(label, style: text.bodySmall),
        ],
      ),
    );

    void openLine(String? id, String title) {
      // A group includes its details' payments.
      final ids = {
        id,
        for (final c in data.categories)
          if (c.parentId == id && id != null) c.id,
      };
      final txns = [
        for (final l in lines)
          if (ids.contains(l.id)) ...l.txns,
      ]..sort((a, b) => b.txnAt.compareTo(a.txnAt));
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ListenableBuilder(
            listenable: data,
            builder: (_, _) => _CategoryTxnsScreen(
              data: data,
              title: title,
              subtitle: _rangeLabel(_range),
              txns: [
                for (final t in txns)
                  if (data.txn(t.id) != null) data.txn(t.id)!,
              ],
            ),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Categories')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final p in presets)
                  ChoiceChip(
                    label: Text(p.label),
                    selected: p.range == _range,
                    onSelected: (_) => setState(() => _range = p.range),
                  ),
                ActionChip(
                  avatar: const Icon(Icons.date_range, size: 18),
                  label: Text(presetLabel == null ? _rangeLabel(_range) : 'Custom range'),
                  onPressed: _custom,
                ),
              ],
            ),
          ),
          Container(
            margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(color: scheme.primaryContainer, borderRadius: BorderRadius.circular(20)),
            child: Column(
              children: [
                Text(_rangeLabel(_range), style: text.labelLarge),
                const SizedBox(height: 12),
                Row(
                  children: [
                    stat('Spent', money(spent), color: scheme.error),
                    stat('Received', money(received), color: Colors.green.shade700),
                    stat('Per month', money((spent / months).roundToDouble())),
                  ],
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: SegmentedButton<bool>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: true, label: Text('Spent'), icon: Icon(Icons.arrow_upward, size: 18)),
                ButtonSegment(value: false, label: Text('Received'), icon: Icon(Icons.arrow_downward, size: 18)),
              ],
              selected: {_spent},
              onSelectionChanged: (s) => setState(() => _spent = s.first),
            ),
          ),
          if (lines.isEmpty)
            const Padding(
              padding: EdgeInsets.all(32),
              child: Center(child: Text('Nothing in this range.')),
            ),
          for (final g in groups) ...[
            _Line(
              cat: data.category(g.id),
              total: g.total,
              share: total == 0 ? 0 : g.total / total,
              count: [
                byId[g.id]?.count ?? 0,
                for (final c in g.children) byId[c.key]?.count ?? 0,
              ].fold(0, (a, b) => a + b),
              perMonth: g.total / months,
              onTap: () => openLine(g.id, data.category(g.id)?.name ?? 'No category'),
            ),
            for (final c in g.children)
              InkWell(
                onTap: () => openLine(c.key, data.category(c.key)?.name ?? '?'),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(72, 2, 16, 8),
                  child: Row(
                    children: [
                      Expanded(child: Text(data.category(c.key)?.name ?? '?', style: text.bodyMedium)),
                      Text(
                        '${byId[c.key]?.count ?? 0}× · ',
                        style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                      Text(money(c.value), style: text.bodyMedium),
                      const Icon(Icons.chevron_right, size: 18),
                    ],
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

class _Line extends StatelessWidget {
  const _Line({
    required this.cat,
    required this.total,
    required this.share,
    required this.count,
    required this.perMonth,
    required this.onTap,
  });

  final Category? cat;
  final double total;
  final double share;
  final int count;
  final double perMonth;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
        child: Row(
          children: [
            CategoryAvatar(cat, size: 40),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          cat?.name ?? 'No category',
                          style: text.titleSmall,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Text(money(total), style: text.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                    ],
                  ),
                  const SizedBox(height: 4),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: share.clamp(0, 1).toDouble(),
                      minHeight: 6,
                      color: colorFor(cat),
                      backgroundColor: colorFor(cat).withValues(alpha: 0.15),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${(share * 100).toStringAsFixed(share < 0.01 && share > 0 ? 1 : 0)}% · $count payments · '
                    '${money(perMonth.roundToDouble())}/month',
                    style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right),
          ],
        ),
      ),
    );
  }
}

/// Every payment of one category in the range, with its month-by-month totals.
class _CategoryTxnsScreen extends StatelessWidget {
  const _CategoryTxnsScreen({required this.data, required this.title, required this.subtitle, required this.txns});

  final AppData data;
  final String title;
  final String subtitle;
  final List<Txn> txns;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final shares = data.shareTotalsNow;
    final byMonth = <DateTime, double>{};
    for (final t in txns) {
      final m = DateTime(t.txnAt.year, t.txnAt.month);
      byMonth[m] = (byMonth[m] ?? 0) + shares.own(t);
    }
    final months = byMonth.entries.toList()..sort((a, b) => b.key.compareTo(a.key));
    final top = months.fold(0.0, (m, e) => e.value > m ? e.value : m);
    final total = txns.fold(0.0, (s, t) => s + shares.own(t));
    return SelectionHost(
      data: data,
      builder: (context, bar) => Scaffold(
        appBar:
            bar(txns.map((t) => t.id)) ??
            AppBar(
              title: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title),
                  Text(subtitle, style: text.bodySmall),
                ],
              ),
            ),
        body: ListView(
          padding: const EdgeInsets.only(bottom: 32),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Text('${money(total)} · ${txns.length} payments', style: text.titleMedium),
            ),
            if (months.length > 1)
              for (final m in months)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 3),
                  child: Row(
                    children: [
                      SizedBox(width: 64, child: Text(DateFormat('MMM yy').format(m.key), style: text.bodySmall)),
                      Expanded(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(3),
                          child: LinearProgressIndicator(value: top == 0 ? 0 : m.value / top, minHeight: 8),
                        ),
                      ),
                      SizedBox(
                        width: 84,
                        child: Text(money(m.value.roundToDouble()), textAlign: TextAlign.end, style: text.bodySmall),
                      ),
                    ],
                  ),
                ),
            const Divider(height: 24),
            for (final t in txns) TxnTile(txn: t, data: data),
          ],
        ),
      ),
    );
  }
}
