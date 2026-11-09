import 'dart:convert';
import 'dart:typed_data';

import 'package:excel/excel.dart' as xl;

import '../core/money.dart';
import 'xlsx_reader.dart';

/// One transaction from a bank statement.
class StatementLine {
  final String date; // YYYY-MM-DD
  final String description;
  final String ref;
  final int debit; // money out of the bank (paise)
  final int credit; // money into the bank (paise)
  final int? balance;
  StatementLine(this.date, this.description, this.ref, this.debit, this.credit, this.balance);
  @override
  String toString() => 'StatementLine($date, $description, -$debit +$credit, bal $balance)';
}

class StatementFormatException implements Exception {
  final String message;
  StatementFormatException(this.message);
  @override
  String toString() => message;
}

/// Reads bank statements downloaded from net-banking: CSV, XLSX, and the
/// ".xls" files many Indian banks produce (which are really HTML tables).
/// Finds the header row by its words (Date / Narration / Withdrawal / Deposit /
/// Balance, or Amount + Dr/Cr) so it works for SBI, HDFC, ICICI, Axis, BoI, co-op banks…
class StatementParser {
  static List<StatementLine> parse(Uint8List bytes, String fileName) => parseRows(rowsFromBytes(bytes, fileName));

  static List<List<String>> rowsFromBytes(Uint8List bytes, String fileName) {
    final lower = fileName.toLowerCase();
    final head = utf8.decode(bytes.take(512).toList(), allowMalformed: true).trimLeft().toLowerCase();
    if (head.startsWith('<')) return _htmlRows(utf8.decode(bytes, allowMalformed: true));
    if (lower.endsWith('.xlsx') || (bytes.length > 2 && bytes[0] == 0x50 && bytes[1] == 0x4B)) return _xlsxRows(bytes);
    if (lower.endsWith('.xls')) {
      throw StatementFormatException('old_xls');
    }
    if (lower.endsWith('.pdf')) throw StatementFormatException('pdf');
    return csvRows(utf8.decode(bytes, allowMalformed: true));
  }

  static List<List<String>> _xlsxRows(Uint8List bytes) {
    try {
      return XlsxReader.read(bytes);
    } catch (_) {
      // fall back to the general library for unusual files
      final book = xl.Excel.decodeBytes(bytes);
      final out = <List<String>>[];
      for (final sheet in book.tables.values) {
        for (final row in sheet.rows) {
          out.add([for (final c in row) _cellText(c?.value)]);
        }
        if (out.isNotEmpty) break;
      }
      return out;
    }
  }

  static String _cellText(xl.CellValue? v) => switch (v) {
        null => '',
        xl.DateCellValue d => isoDate(DateTime(d.year, d.month, d.day)),
        xl.DateTimeCellValue d => isoDate(DateTime(d.year, d.month, d.day)),
        xl.IntCellValue i => '${i.value}',
        xl.DoubleCellValue d => '${d.value}',
        _ => v.toString(),
      };

  static List<List<String>> _htmlRows(String html) {
    final out = <List<String>>[];
    final rowRe = RegExp(r'<tr[^>]*>(.*?)</tr>', caseSensitive: false, dotAll: true);
    final cellRe = RegExp(r'<t[dh][^>]*>(.*?)</t[dh]>', caseSensitive: false, dotAll: true);
    for (final r in rowRe.allMatches(html)) {
      out.add([
        for (final c in cellRe.allMatches(r.group(1)!))
          c
              .group(1)!
              .replaceAll(RegExp(r'<[^>]+>'), ' ')
              .replaceAll('&nbsp;', ' ')
              .replaceAll('&amp;', '&')
              .replaceAll(RegExp(r'\s+'), ' ')
              .trim()
      ]);
    }
    return out;
  }

