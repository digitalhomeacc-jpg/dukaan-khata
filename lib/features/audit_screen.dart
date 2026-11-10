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

/// Fields shown for a new / deleted entry, in this order (the rest only when
/// one entry's own history is open).
const _entryFields = ['date', 'party', 'items', 'amount', 'paid', 'pay_mode', 'hamali', 'transport', 'transporter', 'gst', 'ref', 'narration', 'haste'];

/// One line of the history, read from audit_log.
class _Ev {
  final String id; // audit row
  final String recordId; // entry / account / item … that changed
  final String kind; // voucher | ledger | item | shop | user | bank
  final String action; // create | edit | delete | status | hide | unhide | pin | restore
  final DateTime? at; // phone time
  final DateTime? server; // server time (can't be set by a phone)
  final String user;
  final String title;
  final Map<String, dynamic>? before;
  final Map<String, dynamic>? after;
  final bool legacy;
  final Map<String, Object?> row;
  _Ev(this.id, this.recordId, this.kind, this.action, this.at, this.server, this.user, this.title, this.before, this.after,
      this.legacy, this.row);
  DateTime get when => at ?? server ?? DateTime(2000);
}

class _AuditScreenState extends State<AuditScreen> {
  String kind = 'all'; // all | voucher | ledger | item | other
  bool onlyFixed = false; // only records that were later changed or deleted
  final q = TextEditingController();

  bool get single => widget.voucherId != null;

