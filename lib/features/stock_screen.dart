import 'package:flutter/material.dart';

import '../accounting/models.dart';
import '../accounting/reports.dart';
import '../core/money.dart';
import '../core/theme.dart';
import '../inventory/stock_repo.dart';
import '../shared/export.dart';
import '../shared/widgets.dart';
import '../state/app_controller.dart';
import 'report_view.dart';
import 'voucher_screen.dart';

const itemCategories = ['cement', 'steel', 'blocks', 'plumbing', 'sand', 'other', serviceCategory];
const itemUnits = ['bag', 'kg', 'nos', 'ft', 'ton', 'brass', 'ltr', 'sqft', 'job', 'day'];

class StockScreen extends StatelessWidget {
  const StockScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final app = App.of(context);
    final t = app.t;
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: Text(t('stock')),
          bottom: TabBar(tabs: [Tab(text: t('stock')), Tab(text: t('daily_register'))]),
          actions: [
            PopupMenuButton<String>(
              onSelected: (v) {
                switch (v) {
                  case 'purchase':
                    VoucherScreen.open(context, VoucherType.purchase);
                  case 'adjust':
                    VoucherScreen.open(context, VoucherType.stockAdjust);
                  case 'goods_out':
                    VoucherScreen.open(context, VoucherType.goodsOut);
                  case 'goods_in':
                    VoucherScreen.open(context, VoucherType.goodsIn);
                  case 'sret':
                    VoucherScreen.open(context, VoucherType.salesReturn);
                  case 'pret':
                    VoucherScreen.open(context, VoucherType.purchaseReturn);
                }
              },
              itemBuilder: (_) => [
                PopupMenuItem(value: 'purchase', child: Text(t('purchase'))),
                PopupMenuItem(value: 'sret', child: Text(t('sales_return'))),
                PopupMenuItem(value: 'pret', child: Text(t('purchase_return'))),
                PopupMenuItem(value: 'adjust', child: Text(t('stock_adjust'))),
                PopupMenuItem(value: 'goods_out', child: Text(t('goods_out'))),
                PopupMenuItem(value: 'goods_in', child: Text(t('goods_in'))),
              ],
            ),
          ],
        ),
        floatingActionButton: app.actor.isOwner
            ? Builder(builder: (context) {
                // only on the items tab – on the register it would cover the entries
                final tabs = DefaultTabController.of(context);
                return AnimatedBuilder(
                  animation: tabs.animation!,
                  builder: (context, _) => tabs.animation!.value > 0.5
                      ? const SizedBox.shrink()
                      : FloatingActionButton.extended(
                          heroTag: 'item_add',
                          icon: const Icon(Icons.add),
                          label: Text(t('new_item')),
                          onPressed: () => ItemForm.open(context),
                        ),
                );
              })
            : null,
        body: const TabBarView(children: [_ItemList(), DailyRegisterView()]),
      ),
    );
  }
}

/// Asks for a unit the standard list doesn't have (रेती: ट्रिप …).
Future<String?> askNewUnit(BuildContext context) {
  final t = App.read(context).t;
  final c = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(t('unit_new')),
      content: TextField(
          key: const Key('new_unit'),
          controller: c,
          autofocus: true,
          decoration: InputDecoration(hintText: t('unit_new_hint')),
          onSubmitted: (v) => Navigator.pop(ctx, v.trim())),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: Text(t('cancel'))),
        FilledButton(onPressed: () => Navigator.pop(ctx, c.text.trim()), child: Text(t('save'))),
      ],
    ),
  ).then((v) => v == null || v.isEmpty ? null : v);
}

/// Unit dropdown: standard units, the shop's own, and "+ new unit".
class UnitField extends StatefulWidget {
  final String value;
  final ValueChanged<String> onChanged;
  final InputDecoration decoration;
  const UnitField({super.key, required this.value, required this.onChanged, required this.decoration});
  @override
  State<UnitField> createState() => _UnitFieldState();
}

class _UnitFieldState extends State<UnitField> {
  List<String> units = itemUnits;

