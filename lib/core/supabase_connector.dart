import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:powersync/powersync.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'config.dart';
import 'ids.dart';

/// Connects the local PowerSync database to Supabase:
///  * fetchCredentials – hands PowerSync the logged-in user's login token
///  * uploadData       – sends offline changes to Postgres, one whole entry
///                       (bill + lines + stock + audit) per call, applied
///                       all-or-nothing by the `apply_crud` database function.
class SupabaseConnector extends PowerSyncBackendConnector {
  final SupabaseClient client;
  SupabaseConnector(this.client);

  bool _atomicAvailable = true;

  @override
  Future<PowerSyncCredentials?> fetchCredentials() async {
    final session = client.auth.currentSession;
    if (session == null) return null;
    return PowerSyncCredentials(endpoint: AppConfig.powersyncUrl, token: session.accessToken);
  }

  @override
  void invalidateCredentials() {
    client.auth.refreshSession().ignore();
  }

  static Map<String, Object?> _op(CrudEntry op) => {
        'op': switch (op.op) {
          UpdateType.put => 'PUT',
          UpdateType.patch => 'PATCH',
          UpdateType.delete => 'DELETE',
        },
        'table': op.table,
        'id': op.id,
        'data': op.opData ?? const {},
      };

  /// Errors that will never succeed on retry (permission refused, bad data).
  static bool _isPermanent(PostgrestException e) {
    final c = e.code ?? '';
    return c == '42501' || c.startsWith('22') || c.startsWith('23') || c == 'P0001';
  }

  @override
  Future<void> uploadData(PowerSyncDatabase database) async {
    final tx = await database.getNextCrudTransaction();
    if (tx == null) return;
    final ops = [for (final op in tx.crud) _op(op)];
    try {
      if (_atomicAvailable) {
        try {
          await client.rpc('apply_crud', params: {'ops': ops});
        } on PostgrestException catch (e) {
          // Database not yet updated with apply_crud → fall back to one call per change.
          if (e.code == 'PGRST202' || e.code == '42883') {
            _atomicAvailable = false;
            await _uploadOneByOne(tx.crud);
          } else {
            rethrow;
          }
        }
      } else {
        await _uploadOneByOne(tx.crud);
      }
      await tx.complete();
    } on PostgrestException catch (e) {
      if (!_isPermanent(e)) rethrow; // network / server busy → PowerSync retries later
      // The server refused this entry. Keep a visible record, then move on so
      // later entries are not blocked. The device will match the server again
      // on the next sync, so it never silently disagrees with other devices.
      debugPrint('Server refused change: ${e.message}');
      await database.execute(
        'INSERT INTO sync_errors (id, at, tables, message, ops) VALUES (?, ?, ?, ?, ?)',
        [newId(), nowIso(), {for (final o in tx.crud) o.table}.join(', '), '${e.code}: ${e.message}', jsonEncode(ops)],
      );
      await tx.complete();
    }
  }

  Future<void> _uploadOneByOne(List<CrudEntry> crud) async {
    for (final op in crud) {
      final table = client.from(op.table);
      switch (op.op) {
        case UpdateType.put:
          await table.upsert({...?op.opData, 'id': op.id});
        case UpdateType.patch:
          await table.update(op.opData!).eq('id', op.id);
        case UpdateType.delete:
          await table.delete().eq('id', op.id);
      }
    }
  }
}
