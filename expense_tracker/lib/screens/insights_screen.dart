import 'package:material_ui/material_ui.dart';

import '../data/app_data.dart';
import '../logic/summary.dart';
import '../ui/category_style.dart';
import '../ui/format.dart';
import 'month_bar.dart';

class InsightsScreen extends StatefulWidget {
  const InsightsScreen({super.key, required this.data});

  final AppData data;

  @override
  State<InsightsScreen> createState() => _InsightsScreenState();
}

class _InsightsScreenState extends State<InsightsScreen> {
  var _month = monthStart(DateTime.now());

  @override
  Widget build(BuildContext context) {
    final data = widget.data;
    final s = summarize(data.transactions, _month);
    final trend = monthlySpend(data.transactions, _month, 6);
    final text = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(title: MonthBar(month: _month, onChanged: (m) => setState(() => _month = m)), centerTitle: true),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
        children: [
          Text('Last 6 months', style: text.titleMedium),
          const SizedBox(height: 12),
          _TrendChart(points: trend, selected: _month, onTap: (m) => setState(() => _month = m)),
          const SizedBox(height: 28),
          Row(
            children: [
              Expanded(child: Text('Where the money went', style: text.titleMedium)),
              Text(money(s.spent), style: text.titleMedium),
            ],
          ),
          const SizedBox(height: 8),
          if (s.byCategory.isEmpty)
            const Padding(padding: EdgeInsets.symmetric(vertical: 24), child: Center(child: Text('No spending this month.'))),
          for (final e in s.byCategory)
            _ShareRow(
              leading: CategoryAvatar(data.category(e.key), size: 32),
              label: data.category(e.key)?.name ?? 'No category',
              value: e.value,
              total: s.spent,
              color: colorFor(data.category(e.key)),
            ),
          if (s.byMerchant.isNotEmpty) ...[
            const SizedBox(height: 28),
            Text('Top places', style: text.titleMedium),
            const SizedBox(height: 8),
            for (final e in s.byMerchant.take(8))
              ListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: Text(e.key, maxLines: 1, overflow: TextOverflow.ellipsis),
                trailing: Text(money(e.value), style: text.bodyLarge),
              ),
          ],
        ],
      ),
    );
  }
}

class _ShareRow extends StatelessWidget {
  const _ShareRow({required this.leading, required this.label, required this.value, required this.total, required this.color});

  final Widget leading;
  final String label;
  final double value;
  final double total;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final share = total == 0 ? 0.0 : value / total;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          leading,
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis)),
                    Text('${money(value)}  ·  ${(share * 100).round()}%'),
                  ],
                ),
                const SizedBox(height: 6),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: share,
                    minHeight: 8,
                    color: color,
                    backgroundColor: color.withValues(alpha: 0.12),
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

class _TrendChart extends StatelessWidget {
  const _TrendChart({required this.points, required this.selected, required this.onTap});

  final List<MapEntry<DateTime, double>> points;
  final DateTime selected;
  final ValueChanged<DateTime> onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final max = points.fold(0.0, (m, p) => p.value > m ? p.value : m);
    return SizedBox(
      height: 160,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (final p in points)
            Expanded(
              child: InkWell(
                onTap: () => onTap(p.key),
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Column(
                    children: [
                      FittedBox(child: Text(p.value == 0 ? '' : _compact(p.value), style: const TextStyle(fontSize: 11))),
                      const SizedBox(height: 4),
                      Expanded(
                        child: Align(
                          alignment: Alignment.bottomCenter,
                          child: FractionallySizedBox(
                            heightFactor: max == 0 ? 0.02 : (p.value / max).clamp(0.02, 1.0),
                            child: Container(
                              decoration: BoxDecoration(
                                color: p.key == selected ? scheme.primary : scheme.primary.withValues(alpha: 0.3),
                                borderRadius: BorderRadius.circular(6),
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(shortMonth(p.key),
                          style: TextStyle(fontWeight: p.key == selected ? FontWeight.bold : FontWeight.normal)),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  static String _compact(double v) {
    if (v >= 100000) return '₹${(v / 100000).toStringAsFixed(1)}L';
    if (v >= 1000) return '₹${(v / 1000).toStringAsFixed(1)}k';
    return '₹${v.round()}';
  }
}