  /// Minimal CSV reader (quotes, "" escapes, , ; or tab delimiters).
  static List<List<String>> csvRows(String text) {
    final firstLine = text.split('\n').firstWhere((l) => l.trim().isNotEmpty, orElse: () => '');
    final delim = [',', ';', '\t'].reduce((a, b) => firstLine.split(a).length >= firstLine.split(b).length ? a : b);
    final rows = <List<String>>[];
    var row = <String>[];
    final cell = StringBuffer();
    var quoted = false;
    for (var i = 0; i < text.length; i++) {
      final ch = text[i];
      if (quoted) {
        if (ch == '"') {
          if (i + 1 < text.length && text[i + 1] == '"') {
            cell.write('"');
            i++;
          } else {
            quoted = false;
          }
        } else {
          cell.write(ch);
        }
      } else if (ch == '"') {
        quoted = true;
      } else if (ch == delim) {
        row.add(cell.toString().trim());
        cell.clear();
      } else if (ch == '\n' || ch == '\r') {
        if (ch == '\r' && i + 1 < text.length && text[i + 1] == '\n') i++;
        row.add(cell.toString().trim());
        cell.clear();
        rows.add(row);
        row = <String>[];
      } else {
        cell.write(ch);
      }
    }
    if (cell.isNotEmpty || row.isNotEmpty) {
      row.add(cell.toString().trim());
      rows.add(row);
    }
    return rows;
  }

  static int _find(List<String> h, List<String> words, {List<String> avoid = const []}) {
    for (final w in words) {
      for (var i = 0; i < h.length; i++) {
        if (h[i].contains(w) && !avoid.any(h[i].contains)) return i;
      }
    }
    return -1;
  }

  static _Header? _detect(List<String> cells) {
    final h = cells.map((c) => c.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim()).toList();
    final date = _find(h, ['txn date', 'transaction date', 'tran date', 'trans date', 'posting date', 'date'],
        avoid: ['value date']);
    final dateAlt = date >= 0 ? date : _find(h, ['value date']);
    final desc = _find(h, ['narration', 'description', 'particulars', 'transaction details', 'remarks', 'details']);
    final debit = _find(h, ['withdrawal', 'debit', 'dr amount', 'paid out', 'dr.'], avoid: ['credit']);
    final credit = _find(h, ['deposit', 'credit', 'cr amount', 'paid in', 'cr.'], avoid: ['debit']);
    final amount = _find(h, ['amount'], avoid: ['withdrawal', 'deposit']);
    final drcr = _find(h, ['dr/cr', 'cr/dr', 'dr / cr', 'type']);
    final balance = _find(h, ['balance']);
    final ref = _find(h, ['chq', 'cheque', 'ref', 'utr', 'reference']);
    final hasSplit = debit >= 0 && credit >= 0 && debit != credit;
    final hasSigned = amount >= 0 && drcr >= 0;
    if (dateAlt < 0 || desc < 0 || !(hasSplit || hasSigned)) return null;
    return _Header(dateAlt, desc, debit, credit, amount, drcr, balance, ref, hasSplit);
  }

  static List<StatementLine> parseRows(List<List<String>> rows) {
    for (var hi = 0; hi < rows.length && hi < 60; hi++) {
      final hd = _detect(rows[hi]);
      if (hd == null) continue;
      final out = <StatementLine>[];
      for (final r in rows.skip(hi + 1)) {
        String at(int i) => i >= 0 && i < r.length ? r[i] : '';
        final d = parseDate(at(hd.date));
        if (d == null) continue; // opening/closing lines, footers, repeated headers
        int dr = 0, cr = 0;
        if (hd.split) {
          dr = parseAmount(at(hd.debit))?.abs() ?? 0;
          cr = parseAmount(at(hd.credit))?.abs() ?? 0;
        } else {
          final a = parseAmount(at(hd.amount))?.abs() ?? 0;
          final t = at(hd.drcr).toLowerCase();
          if (t.startsWith('d')) {
            dr = a;
          } else {
            cr = a;
          }
        }
        if (dr == 0 && cr == 0) continue;
        out.add(StatementLine(d, at(hd.desc), at(hd.ref), dr, cr, parseAmount(at(hd.balance), signedByCrDr: true)));
      }
      if (out.isNotEmpty) return out;
    }
    throw StatementFormatException('no_header');
  }

