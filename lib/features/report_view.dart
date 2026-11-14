import 'package:flutter/material.dart';

import 'check_lists_screen.dart';
import 'health_screen.dart';
import 'item_pnl_sheet.dart';
import '../accounting/models.dart';
import '../accounting/reports.dart';
import '../core/money.dart';
import '../shared/export.dart';
import '../shared/widgets.dart';
import '../state/app_controller.dart';
import 'parties_screen.dart';
import 'review_screen.dart';
import 'booking_screen.dart';
import 'interest_screen.dart';
import 'staff_screen.dart';
import 'promise_screen.dart';
import 'voucher_screen.dart';

/// Shows any ReportTable with search, sort (tap a heading) and PDF / Excel /
/// Print – the exports follow the same search and sort.
class ReportView extends StatefulWidget {
  final Future<ReportTable> Function() load;
  final VoidCallback? onEdit;
  /// What tapping a row opens: vouchers (default) or ledgers.
  final bool rowsAreLedgers;
  const ReportView({super.key, required this.load, this.onEdit, this.rowsAreLedgers = false});
  @override
  State<ReportView> createState() => _ReportViewState();
}

class _ReportViewState extends State<ReportView> {
  final query = TextEditingController();
  int? sortCol;
  bool ascending = true;

  ReportTable _shape(ReportTable t) => shapeReport(t, query: query.text, sortCol: sortCol, ascending: ascending);

  void _sortBy(int col) => setState(() {
        if (sortCol == col) {
          // asc → desc → original order
          if (ascending) {
            ascending = false;
          } else {
            sortCol = null;
            ascending = true;
          }
        } else {
          sortCol = col;
          ascending = true;
        }
      });

  @override
  Widget build(BuildContext context) {
    final app = App.of(context);
    final t0 = app.t;
    return LiveBuilder<ReportTable>(
      load: widget.load,
      builder: (context, full) {
        final t = _shape(full);
        return Scaffold(
          appBar: AppBar(
            title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(t.title),
              if (t.subtitle.isNotEmpty) Text(t.subtitle, style: Theme.of(context).textTheme.bodySmall, maxLines: 2),
            ]),
            actions: [
              if (widget.onEdit != null) IconButton(icon: const Icon(Icons.edit), onPressed: widget.onEdit),
              IconButton(
                icon: const Icon(Icons.picture_as_pdf),
                tooltip: 'PDF',
                onPressed: () async => Exporter.sharePdf(_shape(await app.pdfTable(widget.load)), shop: app.pdfShopName),
              ),
              IconButton(
                icon: const Icon(Icons.table_chart),
                tooltip: 'Excel',
                onPressed: () => Exporter.shareExcel([t], t.title),
              ),
              IconButton(
                  icon: const Icon(Icons.print),
                  onPressed: () async => Exporter.printPdf(_shape(await app.pdfTable(widget.load)), shop: app.pdfShopName)),
            ],
          ),
          body: Column(children: [
            if (full.rows.length > 3)
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
                child: TextField(
                  key: const Key('report_search'),
                  controller: query,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    prefixIcon: const Icon(Icons.filter_list),
                    hintText: t0('report_filter_hint'),
                    isDense: true,
                    border: const OutlineInputBorder(),
                    suffixIcon: query.text.isEmpty
                        ? null
                        : IconButton(icon: const Icon(Icons.close), onPressed: () => setState(() => query.clear())),
                  ),
                ),
              ),
            Expanded(
              child: ReportTableView(
                table: t,
                sortCol: sortCol,
                ascending: ascending,
                onSort: _sortBy,
                onTapRow: (ref) async {
                  if (ref.startsWith('pnl:')) {
                    // an item in the profit reports: show how its profit was worked out
                    final p = ref.split(':');
                    await ItemPnlSheet.show(context, p[1], p.sublist(2).join(':'));
                  } else if (widget.rowsAreLedgers) {
                    final l = await app.ledgers.byId(ref);
                    if (l != null && context.mounted) KhataScreen.open(context, l.id);
                  } else {
                    final v = await app.db.getOptional('SELECT id FROM vouchers WHERE id = ?', [ref]);
                    if (v != null && context.mounted) VoucherScreen.edit(context, ref);
                  }
                },
              ),
            ),
          ]),
        );
      },
    );
  }
}

class ReportTableView extends StatelessWidget {
  final ReportTable table;
  final void Function(String ref)? onTapRow;
  final int? sortCol;
  final bool ascending;
  final void Function(int col)? onSort;
  const ReportTableView({super.key, required this.table, this.onTapRow, this.sortCol, this.ascending = true, this.onSort});

