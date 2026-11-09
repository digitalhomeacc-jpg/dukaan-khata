import 'dart:convert';
import 'dart:typed_data';

import 'package:sqlite_async/sqlite_async.dart';

import 'ids.dart';
import 'schema.dart';

/// Full backup of one shop: every row of every table, as a JSON file.
/// Restoring it on a fresh device brings back all entries exactly.
class Backup {
  static const format = 'dukaan-khata-backup';

  static Future<Uint8List> export(SqliteReadContext db, String businessId) async {
    final tables = <String, List<Map<String, Object?>>>{};
    for (final t in appTables.where((t) => !t.localOnly)) {
      final where = t.name == 'businesses' ? 'id = ?' : 'business_id = ?';
      final rows = await db.getAll('SELECT * FROM ${t.name} WHERE $where', [businessId]);
      tables[t.name] = [for (final r in rows) Map<String, Object?>.from(r)];
    }
    final json = jsonEncode({
      'format': format,
      'version': 1,
      'business_id': businessId,
      'exported_at': nowIso(),
      'tables': tables,
    });
    return Uint8List.fromList(utf8.encode(json));
  }

  /// Inserts every row from a backup. Returns (businessId, businessName).
  /// Only for an empty device – existing rows with the same id are skipped.
  static Future<(String, String)> restore(SqliteWriteContext tx, Uint8List bytes) async {
    final data = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    if (data['format'] != format) throw const FormatException('Not a Dukaan Khata backup file');
    final bid = data['business_id'] as String;
    final tables = (data['tables'] as Map<String, dynamic>);
    for (final t in appTables.where((t) => !t.localOnly)) {
      final allowed = {'id', for (final c in t.columns) c.name};
      for (final raw in (tables[t.name] as List? ?? const [])) {
        final row = Map<String, Object?>.from(raw as Map)..removeWhere((k, _) => !allowed.contains(k));
        if (row['id'] == null) continue;
        if (await tx.getOptional('SELECT id FROM ${t.name} WHERE id = ?', [row['id']]) != null) continue;
        final cols = row.keys.toList();
        await tx.execute(
          'INSERT INTO ${t.name} (${cols.join(', ')}) VALUES (${List.filled(cols.length, '?').join(', ')})',
          [for (final c in cols) row[c]],
        );
      }
    }
    final biz = (tables['businesses'] as List).cast<Map>().firstWhere((b) => b['id'] == bid);
    return (bid, (biz['name'] as String?) ?? '');
  }
}
