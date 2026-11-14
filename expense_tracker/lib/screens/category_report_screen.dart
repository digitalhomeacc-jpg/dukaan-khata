import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';

import '../data/app_data.dart';
import '../logic/summary.dart';
import '../models.dart';
import '../ui/category_style.dart';
import '../ui/format.dart';
import '../ui/paid_with.dart';
import '../ui/range.dart';
import '../ui/selection.dart';
import 'txn_editor.dart';

enum _Mode { spent, received, net }

/// The longest range a report covers.
const _maxDays = 731;

Future<void> openCategoryReport(
  BuildContext context,
  AppData data, {
  DateTimeRange? range,
  PaidWith paidWith = const PaidWith.all(),
}) => Navigator.of(context).push(
  MaterialPageRoute<void>(
    builder: (_) => ListenableBuilder(
      listenable: data,
      builder: (_, _) => CategoryReportScreen(data: data, initial: range, paidWith: paidWith),
    ),
  ),
);

/// Spending (or money received) by category over any range up to two years.
class CategoryReportScreen extends StatefulWidget {
  const CategoryReportScreen({super.key, required this.data, this.initial, this.paidWith = const PaidWith.all()});

  final AppData data;
  final DateTimeRange? initial;
  final PaidWith paidWith;

  @override
  State<CategoryReportScreen> createState() => _CategoryReportScreenState();
}

class _CategoryReportScreenState extends State<CategoryReportScreen> {
  late DateTimeRange _range = widget.initial == null || widget.initial!.start.year <= 2015
      ? rangePresets().first.range
      : widget.initial!;

  /// What the list shows: money out, money in, or in minus out.
  var _mode = _Mode.spent;
  late var _paidWith = widget.paidWith;

