import 'package:material_ui/material_ui.dart';

import '../logic/summary.dart';
import '../ui/format.dart';

/// "‹  November 2026  ›" – can't go past the current month.
class MonthBar extends StatelessWidget {
  const MonthBar({super.key, required this.month, required this.onChanged});

  final DateTime month;
  final ValueChanged<DateTime> onChanged;

  @override
  Widget build(BuildContext context) {
    final isCurrent = month == monthStart(DateTime.now());
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: 'Previous month',
          icon: const Icon(Icons.chevron_left),
          onPressed: () => onChanged(addMonths(month, -1)),
        ),
        Flexible(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(monthLabel(month), style: Theme.of(context).textTheme.titleMedium),
          ),
        ),
        IconButton(
          tooltip: 'Next month',
          icon: const Icon(Icons.chevron_right),
          onPressed: isCurrent ? null : () => onChanged(addMonths(month, 1)),
        ),
      ],
    );
  }
}
