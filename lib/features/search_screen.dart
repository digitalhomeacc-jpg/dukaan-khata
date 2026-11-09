import 'dart:async';

import 'package:flutter/material.dart';

import '../accounting/models.dart';
import '../core/money.dart';
import '../core/theme.dart';
import '../shared/widgets.dart';
import '../state/app_controller.dart';
import 'parties_screen.dart';
import 'report_view.dart';
import 'voucher_screen.dart';

/// One search box for everything: customers, suppliers, accounts (by name,
/// page no., phone), items (by name / code) and entries (by amount, bill no.,
/// note, ref no. or party). Marathi or English, Devanagari digits too.
class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});
  static Future<void> open(BuildContext context) =>
      Navigator.push(context, MaterialPageRoute(builder: (_) => const SearchScreen()));
  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _Results {
  final List<Ledger> ledgers;
  final List<Item> items;
  final List<Voucher> vouchers;
  _Results(this.ledgers, this.items, this.vouchers);
  bool get isEmpty => ledgers.isEmpty && items.isEmpty && vouchers.isEmpty;
}

class _SearchScreenState extends State<SearchScreen> {
  final q = TextEditingController();
  Timer? _debounce;
  _Results? results;
  int _seq = 0;

  void _changed(String _) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 180), _run);
    setState(() {});
  }

  Future<void> _run() async {
    final app = App.read(context);
    final text = q.text.trim();
    final seq = ++_seq;
    if (text.isEmpty) {
      setState(() => results = null);
      return;
    }
    final ledgers = await app.ledgers.search(text, limit: 25);
    final norm = normalizeDigits(text).toLowerCase();
    final items = (await app.stock.list())
        .where((i) =>
            i.name.toLowerCase().contains(norm) ||
            (i.nameEn?.toLowerCase().contains(norm) ?? false) ||
            (i.shortCode?.toLowerCase() == norm))
        .take(8)
        .toList();
    final vouchers = await app.ledgers.searchVouchers(text);
    if (mounted && seq == _seq) setState(() => results = _Results(ledgers, items, vouchers));
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = App.of(context);
    final t = app.t;
    final r = results;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Padding(
          padding: const EdgeInsets.only(right: 12),
          child: TextField(
            key: const Key('global_search'),
            controller: q,
            autofocus: true,
            onChanged: _changed,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              hintText: t('search_all_hint'),
              prefixIcon: const Icon(Icons.search),
              suffixIcon: q.text.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () {
                        q.clear();
                        _changed('');
                      },
                    ),
              contentPadding: const EdgeInsets.symmetric(vertical: 10),
            ),
          ),
        ),
      ),
      body: r == null
          ? _Tips(t: t)
          : r.isEmpty
              ? Center(child: Text(t('no_results')))
              : ListView(padding: const EdgeInsets.only(bottom: 24), children: [
                  if (r.ledgers.isNotEmpty) ...[
                    SectionTitle('${t('accounts_people')} (${r.ledgers.length})'),
                    for (final l in r.ledgers)
                      ListTile(
                        leading: CircleAvatar(
                          backgroundColor: Theme.of(context).colorScheme.primaryContainer,
                          child: Text(l.pageNo ?? l.name.characters.first, style: const TextStyle(fontSize: 13)),
                        ),
                        title: Text(l.name),
                        subtitle: Text([t('grp_${l.group.code}'), if (l.nameEn != null) l.nameEn!, if (l.phone != null) l.phone!].join(' · ')),
                        trailing: l.group.isParty || l.group == LedgerGroup.transporter
                            ? BalanceText(l.balance, supplier: l.group != LedgerGroup.customer, size: 15)
                            : Text(Money.fmt(l.balance)),
                        onTap: () => KhataScreen.open(context, l.id),
                      ),
                  ],
                  if (r.items.isNotEmpty) ...[
                    SectionTitle('${t('items')} (${r.items.length})'),
                    for (final i in r.items)
                      ListTile(
                        leading: CircleAvatar(child: Text(i.shortCode ?? '', style: const TextStyle(fontSize: 12))),
                        title: Text(i.display(app.english)),
                        trailing: Text('${fmtQty(i.stock)} ${t('unit_${i.unit}')}', style: const TextStyle(fontWeight: FontWeight.w600)),
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => ReportView(load: () => app.reports.itemMovement(i.id, fyStart(todayIso()), todayIso())),
                          ),
                        ),
                      ),
                  ],
                  if (r.vouchers.isNotEmpty) ...[
                    SectionTitle('${t('entries')} (${r.vouchers.length})'),
                    for (final v in r.vouchers) VoucherTile(v),
                  ],
                ]),
    );
  }
}

class _Tips extends StatelessWidget {
  final String Function(String) t;
  const _Tips({required this.t});
  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodyMedium?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant);
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(t('search_tips_title'), style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 12),
        for (final k in ['search_tip_name', 'search_tip_page', 'search_tip_amount', 'search_tip_note'])
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Icon(Icons.subdirectory_arrow_right, size: 18),
              const SizedBox(width: 8),
              Expanded(child: Text(t(k), style: style)),
            ]),
          ),
      ]),
    );
  }
}

/// A single entry row used by search and the home screen.
class VoucherTile extends StatelessWidget {
  final Voucher v;
  const VoucherTile(this.v, {super.key});

  static Color colorFor(VoucherType t) => switch (t) {
        VoucherType.sale => AppColors.sale,
        VoucherType.receipt => AppColors.receipt,
        VoucherType.purchase => AppColors.purchase,
        VoucherType.payment => AppColors.expense,
        _ => AppColors.neutral,
      };

  static IconData iconFor(VoucherType t) => switch (t) {
        VoucherType.sale => Icons.point_of_sale,
        VoucherType.receipt => Icons.south_west,
        VoucherType.purchase => Icons.local_shipping_outlined,
        VoucherType.payment => Icons.north_east,
        VoucherType.contra => Icons.swap_horiz,
        VoucherType.history => Icons.history_edu,
        VoucherType.goodsOut || VoucherType.goodsIn => Icons.inventory_2_outlined,
        _ => Icons.receipt_long,
      };

  @override
  Widget build(BuildContext context) {
    final t = App.of(context).t;
    final c = colorFor(v.type);
    return ListTile(
      leading: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(color: c.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(12)),
        child: Icon(iconFor(v.type), color: c, size: 22),
      ),
      title: Text(v.partyName ?? (v.type == VoucherType.sale ? t('cash_sale') : (v.narration ?? t('vt_${v.type.code}'))),
          maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        [
          '${t('vt_${v.type.code}')} #${v.vno}',
          shortDate(v.date),
          if (v.payCode != null) v.payCode!,
          if (v.haste != null) '${t('haste')}: ${v.haste}',
          if (v.type == VoucherType.sale && v.due > 0) '${t('due')} ₹${Money.fmt(v.due)}',
        ].join(' · '),
      ),
      // उसना माल has no money value – the bags show on the khata
      trailing: v.type.isGoodsLoan
          ? null
          : Text('₹${Money.fmt(v.amount)}',
          style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15, fontFeatures: const [FontFeature.tabularFigures()])),
      onTap: () => VoucherScreen.edit(context, v.id),
    );
  }
}
