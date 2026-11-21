import 'package:material_ui/material_ui.dart';

import 'format.dart';

/// The opening balance stays exactly as you set it. When the entries before it (e.g. one you changed later) add
/// up to something else, this says so, with the difference: nothing changes on its own.
class OpeningDifference extends StatelessWidget {
  const OpeningDifference({super.key, required this.history, required this.opening, required this.person});

  /// What the entries before the opening add up to; [opening] what you set (positive: you owed them).
  final double history;
  final double opening;
  final String person;

  static bool differs(double history, double opening) => (history - opening).abs() >= 0.005;

  @override
  Widget build(BuildContext context) {
    if (!differs(history, opening)) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final first = person.split(' ').first;
    String side(double v) =>
        v.abs() < 0.005 ? 'settled (₹0)' : (v > 0 ? 'you owed ${money(v)}' : '$first owed you ${money(-v)}');
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: scheme.tertiaryContainer, borderRadius: BorderRadius.circular(14)),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.difference_outlined, size: 20, color: scheme.onTertiaryContainer),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Differs by ${money((history - opening).abs())}. The entries before it add up to ${side(history)}; '
              'the opening you set says ${side(opening)}. Your opening stays as you set it.',
              style: text.bodySmall?.copyWith(color: scheme.onTertiaryContainer),
            ),
          ),
        ],
      ),
    );
  }
}
