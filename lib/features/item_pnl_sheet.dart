import 'package:flutter/material.dart';

import '../accounting/models.dart';
import '../accounting/stock_pnl.dart';
import '../core/money.dart';
import '../state/app_controller.dart';
import 'stock_screen.dart';

/// मालनिहाय नफा → tap an item: how its profit was worked out, step by step,
/// and – when something is missing – exactly what and how to fix it.
/// Read-only; the owner can open the item to fill in a missing rate.
class ItemPnlSheet {
  static Future<void> show(BuildContext context, String to, String itemId) async {
    final app = App.read(context);
    final t = app.t;
    final r = await StockPnlEngine(app.db, app.businessId!).compute(to);
    final i = r.items.where((x) => x.item.id == itemId).firstOrNull;
    if (i == null || !context.mounted) return;
    final it = i.item;
    // facts that help explain a missing cost
    final purchases = await app.db.getAll(
        "SELECT v.vdate, v.vtype, il.qty, il.rate FROM inventory_lines il JOIN vouchers v ON v.id = il.voucher_id "
        "WHERE il.item_id = ? AND il.deleted = 0 AND v.deleted = 0 AND (v.vtype = 'purchase' OR (v.vtype = 'history' AND v.pay_ledger_id = 'hist:purchase')) "
        'ORDER BY v.vdate DESC LIMIT 1',
        [itemId]);
    final lastBuy = purchases.firstOrNull;
    if (!context.mounted) return;
    final unit = t('unit_${it.unit}');
    String q(double x) => '${fmtQty(x)} $unit';
    String m(num x) => '₹${Money.fmt(x.round())}';
    final openRateUsed = i.openQty == 0 ? 0 : (i.openVal / i.openQty);

    final reasons = <(String, String)>[]; // why, what to do
    if (i.flags.contains('opening_rate_missing')) {
      reasons.add((
        t('pnl_why_open_rate')
            .replaceAll('{q}', q(i.openQty))
            .replaceAll('{r}', it.purchaseRate > 0 ? m(it.purchaseRate) : '₹0'),
        it.purchaseRate > 0 ? t('pnl_fix_open_rate') : t('pnl_fix_open_rate_zero'),
      ));
    }
    if (i.flags.contains('no_cost')) {
      reasons.add((
        t('pnl_why_no_cost').replaceAll('{q}', q(i.saleQty)).replaceAll('{r}', m(i.avg)),
        t('pnl_fix_no_cost'),
      ));
    }
    if (i.flags.contains('negative_stock')) {
      reasons.add((
        t('pnl_why_negative')
            .replaceAll('{have}', q(i.openQty + i.purQty))
            .replaceAll('{sold}', q(i.saleQty))
            .replaceAll('{short}', q(-i.closeQty)),
        t('pnl_fix_negative'),
      ));
    }
    if (i.cost == 0 && i.sales > 0 && reasons.isEmpty) {
      reasons.add((t('pnl_why_zero_cost'), t('pnl_fix_no_cost')));
    }

    Widget row(String label, String value, {bool bold = false, Color? color}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(flex: 3, child: Text(label, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant))),
            Expanded(
              flex: 2,
              child: Text(value,
                  textAlign: TextAlign.right, style: TextStyle(fontWeight: bold ? FontWeight.w800 : FontWeight.w600, color: color)),
            ),
          ]),
        );

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.85,
        maxChildSize: 0.95,
        builder: (ctx, scroll) => ListView(controller: scroll, padding: const EdgeInsets.fromLTRB(20, 0, 20, 24), children: [
          Text(it.name, style: Theme.of(ctx).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
          Text('${shortDate(r.from)} – ${shortDate(r.to)}', style: Theme.of(ctx).textTheme.bodySmall),
          const SizedBox(height: 12),
          // what is missing, first
          for (final (why, fix) in reasons)
            Card(
              color: Colors.orange.withValues(alpha: 0.12),
              margin: const EdgeInsets.only(bottom: 10),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Icon(Icons.warning_amber_rounded, color: Colors.orange),
                    const SizedBox(width: 8),
                    Expanded(child: Text(why, style: const TextStyle(fontWeight: FontWeight.w600))),
                  ]),
                  const SizedBox(height: 6),
                  Text('→ $fix'),
                ]),
              ),
            ),
          if (reasons.isEmpty)
            Card(
              color: Colors.green.withValues(alpha: 0.10),
              margin: const EdgeInsets.only(bottom: 10),
              child: Padding(padding: const EdgeInsets.all(12), child: Text('✓ ${t('pnl_item_ok')}')),
            ),
          // the working, line by line
          Text(t('pnl_working'), style: const TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          row(t('opening_stock'), '${q(i.openQty)} · ${m(i.openVal)}'),
          if (i.openQty != 0)
            row(
                '   ${t('pnl_rate_used')}',
                it.openingRate > 0
                    ? '${m(openRateUsed)} (${t('pnl_rate_opening')})'
                    : '${m(openRateUsed)} (${t('pnl_rate_purchase_master')})'),
          row('+ ${t('pnl_bought_books')}', '${q(i.purQty)} · ${m(i.purVal)}'),
          if (i.discR != 0) row('− ${t('pnl_disc')}', m(i.discR)),
          row('= ${t('pnl_available')}', '${q(i.openQty + i.purQty)} · ${m(i.openVal + i.netPur)}'),
          row('   ${t('pnl_unit_cost')}', m(i.avg)),
          if (i.adjQty != 0) row(t('stock_adjust'), q(i.adjQty)),
          row('− ${t('closing_stock')}', '${q(i.closeQty)} · ${m(i.closeVal)}'),
          const Divider(),
          row(t('pnl_cost'), m(i.cost), bold: true),
          row('${t('sales')} (${q(i.saleQty)})', m(i.sales), bold: true),
          row(t('profit'), m(i.profit), bold: true, color: i.profit >= 0 ? Colors.green.shade700 : Colors.red.shade700),
          const Divider(),
          // useful facts
          row(t('pnl_master_purchase_rate'), it.purchaseRate > 0 ? m(it.purchaseRate) : t('pnl_not_set')),
          row(t('pnl_master_opening_rate'), it.openingRate > 0 ? m(it.openingRate) : t('pnl_not_set')),
          if (lastBuy != null)
            row(
                t('pnl_last_purchase'),
                '${m((lastBuy['rate'] as num?) ?? 0)} · ${shortDate(lastBuy['vdate'] as String)}'
                    '${lastBuy['vtype'] == 'history' ? ' (${t('old_entry_short')})' : ''}')
          else
            row(t('pnl_last_purchase'), t('pnl_none_entered')),
          const SizedBox(height: 14),
          if (app.actor.isOwner)
            FilledButton.icon(
              key: const Key('pnl_edit_item'),
              icon: const Icon(Icons.edit_outlined),
              label: Text(t('pnl_edit_item')),
              onPressed: () async {
                final fresh = await app.stock.byId(it.id) ?? it;
                if (!ctx.mounted) return;
                Navigator.pop(ctx);
                if (context.mounted) await ItemForm.open(context, existing: fresh);
              },
            ),
        ]),
      ),
    );
  }
}
