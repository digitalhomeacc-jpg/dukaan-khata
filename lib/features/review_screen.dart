import 'package:flutter/material.dart';

import '../accounting/models.dart';
import '../core/money.dart';
import '../core/theme.dart';
import '../shared/export.dart';
import '../shared/widgets.dart';
import '../state/app_controller.dart';
import 'parties_screen.dart';
import 'search_screen.dart' show VoucherTile;
import 'voucher_screen.dart';

/// नोंदी तपासा: go through a day (or a range) over the phone against the
/// paper books – summary, cash / PhonePe / bank flow, every account that
/// moved, stock moved, then entry by entry with a tick for each one checked.
class ReviewScreen extends StatefulWidget {
  const ReviewScreen({super.key});
  static Future<void> open(BuildContext context) => Navigator.push(context, MaterialPageRoute(builder: (_) => const ReviewScreen()));
  @override
  State<ReviewScreen> createState() => _ReviewScreenState();
}

class _Review {
  final List<(VoucherType, int, int)> byType; // type, count, amount
  final List<(Ledger, int, int, int, int)> money; // account, opening, in, out, closing
  final List<(String, String, String, int, int)> accounts; // id, name, group, debit, credit
  final List<(String, String, double, double)> stock; // item, unit, in, out
  final List<Voucher> entries;
  final Map<String, String> items; // voucher id → "M 10, सळई 8mm 50"
  _Review(this.byType, this.money, this.accounts, this.stock, this.entries, this.items);
}

class _ReviewScreenState extends State<ReviewScreen> {
  String from = todayIso(), to = todayIso();
  String preset = 'today';
  int tab = 0; // 0 summary · 1 accounts · 2 entries

  Future<_Review> _load(AppController app) async {
    final db = app.db, b = app.businessId;
    final types = await db.getAll(
        'SELECT vtype, COUNT(*) AS n, COALESCE(SUM(amount), 0) AS a FROM vouchers WHERE business_id = ? AND deleted = 0 '
        "AND vdate BETWEEN ? AND ? AND vtype NOT IN ('history', 'promise', 'recurring', 'recurring_pay', 'booking') "
        "AND COALESCE(status, '') NOT LIKE 'split:%' GROUP BY vtype ORDER BY n DESC",
        [b, from, to]);
    final moves = await db.getAll(
        'SELECT l.id, l.name, l.grp, SUM(vl.debit) AS d, SUM(vl.credit) AS c FROM voucher_lines vl JOIN ledgers l ON l.id = vl.ledger_id '
        'WHERE vl.business_id = ? AND vl.deleted = 0 AND vl.vdate BETWEEN ? AND ? GROUP BY l.id ORDER BY l.grp, l.name',
        [b, from, to]);
    final money = <(Ledger, int, int, int, int)>[];
    for (final a in await app.ledgers.list([LedgerGroup.cash, LedgerGroup.upi, LedgerGroup.bank])) {
      final m = moves.where((r) => r['id'] == a.id).firstOrNull;
      final open = await app.ledgers.balanceAt(a.id, date: from, before: true);
      final i = ((m?['d'] as num?) ?? 0).toInt(), o = ((m?['c'] as num?) ?? 0).toInt();
      if (open == 0 && i == 0 && o == 0) continue;
      money.add((a, open, i, o, open + i - o));
    }
    final stock = await db.getAll(
        'SELECT i.name, i.unit, SUM(CASE WHEN il.direction > 0 THEN il.qty ELSE 0 END) AS qi, '
        'SUM(CASE WHEN il.direction < 0 THEN il.qty ELSE 0 END) AS qo FROM inventory_lines il JOIN items i ON i.id = il.item_id '
        'WHERE il.business_id = ? AND il.deleted = 0 AND il.direction <> 0 AND il.vdate BETWEEN ? AND ? GROUP BY i.id ORDER BY i.sort_order, i.name',
        [b, from, to]);
    final entries = (await app.ledgers.dayBook(from, to)).where((v) => !(v.status ?? '').startsWith('split:')).toList();
    final items = <String, String>{};
    for (final r in await db.getAll(
        'SELECT il.voucher_id, GROUP_CONCAT(i.name || \' \' || il.qty, \', \') AS s FROM inventory_lines il JOIN items i ON i.id = il.item_id '
        'WHERE il.business_id = ? AND il.deleted = 0 AND il.vdate BETWEEN ? AND ? GROUP BY il.voucher_id',
        [b, from, to])) {
      items[r['voucher_id'] as String] = '${r['s']}'.replaceAllMapped(RegExp(r'(\d+)\.0(?=,|$)'), (m) => m[1]!);
    }
    return _Review(
      [for (final r in types) (VoucherType.fromCode(r['vtype'] as String), r['n'] as int, (r['a'] as num).toInt())],
      money,
      [
        for (final r in moves)
          if (!const {'cash', 'upi', 'bank'}.contains(r['grp']))
            (r['id'] as String, r['name'] as String, r['grp'] as String, (r['d'] as num).toInt(), (r['c'] as num).toInt()),
      ],
      [for (final r in stock) ('${r['name']}', '${r['unit']}', (r['qi'] as num).toDouble(), (r['qo'] as num).toDouble())],
      entries,
      items,
    );
  }

