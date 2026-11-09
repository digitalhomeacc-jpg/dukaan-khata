import 'package:flutter/material.dart';

import '../accounting/models.dart';
import '../accounting/reports.dart';
import '../core/money.dart';
import '../shared/export.dart';
import '../shared/widgets.dart';
import '../state/app_controller.dart';
import 'parties_screen.dart';
import 'promise_screen.dart';
import 'voucher_screen.dart';

/// Shows any ReportTable with PDF / Excel / Print buttons.
class ReportView extends StatelessWidget {
  final Future<ReportTable> Function() load;
  final VoidCallback? onEdit;
  /// What tapping a row opens: vouchers (default) or ledgers.
  final bool rowsAreLedgers;
  const ReportView({super.key, required this.load, this.onEdit, this.rowsAreLedgers = false});

  @override
  Widget build(BuildContext context) {
    final app = App.of(context);
    return LiveBuilder<ReportTable>(
      load: load,
      builder: (context, t) => Scaffold(
        appBar: AppBar(
          title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(t.title),
            if (t.subtitle.isNotEmpty) Text(t.subtitle, style: Theme.of(context).textTheme.bodySmall, maxLines: 2),
          ]),
          actions: [
            if (onEdit != null) IconButton(icon: const Icon(Icons.edit), onPressed: onEdit),
            IconButton(
              icon: const Icon(Icons.picture_as_pdf),
              tooltip: 'PDF',
              onPressed: () => Exporter.sharePdf(t, shop: app.businessName),
            ),
            IconButton(
              icon: const Icon(Icons.table_chart),
              tooltip: 'Excel',
              onPressed: () => Exporter.shareExcel([t], t.title),
            ),
            IconButton(icon: const Icon(Icons.print), onPressed: () => Exporter.printPdf(t, shop: app.businessName)),
          ],
        ),
        body: ReportTableView(
          table: t,
          onTapRow: (ref) async {
            if (rowsAreLedgers) {
              final l = await app.ledgers.byId(ref);
              if (l != null && context.mounted) KhataScreen.open(context, l.id);
            } else {
              final v = await app.db.getOptional('SELECT id FROM vouchers WHERE id = ?', [ref]);
              if (v != null && context.mounted) VoucherScreen.edit(context, ref);
            }
          },
        ),
      ),
    );
  }
}

class ReportTableView extends StatelessWidget {
  final ReportTable table;
  final void Function(String ref)? onTapRow;
  const ReportTableView({super.key, required this.table, this.onTapRow});

  @override
  Widget build(BuildContext context) {
    final t = table;
    final w = MediaQuery.of(context).size.width;
    final totalFlex = t.columns.fold<int>(0, (s, c) => s + c.flex);
    final minWidth = totalFlex * 38.0;
    final width = w > minWidth ? w : minWidth;
    TextAlign al(int i) => t.columns[i].align == ColAlign.right ? TextAlign.right : TextAlign.left;
    Widget row(List<String> cells, {TextStyle? style, Color? bg, VoidCallback? onTap}) => InkWell(
          onTap: onTap,
          child: Container(
            color: bg,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              for (var i = 0; i < t.columns.length; i++)
                Expanded(
                  flex: t.columns[i].flex,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 3),
                    child: Text(i < cells.length ? cells[i] : '', textAlign: al(i), style: style),
                  ),
                ),
            ]),
          ),
        );
    const bold = TextStyle(fontWeight: FontWeight.bold);
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: SizedBox(
        width: width,
        child: Column(children: [
          row([for (final c in t.columns) c.title], style: bold, bg: Theme.of(context).colorScheme.surfaceContainerHigh),
          Expanded(
            child: t.rows.isEmpty
                ? Center(child: Text(App.of(context).t('no_entries')))
                : ListView.separated(
                    itemCount: t.rows.length,
                    separatorBuilder: (_, __) => Divider(height: 1, color: Theme.of(context).colorScheme.outlineVariant.withValues(alpha: 0.5)),
                    itemBuilder: (_, r) => row(
                      t.rows[r],
                      bg: t.highlight.contains(r) ? Theme.of(context).colorScheme.tertiaryContainer.withValues(alpha: 0.5) : null,
                      onTap: t.rowRefs[r] == null || onTapRow == null ? null : () => onTapRow!(t.rowRefs[r]!),
                    ),
                  ),
          ),
          if (t.totals != null) row(t.totals!, style: bold, bg: Theme.of(context).colorScheme.surfaceContainerHigh),
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
      (Icons.today, t('r_daybook'), () => open(() => r.dayBook(from, to)), false),
      (Icons.payments, t('r_cashbook'), () => moneyBook([LedgerGroup.cash], t('r_cashbook')), false),
      (Icons.calculate_outlined, t('r_cash_diff'), () => open(() => r.ledgerStatement(app.vouchers.sys('cash_diff'), from: from, to: to)), false),
      (Icons.account_balance, t('r_upibook'), () => moneyBook([LedgerGroup.upi, LedgerGroup.bank], t('r_upibook')), false),
      (Icons.people, t('r_receivable'), () => open(() => r.outstanding(LedgerGroup.customer), ledgers: true), false),
      (Icons.local_shipping, t('r_payable'), () => open(() => r.outstanding(LedgerGroup.supplier), ledgers: true), false),
      (Icons.inventory_2_outlined, t('r_goods_owed'), () => open(() => r.goodsOwed(), ledgers: true), false),
      (Icons.menu_book, t('r_ledger'), () async {
        final l = await pickLedger(context, groups: LedgerGroup.values);
        if (l != null) open(() => r.ledgerStatement(l.id, from: from, to: to));
      }, false),
      (Icons.inventory_2, t('r_stock'), () => open(() => r.stockSummary()), false),
      (Icons.point_of_sale, t('r_sales'), () => open(() => r.register(VoucherType.sale, from, to)), false),
      (Icons.shopping_cart, t('r_purchases'), () => open(() => r.register(VoucherType.purchase, from, to)), false),
      (Icons.receipt_long, t('r_expenses'), () => open(() => r.expenseSummary(from, to), ledgers: true), false),
      (Icons.receipt, t('r_gst_bills'), () => open(() => r.gstBillsNeeded(from, to)), true),
      (Icons.percent, t('r_gst_summary'), () => open(() => r.gstSummary(from, to)), true),
      (Icons.request_quote, t('r_gst'), () => open(() => r.gstLedger(from, to)), true),
      (Icons.trending_up, t('r_item_profit'), () => open(() => r.itemProfit(from, to)), true),
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
