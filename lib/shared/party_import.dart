import '../accounting/models.dart';
import '../core/money.dart';

/// One customer / supplier read from the opening-balance sheet.
class PartyRow {
  final int line; // row number in the sheet (1 = header)
  final String name; // Marathi name, or the English one when Marathi is empty
  final String? nameEn;
  final String? pageNo;
  final String? phone;
  final int balance; // paise; + = they owe us (येणे), − = advance / we owe (देणे)
  final LedgerGroup group;
  PartyRow(this.line, this.name, this.nameEn, this.pageNo, this.phone, this.balance, this.group);
}

class PartySheet {
  final List<PartyRow> rows;
  final List<String> skipped; // "Row 5: no name"
  PartySheet(this.rows, this.skipped);
}

/// Reads the opening-balance sheet (Excel / CSV / Google Sheets download).
///
/// * Columns are found by their header (name, page_no, phone, balance,
///   name_en, type – in any order; Marathi headers work too). Without a
///   header row the template order is assumed.
/// * `name` may be left empty when `name_en` is filled (type Marathi later).
/// * Balance: a plain amount means the person owes us (येणे). An amount in
///   brackets `(65,000)`, with a minus `-65000`, or marked `Cr` / `जमा` /
///   `advance` is money they have given in advance – we owe them (देणे).
///   For suppliers it is the other way round: a plain amount is what we owe.
class PartyImport {
  static const _headers = {
    'name': ['name', 'नाव', 'marathi', 'मराठी नाव', 'party'],
    'name_en': ['name_en', 'name en', 'english', 'english name', 'इंग्रजी'],
    'page_no': ['page_no', 'page', 'page no', 'पान'],
    'phone': ['phone', 'mobile', 'फोन', 'मोबाईल'],
    'balance': ['balance', 'amount', 'baki', 'बाकी', 'रक्कम', 'opening'],
    'type': ['type', 'group', 'प्रकार'],
  };

  static PartySheet parse(List<List<String>> table) {
    // find the header row (first row that names at least two known columns)
    var headerAt = -1;
    final cols = <String, int>{};
    for (var r = 0; r < table.length && r < 10; r++) {
      final found = <String, int>{};
      for (var c = 0; c < table[r].length; c++) {
        final h = table[r][c].trim().toLowerCase();
        if (h.isEmpty) continue;
        for (final e in _headers.entries) {
          if (found.containsKey(e.key)) continue;
          // exact match first so "name" does not grab the "name_en" column
          if (e.value.contains(h) || (h.length > 3 && e.value.any((w) => w.length > 3 && h.startsWith(w)))) {
            if (e.key == 'name' && (h.contains('en') || h.contains('english'))) continue;
            found[e.key] = c;
            break;
          }
        }
      }
      if (found.length >= 2) {
        headerAt = r;
        cols.addAll(found);
        break;
      }
    }
    if (headerAt < 0) {
      cols.addAll({'name': 0, 'page_no': 1, 'phone': 2, 'balance': 3, 'name_en': 4, 'type': 5});
    }

    final rows = <PartyRow>[];
    final skipped = <String>[];
    for (var r = headerAt + 1; r < table.length; r++) {
      final row = table[r];
      String cell(String key) {
        final c = cols[key];
        return c == null || c >= row.length ? '' : row[c].trim();
      }

      if (row.every((c) => c.trim().isEmpty)) continue;
      final mr = cell('name');
      final en = cell('name_en');
      final name = mr.isNotEmpty ? mr : en;
      if (name.isEmpty) {
        skipped.add('${r + 1}');
        continue;
      }
      final t = cell('type').toLowerCase();
      final group = t.startsWith('s') || t.contains('पुरवठा') || t.contains('supplier')
          ? LedgerGroup.supplier
          : t.startsWith('tr') || t.contains('ट्रान्स')
          ? LedgerGroup.transporter
          : LedgerGroup.customer;
      var bal = parseBalance(cell('balance'));
      // for suppliers / transporters a plain amount is what we owe them
      if (group != LedgerGroup.customer) bal = -bal;
      rows.add(PartyRow(
        r + 1,
        name,
        mr.isNotEmpty && en.isNotEmpty ? en : (mr.isEmpty ? en : null),
        _wholeNumber(cell('page_no')),
        _phone(cell('phone')),
        bal,
        group,
      ));
    }
    return PartySheet(rows, skipped);
  }

  /// "1,23,456.50" → 12345650; "(65,000.00)", "-65000", "65000 Cr", "65000 जमा" → negative.
  static int parseBalance(String raw) {
    var s = normalizeDigits(raw).trim().toLowerCase();
    if (s.isEmpty) return 0;
    var negative = false;
    if (s.startsWith('(') && s.endsWith(')')) {
      negative = true;
      s = s.substring(1, s.length - 1);
    }
    for (final w in ['cr', 'जमा', 'advance', 'adv', 'jama']) {
      if (s.endsWith(w)) {
        negative = true;
        s = s.substring(0, s.length - w.length);
      }
    }
    for (final w in ['dr', 'येणे', 'baki', 'बाकी']) {
      if (s.endsWith(w)) s = s.substring(0, s.length - w.length);
    }
    s = s.replaceAll(RegExp(r'[^0-9.\-]'), '');
    if (s.startsWith('-')) {
      negative = true; // a minus always means advance
      s = s.substring(1);
    }
    final v = double.tryParse(s);
    if (v == null) return 0;
    final p = (v * 100).round();
    return negative ? -p : p;
  }

  /// Excel turns 12 into "12.0" and big numbers into "8.010923291E9".
  static String? _wholeNumber(String s) {
    if (s.isEmpty) return null;
    final d = double.tryParse(s);
    if (d != null && d == d.roundToDouble()) return d.toInt().toString();
    return s;
  }

  static String? _phone(String s) {
    final w = _wholeNumber(s);
    if (w == null) return null;
    final digits = w.replaceAll(RegExp(r'[^0-9+]'), '');
    return digits.isEmpty ? null : digits;
  }
}
