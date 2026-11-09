import 'package:flutter/material.dart';

import '../accounting/ledger_repo.dart';
import '../accounting/models.dart';
import '../core/money.dart';
import '../shared/export.dart';
import '../shared/widgets.dart';
import '../state/app_controller.dart';
import 'voucher_screen.dart';

/// Rojmal – the daily cash book. Inflow on the left, outflow on the right,
/// with one tab per money account (Cash, PhonePe H/D/P, Bank/RTGS).
class RojmalScreen extends StatefulWidget {
  const RojmalScreen({super.key});
  @override
  State<RojmalScreen> createState() => _RojmalScreenState();
}

class _RojmalScreenState extends State<RojmalScreen> {
  String date = todayIso();
  String? accountId; // null = all money accounts

  @override
  Widget build(BuildContext context) {
    final app = App.of(context);
    final t = app.t;
    return LiveBuilder<(List<Ledger>, CashBook, DayCharges)>(
      reloadKey: '$date|$accountId',
      load: () async {
        final accts = await app.ledgers.list([LedgerGroup.cash, LedgerGroup.upi, LedgerGroup.bank]);
        final ids = accountId == null ? accts.map((a) => a.id).toList() : [accountId!];
        return (accts, await app.ledgers.cashBook(ids, date), await app.ledgers.dayCharges(date));
      },
      builder: (context, data) {
        final (accts, book, charges) = data;
        final ins = book.rows.where((r) => r.inflow > 0).toList();
        final outs = book.rows.where((r) => r.outflow > 0).toList();
        final wide = MediaQuery.of(context).size.width > 700;
        return Scaffold(
          appBar: AppBar(
            title: Text(t('rojmal')),
            actions: [
              IconButton(
                icon: const Icon(Icons.picture_as_pdf),
                onPressed: () async {
                  final ids = accountId == null ? accts.map((a) => a.id).toList() : [accountId!];
                  final title = accountId == null ? t('rojmal') : accts.firstWhere((a) => a.id == accountId).name;
                  await Exporter.sharePdf(await app.reports.moneyBook(ids, title, date, date), shop: app.businessName);
                },
              ),
            ],
          ),
          floatingActionButton: FloatingActionButton(
            heroTag: 'rojmal_add',
            onPressed: () => _quickAdd(context),
            child: const Icon(Icons.add),
          ),
          body: Column(children: [
            Center(child: DayStepper(date: date, onChanged: (d) => setState(() => date = d))),
            SizedBox(
              height: 44,
              child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 8), children: [
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: ChoiceChip(label: Text(t('all_accounts')), selected: accountId == null, onSelected: (_) => setState(() => accountId = null)),
                ),
                for (final a in accts)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ChoiceChip(
                      avatar: a.shortCode == null ? null : CircleAvatar(child: Text(a.shortCode!, style: const TextStyle(fontSize: 11))),
                      label: Text(a.display(app.english)),
                      selected: accountId == a.id,
                      onSelected: (_) => setState(() => accountId = a.id),
                    ),
                  ),
              ]),
            ),
            _summary(context, book),
            if (!charges.isEmpty) _DayEndCard(charges: charges),
            Expanded(
              child: wide
                  ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Expanded(child: _side(context, t('inflow'), ins, true)),
                      const VerticalDivider(width: 1),
                      Expanded(child: _side(context, t('outflow'), outs, false)),
                    ])
                  : ListView(padding: const EdgeInsets.only(bottom: 90), children: [
                      _side(context, t('inflow'), ins, true, scroll: false),
                      _side(context, t('outflow'), outs, false, scroll: false),
                    ]),
            ),
          ]),
        );
      },
    );
  }

  Widget _summary(BuildContext context, CashBook b) {
    final t = App.of(context).t;
    Widget box(String label, int v, Color c) => Expanded(
          child: Column(children: [
            Text(label, style: Theme.of(context).textTheme.bodySmall),
            Text(Money.fmt(v), style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: c)),
          ]),
        );
    return Card(
      margin: const EdgeInsets.all(8),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Row(children: [
          box(t('opening'), b.opening, Colors.blueGrey),
          box('+ ${t('inflow')}', b.totalIn, Colors.green.shade700),
          box('− ${t('outflow')}', b.totalOut, Colors.red.shade700),
          box(t('closing'), b.closing, Theme.of(context).colorScheme.primary),
        ]),
      ),
    );
  }

  Widget _side(BuildContext context, String title, List<CashRow> rows, bool inflow, {bool scroll = true}) {
    final color = inflow ? Colors.green.shade700 : Colors.red.shade700;
    final total = rows.fold<int>(0, (s, r) => s + (inflow ? r.inflow : r.outflow));
    final tiles = [
      for (final r in rows)
        ListTile(
          dense: true,
          leading: r.code == null ? null : CircleAvatar(radius: 14, child: Text(r.code!, style: const TextStyle(fontSize: 11))),
          title: Text(r.particulars.isNotEmpty ? r.particulars : App.of(context).t(r.type == VoucherType.sale ? 'cash_sale' : 'vt_${r.type.code}')),
          subtitle: Text([App.of(context).t('vt_${r.type.code}'), if (r.narration != null && r.narration != r.particulars) r.narration!].join(' · ')),
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            if (r.gstBillNeeded) const Padding(padding: EdgeInsets.only(right: 4), child: Chip(label: Text('GST'), visualDensity: VisualDensity.compact)),
            Text(Money.fmt(inflow ? r.inflow : r.outflow), style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 15)),
          ]),
          onTap: () => VoucherScreen.edit(context, r.voucherId),
        ),
    ];
    final header = Container(
      color: color.withValues(alpha: 0.08),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(children: [
        Text(title, style: TextStyle(color: color, fontWeight: FontWeight.bold)),
        const Spacer(),
        Text(Money.fmt(total), style: TextStyle(color: color, fontWeight: FontWeight.bold)),
      ]),
    );
    if (!scroll) return Column(children: [header, ...tiles]);
    return Column(children: [header, Expanded(child: ListView(padding: const EdgeInsets.only(bottom: 90), children: tiles))]);
  }

  void _quickAdd(BuildContext context) {
    final t = App.read(context).t;
    showModalBottomSheet(
      context: context,
      builder: (_) => SafeArea(
        child: Wrap(children: [
          for (final (type, label, icon, exp) in [
            (VoucherType.receipt, t('receipt'), Icons.call_received, false),
            (VoucherType.payment, t('expense'), Icons.receipt_long, true),
            (VoucherType.payment, t('payment'), Icons.call_made, false),
            (VoucherType.contra, t('contra'), Icons.swap_horiz, false),
          ])
            ListTile(
              leading: Icon(icon),
              title: Text(label),
              onTap: () {
                Navigator.pop(context);
                VoucherScreen.open(context, type, expense: exp);
              },
            ),
        ]),
      ),
    );
  }
}

