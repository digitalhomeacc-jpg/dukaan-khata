import 'package:intl/intl.dart';

final _inr = NumberFormat.currency(locale: 'en_IN', symbol: '₹', decimalDigits: 2);
final _inrShort = NumberFormat.currency(locale: 'en_IN', symbol: '₹', decimalDigits: 0);

/// ₹1,23,456.50 – drops the paise when they are zero.
String money(double v) => v == v.roundToDouble() ? _inrShort.format(v) : _inr.format(v);

String signedMoney(double v, {required bool isDebit}) => '${isDebit ? '−' : '+'}${money(v)}';

String monthLabel(DateTime m) => DateFormat('MMMM yyyy').format(m);
String shortMonth(DateTime m) => DateFormat('MMM').format(m);

String dayLabel(DateTime d) {
  final today = DateTime.now();
  final t = DateTime(today.year, today.month, today.day);
  final diff = t.difference(DateTime(d.year, d.month, d.day)).inDays;
  if (diff == 0) return 'Today';
  if (diff == 1) return 'Yesterday';
  return DateFormat(d.year == today.year ? 'EEE, d MMM' : 'EEE, d MMM yyyy').format(d);
}

String timeLabel(DateTime d) => DateFormat('h:mm a').format(d);

String ago(DateTime d) {
  final s = DateTime.now().difference(d);
  if (s.inMinutes < 1) return 'just now';
  if (s.inMinutes < 60) return '${s.inMinutes} min ago';
  if (s.inHours < 24) return '${s.inHours} h ago';
  return '${s.inDays} days ago';
}

/// The day, with the time when there is one ("Sat, 15 Nov, 9:12 PM"; just the day for a day-only date).
String momentLabel(DateTime d) =>
    d.hour == 0 && d.minute == 0 && d.second == 0 ? dayLabel(d) : '${dayLabel(d)}, ${timeLabel(d)}';
