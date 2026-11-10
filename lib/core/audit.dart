import 'dart:convert';

import 'package:sqlite_async/sqlite_async.dart';

import '../accounting/voucher_service.dart' show Actor;
import 'ids.dart';
import 'money.dart';

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

  /// An entry's saved copy from the older history (voucher row + lines +
  /// items) in the same shape as today's records, so the two compare.
  static Map<String, dynamic> legacySummary(Map<String, dynamic> snap, Map<String, String> ledgers, Map<String, String> items) {
    final v = snap['voucher'] as Map<String, dynamic>;
    String m(Object? p) => (p as int? ?? 0) == 0 ? '' : Money.fmt(p as int);
    String q(num x) => x == x.roundToDouble() ? '${x.toInt()}' : '$x';
    final pay = v['pay_ledger_id'] as String?;
    String? s(Object? x) => x == null || '$x'.isEmpty ? null : '$x';
    return {
      'type': v['vtype'],
      'vno': '${v['vno'] ?? ''}',
      'date': v['vdate'],
      'party': ledgers[v['party_id']],
      'amount': m(v['amount']),
      'paid': m(v['paid']),
      'pay_mode': pay == null ? null : ledgers[pay],
      'items': [
        for (final i in (snap['items'] as List? ?? const []))
          '${items[i['item_id']] ?? '?'} ${q(i['qty'] as num)}${((i['rate'] as int?) ?? 0) > 0 ? '×${Money.fmt(i['rate'] as int)}' : ''}'
      ].join(', '),
      'hamali': m(v['hamali']),
      'transport': m(v['transport']),
      'transporter': v['transporter_id'] == null ? null : ledgers[v['transporter_id']],
      'gst': m(v['gst']),
      'ref': s(v['ref_no']),
      'narration': s(v['narration']),
      'haste': s(v['haste']),
      'status': s(v['status']),
      'transporter_fare': m(v['transporter_fare']),
      'gst_rate': ((v['gst_rate'] as int?) ?? 0) == 0 ? '' : '${(v['gst_rate'] as int) / 100}%',
      'gst_bill': ((v['gst_bill_needed'] as int?) ?? 0) == 1 ? '✓' : '',
      'postings': [
        for (final l in (snap['lines'] as List? ?? const []))
          '${ledgers[l['ledger_id']] ?? '?'} ${((l['debit'] as int?) ?? 0) > 0 ? '+${Money.fmt(l['debit'] as int)}' : '−${Money.fmt((l['credit'] as int?) ?? 0)}'}'
      ].join(', '),
    }..removeWhere((k, v) => v == null || '$v'.isEmpty);
  }
}