  static final _amountLike = RegExp(r'^\(?-?[\d,]+(\.\d{1,2})?\)?\s*(cr|dr)?\.?$', caseSensitive: false);

  /// Rebuilds the statement table from PDF text pieces
  /// (`[page, x, y, width, text]`, as pdf.js reports them).
  ///
  /// 1. pieces at the same height form a line; close pieces join into cells
  /// 2. the header line gives the column positions
  /// 3. amounts go to the nearest column, text to the column it starts in
  /// 4. a line without a date that only has text continues the previous
  ///    row's description (long narrations wrap onto several lines)
  static List<List<String>> layoutPdf(List<List<Object?>> items) {
    final pieces = [
      for (final i in items)
        (page: (i[0] as num).toInt(), x: (i[1] as num).toDouble(), y: (i[2] as num).toDouble(),
         w: (i[3] as num).toDouble(), s: '${i[4]}'.trim())
    ]..sort((a, b) => a.page != b.page ? a.page.compareTo(b.page) : b.y.compareTo(a.y)); // top of page first

    // 1. lines → cells
    final lines = <List<({double x0, double x1, String s})>>[];
    var cur = <({int page, double x, double y, double w, String s})>[];
    void flush() {
      if (cur.isEmpty) return;
      cur.sort((a, b) => a.x.compareTo(b.x));
      final cells = <({double x0, double x1, String s})>[];
      for (final p in cur) {
        if (cells.isNotEmpty && p.x - cells.last.x1 < 4.5) {
          final last = cells.removeLast();
          final gap = p.x - last.x1;
          cells.add((x0: last.x0, x1: p.x + p.w, s: '${last.s}${gap > 0.8 ? ' ' : ''}${p.s}'));
        } else {
          cells.add((x0: p.x, x1: p.x + p.w, s: p.s));
        }
      }
      lines.add(cells);
      cur = [];
    }

    for (final p in pieces) {
      if (p.s.isEmpty) continue;
      if (cur.isNotEmpty && (cur.first.page != p.page || (cur.first.y - p.y).abs() > 2.5)) flush();
      cur.add(p);
    }
    flush();

    // 2. header
    var hi = -1;
    _Header? hd;
    for (var i = 0; i < lines.length; i++) {
      hd = _detect([for (final c in lines[i]) c.s]);
      if (hd != null) {
        hi = i;
        break;
      }
    }
    if (hd == null) throw StatementFormatException(lines.isEmpty ? 'pdf_scanned' : 'no_header');
    final cols = lines[hi];
    final n = cols.length;
    final textCols = {hd.desc, if (hd.ref >= 0) hd.ref};

    int nearest(double c) {
      var best = 0;
      var bestD = double.infinity;
      for (var k = 0; k < n; k++) {
        final d = ((cols[k].x0 + cols[k].x1) / 2 - c).abs();
        if (d < bestD) {
          bestD = d;
          best = k;
        }
      }
      return best;
    }

    int startsIn(double x) {
      var col = 0;
      for (var k = 0; k < n; k++) {
        if (cols[k].x0 <= x + 6) col = k;
      }
      return col;
    }

    // 3 + 4. rows
    final out = <List<String>>[
      [for (final c in cols) c.s]
    ];
    for (final line in lines.skip(hi + 1)) {
      if (_detect([for (final c in line) c.s]) != null) continue; // header repeated on each page
      final row = List.filled(n, '');
      var hasAmount = false;
      for (final c in line) {
        final amount = _amountLike.hasMatch(c.s.replaceAll(' ', '')) && parseAmount(c.s) != null && parseDate(c.s) == null;
        final k = amount ? nearest((c.x0 + c.x1) / 2) : startsIn(c.x0);
        if (amount) hasAmount = true;
        row[k] = row[k].isEmpty ? c.s : '${row[k]} ${c.s}';
      }
      if (parseDate(row[hd.date]) != null) {
        out.add(row);
      } else if (!hasAmount && out.length > 1 && [for (var k = 0; k < n; k++) if (row[k].isNotEmpty) k].every(textCols.contains)) {
        final prev = out.last;
        for (final k in textCols) {
          if (row[k].isNotEmpty) prev[k] = prev[k].isEmpty ? row[k] : '${prev[k]} ${row[k]}';
        }
      }
    }
    return out;
  }