  @override
  void initState() {
    super.initState();
    App.read(context).stock.units(itemUnits).then((u) {
      if (mounted) setState(() => units = u);
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = App.of(context).t;
    final all = [...units, if (!units.contains(widget.value)) widget.value];
    return DropdownButtonFormField<String>(
      key: ValueKey('unit_${widget.value}_${all.length}'),
      initialValue: widget.value,
      isExpanded: true,
      decoration: widget.decoration,
      items: [
        for (final u in all) DropdownMenuItem(value: u, child: Text(t('unit_$u'))),
        DropdownMenuItem(value: '+', child: Text(t('unit_new'), style: TextStyle(color: Theme.of(context).colorScheme.primary))),
      ],
      onChanged: (v) async {
        if (v != '+') return widget.onChanged(v!);
        final n = await askNewUnit(context);
        if (n != null) {
          setState(() => units = [...units, if (!units.contains(n)) n]);
          widget.onChanged(n);
        } else {
          setState(() {}); // back to the old value
        }
      },
    );
  }
}

/// Stock list: search, grouped by category → optional subcategory; the owner
/// can long-press to select several items and change them together.
class _ItemList extends StatefulWidget {
  const _ItemList();
  @override
  State<_ItemList> createState() => _ItemListState();
}

class _ItemListState extends State<_ItemList> {
  final q = TextEditingController();
  final selected = <String>{};

  bool get selecting => selected.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final app = App.of(context);
    final t = app.t;
    final scheme = Theme.of(context).colorScheme;
    return LiveBuilder<List<Item>>(
      load: () => app.stock.list(),
      builder: (context, all) {
        final s = normalizeDigits(q.text.trim()).toLowerCase();
        final items = all
            .where((i) =>
                s.isEmpty ||
                i.name.toLowerCase().contains(s) ||
                (i.nameEn ?? '').toLowerCase().contains(s) ||
                (i.subcategory ?? '').toLowerCase().contains(s) ||
                (i.shortCode ?? '').toLowerCase() == s)
            .toList()
          ..sort((a, b) {
            final c = itemCategories.indexOf(a.category).compareTo(itemCategories.indexOf(b.category));
            if (c != 0) return c;
            // items without a subcategory first, then subcategories A–Z
            final sa = a.subcategory ?? '', sb = b.subcategory ?? '';
            if (sa != sb) return sa.isEmpty ? -1 : sb.isEmpty ? 1 : sa.compareTo(sb);
            return a.sortOrder.compareTo(b.sortOrder);
          });
        String? lastCat, lastSub;
        final children = <Widget>[];
        for (final i in items) {
          if (i.category != lastCat) {
            final group = items.where((x) => x.category == i.category).map((x) => x.id).toList();
            children.add(_groupHeader(t('cat_${i.category}'), group, big: true));
            lastCat = i.category;
            lastSub = null;
          }
          if (i.subcategory != null && i.subcategory != lastSub) {
            final group = items.where((x) => x.category == i.category && x.subcategory == i.subcategory).map((x) => x.id).toList();
            children.add(_groupHeader(i.subcategory!, group));
            lastSub = i.subcategory;
          }
          final low = i.lowStock > 0 && i.stock <= i.lowStock;
          final sel = selected.contains(i.id);
          children.add(ListTile(
            selected: sel,
            selectedTileColor: scheme.primaryContainer.withValues(alpha: 0.45),
            contentPadding: EdgeInsets.only(left: i.subcategory != null ? 28 : 16, right: 16),
            leading: selecting
                ? Checkbox(value: sel, onChanged: (_) => _toggle(i.id))
                : CircleAvatar(
                    backgroundColor: low ? scheme.outlineVariant.withValues(alpha: 0.5) : null,
                    // short code, else the name's first letter
                    child: Text(i.shortCode ?? (i.display(app.english).isEmpty ? '' : i.display(app.english).characters.first),
                        style: const TextStyle(fontSize: 12)),
                  ),
            title: Text(i.display(app.english)),
            subtitle: Text('${t('sale_rate')} ₹${Money.fmt(i.saleRate)}${i.isService ? ' / ${t('unit_${i.unit}')}' : ''}'),
            // a service has no stock
            trailing: i.isService
                ? Text(t('no_stock'), style: TextStyle(color: scheme.onSurfaceVariant))
                : Text(
                    '${fmtQty(i.stock)} ${t('unit_${i.unit}')}',
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: low || i.stock < 0 ? Colors.red.shade700 : null),
                  ),
            onLongPress: app.actor.isOwner ? () => _toggle(i.id) : null,
            onTap: selecting
                ? () => _toggle(i.id)
                : () {
                    final to = todayIso();
                    final from = fyStart(to);
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => ReportView(
                          load: () => app.reports.itemMovement(i.id, from, to),
                          onEdit: app.actor.isOwner ? () => ItemForm.open(context, existing: i) : null,
                        ),
                      ),
                    );
                  },
          ));
        }
        return Column(children: [
          if (selecting)
            Material(
              color: scheme.primaryContainer,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(4, 4, 8, 4),
                child: Row(children: [
                  IconButton(tooltip: t('cancel'), icon: const Icon(Icons.close), onPressed: () => setState(selected.clear)),
                  Text(t('n_selected').replaceAll('{n}', '${selected.length}'), style: const TextStyle(fontWeight: FontWeight.w700)),
                  const Spacer(),
                  PopupMenuButton<String>(
                    key: const Key('bulk_menu'),
                    tooltip: t('bulk_change'),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        const Icon(Icons.edit_note),
                        const SizedBox(width: 4),
                        Text(t('bulk_change'), style: const TextStyle(fontWeight: FontWeight.w700)),
                        const Icon(Icons.arrow_drop_down),
                      ]),
                    ),
                    onSelected: (v) => _bulk(v, all),
                    itemBuilder: (_) => [
                      PopupMenuItem(value: 'category', child: Text(t('bulk_category'))),
                      PopupMenuItem(value: 'subcategory', child: Text(t('bulk_subcategory'))),
                      PopupMenuItem(value: 'unit', child: Text(t('bulk_unit'))),
                      PopupMenuItem(value: 'hide', child: Text(t('bulk_hide'))),
                    ],
                  ),
                ]),
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
              child: TextField(
                controller: q,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.search),
                  hintText: t(app.actor.isOwner ? 'stock_search_hint_owner' : 'stock_search_hint'),
                  isDense: true,
                  border: const OutlineInputBorder(),
                ),
              ),
            ),
          Expanded(child: ListView(padding: const EdgeInsets.only(bottom: 90), children: children)),
        ]);
      },
    );
  }

  void _toggle(String id) => setState(() => selected.contains(id) ? selected.remove(id) : selected.add(id));

  /// Category / subcategory heading; in selection mode a tap selects the whole group.
  Widget _groupHeader(String text, List<String> ids, {bool big = false}) {
    final scheme = Theme.of(context).colorScheme;
    final all = ids.every(selected.contains);
    return InkWell(
      onTap: selecting ? () => setState(() => all ? selected.removeAll(ids) : selected.addAll(ids)) : null,
      child: Padding(
        padding: EdgeInsets.fromLTRB(big ? 16 : 28, big ? 14 : 8, 16, 4),
        child: Row(children: [
          if (selecting) ...[Icon(all ? Icons.check_box : Icons.check_box_outline_blank, size: 18, color: scheme.primary), const SizedBox(width: 6)],
          Expanded(
            child: Text(big ? text : '› $text',
                style: (big ? Theme.of(context).textTheme.titleSmall : Theme.of(context).textTheme.labelLarge)
                    ?.copyWith(color: big ? scheme.primary : scheme.onSurfaceVariant, fontWeight: FontWeight.w700)),
          ),
          Text('${ids.length}', style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
        ]),
      ),
    );
  }

  Future<void> _bulk(String what, List<Item> all) async {
    final app = App.read(context);
    final t = app.t;
    final ids = selected.toList();
    String? category, subcategory, unit;
    bool? archived;
    switch (what) {
      case 'category':
        category = await _pick(t('bulk_category'), [for (final c in itemCategories) (c, t('cat_$c'))]);
        if (category == null) return;
      case 'unit':
        unit = await _pick(t('bulk_unit'), [for (final u in await app.stock.units(itemUnits)) (u, t('unit_$u')), ('+', t('unit_new'))]);
        if (unit == '+' && mounted) unit = await askNewUnit(context);
        if (unit == null) return;
      case 'subcategory':
        final cats = all.where((i) => ids.contains(i.id)).map((i) => i.category).toSet();
        subcategory = await _askSubcategory(await app.stock.subcategories(category: cats.length == 1 ? cats.first : null));
        if (subcategory == null) return;
      case 'hide':
        if (!await confirm(context, t('bulk_hide_q').replaceAll('{n}', '${ids.length}'))) return;
        archived = true;
    }
    await app.stock.bulkUpdate(ids, category: category, subcategory: subcategory, unit: unit, archived: archived);
    if (!mounted) return;
    toast(context, '${t('saved')} · ${ids.length}');
    setState(selected.clear);
  }

  Future<String?> _pick(String title, List<(String, String)> options) => showModalBottomSheet<String>(
        context: context,
        showDragHandle: true,
        builder: (ctx) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: Theme.of(ctx).textTheme.titleMedium),
              const SizedBox(height: 10),
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final (v, l) in options) ActionChip(label: Text(l), onPressed: () => Navigator.pop(ctx, v)),
              ]),
            ]),
          ),
        ),
      );

  /// Type a subcategory or tap an existing one; "none" removes it ('').
  Future<String?> _askSubcategory(List<String> existing) {
    final t = App.read(context).t;
    final c = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t('bulk_subcategory')),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          TextField(controller: c, autofocus: true, decoration: InputDecoration(hintText: t('subcategory_hint'))),
          if (existing.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(spacing: 6, runSpacing: 6, children: [
              for (final e in existing) ActionChip(label: Text(e), onPressed: () => Navigator.pop(ctx, e)),
            ]),
          ],
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, ''), child: Text(t('subcategory_none'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, c.text.trim()), child: Text(t('save'))),
        ],
      ),
    );
  }
}