  void _preset(String p) {
    final now = DateTime.now();
    setState(() {
      preset = p;
      switch (p) {
        case 'today':
          from = to = todayIso();
        case 'yesterday':
          from = to = isoDate(now.subtract(const Duration(days: 1)));
        case 'week':
          from = isoDate(now.subtract(Duration(days: now.weekday - 1)));
          to = todayIso();
        case 'month':
          from = isoDate(DateTime(now.year, now.month, 1));
          to = todayIso();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final app = App.of(context);
    final t = app.t;
    return Scaffold(
      appBar: AppBar(
        title: Text(t('review')),
        actions: [
          IconButton(
            tooltip: 'PDF',
            icon: const Icon(Icons.picture_as_pdf),
            onPressed: () async => Exporter.sharePdf(await app.pdfTable(() => app.reports.dayBook(from, to)), shop: app.pdfShopName),
          ),
        ],
      ),
      body: Column(children: [
        // which days
        SizedBox(
          height: 48,
          child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.fromLTRB(8, 6, 8, 0), children: [
            for (final p in const ['today', 'yesterday', 'week', 'month'])
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: ChoiceChip(label: Text(t('rv_$p')), selected: preset == p, onSelected: (_) => _preset(p)),
              ),
            ChoiceChip(
              key: const Key('rv_range'),
              avatar: const Icon(Icons.date_range, size: 18),
              label: Text(preset == 'custom' ? (from == to ? shortDate(from) : '${shortDate(from)} – ${shortDate(to)}') : t('rv_pick')),
              selected: preset == 'custom',
              onSelected: (_) async {
                final r = await showDateRangePicker(
                  context: context,
                  firstDate: DateTime(2015),
                  lastDate: DateTime.now().add(const Duration(days: 1)),
                  initialDateRange: DateTimeRange(start: parseIso(from), end: parseIso(to)),
                );
                if (r != null) {
                  setState(() {
                    preset = 'custom';
                    from = isoDate(r.start);
                    to = isoDate(r.end);
                  });
                }
              },
            ),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
          child: SegmentedButton<int>(
            segments: [
              ButtonSegment(value: 0, label: Text(t('rv_summary'))),
              ButtonSegment(value: 1, label: Text(t('rv_accounts'))),
              ButtonSegment(value: 2, label: Text(t('rv_entries'))),
            ],
            selected: {tab},
            onSelectionChanged: (s) => setState(() => tab = s.first),
          ),
        ),
        Expanded(
          child: LiveBuilder<_Review>(
            reloadKey: '$from|$to',
            load: () => _load(app),
            builder: (context, r) => switch (tab) {
              0 => _summary(app, r),
              1 => _accounts(app, r),
              _ => _entries(app, r),
            },
          ),
        ),
      ]),
    );
  }

  Widget _money(int v, {Color? color, bool bold = false}) => Text(Money.fmt(v),
      style: TextStyle(color: color, fontWeight: bold ? FontWeight.w800 : FontWeight.w600, fontFeatures: const [FontFeature.tabularFigures()]));

  Widget _summary(AppController app, _Review r) {
    final t = app.t;
    final head = Theme.of(context).textTheme.titleSmall?.copyWith(color: Theme.of(context).colorScheme.primary, fontWeight: FontWeight.w700);
    return ListView(padding: const EdgeInsets.fromLTRB(12, 4, 12, 24), children: [
      Text('${r.entries.length} ${t('rv_n_entries')} · ${from == to ? shortDate(from) : '${shortDate(from)} – ${shortDate(to)}'}',
          style: Theme.of(context).textTheme.bodySmall),
      const SizedBox(height: 6),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(t('rv_by_type'), style: head),
            const SizedBox(height: 6),
            if (r.byType.isEmpty) Text(t('no_entries')),
            for (final (type, n, a) in r.byType)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(children: [
                  Icon(VoucherTile.iconFor(type), size: 18, color: VoucherTile.colorFor(type)),
                  const SizedBox(width: 8),
                  Expanded(child: Text('${t('vt_${type.code}')} × $n')),
                  if (!type.isGoodsLoan && type != VoucherType.stockAdjust) _money(a),
                ]),
              ),
          ]),
        ),
      ),
      // cash / PhonePe / bank: opening + in − out = closing
      Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(t('rv_money'), style: head),
            const SizedBox(height: 6),
            Row(children: [
              const Expanded(flex: 3, child: SizedBox()),
              for (final h in [t('opening'), '+ ${t('inflow')}', '− ${t('outflow')}', t('closing')])
                Expanded(flex: 2, child: Text(h, textAlign: TextAlign.right, style: Theme.of(context).textTheme.bodySmall)),
            ]),
            for (final (a, o, i, out, c) in r.money)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(children: [
                  Expanded(flex: 3, child: Text(a.display(app.english), maxLines: 1, overflow: TextOverflow.ellipsis)),
                  Expanded(flex: 2, child: Align(alignment: Alignment.centerRight, child: FittedBox(child: _money(o)))),
                  Expanded(flex: 2, child: Align(alignment: Alignment.centerRight, child: FittedBox(child: _money(i, color: AppColors.paid)))),
                  Expanded(flex: 2, child: Align(alignment: Alignment.centerRight, child: FittedBox(child: _money(out, color: AppColors.due)))),
                  Expanded(flex: 2, child: Align(alignment: Alignment.centerRight, child: FittedBox(child: _money(c, bold: true)))),
                ]),
              ),
          ]),
        ),
      ),
      if (r.stock.isNotEmpty)
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(t('rv_stock'), style: head),
              const SizedBox(height: 6),
              Row(children: [
                const Expanded(flex: 4, child: SizedBox()),
                Expanded(flex: 2, child: Text(t('in'), textAlign: TextAlign.right, style: Theme.of(context).textTheme.bodySmall)),
                Expanded(flex: 2, child: Text(t('out'), textAlign: TextAlign.right, style: Theme.of(context).textTheme.bodySmall)),
              ]),
              for (final (name, unit, qi, qo) in r.stock)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(children: [
                    Expanded(flex: 4, child: Text('$name (${t('unit_$unit')})', maxLines: 1, overflow: TextOverflow.ellipsis)),
                    Expanded(flex: 2, child: Text(qi == 0 ? '' : fmtQty(qi), textAlign: TextAlign.right, style: const TextStyle(color: AppColors.paid))),
                    Expanded(flex: 2, child: Text(qo == 0 ? '' : fmtQty(qo), textAlign: TextAlign.right, style: const TextStyle(color: AppColors.due))),
                  ]),
                ),
            ]),
          ),
        ),
    ]);
  }

  Widget _accounts(AppController app, _Review r) {
    final t = app.t;
    final scheme = Theme.of(context).colorScheme;
    String? lastGroup;
    final children = <Widget>[];
    var td = 0, tc = 0;
    for (final (id, name, grp, d, c) in r.accounts) {
      if (grp != lastGroup) {
        children.add(Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
          child: Text(t('grp_$grp'), style: Theme.of(context).textTheme.titleSmall?.copyWith(color: scheme.primary, fontWeight: FontWeight.w700)),
        ));
        lastGroup = grp;
      }
      td += d;
      tc += c;
      children.add(ListTile(
        dense: true,
        title: Text(name),
        subtitle: d != 0 && c != 0 ? Text('${t('rv_net')}: ${Money.fmt((d - c).abs())} ${d >= c ? t('dr_short') : t('cr_short')}') : null,
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          SizedBox(width: 92, child: Align(alignment: Alignment.centerRight, child: d == 0 ? const SizedBox() : _money(d, color: AppColors.due))),
          SizedBox(width: 92, child: Align(alignment: Alignment.centerRight, child: c == 0 ? const SizedBox() : _money(c, color: AppColors.paid))),
        ]),
        onTap: () => KhataScreen.open(context, id),
      ));
    }
    return ListView(padding: const EdgeInsets.only(bottom: 24), children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
        child: Row(children: [
          Expanded(child: Text(t('rv_accounts_help'), style: Theme.of(context).textTheme.bodySmall)),
          SizedBox(width: 92, child: Text(t('debit_given'), textAlign: TextAlign.right, style: Theme.of(context).textTheme.bodySmall)),
          SizedBox(width: 92, child: Text(t('credit_got'), textAlign: TextAlign.right, style: Theme.of(context).textTheme.bodySmall)),
          const SizedBox(width: 8),
        ]),
      ),
      ...children,
      if (r.accounts.isNotEmpty)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 24, 0),
          child: Row(children: [
            Expanded(child: Text(t('total'), style: const TextStyle(fontWeight: FontWeight.w800))),
            _money(td, bold: true),
            const SizedBox(width: 16),
            _money(tc, bold: true),
          ]),
        ),
    ]);
  }

  Widget _entries(AppController app, _Review r) {
    final t = app.t;
    final done = r.entries.where((v) => app.prefInt('rv_${v.id}', 0) == 1).length;
    final scheme = Theme.of(context).colorScheme;
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 6),
        child: Row(children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                  value: r.entries.isEmpty ? 0 : done / r.entries.length, minHeight: 8, backgroundColor: scheme.surfaceContainerHighest),
            ),
          ),
          const SizedBox(width: 10),
          Text(t('rv_checked').replaceAll('{a}', '$done').replaceAll('{n}', '${r.entries.length}'),
              style: const TextStyle(fontWeight: FontWeight.w700)),
        ]),
      ),
      Expanded(
        child: r.entries.isEmpty
            ? Center(child: Text(t('no_entries')))
            : ListView.builder(
                padding: const EdgeInsets.only(bottom: 24),
                itemCount: r.entries.length,
                itemBuilder: (_, i) {
                  final v = r.entries[i];
                  final ok = app.prefInt('rv_${v.id}', 0) == 1;
                  return Card(
                    margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                    color: ok ? Color.alphaBlend(AppColors.paid.withValues(alpha: 0.08), Theme.of(context).cardTheme.color!) : null,
                    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Expanded(
                        child: InkWell(
                          onTap: () => VoucherScreen.edit(context, v.id),
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            VoucherTile(v),
                            if (r.items[v.id] case final s?)
                              Padding(
                                padding: const EdgeInsets.fromLTRB(72, 0, 12, 8),
                                child: Text(s, style: Theme.of(context).textTheme.bodySmall),
                              ),
                            if ((v.narration ?? '').isNotEmpty && v.partyName != null)
                              Padding(
                                padding: const EdgeInsets.fromLTRB(72, 0, 12, 8),
                                child: Text(v.narration!, style: Theme.of(context).textTheme.bodySmall),
                              ),
                          ]),
                        ),
                      ),
                      // ✓ checked against the paper book (kept on this phone)
                      Checkbox(
                        key: Key('rv_check_${v.id}'),
                        value: ok,
                        activeColor: AppColors.paid,
                        onChanged: (x) => app.setPrefInt('rv_${v.id}', x == true ? 1 : 0),
                      ),
                    ]),
                  );
                },
              ),
      ),
    ]);
  }
}