  /// PDF → statement lines (JSON from [extractPdfText]).
  static List<StatementLine> parsePdfJson(String json) {
    final items = (jsonDecode(json) as List).cast<List<Object?>>();
    if (items.isEmpty) throw StatementFormatException('pdf_scanned');
    return parseRows(layoutPdf(items));
  }

  static const _months = {
    'jan': 1, 'feb': 2, 'mar': 3, 'apr': 4, 'may': 5, 'jun': 6,
    'jul': 7, 'aug': 8, 'sep': 9, 'oct': 10, 'nov': 11, 'dec': 12,
  };

  /// dd/mm/yyyy, dd-mm-yy, dd.mm.yyyy, dd-MMM-yyyy, dd MMM yy, yyyy-mm-dd, Excel serial.
  static String? parseDate(String raw) {
    final s = normalizeDigits(raw).trim();
    if (s.isEmpty) return null;
    String? mk(int y, int m, int d) {
      if (y < 100) y += 2000;
      if (m < 1 || m > 12 || d < 1 || d > 31 || y < 2000 || y > 2100) return null;
      return isoDate(DateTime(y, m, d));
    }

    var m = RegExp(r'^(\d{4})-(\d{1,2})-(\d{1,2})').firstMatch(s);
    if (m != null) return mk(int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!));
    m = RegExp(r'^(\d{1,2})[/\-. ](\d{1,2})[/\-. ](\d{2,4})\b').firstMatch(s);
    if (m != null) return mk(int.parse(m[3]!), int.parse(m[2]!), int.parse(m[1]!));
    m = RegExp(r'^(\d{1,2})[/\-. ]?([A-Za-z]{3})[A-Za-z]*[/\-., ]+(\d{2,4})\b').firstMatch(s);
    if (m != null) {
      final mon = _months[m[2]!.toLowerCase()];
      if (mon != null) return mk(int.parse(m[3]!), mon, int.parse(m[1]!));
    }
    final serial = double.tryParse(s);
    if (serial != null && serial > 36000 && serial < 60000) {
      return isoDate(DateTime(1899, 12, 30).add(Duration(days: serial.floor())));
    }
    return null;
  }

  /// "1,23,456.50", "1500 Cr", "(200.00)", "-" → paise.
  static int? parseAmount(String raw, {bool signedByCrDr = false}) {
    var s = normalizeDigits(raw).trim();
    if (s.isEmpty || s == '-') return null;
    var sign = 1;
    final lower = s.toLowerCase();
    if (lower.endsWith('dr')) {
      if (signedByCrDr) sign = -1;
      s = s.substring(0, s.length - 2);
    } else if (lower.endsWith('cr')) {
      s = s.substring(0, s.length - 2);
    }
    if (s.startsWith('(') && s.endsWith(')')) {
      sign = -1;
      s = s.substring(1, s.length - 1);
    }
    s = s.replaceAll(RegExp(r'[^0-9.\-]'), '');
    final v = double.tryParse(s);
    if (v == null) return null;
    return (v * 100).round() * sign;
  }
}

class _Header {
  final int date, desc, debit, credit, amount, drcr, balance, ref;
  final bool split;
  _Header(this.date, this.desc, this.debit, this.credit, this.amount, this.drcr, this.balance, this.ref, this.split);
}