/// दैनिक स्टॉक रजिस्टर: what came in and went out on one day.
/// "सोपे" – item summary + one card per bill; "रजिस्टर" – the paper layout, one column per item.
class DailyRegisterView extends StatefulWidget {
  const DailyRegisterView({super.key});
  @override
  State<DailyRegisterView> createState() => _DailyRegisterViewState();
}

class _DailyRegisterViewState extends State<DailyRegisterView> {
  String date = todayIso();
  bool grid = false;
  bool allItems = false;

  @override
  Widget build(BuildContext context) {
    final app = App.of(context);
    final t = app.t;
    final scheme = Theme.of(context).colorScheme;
    return Column(children: [
      Container(
        decoration: BoxDecoration(border: Border(bottom: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.6)))),
        padding: const EdgeInsets.fromLTRB(4, 6, 12, 6),
        child: Row(children: [
          Expanded(child: Align(alignment: Alignment.centerLeft, child: DayStepper(date: date, onChanged: (d) => setState(() => date = d)))),
          PopupMenuButton<String>(
            key: const Key('register_export'),
            tooltip: '${t('print')} / PDF',
            icon: const Icon(Icons.print_outlined),
            onSelected: (v) async {
              Future<ReportTable> build() => app.reports.dailyRegister(date, allItems: allItems);
              switch (v) {
                case 'pdf':
                  await Exporter.sharePdf(await app.pdfTable(build), shop: app.pdfShopName);
                case 'print':
                  await Exporter.printPdf(await app.pdfTable(build), shop: app.pdfShopName);
                case 'xls':
                  await Exporter.shareExcel([await build()], '${t('daily_register')} ${shortDate(date)}');
              }
            },
            itemBuilder: (_) => [
              PopupMenuItem(value: 'print', child: Text(t('print'))),
              const PopupMenuItem(value: 'pdf', child: Text('PDF')),
              const PopupMenuItem(value: 'xls', child: Text('Excel')),
            ],
          ),
          SegmentedButton<bool>(
            showSelectedIcon: false,
            style: const ButtonStyle(visualDensity: VisualDensity.compact),
            segments: [
              ButtonSegment(value: false, icon: const Icon(Icons.view_agenda_outlined, size: 18), tooltip: t('reg_simple')),
              ButtonSegment(value: true, icon: const Icon(Icons.table_chart_outlined, size: 18), tooltip: t('reg_grid')),
            ],
            selected: {grid},
            onSelectionChanged: (s) => setState(() => grid = s.first),
          ),
        ]),
      ),
      Expanded(
        child: LiveBuilder<DailyRegister>(
          reloadKey: date,
          load: () => app.stock.dailyRegister(date),
          builder: (context, reg) {
            final items = reg.items.where((i) => allItems || reg.moved(i.id)).toList();
            final allChip = FilterChip(
              label: Text(t('reg_all_items')),
              selected: allItems,
              visualDensity: VisualDensity.compact,
              onSelected: (v) => setState(() => allItems = v),
            );
            return grid ? _RegisterGrid(reg: reg, items: items, allChip: allChip) : _RegisterSimple(reg: reg, items: items, allChip: allChip);
          },
        ),
      ),
    ]);
  }
}

