import 'dart:convert';

import 'package:flutter/material.dart';

import '../core/audit.dart';
import '../core/money.dart';
import '../core/theme.dart';
import '../shared/widgets.dart';
import '../state/app_controller.dart';
import 'voucher_screen.dart';

/// बदल इतिहास: every change – who, when, and what it was before → after.
class AuditScreen extends StatefulWidget {
  final String? voucherId; // one entry's history, or null for everything
  const AuditScreen({super.key, this.voucherId});
  @override
  State<AuditScreen> createState() => _AuditScreenState();
}

/// Field → label key (most are the app's own words).
const _labels = {
  'type': 'type',
  'date': 'date',
  'party': 'party',
  'amount': 'amount',
  'paid': 'paid',
  'pay_mode': 'pay_mode',
  'items': 'items',
  'hamali': 'hamali',
  'transport': 'transport',
  'transporter': 'transporter',
  'gst': 'GST',
  'ref': 'ref',
  'narration': 'narration',
  'haste': 'haste',
  'status': 'audit_f_status',
  'name': 'name',
  'name_en': 'name_en',
  'group': 'category',
  'page_no': 'page_no',
  'phone': 'phone',
  'address': 'address',
  'gstin': 'GSTIN',
  'opening_balance': 'opening_balance',
  'credit_limit': 'credit_limit',
  'interest_rate': 'interest_rate',
  'salary': 'salary_monthly',
  'salary_cut': 'salary_cut_monthly',
  'hidden': 'audit_hidden',
  'category': 'category',
  'unit': 'unit',
  'short_code': 'short_code',
  'sale_rate': 'sale_rate',
  'purchase_rate': 'purchase_rate',
  'opening_qty': 'opening_qty',
  'opening_rate': 'opening_rate',
  'low_stock': 'low_stock',
  'books_start': 'books_start',
  'fy_start_month': 'fy_start',
};

/// What a new / deleted entry is described by (all fields would be too long).
const _keyFields = ['date', 'party', 'amount', 'paid', 'pay_mode', 'items', 'hamali', 'narration'];

class _AuditScreenState extends State<AuditScreen> {
  String kind = 'all'; // all | voucher | ledger | item | other
  final q = TextEditingController();