  Future<List<_Ev>> _load() async {
    final app = App.read(context);
    final rows = await app.db.getAll(
      'SELECT a.*, v.vtype, v.vno, v.vdate, v.amount, v.deleted AS v_deleted, v.created_at AS v_created, v.created_by AS v_by, '
      'p.name AS party FROM audit_log a LEFT JOIN vouchers v ON v.id = a.voucher_id LEFT JOIN ledgers p ON p.id = v.party_id '
      'WHERE a.business_id = ? ${single ? 'AND a.voucher_id = ?' : ''} ORDER BY a.at DESC LIMIT 3000',
      [app.businessId, if (single) widget.voucherId],
    );
    return [
      for (final r in rows)
        () {
          final snap = r['snapshot'] == null ? <String, dynamic>{} : jsonDecode(r['snapshot'] as String) as Map<String, dynamic>;
          final legacy = snap.containsKey('voucher'); // history written before the full log
          return _Ev(
            r['id'] as String,
            (r['voucher_id'] as String?) ?? '',
            legacy ? 'voucher' : (snap['kind'] as String? ?? 'voucher'),
            r['action'] as String,
            _time(r['at'] as String?),
            _time(r['received_at'] as String?),
            (r['user_name'] as String?) ?? '',
            (snap['title'] as String?) ?? '',
            legacy ? _legacyBefore(snap) : (snap['before'] as Map?)?.cast<String, dynamic>(),
            (snap['after'] as Map?)?.cast<String, dynamic>(),
            legacy,
            Map<String, Object?>.from(r),
          );
        }(),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final app = App.of(context);
    final t = app.t;
    return Scaffold(
      appBar: AppBar(title: Text(single ? t('audit_one') : t('audit'))),
      body: LiveBuilder<List<_Ev>>(
        tables: const ['audit_log', 'vouchers'],
        reloadKey: kind,
        load: _load,
        builder: (context, all) {
          // what happened to each record afterwards (for the badges)
          final byRecord = <String, List<_Ev>>{};
          for (final e in all) {
            (byRecord[e.recordId] ??= []).add(e);
          }
          for (final l in byRecord.values) {
            l.sort((a, b) => a.when.compareTo(b.when));
          }
          final search = normalizeDigits(q.text.trim()).toLowerCase();
          var list = single ? (all.toList()..sort((a, b) => a.when.compareTo(b.when))) : all;
          if (!single) {
            list = list.where((e) {
              final group = const {'voucher', 'ledger', 'item'}.contains(e.kind) ? e.kind : 'other';
              if (kind != 'all' && kind != group) return false;
              if (onlyFixed) {
                final later = byRecord[e.recordId]!;
                if (!later.any((x) => x.action == 'edit' || x.action == 'delete')) return false;
              }
              if (search.isEmpty) return true;
              final text = '${e.user} ${_title(e, t)} ${jsonEncode(e.before ?? {})} ${jsonEncode(e.after ?? {})}';
              return normalizeDigits(text).toLowerCase().contains(search);
            }).toList();
          }
          return Column(children: [
            if (!single) ...[
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
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: FilterChip(
                      avatar: const Icon(Icons.warning_amber_rounded, size: 16),
                      label: Text(t('audit_only_fixed')),
                      selected: onlyFixed,
                      onSelected: (v) => setState(() => onlyFixed = v),
                    ),
                  ),
                  for (final (k, l) in [('all', 'all'), ('voucher', 'entries'), ('ledger', 'audit_accounts'), ('item', 'items'), ('other', 'audit_other')])
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: ChoiceChip(label: Text(t(l)), selected: kind == k, onSelected: (_) => setState(() => kind = k)),
                    ),
                ]),
              ),
            ],
            Expanded(
              child: list.isEmpty
                  ? Center(child: Text(t('no_entries')))
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(8, 4, 8, 40),
                      itemCount: list.length,
                      itemBuilder: (_, i) => _card(list[i], byRecord[list[i].recordId]!, app),
                    ),
            ),
          ]);
        },
      ),
    );
  }

  /// "विक्री #12 · सुरेश जाधव" / "खाते · सुरेश जाधव"
  String _title(_Ev e, String Function(String) t) {
    if (e.kind == 'voucher') {
      final parts = e.title.split('|');
      final type = parts.isNotEmpty && parts[0].isNotEmpty ? parts[0] : e.row['vtype'] as String?;
      final vno = parts.length > 1 && parts[1].isNotEmpty ? parts[1] : '${e.row['vno'] ?? ''}';
      final party = parts.length > 2 && parts[2].isNotEmpty ? parts[2] : (e.row['party'] as String? ?? '');
      return '${type == null ? '' : t('vt_$type')} #$vno${party.isEmpty ? '' : ' · $party'}';
    }
    return '${t('audit_kind_${e.kind}')} · ${e.title}';
  }

  Widget _card(_Ev e, List<_Ev> story, AppController app) {
    final t = app.t;
    final scheme = Theme.of(context).colorScheme;
    String label(String k) => _labels[k] == null ? k : t(_labels[k]!);
    String show(String k, Object? v) {
      final s = v?.toString() ?? '';
      if (s.isEmpty) return '–';
      if (k == 'date' || k == 'books_start') return shortDate(s);
      if (k == 'type') return t('vt_$s');
      if (k == 'group') return t('grp_$s');
      if (k == 'category') return t('cat_$s');
      if (k == 'unit') return t('unit_$s');
      if (k == 'status') return t('audit_st_$s') == 'audit_st_$s' ? s : t('audit_st_$s');
      return s;
    }

    final (Color color, IconData icon) = switch (e.action) {
      'create' => (AppColors.paid, Icons.add_circle),
      'delete' => (AppColors.due, Icons.delete),
      'edit' => (AppColors.haldi, Icons.edit),
      'hide' => (AppColors.neutral, Icons.visibility_off),
      _ => (scheme.primary, Icons.flag),
    };
    final actionText = t('audit_${e.action}') == 'audit_${e.action}' ? e.action : t('audit_${e.action}');
    // what happened to this record after this line
    final later = story.where((x) => x.when.isAfter(e.when) || (x.when == e.when && x.id != e.id && x.action == 'delete')).toList();
    final deletedLater = e.action == 'delete' ? null : later.where((x) => x.action == 'delete').lastOrNull;
    final editsLater = later.where((x) => x.action == 'edit').length;
    final clockOff = e.at != null && e.server != null && e.server!.difference(e.at!).inMinutes.abs() > 10;

    // details: a field table for new / deleted, a before | after table for changes
    final rows = <TableRow>[];
    final small = TextStyle(fontSize: 12, color: scheme.onSurfaceVariant);
    const val = TextStyle(fontSize: 13.5);
    if (e.action == 'create' || e.action == 'delete' || e.action == 'restore') {
      final m = (e.action == 'delete' ? e.before : e.after) ?? {};
      final keys = e.kind == 'voucher' ? [..._entryFields, if (single) 'postings'] : m.keys.toList();
      for (final f in keys) {
        if (m[f] == null || '${m[f]}'.isEmpty) continue;
        rows.add(TableRow(children: [
          Padding(padding: const EdgeInsets.only(right: 10, bottom: 3), child: Text(label(f), style: small)),
          Padding(
            padding: const EdgeInsets.only(bottom: 3),
            child: Text(show(f, m[f]),
                style: e.action == 'delete' ? val.copyWith(decoration: TextDecoration.lineThrough, color: scheme.onSurfaceVariant) : val),
          ),
        ]));
      }
    }
    final diff = e.legacy
        ? <(String, String?, String?)>[for (final f in e.before?.keys ?? const <String>[]) (f, '${e.before![f] ?? ''}', null)]
        : AuditLog.diff(e.before, e.after);
    final isChange = const {'edit', 'status', 'hide', 'unhide'}.contains(e.action);

    Widget badge(String text, Color c, {IconData? i}) => Container(
          margin: const EdgeInsets.only(top: 6, right: 6),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(color: c.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(20), border: Border.all(color: c.withValues(alpha: 0.5))),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            if (i != null) ...[Icon(i, size: 13, color: c), const SizedBox(width: 4)],
            Flexible(child: Text(text, style: TextStyle(fontSize: 12, color: c, fontWeight: FontWeight.w700))),
          ]),
        );

    final vdate = e.row['vdate'] as String? ?? (e.after ?? e.before)?['date'] as String?;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: color.withValues(alpha: 0.35))),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        // the whole story of this entry / account / item
        onTap: single ? null : () => Navigator.push(context, MaterialPageRoute(builder: (_) => AuditScreen(voucherId: e.recordId))),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            // action · who · exact time
            Row(children: [
              Icon(icon, size: 18, color: color),
              const SizedBox(width: 6),
              Text(actionText, style: TextStyle(color: color, fontWeight: FontWeight.w800)),
              Text('  ·  ${e.user}', style: const TextStyle(fontWeight: FontWeight.w600)),
              const Spacer(),
              Text(_fmt(e.at), style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant, fontFeatures: const [FontFeature.tabularFigures()])),
            ]),
            const SizedBox(height: 4),
            Text(_title(e, t), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15.5)),
            if (e.kind == 'voucher' && vdate != null)
              Text(
                '${t('audit_bill_date')}: ${shortDate(vdate)}'
                '${e.row['v_created'] != null ? '  ·  ${t('audit_entry_made')}: ${_fmt(_time(e.row['v_created'] as String?))}${e.row['v_by'] != null ? ' (${e.row['v_by']})' : ''}' : ''}',
                style: small,
              ),
            if (rows.isNotEmpty) ...[
              const SizedBox(height: 6),
              Table(columnWidths: const {0: IntrinsicColumnWidth(), 1: FlexColumnWidth()}, children: rows),
            ],
            if (isChange && diff.isNotEmpty) ...[
              const SizedBox(height: 6),
              Table(
                columnWidths: const {0: IntrinsicColumnWidth(), 1: FlexColumnWidth(), 2: FlexColumnWidth()},
                border: TableBorder(horizontalInside: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.5))),
                children: [
                  TableRow(children: [
                    const SizedBox(),
                    Padding(padding: const EdgeInsets.only(bottom: 3), child: Text(t('audit_before'), style: small)),
                    Padding(padding: const EdgeInsets.only(bottom: 3), child: Text(t('audit_after'), style: small)),
                  ]),
                  for (final (f, b, a) in diff)
                    if (single || f != 'postings' || diff.length == 1)
                      TableRow(children: [
                        Padding(padding: const EdgeInsets.fromLTRB(0, 4, 10, 4), child: Text(label(f), style: small)),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(0, 4, 8, 4),
                          child: Text(show(f, b), style: val.copyWith(color: AppColors.due, decoration: e.legacy ? null : TextDecoration.lineThrough)),
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Text(e.legacy ? '' : show(f, a), style: val.copyWith(color: AppColors.paid, fontWeight: FontWeight.w700)),
                        ),
                      ]),
                ],
              ),
            ],
            // what happened later – right where the entry was made
            Wrap(children: [
              if (deletedLater != null)
                badge('${t('audit_deleted_later')}: ${_fmt(deletedLater.at)} · ${deletedLater.user}', AppColors.due, i: Icons.delete),
              if (editsLater > 0) badge(t('audit_edited_later').replaceAll('{n}', '$editsLater'), AppColors.haldi, i: Icons.edit),
            ]),
            if (e.server != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  '${t('audit_server_time')}: ${_fmt(e.server)}${clockOff ? '  ⚠ ${t('audit_clock_off')}' : ''}',
                  style: TextStyle(fontSize: 11, color: clockOff ? AppColors.due : scheme.onSurfaceVariant),
                ),
              ),
            if (single && e.kind == 'voucher' && e.action != 'delete' && e.row['v_deleted'] == 0 && e == story.last)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  icon: const Icon(Icons.open_in_new, size: 16),
                  label: Text(t('audit_open_entry')),
                  onPressed: () => VoucherScreen.edit(context, e.recordId),
                ),
              ),
          ]),
        ),
      ),
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