String _itemName(Item i, bool english) => i.display(english);

/// Status pill for a bill: paid into रोख/फोनपे, उधार, or part paid.
Widget _payPill(BuildContext context, RegisterRow r) {
  final app = App.of(context);
  final t = app.t;
  final (String text, Color c) = switch (r.type) {
    VoucherType.salesReturn || VoucherType.purchaseReturn || VoucherType.stockAdjust => (t('vt_${r.type.code}'), AppColors.neutral),
    _ when r.amount == 0 => (t('vt_${r.type.code}'), AppColors.neutral),
    _ when r.paid >= r.amount => ((app.english ? r.payNameEn : null) ?? r.payName ?? t('paid'), AppColors.paid),
    _ when r.paid == 0 => (t('reg_credit'), r.type == VoucherType.purchase ? AppColors.haldi : AppColors.due),
    _ => (t('reg_part_paid').replaceAll('{paid}', Money.fmt(r.paid)), AppColors.haldi),
  };
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
    decoration: BoxDecoration(color: c.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(20)),
    child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: c, fontSize: 12, fontWeight: FontWeight.w600)),
  );
}

String _partyLabel(RegisterRow r, AppController app) {
  final name = (app.english ? r.partyNameEn : null) ?? r.partyName;
  if (name != null) return name;
  return r.type == VoucherType.sale ? app.t('cash_sale') : app.t('vt_${r.type.code}');
}

