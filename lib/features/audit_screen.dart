import 'dart:convert';

import 'package:flutter/material.dart';

import '../core/money.dart';
import '../shared/widgets.dart';
import '../state/app_controller.dart';

/// Who created / changed / deleted an entry and what it looked like before.
class AuditScreen extends StatelessWidget {
  final String? voucherId; // null = all recent changes
  const AuditScreen({super.key, this.voucherId});

  @override
  Widget build(BuildContext context) {
    final app = App.of(context);
    final t = app.t;
    return Scaffold(
      appBar: AppBar(title: Text(t('audit'))),
      body: LiveBuilder<List<Map<String, Object?>>>(
        tables: const ['audit_log'],
        load: () async => (await app.db.getAll(
          'SELECT a.*, v.vtype, v.vno, v.vdate, v.amount, p.name AS party FROM audit_log a '
          'LEFT JOIN vouchers v ON v.id = a.voucher_id LEFT JOIN ledgers p ON p.id = v.party_id '
          'WHERE a.business_id = ? ${voucherId != null ? 'AND a.voucher_id = ?' : ''} ORDER BY a.at DESC LIMIT 300',
          [app.businessId, if (voucherId != null) voucherId],
        ))
            .map((r) => Map<String, Object?>.from(r))
            .toList(),
        builder: (context, rows) => rows.isEmpty
            ? Center(child: Text(t('no_entries')))
            : ListView.separated(
                itemCount: rows.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (_, i) {
                  final r = rows[i];
                  final action = r['action'] as String;
                  final at = DateTime.parse(r['at'] as String).toLocal();
                  String? before;
                  if (r['snapshot'] != null) {
                    final s = jsonDecode(r['snapshot'] as String) as Map<String, dynamic>;
                    final v = s['voucher'] as Map<String, dynamic>;
                    before = '${shortDate(v['vdate'] as String)} · ₹${Money.fmt((v['amount'] as int?) ?? 0)}'
                        '${(v['narration'] as String?)?.isNotEmpty ?? false ? ' · ${v['narration']}' : ''}';
                  }
                  return ListTile(
                    leading: Icon(
                      action == 'create' ? Icons.add_circle_outline : action == 'edit' ? Icons.edit : Icons.delete_outline,
                      color: action == 'delete' ? Colors.red : action == 'edit' ? Colors.orange : Colors.green,
                    ),
                    title: Text('${r['user_name'] ?? ''} · ${t(action == 'create' ? 'add' : action)}'
                        ' · ${r['vtype'] == null ? '' : t('vt_${r['vtype']}')} #${r['vno'] ?? ''} ${r['party'] ?? ''}'),
                    subtitle: Text([
                      '${at.day}/${at.month}/${at.year} ${at.hour}:${at.minute.toString().padLeft(2, '0')}',
                      if (before != null) '${t('before_change')}: $before',
                    ].join('\n')),
                    isThreeLine: before != null,
                  );
                },
              ),
      ),
    );
  }
}
