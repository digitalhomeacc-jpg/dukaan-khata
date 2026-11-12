import 'package:intl/intl.dart';

/// Money helpers. All amounts are integer paise.
class Money {
  static final _fmt0 = NumberFormat.decimalPattern('en_IN');
  static final _fmt2 = NumberFormat('#,##,##0.00', 'en_IN');

  /// 123456700 → "12,34,567" ; 12345 → "123.45"
  static String fmt(int paise, {bool symbol = false, bool abs = false}) {
    final v = abs ? paise.abs() : paise;
    final s = v % 100 == 0 ? _fmt0.format(v ~/ 100) : _fmt2.format(v / 100);
    return symbol ? '₹$s' : s;
  }

  /// "1,500" / "1500.50" / "१५००" → paise. Returns null for invalid input.
  static int? parse(String? input) {
    if (input == null) return null;
    final s = normalizeDigits(input).replaceAll(',', '').replaceAll('₹', '').trim();
    if (s.isEmpty) return null;
    final d = double.tryParse(s);
    if (d == null) return null;
    return (d * 100).round();
  }

  static int fromRupees(num r) => (r * 100).round();
}

const _devanagariDigits = '०१२३४५६७८९';

/// Converts Devanagari (Marathi) digits to ASCII so "१५/२७५" works like "15/275".
String normalizeDigits(String s) {
  final b = StringBuffer();
  for (final ch in s.runes) {
    final c = String.fromCharCode(ch);
    final i = _devanagariDigits.indexOf(c);
    b.write(i >= 0 ? i.toString() : c);
  }
  return b.toString();
}

/// Quantity as typed: up to 3 decimals, never rounded shorter (12.345 ton stays
/// 12.345 – an edited bill must show exactly what was saved).
String fmtQty(double q) {
  if (q == q.roundToDouble()) return q.toInt().toString();
  final s = q.toStringAsFixed(3).replaceFirst(RegExp(r'0+$'), '');
  return s.endsWith('.') ? s.substring(0, s.length - 1) : s;
}

/// Dates are stored as YYYY-MM-DD strings (sortable, timezone-free).
String isoDate(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

String todayIso() => isoDate(DateTime.now());

DateTime parseIso(String s) => DateTime.parse(s);

/// "2026-11-05" → "5/11/26" (as written in the registers)
String shortDate(String iso) {
  final d = parseIso(iso);
  return '${d.day}/${d.month}/${(d.year % 100).toString().padLeft(2, '0')}';
}

/// Shop-wide book settings (loaded from the businesses row at login).
class Books {
  /// First day of the books. Entries before this date are "history":
  /// they show on a customer's khata but never touch cash, sales or stock.
  static String start = '2026-11-08';

  /// Month the financial year starts (4 = April, Indian default).
  static int fyStartMonth = 4;

  static bool isHistory(String iso) => iso.compareTo(start) < 0;
}

/// Financial year start for a date (default 1 April; configurable).
String fyStart(String iso) {
  final d = parseIso(iso);
  final m = Books.fyStartMonth;
  final y = d.month >= m ? d.year : d.year - 1;
  return '$y-${m.toString().padLeft(2, '0')}-01';
}

/// Reads a date typed on the keyboard, Tally-style. Accepts
///   14/9/26  14-9-2026  14.09.26  14 9 26   – day / month / year
///   140926  14092026                         – digits only
///   14/9  1409                               – no year: the latest such date
///                                              not after [latest] (default today)
/// Returns YYYY-MM-DD, or null if it is not a real date.
String? parseTypedDate(String input, {String? latest}) {
  final s = normalizeDigits(input).trim();
  if (s.isEmpty) return null;
  int? d, m, y;
  final parts = s.split(RegExp(r'[/\-. ]+')).where((p) => p.isNotEmpty).toList();
  if (parts.length >= 2 && parts.every((p) => RegExp(r'^\d+$').hasMatch(p))) {
    d = int.parse(parts[0]);
    m = int.parse(parts[1]);
    if (parts.length >= 3) y = int.parse(parts[2]);
  } else if (RegExp(r'^\d+$').hasMatch(s)) {
    switch (s.length) {
      case 4:
        d = int.parse(s.substring(0, 2));
        m = int.parse(s.substring(2, 4));
      case 6:
        d = int.parse(s.substring(0, 2));
        m = int.parse(s.substring(2, 4));
        y = int.parse(s.substring(4, 6));
      case 8:
        d = int.parse(s.substring(0, 2));
        m = int.parse(s.substring(2, 4));
        y = int.parse(s.substring(4, 8));
      default:
        return null;
    }
  } else {
    return null;
  }
  if (m < 1 || m > 12 || d < 1 || d > 31) return null;
  final limit = parseIso(latest ?? todayIso());
  if (y == null) {
    y = limit.year;
    if (DateTime(y, m, d).isAfter(limit)) y -= 1;
  } else if (y < 100) {
    y += 2000;
  }
  final dt = DateTime(y, m, d);
  if (dt.month != m || dt.day != d) return null; // e.g. 31/2
  return isoDate(dt);
}