class _RegisterSimple extends StatelessWidget {
  final DailyRegister reg;
  final List<Item> items;
  final Widget allChip;
  const _RegisterSimple({required this.reg, required this.items, required this.allChip});

  @override
  Widget build(BuildContext context) {
    final app = App.of(context);
    final t = app.t;
    final scheme = Theme.of(context).colorScheme;
    final muted = TextStyle(color: scheme.onSurfaceVariant, fontSize: 12);
    final sales = reg.rows.where((r) => r.type == VoucherType.sale).toList();
    final ins = reg.rows.where((r) => r.type == VoucherType.purchase).length;
    final itemById = {for (final i in reg.items) i.id: i};

    Widget stat(String label, String value, Color color) => Expanded(
          child: Column(children: [
            Text(label, style: muted),
            const SizedBox(height: 2),
            Text(value, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: color, fontFeatures: const [FontFeature.tabularFigures()])),
          ]),
        );
    Widget head(String text, {Widget? trailing}) => Padding(
          padding: const EdgeInsets.fromLTRB(4, 18, 0, 6),
          child: Row(children: [
            Expanded(
              child: Text(text.toUpperCase(),
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(color: scheme.onSurfaceVariant, letterSpacing: 0.4, fontWeight: FontWeight.w600)),
            ),
            ?trailing,
          ]),
        );

    const num = [FontFeature.tabularFigures()];
    Widget cell(String text, {Color? color, bool bold = false}) => Expanded(
          flex: 2,
          child: Text(text,
              textAlign: TextAlign.right,
              maxLines: 1,
              style: TextStyle(fontSize: 14, color: color, fontWeight: bold ? FontWeight.w700 : FontWeight.w500, fontFeatures: num)),
        );
    final dim = scheme.outlineVariant;

    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: ListView(padding: const EdgeInsets.fromLTRB(12, 4, 12, 96), children: [
          const SizedBox(height: 8),
          Card(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Row(children: [
                stat(t('reg_bills'), '${sales.length}', scheme.onSurface),
                Container(width: 1, height: 32, color: dim),
                stat(t('reg_sales'), '₹${Money.fmt(sales.fold(0, (s, r) => s + r.amount))}', AppColors.sale),
                Container(width: 1, height: 32, color: dim),
                stat(t('reg_goods_in'), '$ins', AppColors.paid),
              ]),
            ),
          ),
          head(t('reg_movement'), trailing: allChip),
          Card(
            clipBehavior: Clip.antiAlias,
            child: items.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(children: [
                      Icon(Icons.inventory_2_outlined, size: 36, color: dim),
                      const SizedBox(height: 8),
                      Text(t('reg_nothing'), style: muted.copyWith(fontSize: 14), textAlign: TextAlign.center),
                    ]),
                  )
                : Column(children: [
                    Container(
                      color: scheme.surfaceContainerHigh,
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                      child: Row(children: [
                        Expanded(flex: 3, child: Text(t('item'), style: muted)),
                        for (final h in ['opening', 'out', 'in', 'closing'])
                          Expanded(flex: 2, child: Text(t(h), style: muted, textAlign: TextAlign.right)),
                      ]),
                    ),
                    for (var n = 0; n < items.length; n++) ...[
                      if (n > 0) Divider(height: 1, color: dim.withValues(alpha: 0.5)),
                      Builder(builder: (context) {
                        final i = items[n];
                        final out = reg.totalOut(i.id), inn = reg.totalIn(i.id), close = reg.closing(i.id);
                        final low = close < 0 || (i.lowStock > 0 && close <= i.lowStock);
                        return Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                          child: Row(children: [
                            Expanded(
                              flex: 3,
                              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                Text(_itemName(i, app.english), maxLines: 2, overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                                Text(t('unit_${i.unit}'), style: muted),
                              ]),
                            ),
                            cell(fmtQty(reg.opening[i.id] ?? 0), color: scheme.onSurfaceVariant),
                            cell(out == 0 ? '–' : '−${fmtQty(out)}', color: out == 0 ? dim : AppColors.due),
                            cell(inn == 0 ? '–' : '+${fmtQty(inn)}', color: inn == 0 ? dim : AppColors.paid),
                            cell(fmtQty(close), bold: true, color: low ? AppColors.due : null),
                          ]),
                        );
                      }),
                    ],
                  ]),
          ),
          if (reg.rows.isNotEmpty) ...[
            head('${t('entries')} · ${reg.rows.length}'),
            for (final r in reg.rows)
              Card(
                margin: const EdgeInsets.only(bottom: 8),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: () => VoucherScreen.edit(context, r.voucherId),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 12, 14, 12),
                    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Container(
                        width: 30,
                        height: 30,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: (r.isIn ? AppColors.paid : AppColors.ink).withValues(alpha: 0.1),
                          shape: BoxShape.circle,
                        ),
                        child: Text('${r.serial}',
                            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: r.isIn ? AppColors.paid : scheme.primary)),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Expanded(
                              child: Text.rich(
                                TextSpan(children: [
                                  TextSpan(text: _partyLabel(r, app), style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
                                  if (r.pageNo != null) TextSpan(text: '  ${t('page_no')} ${r.pageNo}', style: muted),
                                ]),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                              if (!r.type.isGoodsLoan)
                                Text('₹${Money.fmt(r.amount)}',
                                  style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15, fontFeatures: num)),
                              const SizedBox(height: 3),
                              _payPill(context, r),
                            ]),
                          ]),
                          const SizedBox(height: 6),
                          Wrap(spacing: 6, runSpacing: 6, children: [
                            for (final e in r.qty.entries)
                              if (itemById[e.key] case final i?)
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: e.value > 0 ? AppColors.paid.withValues(alpha: 0.08) : scheme.surfaceContainerHigh,
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Text.rich(TextSpan(children: [
                                    TextSpan(text: '${_itemName(i, app.english)}  ', style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
                                    TextSpan(
                                      text: '${e.value > 0 ? '+' : ''}${fmtQty(e.value.abs())} ${t('unit_${i.unit}')}',
                                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: e.value > 0 ? AppColors.paid : scheme.onSurface),
                                    ),
                                    if ((r.rate[e.key] ?? 0) > 0)
                                      TextSpan(text: ' × ₹${Money.fmt(r.rate[e.key]!)}', style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
                                  ])),
                                ),
                          ]),
                          if (r.haste != null && r.haste!.isNotEmpty) ...[
                            const SizedBox(height: 4),
                            Text('${t('haste')}: ${r.haste}', style: muted),
                          ],
                        ]),
                      ),
                    ]),
                  ),
                ),
              ),
          ],
        ]),
      ),
    );
  }
}

