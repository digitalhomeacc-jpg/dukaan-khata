import 'package:flutter/material.dart';

import '../accounting/models.dart';
import '../core/money.dart';
import '../inventory/stock_repo.dart';
import '../shared/widgets.dart';
import '../state/app_controller.dart';
import 'report_view.dart';
import 'voucher_screen.dart';

const itemCategories = ['cement', 'steel', 'blocks', 'plumbing', 'sand', 'other'];
const itemUnits = ['bag', 'kg', 'nos', 'ft', 'ton', 'brass', 'ltr'];

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
              ],
            ),
          ],
        ),
        floatingActionButton: app.actor.isOwner
            ? FloatingActionButton.extended(
                heroTag: 'item_add',
                icon: const Icon(Icons.add),
                label: Text(t('new_item')),
                onPressed: () => ItemForm.open(context),
              )
            : null,
        body: const TabBarView(children: [_ItemList(), DailyRegisterView()]),
      ),
    );
  }
}

class _ItemList extends StatelessWidget {
  const _ItemList();
  @override
  Widget build(BuildContext context) {
    final app = App.of(context);
    final t = app.t;
    return LiveBuilder<List<Item>>(
      load: () => app.stock.list(),
      builder: (context, items) {
        String? lastCat;
        final children = <Widget>[];
        for (final i in items..sort((a, b) => itemCategories.indexOf(a.category).compareTo(itemCategories.indexOf(b.category)))) {
          if (i.category != lastCat) {
            children.add(SectionTitle(t('cat_${i.category}')));
            lastCat = i.category;
          }
          final low = i.lowStock > 0 && i.stock <= i.lowStock;
          children.add(ListTile(
            leading: CircleAvatar(
              backgroundColor: low ? Theme.of(context).colorScheme.outlineVariant.withValues(alpha: 0.5) : null,
              child: Text(i.shortCode ?? '', style: const TextStyle(fontSize: 12)),
            ),
            title: Text(i.display(app.english)),
            subtitle: Text('${t('sale_rate')} ₹${Money.fmt(i.saleRate)}'),
            trailing: Text(
              '${fmtQty(i.stock)} ${t('unit_${i.unit}')}',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: low || i.stock < 0 ? Colors.red.shade700 : null),
            ),
            onTap: () async {
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
        return ListView(padding: const EdgeInsets.only(bottom: 90), children: children);
      },
    );
  }
}

/// The paper stock register for a day: one column per item.
class DailyRegisterView extends StatefulWidget {
  const DailyRegisterView({super.key});
  @override
  State<DailyRegisterView> createState() => _DailyRegisterViewState();
}

class _DailyRegisterViewState extends State<DailyRegisterView> {
  String date = todayIso();
  bool onlyMoving = true;

  @override
  Widget build(BuildContext context) {
    final app = App.of(context);
    final t = app.t;
    return Column(children: [
      Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        DayStepper(date: date, onChanged: (d) => setState(() => date = d)),
        FilterChip(label: Text(t('all')), selected: !onlyMoving, onSelected: (v) => setState(() => onlyMoving = !v)),
      ]),
      Expanded(
        child: LiveBuilder<DailyRegister>(
          reloadKey: date,
          load: () => app.stock.dailyRegister(date),
          builder: (context, reg) {
            final cols = reg.items
                .where((i) => !onlyMoving || reg.rows.any((r) => r.qty.containsKey(i.id)) || (reg.opening[i.id] ?? 0) != 0)
                .toList();
            const bold = TextStyle(fontWeight: FontWeight.bold);
            DataCell num(double v, {TextStyle? s}) => DataCell(Text(v == 0 ? '' : fmtQty(v), style: s));
            return SingleChildScrollView(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: DataTable(
                  showCheckboxColumn: false,
                  columnSpacing: 14,
                  headingRowColor: WidgetStatePropertyAll(Theme.of(context).colorScheme.surfaceContainerHigh),
                  columns: [
                    const DataColumn(label: Text('#')),
                    DataColumn(label: Text(t('party'))),
                    for (final i in cols) DataColumn(label: Text(i.shortCode ?? i.name), numeric: true),
                    const DataColumn(label: Text('')),
                    DataColumn(label: Text(t('amount')), numeric: true),
                  ],
                  rows: [
                    DataRow(cells: [
                      const DataCell(Text('')),
                      DataCell(Text(t('opening'), style: bold)),
                      for (final i in cols) num(reg.opening[i.id] ?? 0, s: bold),
                      const DataCell(Text('')),
                      const DataCell(Text('')),
                    ]),
                    for (final r in reg.rows)
                      DataRow(
                        onSelectChanged: (_) => VoucherScreen.edit(context, r.voucherId),
                        color: r.type == VoucherType.purchase || r.type == VoucherType.salesReturn
                            ? WidgetStatePropertyAll(Theme.of(context).colorScheme.secondaryContainer.withValues(alpha: 0.5))
                            : null,
                        cells: [
                          DataCell(Text('${r.serial}')),
                          DataCell(Text('${r.partyName ?? t('cash_sale')}${r.pageNo != null ? ' (${r.pageNo})' : ''}')),
                          for (final i in cols)
                            DataCell(Text(
                              r.qty[i.id] == null
                                  ? ''
                                  : '${fmtQty(r.qty[i.id]!.abs())}/${Money.fmt(r.rate[i.id] ?? 0)}',
                              style: TextStyle(color: (r.qty[i.id] ?? 0) > 0 ? Colors.green.shade800 : null),
                            )),
                          DataCell(Text(r.payCode ?? (r.amount > r.paid ? t('due') : ''))),
                          DataCell(Text(Money.fmt(r.amount))),
                        ],
                      ),
                    DataRow(cells: [
                      const DataCell(Text('')),
                      DataCell(Text('− ${t('out')}', style: bold)),
                      for (final i in cols) num(reg.totalOut(i.id), s: bold),
                      const DataCell(Text('')),
                      DataCell(Text(Money.fmt(reg.rows.where((r) => r.type == VoucherType.sale).fold(0, (s, r) => s + r.amount)), style: bold)),
                    ]),
                    DataRow(cells: [
                      const DataCell(Text('')),
                      DataCell(Text('+ ${t('in')}', style: bold)),
                      for (final i in cols) num(reg.totalIn(i.id), s: bold),
                      const DataCell(Text('')),
                      const DataCell(Text('')),
                    ]),
                    DataRow(color: WidgetStatePropertyAll(Theme.of(context).colorScheme.surfaceContainerHigh), cells: [
                      const DataCell(Text('')),
                      DataCell(Text(t('closing'), style: bold)),
                      for (final i in cols) num(reg.closing(i.id), s: bold),
                      const DataCell(Text('')),
                      const DataCell(Text('')),
                    ]),
                  ],
                ),
              ),
            );
          },
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
      openingQty: double.tryParse(normalizeDigits(oq.text)) ?? 0,
      openingRate: Money.parse(orate.text) ?? 0,
      lowStock: double.tryParse(normalizeDigits(low.text)) ?? 0,
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
            child: DropdownButtonFormField<String>(
              initialValue: unit,
              decoration: d(t('unit')),
              items: [for (final u in itemUnits) DropdownMenuItem(value: u, child: Text(t('unit_$u')))],
              onChanged: (v) => setState(() => unit = v!),
            ),
          ),
        ]),
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          initialValue: category,
          decoration: d(t('category')),
          items: [for (final c in itemCategories) DropdownMenuItem(value: c, child: Text(t('cat_$c')))],
          onChanged: (v) => setState(() => category = v!),
        ),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(child: TextField(controller: sale, keyboardType: TextInputType.number, decoration: d('${t('sale_rate')} ₹'))),
          const SizedBox(width: 12),
          Expanded(child: TextField(controller: purchase, keyboardType: TextInputType.number, decoration: d('${t('purchase_rate')} ₹'))),
        ]),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(child: TextField(controller: oq, keyboardType: TextInputType.number, decoration: d(t('opening_qty')))),
          const SizedBox(width: 12),
          Expanded(child: TextField(controller: orate, keyboardType: TextInputType.number, decoration: d('${t('opening_rate')} ₹'))),
        ]),
        const SizedBox(height: 12),
        TextField(controller: low, keyboardType: TextInputType.number, decoration: d(t('low_stock'))),
        const SizedBox(height: 24),
        FilledButton(style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)), onPressed: _save, child: Text(t('save'))),
      ]),
    );
  }
}