/// Day-end hisab: hamali taken on bills vs paid to labourers, and what each
/// outside transporter is owed – with one-tap payment.
class _DayEndCard extends StatelessWidget {
  final DayCharges charges;
  const _DayEndCard({required this.charges});

  @override
  Widget build(BuildContext context) {
    final app = App.of(context);
    final t = app.t;
    final c = charges;
    final pending = c.hamaliCharged - c.hamaliPaid;
    final owedTotal = c.transporters.fold<int>(0, (s, d) => s + (d.owed > 0 ? d.owed : 0));
    Widget money(int v, {Color? color, bool bold = false}) => Text(Money.fmt(v),
        style: TextStyle(color: color, fontWeight: bold ? FontWeight.bold : null, fontFeatures: const [FontFeature.tabularFigures()]));
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 8),
      child: ExpansionTile(
        key: PageStorageKey('dayend_${c.date}'),
        leading: const Icon(Icons.fact_check_outlined),
        title: Text(t('day_end')),
        subtitle: Text('${t('hamali')}: ${Money.fmt(c.hamaliCharged)} / ${Money.fmt(c.hamaliPaid)}'
            '${owedTotal > 0 ? ' · ${t('transporters')}: ₹${Money.fmt(owedTotal)}' : ''}'),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        children: [
          Row(children: [Expanded(child: Text(t('hamali_charged'))), money(c.hamaliCharged)]),
          Row(children: [Expanded(child: Text(t('hamali_paid'))), money(c.hamaliPaid)]),
          Row(children: [
            Expanded(child: Text(t('hamali_profit'), style: const TextStyle(fontWeight: FontWeight.bold))),
            money(c.hamaliProfit, color: c.hamaliProfit >= 0 ? Colors.green.shade700 : Colors.red.shade700, bold: true),
          ]),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              icon: const Icon(Icons.payments_outlined, size: 18),
              label: Text(t('pay_labourers')),
              onPressed: () => VoucherScreen.open(context, VoucherType.payment,
                  partyId: '${app.businessId}:hamali', expense: true, amount: pending > 0 ? pending : null),
            ),
          ),
          if (c.ownTransport != 0)
            Row(children: [Expanded(child: Text(t('transport_income'))), money(c.ownTransport, color: Colors.green.shade700)]),
          if (c.transporters.isNotEmpty) ...[
            const Divider(),
            Row(children: [
              Expanded(flex: 3, child: Text(t('transporter'), style: Theme.of(context).textTheme.bodySmall)),
              Expanded(flex: 2, child: Text(t('earned_today'), textAlign: TextAlign.right, style: Theme.of(context).textTheme.bodySmall)),
              Expanded(flex: 2, child: Text(t('owed_total'), textAlign: TextAlign.right, style: Theme.of(context).textTheme.bodySmall)),
              const SizedBox(width: 88),
            ]),
            for (final d in c.transporters)
              Row(children: [
                Expanded(flex: 3, child: Text(d.transporter.display(app.english))),
                Expanded(flex: 2, child: Align(alignment: Alignment.centerRight, child: money(d.earnedToday))),
                Expanded(flex: 2, child: Align(alignment: Alignment.centerRight, child: money(d.owed, color: d.owed > 0 ? Colors.red.shade700 : null, bold: true))),
                SizedBox(
                  width: 88,
                  child: d.owed > 0
                      ? TextButton(
                          onPressed: () => VoucherScreen.open(context, VoucherType.payment,
                              partyId: d.transporter.id, amount: d.owed),
                          child: Text(t('pay_now')),
                        )
                      : const SizedBox(),
                ),
              ]),
          ],
        ],
      ),
    );
  }
}