  AppData get data => widget.data;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final txns = _paidWith.isAll ? data.transactions : data.transactions.where(_paidWith.keep).toList();
    List<CategoryLine> report(bool debits) => categoryReport(
      txns,
      _range.start,
      _range.end,
      debits: debits,
      notSpendingIds: data.notSpendingCategoryIds,
      shares: data.shareTotalsNow,
    );
    final out = report(true), into = report(false);
    final spent = out.fold(0.0, (s, l) => s + l.total), received = into.fold(0.0, (s, l) => s + l.total);
    final net = <String?, CategoryLine>{};
    for (final l in [...out, ...into]) {
      final n = net.putIfAbsent(l.id, () => CategoryLine(l.id));
      n.total += out.contains(l) ? -l.total : l.total;
      n.txns.addAll(l.txns);
    }
    final lines = switch (_mode) {
      _Mode.spent => out,
      _Mode.received => into,
      _Mode.net => net.values.toList()..sort((a, b) => b.total.abs().compareTo(a.total.abs())),
    };
    final total = lines.fold(0.0, (s, l) => s + l.total.abs());
    final months = (_range.end.difference(_range.start).inDays / 30.44).clamp(1, 1000);
    final byId = {for (final l in lines) l.id: l};
    final groups = rollUp([for (final l in lines) MapEntry(l.id, l.total)], data.parentOf)
      ..sort((a, b) => b.total.abs().compareTo(a.total.abs()));
    String shown(double v) => _mode == _Mode.net ? '${v > 0 ? '+' : (v < 0 ? '−' : '')}${money(v.abs())}' : money(v);
    Color? tint(double v) =>
        _mode != _Mode.net || v.abs() < 0.005 ? null : (v > 0 ? Colors.green.shade700 : scheme.error);

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
      // Money out and in, so the ledger's balance is the category's net. A payment split across these
      // categories counts once, with the amount that falls in them.
      final amounts = <String, double>{};
      final byId = <String, Txn>{};
      for (final l in [...out, ...into]) {
        if (!ids.contains(l.id)) continue;
        for (final t in l.txns) {
          byId[t.id] = t;
          amounts[t.id] = (amounts[t.id] ?? 0) + (l.amounts[t.id] ?? 0);
        }
      }
      final txns = byId.values.toList()..sort((a, b) => b.txnAt.compareTo(a.txnAt));
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ListenableBuilder(
            listenable: data,
            builder: (_, _) => _CategoryTxnsScreen(
              data: data,
              amounts: amounts,
              title: title,
              subtitle: rangeLabel(_range),
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
            child: RangeChips(
              range: _range,
              onChanged: (r) => setState(() => _range = r),
              withAll: false,
              withTwoYears: true,
              maxDays: _maxDays,
              scroll: false,
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
            child: Align(
              alignment: Alignment.centerLeft,
              child: PaidWithChip(data: data, value: _paidWith, onChanged: (v) => setState(() => _paidWith = v)),
            ),
          ),
          Container(
            margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(color: scheme.primaryContainer, borderRadius: BorderRadius.circular(20)),
            child: Column(
              children: [
                Text(rangeLabel(_range), style: text.labelLarge),
                const SizedBox(height: 12),
                Row(
                  children: [
                    stat('Spent', money(spent), color: scheme.error),
                    stat('Received', money(received), color: Colors.green.shade700),
                    stat(
                      'Net',
                      '${received - spent < 0 ? '−' : '+'}${money((received - spent).abs())}',
                      color: received >= spent ? Colors.green.shade700 : scheme.error,
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text('Spent ${money((spent / months).roundToDouble())} a month on average', style: text.bodySmall),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: SegmentedButton<_Mode>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: _Mode.spent, label: Text('Spent'), icon: Icon(Icons.arrow_upward, size: 18)),
                ButtonSegment(
                  value: _Mode.received,
                  label: Text('Received'),
                  icon: Icon(Icons.arrow_downward, size: 18),
                ),
                ButtonSegment(value: _Mode.net, label: Text('Net'), icon: Icon(Icons.swap_vert, size: 18)),
              ],
              selected: {_mode},
              onSelectionChanged: (s) => setState(() => _mode = s.first),
            ),
          ),
          if (_mode == _Mode.net)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
              child: Text(
                'Money in minus money out for each category: + means more came back than went out.',
                style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
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
              total: shown(g.total),
              color: tint(g.total),
              share: total == 0 ? 0 : g.total.abs() / total,
              count: [
                byId[g.id]?.count ?? 0,
                for (final c in g.children) byId[c.key]?.count ?? 0,
              ].fold(0, (a, b) => a + b),
              perMonth: g.total.abs() / months,
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
                      Text(shown(c.value), style: text.bodyMedium?.copyWith(color: tint(c.value))),
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
    this.color,
    required this.share,
    required this.count,
    required this.perMonth,
    required this.onTap,
  });

  final Category? cat;
  final String total;
  final Color? color;
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
                      Text(
                        total,
                        style: text.titleSmall?.copyWith(fontWeight: FontWeight.w700, color: color),
                      ),
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
  const _CategoryTxnsScreen({
    required this.data,
    required this.title,
    required this.subtitle,
    required this.txns,
    this.amounts = const {},
  });

  final AppData data;

  /// How much of each payment is in this category (part of it when the payment is split).
  final Map<String, double> amounts;
  final String title;
  final String subtitle;
  final List<Txn> txns;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final shares = data.shareTotalsNow;
    // Oldest first gives the running balance; shown newest first.
    final ledger = placeLedger(txns, shares: shares, amounts: amounts);
    final out = ledger.fold(0.0, (s, l) => s + l.out), into = ledger.fold(0.0, (s, l) => s + l.into);
    final net = into - out;
    final byMonth = <DateTime, ({double out, double into})>{};
    for (final l in ledger) {
      final m = DateTime(l.txn.txnAt.year, l.txn.txnAt.month);
      final p = byMonth[m] ?? (out: 0.0, into: 0.0);
      byMonth[m] = (out: p.out + l.out, into: p.into + l.into);
    }
    final months = byMonth.entries.toList()..sort((a, b) => b.key.compareTo(a.key));
    final top = months.fold(0.0, (m, e) => [m, e.value.out, e.value.into].reduce((a, b) => a > b ? a : b));
    String signed(double v) => '${v < 0 ? '−' : (v > 0 ? '+' : '')}${money(v.abs())}';

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

    Widget head(String label, {double width = 74}) => SizedBox(
      width: width,
      child: Text(label, textAlign: TextAlign.end, style: text.labelSmall),
    );

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
        body: CustomScrollView(
          slivers: [
            SliverList.list(
              children: [
                Container(
                  margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(color: scheme.primaryContainer, borderRadius: BorderRadius.circular(20)),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          stat('Money out', money(out), color: scheme.error),
                          stat('Money in', money(into), color: Colors.green.shade700),
                          stat('Net', signed(net), color: net >= 0 ? Colors.green.shade700 : scheme.error),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text('${txns.length} payments', style: text.bodySmall),
                    ],
                  ),
                ),
                if (months.length > 1)
                  for (final m in months)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 3),
                      child: Row(
                        children: [
                          SizedBox(width: 56, child: Text(DateFormat('MMM yy').format(m.key), style: text.bodySmall)),
                          Expanded(
                            child: Column(
                              children: [
                                if (m.value.out > 0)
                                  LinearProgressIndicator(
                                    value: top == 0 ? 0 : m.value.out / top,
                                    minHeight: 6,
                                    color: scheme.error,
                                    backgroundColor: Colors.transparent,
                                  ),
                                if (m.value.into > 0)
                                  LinearProgressIndicator(
                                    value: top == 0 ? 0 : m.value.into / top,
                                    minHeight: 6,
                                    color: Colors.green.shade700,
                                    backgroundColor: Colors.transparent,
                                  ),
                              ],
                            ),
                          ),
                          SizedBox(
                            width: 92,
                            child: Text(
                              signed((m.value.into - m.value.out).roundToDouble()),
                              textAlign: TextAlign.end,
                              style: text.bodySmall,
                            ),
                          ),
                        ],
                      ),
                    ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                  child: Row(
                    children: [
                      Expanded(child: Text('Ledger', style: text.titleSmall)),
                      head('You paid'),
                      head('You got'),
                      head('Balance', width: 86),
                    ],
                  ),
                ),
                const Divider(indent: 16, endIndent: 16),
              ],
            ),
            SliverList.builder(
              itemCount: ledger.length,
              itemBuilder: (context, i) {
                final l = ledger[i];
                final sel = TxnSelection.maybeOf(context);
                final picked = sel?.ids.contains(l.txn.id) ?? false;
                final cat = data.category(l.txn.categoryId);
                return InkWell(
                  onTap: () =>
                      sel?.active == true ? sel!.toggle(l.txn.id) : openTxnEditor(context, data, existing: l.txn),
                  onLongPress: sel == null ? null : () => sel.toggle(l.txn.id),
                  child: Container(
                    color: picked ? scheme.primaryContainer.withValues(alpha: 0.4) : null,
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    child: Row(
                      children: [
                        if (sel?.active == true) SelectTick(selected: picked),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(l.txn.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: text.bodyMedium),
                              Text(
                                [DateFormat('d MMM yy').format(l.txn.txnAt), if (cat != null) cat.name].join(' · '),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                              ),
                            ],
                          ),
                        ),
                        SizedBox(
                          width: 74,
                          child: Text(
                            l.out > 0 ? money(l.out) : '',
                            textAlign: TextAlign.end,
                            style: TextStyle(color: scheme.error, fontWeight: FontWeight.w600),
                          ),
                        ),
                        SizedBox(
                          width: 74,
                          child: Text(
                            l.into > 0 ? money(l.into) : '',
                            textAlign: TextAlign.end,
                            style: TextStyle(color: Colors.green.shade700, fontWeight: FontWeight.w600),
                          ),
                        ),
                        SizedBox(
                          width: 86,
                          child: Text(
                            signed(l.net),
                            textAlign: TextAlign.end,
                            style: text.bodySmall?.copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 40)),
          ],
        ),
      ),
    );
  }
}