/// The paper register: one row per bill, one column per item.
class _RegisterGrid extends StatelessWidget {
  final DailyRegister reg;
  final List<Item> items;
  final Widget allChip;
  const _RegisterGrid({required this.reg, required this.items, required this.allChip});

  @override
  Widget build(BuildContext context) {
    final app = App.of(context);
    final t = app.t;
    final scheme = Theme.of(context).colorScheme;
    final muted = TextStyle(color: scheme.onSurfaceVariant, fontSize: 11);
    const num = [FontFeature.tabularFigures()];
    // ruled like a paper register: every row and column has a line (prints clearly)
    final grid = BorderSide(color: scheme.outline.withValues(alpha: 0.55), width: 0.8);
    final headBg = scheme.surfaceContainerHigh;
    final head = TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: scheme.onSurface);

    Widget pad(Widget c, {Alignment a = Alignment.centerRight}) =>
        Padding(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 9), child: Align(alignment: a, child: c));
    Widget qty(double v, {Color? color, bool bold = true, String sign = ''}) => pad(Text(v == 0 ? '' : '$sign${fmtQty(v)}',
        style: TextStyle(fontWeight: bold ? FontWeight.w700 : FontWeight.w500, fontSize: 14, color: color, fontFeatures: num)));
    TableRow summary(String label, double Function(Item) f, {Color? color, String sign = '', Color? bg, Widget? last}) => TableRow(
          decoration: BoxDecoration(color: bg),
          children: [
            const SizedBox(),
            pad(Text(label, style: TextStyle(fontWeight: FontWeight.w700, color: color)), a: Alignment.centerLeft),
            for (final i in items) qty(f(i), color: color, sign: sign),
            last ?? const SizedBox(),
            const SizedBox(),
          ],
        );
    Widget tap(RegisterRow r, Widget c) => TableRowInkWell(onTap: () => VoucherScreen.edit(context, r.voucherId), child: c);

    final saleTotal = reg.rows.where((r) => r.type == VoucherType.sale).fold(0, (s, r) => s + r.amount);
    final table = Table(
      defaultVerticalAlignment: TableCellVerticalAlignment.middle,
      border: TableBorder(
        top: grid,
        bottom: grid,
        left: grid,
        right: grid,
        horizontalInside: grid,
        verticalInside: grid,
      ),
      columnWidths: {
        0: const FixedColumnWidth(36),
        1: const FixedColumnWidth(150),
        for (var n = 0; n < items.length; n++) n + 2: const FixedColumnWidth(78),
        items.length + 2: const FixedColumnWidth(92),
        items.length + 3: const IntrinsicColumnWidth(),
      },
      children: [
        TableRow(decoration: BoxDecoration(color: headBg), children: [
          pad(Text('#', style: head), a: Alignment.center),
          pad(Text(t('party'), style: head), a: Alignment.centerLeft),
          for (final i in items)
            pad(
              Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                Text(_itemName(i, app.english), maxLines: 2, overflow: TextOverflow.ellipsis, textAlign: TextAlign.right,
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
                Text(t('unit_${i.unit}'), style: muted),
              ]),
            ),
          pad(Text(t('amount'), style: head)),
          pad(Text(t('pay_mode'), style: head), a: Alignment.centerLeft),
        ]),
        summary(t('opening'), (i) => reg.opening[i.id] ?? 0, color: scheme.onSurfaceVariant),
        for (final r in reg.rows)
          TableRow(
            decoration: BoxDecoration(
              color: r.isIn ? AppColors.paid.withValues(alpha: 0.06) : null,
            ),
            children: [
              tap(r, pad(Text('${r.serial}', style: muted.copyWith(fontSize: 13)), a: Alignment.center)),
              tap(
                r,
                pad(
                  Text.rich(
                    TextSpan(children: [
                      TextSpan(text: _partyLabel(r, app), style: const TextStyle(fontWeight: FontWeight.w600)),
                      if (r.pageNo != null) TextSpan(text: ' ${r.pageNo}', style: muted),
                    ]),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  a: Alignment.centerLeft,
                ),
              ),
              for (final i in items)
                tap(
                  r,
                  r.qty[i.id] == null
                      ? const SizedBox(height: 44)
                      : pad(Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                          Text('${r.qty[i.id]! > 0 ? '+' : ''}${fmtQty(r.qty[i.id]!.abs())}',
                              style: TextStyle(
                                  fontWeight: FontWeight.w700,
                                  fontSize: 14,
                                  fontFeatures: num,
                                  color: r.qty[i.id]! > 0 ? AppColors.paid : null)),
                          if ((r.rate[i.id] ?? 0) > 0) Text('@${Money.fmt(r.rate[i.id]!)}', style: muted),
                        ])),
                ),
              tap(r, pad(Text(r.type.isGoodsLoan ? '' : Money.fmt(r.amount), style: const TextStyle(fontWeight: FontWeight.w600, fontFeatures: num)))),
              tap(r, pad(_payPill(context, r), a: Alignment.centerLeft)),
            ],
          ),
        summary('− ${t('out')}', (i) => reg.totalOut(i.id), color: AppColors.due,
            last: pad(Text(Money.fmt(saleTotal), style: const TextStyle(fontWeight: FontWeight.w700, color: AppColors.due, fontFeatures: num)))),
        summary('+ ${t('in')}', (i) => reg.totalIn(i.id), color: AppColors.paid),
        summary(t('closing'), (i) => reg.closing(i.id), bg: scheme.primaryContainer.withValues(alpha: 0.45)),
      ],
    );

    return ListView(padding: const EdgeInsets.fromLTRB(12, 10, 12, 96), children: [
      Row(children: [
        Expanded(child: Text(t('reg_tap_hint'), style: muted.copyWith(fontSize: 12))),
        allChip,
      ]),
      const SizedBox(height: 8),
      if (items.isEmpty)
        Card(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Center(child: Text(t('reg_nothing'), style: TextStyle(color: scheme.onSurfaceVariant))),
          ),
        )
      else
        Center(
          child: Card(
            clipBehavior: Clip.antiAlias,
            child: SingleChildScrollView(scrollDirection: Axis.horizontal, child: table),
          ),
        ),
    ]);
  }
}

