import 'dart:convert';

import 'package:sqlite_async/sqlite_async.dart';

import '../accounting/voucher_service.dart' show Actor;
import 'ids.dart';

/// बदल इतिहास: every change anyone makes – entries, accounts, items, settings –
/// with who, when and what changed (before → after), so a mistake can be traced.
///
/// Rows go into the synced, append-only `audit_log` table:
///   voucher_id = id of the changed record (entry, account, item …)
///   action     = create | edit | delete | status | hide …
///   snapshot   = {"kind": "voucher|ledger|item|shop|user|…", "title": "…",
///                 "before": {field: text}, "after": {field: text}}
class AuditLog {
  /// Who is using the app right now (set by the app when someone unlocks).
  static Actor actor = const Actor(userId: 'local', name: '', isOwner: false);

  static Future<void> write(
    SqliteWriteContext db, {
    required String businessId,
    required String recordId,
    required String action,
    required String kind,
    required String title,
    Map<String, Object?>? before,
    Map<String, Object?>? after,
    Actor? by,
  }) async {
    final b = _clean(before), a = _clean(after);
    // an "edit" that changed nothing is not worth a line
    if (action == 'edit' && b != null && a != null && jsonEncode(b) == jsonEncode(a)) return;
    final who = by ?? actor;
    await db.execute(
      'INSERT INTO audit_log (id, business_id, voucher_id, action, user_id, user_name, at, snapshot) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
      [
        newId(),
        businessId,
        recordId,
        action,
        who.userId,
        who.name,
        nowIso(),
        jsonEncode({'kind': kind, 'title': title, 'before': ?b, 'after': ?a}),
      ],
    );
  }

  static Map<String, String>? _clean(Map<String, Object?>? m) => m == null
      ? null
      : {
          for (final e in m.entries)
            if (e.value != null && '${e.value}'.isNotEmpty) e.key: '${e.value}',
        };

  /// Fields whose value differs (key → (before, after)), in a stable order.
  static List<(String, String?, String?)> diff(Map<String, dynamic>? before, Map<String, dynamic>? after) {
    final keys = <String>{...?before?.keys, ...?after?.keys};
    return [
      for (final k in keys)
        if (before?[k]?.toString() != after?[k]?.toString()) (k, before?[k]?.toString(), after?[k]?.toString()),
    ];
  }
}
