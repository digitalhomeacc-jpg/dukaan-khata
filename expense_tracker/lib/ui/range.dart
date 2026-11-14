import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';

/// A date range: [DateTimeRange.start] up to (not including) [DateTimeRange.end], whole days.
DateTimeRange dayRange(DateTime start, DateTime end) =>
    DateTimeRange(start: DateTime(start.year, start.month, start.day), end: DateTime(end.year, end.month, end.day));

DateTimeRange monthRange(DateTime m) => dayRange(DateTime(m.year, m.month), DateTime(m.year, m.month + 1));

/// Everything: from the first day the app could hold up to today.
DateTimeRange allTimeRange() {
  final now = DateTime.now();
  return dayRange(DateTime(2015), DateTime(now.year, now.month, now.day + 1));
}

bool inRange(DateTime t, DateTimeRange r) => !t.isBefore(r.start) && t.isBefore(r.end);

/// Quick ranges, newest-first thinking: this month, last month, 3/6/12 months, financial years, all time.
List<({String label, DateTimeRange range})> rangePresets({bool withAll = true, bool withTwoYears = false}) {
  final now = DateTime.now();
  final tomorrow = DateTime(now.year, now.month, now.day + 1);
  // Whole months, so the arrows step a month (or three) at a time.
  final nextMonth = DateTime(now.year, now.month + 1);
  final fy = DateTime(now.month >= 4 ? now.year : now.year - 1, 4, 1);
  return [
    (label: 'This month', range: dayRange(DateTime(now.year, now.month), nextMonth)),
    (label: 'Last month', range: dayRange(DateTime(now.year, now.month - 1), DateTime(now.year, now.month))),
    (label: '3 months', range: dayRange(DateTime(now.year, now.month - 2), nextMonth)),
    (label: '6 months', range: dayRange(DateTime(now.year, now.month - 5), nextMonth)),
    (label: '12 months', range: dayRange(DateTime(now.year, now.month - 11), nextMonth)),
    (label: 'This FY', range: dayRange(fy, DateTime(fy.year + 1, 4, 1))),
    (label: 'Last FY', range: dayRange(DateTime(fy.year - 1, 4, 1), fy)),
    if (withTwoYears) (label: '2 years', range: dayRange(DateTime(now.year - 2, now.month, now.day + 1), tomorrow)),
    if (withAll) (label: 'All time', range: allTimeRange()),
  ];
}

/// "1 Nov – 14 Nov 26", "November 2026", "All time".
String rangeLabel(DateTimeRange r) {
  if (r.start.year <= 2015) return 'All time';
  final last = r.end.subtract(const Duration(days: 1));
  if (r.start.day == 1 && r.end.day == 1 && r.end == DateTime(r.start.year, r.start.month + 1)) {
    return DateFormat('MMMM yyyy').format(r.start);
  }
  final f = DateFormat(r.start.year == last.year ? 'd MMM' : 'd MMM yy');
  return '${f.format(r.start)} – ${DateFormat('d MMM yy').format(last)}';
}

/// The same length of time just before or after [r] (whole months move by months).
DateTimeRange shiftRange(DateTimeRange r, int dir) {
  final wholeMonths = r.start.day == 1 && r.end.day == 1;
  if (wholeMonths) {
    final months = (r.end.year - r.start.year) * 12 + r.end.month - r.start.month;
    return dayRange(
      DateTime(r.start.year, r.start.month + dir * months),
      DateTime(r.end.year, r.end.month + dir * months),
    );
  }
  final days = r.end.difference(r.start).inDays;
  return dayRange(r.start.add(Duration(days: dir * days)), r.end.add(Duration(days: dir * days)));
}

/// Quick buttons for a date range, plus a custom one. Wraps onto more lines; set [scroll] to keep one line.
class RangeChips extends StatelessWidget {
  const RangeChips({
    super.key,
    required this.range,
    required this.onChanged,
    this.withAll = true,
    this.withTwoYears = false,
    this.maxDays,
    this.scroll = true,
  });

  final DateTimeRange range;
  final ValueChanged<DateTimeRange> onChanged;
  final bool withAll;
  final bool withTwoYears;

  /// Longest custom range allowed (e.g. two years for reports).
  final int? maxDays;
  final bool scroll;

  Future<void> _custom(BuildContext context) async {
    final now = DateTime.now();
    final lastDay = range.end.subtract(const Duration(days: 1));
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2015),
      lastDate: now,
      initialDateRange: DateTimeRange(
        start: range.start.year <= 2015 ? DateTime(now.year, now.month) : range.start,
        end: lastDay.isAfter(now) ? now : lastDay,
      ),
      helpText: maxDays == null ? 'Pick dates' : 'Up to ${(maxDays! / 365).round()} years',
    );
    if (picked == null || !context.mounted) return;
    var start = picked.start;
    final end = picked.end.add(const Duration(days: 1));
    if (maxDays != null && end.difference(start).inDays > maxDays!) {
      start = end.subtract(Duration(days: maxDays!));
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Up to ${(maxDays! / 365).round()} years: from ${DateFormat('d MMM yy').format(start)}'),
        ),
      );
    }
    onChanged(dayRange(start, end));
  }

  @override
  Widget build(BuildContext context) {
    final presets = rangePresets(withAll: withAll, withTwoYears: withTwoYears);
    final isPreset = presets.any((p) => p.range == range);
    final chips = [
      for (final p in presets)
        ChoiceChip(label: Text(p.label), selected: p.range == range, onSelected: (_) => onChanged(p.range)),
      ActionChip(
        avatar: const Icon(Icons.date_range, size: 18),
        label: Text(isPreset ? 'Custom' : rangeLabel(range)),
        side: isPreset ? null : BorderSide(color: Theme.of(context).colorScheme.primary),
        onPressed: () => _custom(context),
      ),
    ];
    if (!scroll) return Wrap(spacing: 6, runSpacing: 6, children: chips);
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [for (final c in chips) Padding(padding: const EdgeInsets.only(right: 6), child: c)],
      ),
    );
  }
}

/// "‹  November 2026  ›" for any range: the arrows move by the range's own length.
class RangeBar extends StatelessWidget {
  const RangeBar({super.key, required this.range, required this.onChanged});

  final DateTimeRange range;
  final ValueChanged<DateTimeRange> onChanged;

  @override
  Widget build(BuildContext context) {
    final all = range.start.year <= 2015;
    final next = shiftRange(range, 1);
    final canNext = !all && !next.start.isAfter(DateTime.now());
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: 'Earlier',
          icon: const Icon(Icons.chevron_left),
          onPressed: all ? null : () => onChanged(shiftRange(range, -1)),
        ),
        Flexible(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(rangeLabel(range), style: Theme.of(context).textTheme.titleMedium),
          ),
        ),
        IconButton(
          tooltip: 'Later',
          icon: const Icon(Icons.chevron_right),
          onPressed: canNext ? () => onChanged(next) : null,
        ),
      ],
    );
  }
}