  @override
  Widget build(BuildContext context) {
    final t = table;
    final w = MediaQuery.of(context).size.width;
    // each column: ~34px per flex, never under 52px (so "पान नं." / "दिवस" stay on one line);
    // stretched to fill a wide screen
    final base = [for (final c in t.columns) c.flex * 34.0 < 52 ? 52.0 : c.flex * 34.0];
    final baseSum = base.fold<double>(0, (s, x) => s + x) + 16;
    final scale = w > baseSum ? (w - 16) / (baseSum - 16) : 1.0;
    final colW = [for (final b in base) b * scale];
    final width = baseSum > w ? baseSum : w;
    TextAlign al(int i) => t.columns[i].align == ColAlign.right ? TextAlign.right : TextAlign.left;
    Widget row(List<String> cells, {TextStyle? style, Color? bg, VoidCallback? onTap}) => InkWell(
          onTap: onTap,
          child: Container(
            color: bg,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              for (var i = 0; i < t.columns.length; i++)
                SizedBox(
                  width: colW[i],
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 3),
                    child: Text(i < cells.length ? cells[i] : '', textAlign: al(i), style: style),
                  ),
                ),
            ]),
          ),
        );
    const bold = TextStyle(fontWeight: FontWeight.bold);
    final scheme = Theme.of(context).colorScheme;
    // headings: tap to sort, arrow on the sorted column
    final header = Container(
      color: scheme.surfaceContainerHigh,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(children: [
        for (var i = 0; i < t.columns.length; i++)
          SizedBox(
            width: colW[i],
            child: InkWell(
              key: Key('report_sort_$i'),
              onTap: onSort == null ? null : () => onSort!(i),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 9),
                child: Row(
                  mainAxisAlignment: t.columns[i].align == ColAlign.right ? MainAxisAlignment.end : MainAxisAlignment.start,
                  children: [
                    Flexible(child: Text(t.columns[i].title, style: bold, textAlign: al(i))),
                    // only the sorted column shows an arrow (keeps narrow columns readable)
                    if (sortCol == i) Icon(ascending ? Icons.arrow_upward : Icons.arrow_downward, size: 14, color: scheme.primary),
                  ],
                ),
              ),
            ),
          ),
      ]),
    );
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: SizedBox(
        width: width,
        child: Column(children: [
          header,
          Expanded(
            child: t.rows.isEmpty
                ? Center(child: Text(App.of(context).t('no_entries')))
                : ListView.separated(
                    itemCount: t.rows.length,
                    separatorBuilder: (_, __) => Divider(height: 1, color: scheme.outlineVariant.withValues(alpha: 0.5)),
                    itemBuilder: (_, r) => row(
                      t.rows[r],
                      bg: t.highlight.contains(r) ? scheme.tertiaryContainer.withValues(alpha: 0.5) : null,
                      onTap: t.rowRefs[r] == null || onTapRow == null ? null : () => onTapRow!(t.rowRefs[r]!),
                    ),
                  ),
          ),
          if (t.totals != null) row(t.totals!, style: bold, bg: scheme.surfaceContainerHigh),
        ]),
      ),
    );
  }
}

