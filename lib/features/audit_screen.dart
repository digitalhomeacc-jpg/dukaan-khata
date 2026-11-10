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
  'gst_rate': 'gst_rate_label',
  'gst_bill': 'gst_bill_needed',
  'transporter_fare': 'fare_to_transporter',
  'postings': 'audit_postings',
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
              'SELECT a.*, v.vtype, v.vno, v.vdate, v.amount, v.created_at AS v_created, v.created_by AS v_by, p.name AS party FROM audit_log a '
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
                final at = _time(r['at'] as String?);
                final when = _fmt(at);
                // the server's own time for this change (a phone clock can be wrong)
                final server = _time(r['received_at'] as String?);
                final clockOff = at != null && server != null && server.difference(at).inMinutes.abs() > 10;
                // when and by whom the entry itself was first made
                final made = k == 'voucher' && r['v_created'] != null
                    ? '${t('audit_entry_made')}: ${_fmt(_time(r['v_created'] as String?))}${r['v_by'] != null ? ' · ${r['v_by']}' : ''}'
                        '${r['vdate'] != null ? ' · ${t('date')} ${shortDate(r['vdate'] as String)}' : ''}'
                    : null;
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
                          if (made != null) Text(made, style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
                          if (server != null)
                            Text(
                              '${t('audit_server_time')}: ${_fmt(server)}${clockOff ? '  ⚠ ${t('audit_clock_off')}' : ''}',
                              style: TextStyle(fontSize: 11, color: clockOff ? AppColors.due : scheme.onSurfaceVariant),
                            ),
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

  /// ISO / Postgres time text → local time ("2026-11-10 03:05:12.1+00" too).
  static DateTime? _time(String? s) {
    if (s == null || s.isEmpty) return null;
    var x = s.trim().replaceFirst(' ', 'T');
    if (RegExp(r'[+-]\d\d$').hasMatch(x)) x = '$x:00';
    return DateTime.tryParse(x)?.toLocal();
  }

  /// 10/11/26 08:25:43 – to the second.
  static String _fmt(DateTime? d) {
    if (d == null) return '';
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.day}/${d.month}/${d.year % 100} ${two(d.hour)}:${two(d.minute)}:${two(d.second)}';
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
