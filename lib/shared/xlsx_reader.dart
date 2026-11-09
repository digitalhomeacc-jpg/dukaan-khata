import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

/// Minimal, forgiving .xlsx reader: returns the first sheet's cells as text.
///
/// Written because spreadsheet files from Google Sheets, bank software and
/// other tools differ in small ways (absolute part paths, inline strings,
/// missing styles) that made the general Excel library crash. Numbers come
/// back as stored ("812345", "-65000", "45229" for a date serial).
class XlsxReader {
  static List<List<String>> read(Uint8List bytes) {
    final zip = ZipDecoder().decodeBytes(bytes);
    String? text(String path) {
      final f = zip.findFile(path);
      if (f == null) return null;
      return utf8.decode(f.content as List<int>, allowMalformed: true);
    }

    // shared strings
    final shared = <String>[];
    final ss = text('xl/sharedStrings.xml');
    if (ss != null) {
      for (final si in XmlDocument.parse(ss).findAllElements('si')) {
        shared.add(si.findAllElements('t').map((t) => t.innerText).join());
      }
    }

    // first sheet's file
    var sheetPath = 'xl/worksheets/sheet1.xml';
    final wb = text('xl/workbook.xml');
    final rels = text('xl/_rels/workbook.xml.rels');
    if (wb != null && rels != null) {
      final first = XmlDocument.parse(wb).findAllElements('sheet').firstOrNull;
      final rid = first?.attributes.where((a) => a.name.local == 'id').firstOrNull?.value;
      for (final r in XmlDocument.parse(rels).findAllElements('Relationship')) {
        if (r.getAttribute('Id') == rid) {
          final t = r.getAttribute('Target') ?? '';
          sheetPath = t.startsWith('/') ? t.substring(1) : (t.startsWith('xl/') ? t : 'xl/$t');
        }
      }
    }
    final sheet = text(sheetPath) ?? text('xl/worksheets/sheet1.xml');
    if (sheet == null) throw const FormatException('No worksheet in this file');

    final out = <List<String>>[];
    for (final row in XmlDocument.parse(sheet).findAllElements('row')) {
      final cells = <int, String>{};
      var next = 0;
      for (final c in row.findElements('c')) {
        final ref = c.getAttribute('r');
        final col = ref == null ? next : _col(ref);
        next = col + 1;
        final type = c.getAttribute('t');
        final v = c.findElements('v').firstOrNull?.innerText ?? '';
        cells[col] = switch (type) {
          's' => (int.tryParse(v) ?? -1) >= 0 && int.parse(v) < shared.length ? shared[int.parse(v)] : '',
          'inlineStr' => c.findAllElements('t').map((t) => t.innerText).join(),
          'b' => v == '1' ? 'TRUE' : 'FALSE',
          'e' => '',
          _ => v,
        };
      }
      final width = cells.isEmpty ? 0 : cells.keys.reduce((a, b) => a > b ? a : b) + 1;
      out.add([for (var i = 0; i < width; i++) (cells[i] ?? '').trim()]);
    }
    return out;
  }

  /// "AB12" → 27
  static int _col(String ref) {
    var n = 0;
    for (final ch in ref.codeUnits) {
      if (ch < 65 || ch > 90) break;
      n = n * 26 + (ch - 64);
    }
    return n - 1;
  }
}