/// Report menu with a period selector.
class ReportsScreen extends StatefulWidget {
  const ReportsScreen({super.key});
  @override
  State<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends State<ReportsScreen> {
  late String from = todayIso();
  late String to = todayIso();
  String preset = 'today';

  void _preset(String p) {
    final now = DateTime.now();
    setState(() {
      preset = p;
      to = todayIso();
      from = switch (p) {
        'today' => todayIso(),
        'month' => isoDate(DateTime(now.year, now.month, 1)),
        _ => fyStart(todayIso()),
      };
    });
  }

  @override
  Widget build(BuildContext context) {
    final app = App.of(context);
    final t = app.t;
    final r = app.reports;
    final owner = app.actor.isOwner;
    void open(Future<ReportTable> Function() load, {bool ledgers = false}) => Navigator.push(
        context, MaterialPageRoute(builder: (_) => ReportView(load: load, rowsAreLedgers: ledgers)));

    Future<void> moneyBook(List<LedgerGroup> groups, String title) async {
      final accts = await app.ledgers.list(groups);
      open(() => r.moneyBook(accts.map((a) => a.id).toList(), title, from, to));
    }

    final items = <(IconData, String, VoidCallback, bool)>[
      (Icons.event_available, t('promises'), () => PromisesScreen.open(context), false),
      (Icons.fact_check, t('review'), () => ReviewScreen.open(context), true),
      (Icons.verified_outlined, t('health'), () => HealthScreen.open(context), true),
      (Icons.flag_outlined, t('recheck_list'), () => RecheckScreen.open(context), false),
      (Icons.rule, t('old_mismatch_list'), () => OldMismatchScreen.open(context), false),
      (Icons.today, t('r_daybook'), () => open(() => r.dayBook(from, to)), false),
      (Icons.local_shipping_outlined, t('r_charges'), () => open(() => r.chargesRegister(from, to)), false),
      (Icons.payments, t('r_cashbook'), () => moneyBook([LedgerGroup.cash], t('r_cashbook')), false),
      (Icons.calculate_outlined, t('r_cash_diff'), () => open(() => r.ledgerStatement(app.vouchers.sys('cash_diff'), from: from, to: to)), false),
      (Icons.account_balance, t('r_upibook'), () => moneyBook([LedgerGroup.upi, LedgerGroup.bank], t('r_upibook')), true),
      (Icons.people, t('r_receivable'), () => open(() => r.outstanding(LedgerGroup.customer), ledgers: true), true),
      (Icons.local_shipping, t('r_payable'), () => open(() => r.outstanding(LedgerGroup.supplier), ledgers: true), true),
      (Icons.inventory_2_outlined, t('r_goods_owed'), () => open(() => r.goodsOwed(), ledgers: true), false),
      (Icons.percent, t('interest_list'), () => InterestListScreen.open(context), true),
      (Icons.bookmark_added_outlined, t('bookings'), () => BookingsScreen.open(context), false),
      (Icons.badge_outlined, t('r_staff_advance'), () => StaffScreen.open(context), true),
      (Icons.menu_book, t('r_ledger'), () async {
        // staff: one party's khata only – not bank, capital or expense totals
        final l = await pickLedger(context,
            groups: owner ? LedgerGroup.values : const [LedgerGroup.customer, LedgerGroup.supplier, LedgerGroup.transporter]);
        if (l != null) open(() => r.ledgerStatement(l.id, from: from, to: to));
      }, false),
      (Icons.inventory_2, t('r_stock'), () => open(() => r.stockSummary()), true),
      (Icons.point_of_sale, t('r_sales'), () => open(() => r.register(VoucherType.sale, from, to)), true),
      (Icons.shopping_cart, t('r_purchases'), () => open(() => r.register(VoucherType.purchase, from, to)), true),
      (Icons.receipt_long, t('r_expenses'), () => open(() => r.expenseSummary(from, to), ledgers: true), true),
      (Icons.receipt, t('r_gst_bills'), () => open(() => r.gstBillsNeeded(from, to)), true),
      (Icons.percent, t('r_gst_summary'), () => open(() => r.gstSummary(from, to)), true),
      (Icons.request_quote, t('r_gst'), () => open(() => r.gstLedger(from, to)), true),
      (Icons.trending_up, t('r_item_profit'), () => open(() => r.itemProfit(from, to)), true),
      (Icons.category_outlined, t('r_cat_profit'), () => open(() => r.categoryProfit(to)), true),
      (Icons.price_check, t('r_pnl_proof'), () => open(() => r.profitProof(to)), true),
      (Icons.inventory_outlined, t('r_stock_costing'), () => open(() => r.stockCosting(to)), true),
      (Icons.balance, t('r_pnl'), () => open(() => r.profitAndLoss(from, to)), true),
      (Icons.list_alt, t('r_trial'), () => open(() => r.trialBalance(to)), true),
      (Icons.account_balance_wallet, t('r_bs'), () => open(() => r.balanceSheet(to)), true),
    ];
    return Scaffold(
      appBar: AppBar(title: Text(t('reports'))),
      body: ListView(children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
            for (final (k, l) in [('today', t('today')), ('month', t('this_month')), ('fy', t('this_fy'))])
              ChoiceChip(label: Text(l), selected: preset == k, onSelected: (_) => _preset(k)),
            ActionChip(
              avatar: const Icon(Icons.date_range, size: 18),
              label: Text('${shortDate(from)} – ${shortDate(to)}'),
              onPressed: () async {
                final res = await showDateRangePicker(
                  context: context,
                  firstDate: DateTime(2015),
                  lastDate: DateTime.now().add(const Duration(days: 365)),
                  initialDateRange: DateTimeRange(start: parseIso(from), end: parseIso(to)),
                );
                if (res != null) {
                  setState(() {
                    preset = '';
                    from = isoDate(res.start);
                    to = isoDate(res.end);
                  });
                }
              },
            ),
          ]),
        ),
        for (final (icon, label, onTap, ownerOnly) in items)
          if (!ownerOnly || owner)
            ListTile(leading: Icon(icon), title: Text(label), trailing: const Icon(Icons.chevron_right), onTap: onTap)
          else
            ListTile(leading: Icon(icon, color: Colors.grey), title: Text(label), subtitle: Text(t('owner_only')), enabled: false),
        if (owner)
          ListTile(
            leading: const Icon(Icons.download),
            title: Text('${t('backup')} – ${t('all')}'),
            onTap: () async {
              final tables = [
                await r.dayBook(fyStart(to), to),
                await r.outstanding(LedgerGroup.customer),
                await r.outstanding(LedgerGroup.supplier),
                await r.stockSummary(),
                await r.trialBalance(to),
                await r.profitAndLoss(fyStart(to), to),
              ];
              await Exporter.shareExcel(tables, '${app.businessName}_${todayIso()}');
            },
          ),
      ]),
    );
  }
}