class ItemForm extends StatefulWidget {
  final Item? existing;
  const ItemForm({super.key, this.existing});
  static Future<void> open(BuildContext context, {Item? existing}) =>
      Navigator.push(context, MaterialPageRoute(builder: (_) => ItemForm(existing: existing)));
  @override
  State<ItemForm> createState() => _ItemFormState();
}

class _ItemFormState extends State<ItemForm> {
  late final e = widget.existing;
  late final name = TextEditingController(text: e?.name);
  late final nameEn = TextEditingController(text: e?.nameEn);
  late final code = TextEditingController(text: e?.shortCode);
  late final sale = TextEditingController(text: e == null || e!.saleRate == 0 ? '' : (e!.saleRate / 100).toString());
  late final purchase = TextEditingController(text: e == null || e!.purchaseRate == 0 ? '' : (e!.purchaseRate / 100).toString());
  late final oq = TextEditingController(text: e == null || e!.openingQty == 0 ? '' : fmtQty(e!.openingQty));
  late final orate = TextEditingController(text: e == null || e!.openingRate == 0 ? '' : (e!.openingRate / 100).toString());
  late final low = TextEditingController(text: e == null || e!.lowStock == 0 ? '' : fmtQty(e!.lowStock));
  late String category = e?.category ?? 'cement';
  late String unit = e?.unit ?? 'bag';
  late final sub = TextEditingController(text: e?.subcategory);
  List<String> subs = [];

