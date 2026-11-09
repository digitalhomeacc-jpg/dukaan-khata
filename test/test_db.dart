import 'dart:io';

import 'package:dukaan_khata/core/schema.dart';
import 'package:dukaan_khata/core/seed.dart';
import 'package:sqlite_async/sqlite_async.dart';

/// Opens a fresh SQLite DB with the same tables the app uses (without PowerSync).
Future<SqliteDatabase> openTestDb(String businessId) async {
  final dir = await Directory.systemTemp.createTemp('khata_test');
  final db = SqliteDatabase(path: '${dir.path}/t.db');
  await db.writeTransaction((tx) async {
    for (final s in buildSqliteDdl()) {
      await tx.execute(s);
    }
    await tx.execute('INSERT INTO businesses (id, name) VALUES (?, ?)', [businessId, 'Test Shop']);
    await seedBusiness(tx, businessId);
  });
  return db;
}