  @override
  Widget build(BuildContext context) {
    final app = App.of(context);
    final t = app.t;
    final scheme = Theme.of(context).colorScheme;
    String label(String k) => _labels[k] == null ? k : t(_labels[k]!);
    String show(String k, String? v) {
      if (v == null || v.isEmpty) return '–';
      if (k == 'date' || k == 'books_start') return shortDate(v);
      if (k == 'type') return t('vt_$v');
      if (k == 'group') return t('grp_$v');
      if (k == 'category') return t('cat_$v');
      if (k == 'unit') return t('unit_$v');
      return v;
    }

    return Scaffold(
      appBar: AppBar(title: Text(t('audit'))),
      body: Column(children: [
        if (widget.voucherId == null) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 6, 8, 0),
            child: TextField(
              controller: q,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(prefixIcon: const Icon(Icons.search), hintText: t('audit_search'), isDense: true, border: const OutlineInputBorder()),
            ),
          ),
          SizedBox(
            height: 46,
            child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6), children: [
              for (final (k, l) in [('all', 'all'), ('voucher', 'entries'), ('ledger', 'audit_accounts'), ('item', 'items'), ('other', 'audit_other')])
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: ChoiceChip(label: Text(t(l)), selected: kind == k, onSelected: (_) => setState(() => kind = k)),
                ),
            ]),
          ),
        ],
        Expanded(
          child: LiveBuilder<List<Map<String, Object?>>>(
            tables: const ['audit_log'],
            reloadKey: kind,
            load: () async => (await app.db.getAll(
              'SELECT a.*, v.vtype, v.vno, v.vdate, v.amount, p.name AS party FROM audit_log a '
              'LEFT JOIN vouchers v ON v.id = a.voucher_id LEFT JOIN ledgers p ON p.id = v.party_id '
              'WHERE a.business_id = ? ${widget.voucherId != null ? 'AND a.voucher_id = ?' : ''} ORDER BY a.at DESC LIMIT 1000',
              [app.businessId, if (widget.voucherId != null) widget.voucherId],
            ))
                .map((r) => Map<String, Object?>.from(r))
                .toList(),
            builder: (context, rows) {
              final search = normalizeDigits(q.text.trim()).toLowerCase();
              final items = <Widget>[];
              for (final r in rows) {
                final snap = r['snapshot'] == null ? <String, dynamic>{} : jsonDecode(r['snapshot'] as String) as Map<String, dynamic>;
                // old rows (before the full history) only kept the entry as it was
                final legacy = snap.containsKey('voucher');
                final k = legacy ? 'voucher' : (snap['kind'] as String? ?? 'voucher');
                final group = const {'voucher', 'ledger', 'item'}.contains(k) ? k : 'other';
                if (kind != 'all' && kind != group) continue;
                final action = r['action'] as String;
                final before = legacy ? _legacyBefore(snap) : snap['before'] as Map<String, dynamic>?;
                final after = snap['after'] as Map<String, dynamic>?;
                // what was changed
                String what;
                if (k == 'voucher') {
                  final parts = ((snap['title'] as String?) ?? '').split('|');
                  final type = parts.isNotEmpty && parts[0].isNotEmpty ? parts[0] : r['vtype'] as String?;
                  final vno = parts.length > 1 && parts[1].isNotEmpty ? parts[1] : '${r['vno'] ?? ''}';
                  final party = parts.length > 2 && parts[2].isNotEmpty ? parts[2] : (r['party'] as String? ?? '');
                  what = '${type == null ? '' : t('vt_$type')} #$vno $party';
                } else {
                  what = '${t('audit_kind_$k')} · ${snap['title'] ?? ''}';
                }
                // the fields shown under it
                final lines = <String>[];
                if (legacy && action == 'edit') {
                  // older history only kept the entry as it was before the change
                  for (final f in before?.keys ?? const <String>[]) {
                    if (before![f] != null && '${before[f]}'.isNotEmpty) lines.add('${t('before_change')} ${label(f)}: ${show(f, '${before[f]}')}');
                  }
                } else if (action == 'edit' || action == 'status' || action == 'hide' || action == 'unhide') {
                  for (final (f, b, a) in AuditLog.diff(before, after)) {
                    lines.add('${label(f)}: ${show(f, b)} → ${show(f, a)}');
                  }
                } else if (action == 'create' || action == 'delete') {
                  final m = action == 'create' ? after : before;
                  if (m != null) {
                    for (final f in k == 'voucher' ? _keyFields : m.keys) {
                      if (m[f] != null && '${m[f]}'.isNotEmpty) lines.add('${label(f)}: ${show(f, '${m[f]}')}');
                    }
                  }
                }
                final at = DateTime.parse(r['at'] as String).toLocal();
                final when = '${at.day}/${at.month}/${at.year % 100} ${at.hour}:${at.minute.toString().padLeft(2, '0')}';
                final head = '${r['user_name'] ?? ''} · ${t('audit_$action') == 'audit_$action' ? action : t('audit_$action')}';
                if (search.isNotEmpty &&
                    !normalizeDigits('$head $what ${lines.join(' ')}').toLowerCase().contains(search)) {
                  continue;
                }
                final color = switch (action) {
                  'create' => AppColors.paid,
                  'delete' => AppColors.due,
                  'edit' => AppColors.haldi,
                  _ => scheme.primary,
                };
                items.add(InkWell(
                  onTap: k == 'voucher' && r['vtype'] != null && action != 'delete'
                      ? () => VoucherScreen.edit(context, r['voucher_id'] as String)
                      : null,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Icon(
                        switch (action) {
                          'create' => Icons.add_circle_outline,
                          'delete' => Icons.delete_outline,
                          'edit' => Icons.edit_outlined,
                          'hide' => Icons.visibility_off_outlined,
                          'pin' => Icons.pin_outlined,
                          _ => Icons.flag_outlined,
                        },
                        color: color,
                        size: 22,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Row(children: [
                            Expanded(child: Text(what, style: const TextStyle(fontWeight: FontWeight.w700))),
                            Text(when, style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
                          ]),
                          Text(head, style: TextStyle(fontSize: 12, color: color, fontWeight: FontWeight.w600)),
                          for (final l in lines) Text(l, style: const TextStyle(fontSize: 13)),
                        ]),
                      ),
                    ]),
                  ),
                ));
                items.add(const Divider(height: 1));
              }
              if (items.isEmpty) return Center(child: Text(t('no_entries')));
              return ListView(padding: const EdgeInsets.only(bottom: 40), children: items);
            },
          ),
        ),
      ]),
    );
  }

  /// Entries changed before the full history: their saved "before" copy.
  static Map<String, dynamic> _legacyBefore(Map<String, dynamic> snap) {
    final v = snap['voucher'] as Map<String, dynamic>;
    return {
      'date': v['vdate'],
      'amount': (v['amount'] as int? ?? 0) == 0 ? '' : Money.fmt(v['amount'] as int),
      'paid': (v['paid'] as int? ?? 0) == 0 ? '' : Money.fmt(v['paid'] as int),
      'narration': v['narration'],
    };
  }
}