  @override
  void initState() {
    super.initState();
    _loadSubs();
  }

  Future<void> _loadSubs() async {
    final l = await App.read(context).stock.subcategories(category: category);
    if (mounted) setState(() => subs = l);
  }

  Future<void> _save() async {
    final app = App.read(context);
    if (name.text.trim().isEmpty) return toast(context, app.t('err_required'), error: true);
    await app.stock.save(
      id: e?.id,
      name: name.text,
      nameEn: nameEn.text,
      category: category,
      unit: unit,
      shortCode: code.text,
      saleRate: Money.parse(sale.text) ?? 0,
      purchaseRate: Money.parse(purchase.text) ?? 0,
      openingQty: category == serviceCategory ? 0 : double.tryParse(normalizeDigits(oq.text)) ?? 0,
      openingRate: Money.parse(orate.text) ?? 0,
      lowStock: category == serviceCategory ? 0 : double.tryParse(normalizeDigits(low.text)) ?? 0,
      subcategory: sub.text.trim(),
    );
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final t = App.of(context).t;
    InputDecoration d(String l) => InputDecoration(labelText: l, border: const OutlineInputBorder());
    return Scaffold(
      appBar: AppBar(
        title: Text(e?.name ?? t('new_item')),
        actions: [
          if (e != null)
            IconButton(
              icon: const Icon(Icons.archive_outlined),
              onPressed: () async {
                await App.read(context).stock.setArchived(e!.id, true);
                if (context.mounted) Navigator.pop(context);
              },
            ),
        ],
      ),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        TextField(controller: name, decoration: d(t('name'))),
        const SizedBox(height: 12),
        TextField(controller: nameEn, decoration: d(t('name_en'))),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(child: TextField(controller: code, textCapitalization: TextCapitalization.characters, decoration: d(t('short_code')))),
          const SizedBox(width: 12),
          Expanded(
            child: UnitField(value: unit, decoration: d(t('unit')), onChanged: (v) => setState(() => unit = v)),
          ),
        ]),
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          initialValue: category,
          decoration: d(t('category')),
          items: [for (final c in itemCategories) DropdownMenuItem(value: c, child: Text(t('cat_$c')))],
          onChanged: (v) => setState(() {
            category = v!;
            _loadSubs();
            if (v == serviceCategory && const ['bag', 'kg'].contains(unit)) unit = 'job';
          }),
        ),
        const SizedBox(height: 12),
        // optional: टाकी, पाईप … – leave empty if not needed
        TextField(
          key: const Key('item_subcategory'),
          controller: sub,
          onChanged: (_) => setState(() {}),
          decoration: d(t('subcategory_opt')).copyWith(hintText: t('subcategory_hint')),
        ),
        if (subs.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Wrap(spacing: 6, runSpacing: 4, children: [
              for (final x in subs)
                ChoiceChip(
                  label: Text(x),
                  selected: sub.text.trim() == x,
                  onSelected: (on) => setState(() => sub.text = on ? x : ''),
                ),
            ]),
          ),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(child: TextField(controller: sale, keyboardType: TextInputType.number, decoration: d('${t('sale_rate')} ₹'))),
          const SizedBox(width: 12),
          Expanded(child: TextField(controller: purchase, keyboardType: TextInputType.number, decoration: d('${t('purchase_rate')} ₹'))),
        ]),
        // a service has no stock: no opening stock or low-stock alert
        if (category == serviceCategory) ...[
          const SizedBox(height: 10),
          Text(t('service_help'), style: Theme.of(context).textTheme.bodySmall),
        ] else ...[
          const SizedBox(height: 12),
          Row(children: [
            Expanded(child: TextField(controller: oq, keyboardType: TextInputType.number, decoration: d(t('opening_qty')))),
            const SizedBox(width: 12),
            Expanded(child: TextField(controller: orate, keyboardType: TextInputType.number, decoration: d('${t('opening_rate')} ₹'))),
          ]),
          const SizedBox(height: 12),
          TextField(controller: low, keyboardType: TextInputType.number, decoration: d(t('low_stock'))),
        ],
        const SizedBox(height: 24),
        FilledButton(style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)), onPressed: _save, child: Text(t('save'))),
      ]),
    );
  }
}
