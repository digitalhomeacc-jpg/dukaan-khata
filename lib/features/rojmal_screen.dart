import 'package:flutter/material.dart';

import '../accounting/ledger_repo.dart';
import '../accounting/models.dart';
import '../accounting/reports.dart';
import '../core/money.dart';
import '../core/theme.dart';
import '../shared/export.dart';
import '../shared/widgets.dart';
import '../state/app_controller.dart';
import 'booking_screen.dart';
import 'cash_count_screen.dart';
import 'day_close_screen.dart';
import 'review_screen.dart';
import 'report_view.dart';
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
  static const udhari = '_udhari'; // the उधारी tab: what went on credit today
  bool get onUdhari => accountId == udhari;

  @override
  Widget build(BuildContext context) {
    final app = App.of(context);
    final t = app.t;
    return LiveBuilder<(List<Ledger>, CashBook, DayCharges)>(
      reloadKey: '$date|$accountId',
      load: () async {
        final accts = await app.ledgers.list([LedgerGroup.cash, LedgerGroup.upi, LedgerGroup.bank]);
        final ids = onUdhari ? <String>[] : accountId == null ? accts.map((a) => a.id).toList() : [accountId!];
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
              if (app.actor.isOwner)
                IconButton(
                  key: const Key('review_open'),
                  tooltip: t('review'),
                  icon: const Icon(Icons.fact_check_outlined),
                  onPressed: () => ReviewScreen.open(context),
                ),
              IconButton(
                key: const Key('cash_count'),
                tooltip: t('cash_count'),
                icon: const Icon(Icons.calculate_outlined),
                onPressed: () => CashCountScreen.open(context, date: date),
              ),
              IconButton(
                icon: const Icon(Icons.picture_as_pdf),
                onPressed: () async {
                  if (onUdhari) {
                    return Exporter.sharePdf(await app.pdfTable(() => app.reports.udhariTable(date)), shop: app.pdfShopName);
                  }
                  if (accountId != null) {
                    final title = accts.firstWhere((a) => a.id == accountId).name;
                    return Exporter.sharePdf(await app.pdfTable(() => app.reports.moneyBook([accountId!], title, date, date)),
                        shop: app.pdfShopName);
                  }
                  // सर्व: one table each – cash, PhonePe, bank – then the day's उधारी
                  final tables = <ReportTable>[];
                  for (final (g, key) in [(LedgerGroup.cash, 'cash_tbl'), (LedgerGroup.upi, 'upi_tbl'), (LedgerGroup.bank, 'bank_tbl')]) {
                    final ids = accts.where((a) => a.group == g).map((a) => a.id).toList();
                    if (ids.isEmpty) continue;
                    tables.add(await app.pdfTable(() async {
                      final tb = await app.reports.moneyBook(ids, app.reports.tr(key), date, date);
                      return tb;
                    }));
                  }
                  tables.add(await app.pdfTable(() => app.reports.udhariTable(date)));
                  await Exporter.sharePdfMulti(tables, heading: 'Rojmel ${shortDate(date)}', shop: app.pdfShopName);
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
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: ChoiceChip(
                    key: const Key('udhari_tab'),
                    avatar: Icon(Icons.menu_book_outlined, size: 18, color: Colors.orange.shade800),
                    label: Text(t('udhari_tab')),
                    selected: onUdhari,
                    selectedColor: Colors.orange.shade200,
                    onSelected: (_) => setState(() => accountId = udhari),
                  ),
                ),
              ]),
            ),
            if (onUdhari) Expanded(child: _UdhariView(date: date)),
            if (!onUdhari) _summary(context, book),
            if (!onUdhari && !charges.isEmpty) _DayEndCard(charges: charges),
            if (!onUdhari)
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
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(Money.fmt(v), maxLines: 1, style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: c)),
            ),
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
    Widget tile(CashRow r) => ListTile(
          dense: true,
          leading: r.code == null ? null : CircleAvatar(radius: 14, child: Text(r.code!, style: const TextStyle(fontSize: 11))),
          title: Text(r.varhai
              ? '${App.of(context).t('varhai')}${r.particulars.isNotEmpty ? ' · ${r.particulars}' : ''}'
              : r.particulars.isNotEmpty
                  ? r.particulars
                  : App.of(context).t(r.type == VoucherType.sale ? 'cash_sale' : r.type == VoucherType.purchase ? 'cash_purchase' : 'vt_${r.type.code}')),
          subtitle: Text([App.of(context).t('vt_${r.type.code}'), if (r.narration != null && r.narration != r.particulars) r.narration!].join(' · ')),
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            if (r.gstBillNeeded) const Padding(padding: EdgeInsets.only(right: 4), child: Chip(label: Text('GST'), visualDensity: VisualDensity.compact)),
            Text(Money.fmt(inflow ? r.inflow : r.outflow), style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 15)),
          ]),
          onTap: () => VoucherScreen.edit(context, r.voucherId),
        );
    // counter sales without a customer name (रोख विक्री): one line with the
    // total, tap to see each bill
    bool walkIn(CashRow r) => r.type == VoucherType.sale && r.particulars.isEmpty && !r.varhai;
    final groups = <String, List<CashRow>>{}; // by cash / PhonePe / bank
    for (final r in rows.where(walkIn)) {
      groups.putIfAbsent(r.code ?? '', () => []).add(r);
    }
    final tiles = <Widget>[];
    for (final r in rows) {
      final g = walkIn(r) ? groups[r.code ?? '']! : const <CashRow>[];
      if (g.length < 2) {
        tiles.add(tile(r));
      } else if (identical(r, g.first)) {
        final t = App.of(context).t;
        tiles.add(ExpansionTile(
          key: Key('counter_sales_${inflow}_${r.code}'),
          dense: true,
          leading: r.code == null ? null : CircleAvatar(radius: 14, child: Text(r.code!, style: const TextStyle(fontSize: 11))),
          title: Text('${t('cash_sale')} · ${g.length} ${t('bills')}', style: const TextStyle(fontWeight: FontWeight.w600)),
          subtitle: Text(t('tap_to_see')),
          trailing: Text(Money.fmt(g.fold<int>(0, (s, r) => s + (inflow ? r.inflow : r.outflow))),
              style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 15)),
          childrenPadding: const EdgeInsets.only(left: 16),
          children: [for (final c in g) tile(c)],
        ));
      }
    }
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
          ListTile(
            leading: const Icon(Icons.nightlight_round),
            title: Text(t('day_close')),
            onTap: () {
              Navigator.pop(context);
              DayCloseScreen.open(context);
            },
          ),
          ListTile(
            leading: const Icon(Icons.local_shipping_outlined),
            title: Text(t('incoming_add')),
            subtitle: Text(t('incoming_add_sub')),
            onTap: () {
              Navigator.pop(context);
              BookingScreen.open(context, supplier: true);
            },
          ),
          ListTile(
            leading: const Icon(Icons.calculate_outlined),
            title: Text(t('cash_count')),
            subtitle: Text(t('cash_count_sub')),
            onTap: () {
              Navigator.pop(context);
              CashCountScreen.open(context);
            },
          ),
          ListTile(
            leading: const Icon(Icons.engineering),
            title: Text(t('varhai_add')),
            subtitle: Text(t('varhai_sub')),
            onTap: () {
              Navigator.pop(context);
              VoucherScreen.open(context, VoucherType.receipt, partyId: '${App.read(context).businessId}:varhai');
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
    // आज किती हमाल: each gets at least the minimum; a shortfall is paid from pocket
    final hamals = app.prefInt('hamals_${c.date}', 0);
    final minEach = app.prefInt('hamal_min', 300) * 100;
    final minTotal = hamals * minEach;
    final pocket = minTotal > c.hamaliToPay ? minTotal - c.hamaliToPay : 0;
    final toPay = c.hamaliToPay + pocket;
    final pending = toPay - c.hamaliPaid;
    final owedTotal = c.transporters.fold<int>(0, (s, d) => s + (d.owed > 0 ? d.owed : 0));
    Widget money(int v, {Color? color, bool bold = false}) => Text(Money.fmt(v),
        style: TextStyle(color: color, fontWeight: bold ? FontWeight.bold : null, fontFeatures: const [FontFeature.tabularFigures()]));
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 8),
      child: ExpansionTile(
        key: PageStorageKey('dayend_${c.date}'),
        leading: const Icon(Icons.fact_check_outlined),
        title: Text(t('day_end')),
        // taken / given, for both
        subtitle: Text('${t('hamali')}: ${Money.fmt(c.hamaliToPay)} / ${Money.fmt(c.hamaliPaid)}'
            '${c.hasTransport ? ' · ${t('transport')}: ${Money.fmt(c.transportCharged)} / ${Money.fmt(c.transportPaid)}' : ''}'),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        children: [
          Row(children: [Expanded(child: Text(t('hamali_charged'))), money(c.hamaliCharged)]),
          Row(children: [
            Expanded(child: Text('+ ${t('varhai')}')),
            money(c.varhai),
          ]),
          const Divider(height: 12),
          Row(children: [
            Expanded(child: Text(t('hamali_to_pay'), style: const TextStyle(fontWeight: FontWeight.w600))),
            money(c.hamaliToPay, bold: true),
          ]),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(children: [
              Expanded(child: Text(t('hamal_count'), style: const TextStyle(fontWeight: FontWeight.w600))),
              IconButton.filledTonal(
                  key: const Key('hamal_minus'),
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.remove, size: 18),
                  onPressed: hamals > 0 ? () => app.setPrefInt('hamals_${c.date}', hamals - 1) : null),
              SizedBox(width: 36, child: Text('$hamals', textAlign: TextAlign.center, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800))),
              IconButton.filledTonal(
                  key: const Key('hamal_plus'),
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.add, size: 18),
                  onPressed: () => app.setPrefInt('hamals_${c.date}', hamals + 1)),
            ]),
          ),
          if (hamals > 0) ...[
            InkWell(
              // tap to change the ₹300 minimum
              onTap: () async {
                final ctl = TextEditingController(text: '${minEach ~/ 100}');
                final v = await showDialog<String>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: Text(t('hamal_rate_q')),
                    content: TextField(controller: ctl, autofocus: true, keyboardType: TextInputType.number),
                    actions: [FilledButton(onPressed: () => Navigator.pop(ctx, ctl.text), child: Text(t('save')))],
                  ),
                );
                final n = int.tryParse(normalizeDigits(v ?? '').trim());
                if (n != null && n > 0) await app.setPrefInt('hamal_min', n);
              },
              child: Row(children: [
                Expanded(child: Text('${t('hamal_min').replaceAll('{r}', '${minEach ~/ 100}').replaceAll('{n}', '$hamals')}  ✎')),
                money(minTotal),
              ]),
            ),
            if (pocket > 0)
              Row(children: [
                Expanded(child: Text('+ ${t('hamal_pocket')}', style: TextStyle(color: Colors.red.shade700, fontWeight: FontWeight.w600))),
                money(pocket, color: Colors.red.shade700, bold: true),
              ]),
            Row(children: [
              Expanded(child: Text(t('hamal_each'))),
              money((toPay / hamals).round()),
            ]),
          ],
          Row(children: [Expanded(child: Text('− ${t('hamali_paid')}')), money(c.hamaliPaid)]),
          Row(children: [
            // left to give the labourers / paid more than taken / all settled
            Expanded(
              child: Text(t(pending > 0 ? 'hamali_left' : pending < 0 ? 'hamali_over' : 'hamali_settled'),
                  style: const TextStyle(fontWeight: FontWeight.bold)),
            ),
            money(pending.abs(), color: pending > 0 ? AppColors.haldi : pending < 0 ? Colors.red.shade700 : Colors.green.shade700, bold: true),
          ]),
          Wrap(alignment: WrapAlignment.end, spacing: 4, children: [
            TextButton.icon(
              icon: const Icon(Icons.add, size: 18),
              label: Text(t('varhai_add')),
              onPressed: () => VoucherScreen.open(context, VoucherType.receipt, partyId: '${app.businessId}:varhai'),
            ),
            TextButton.icon(
              icon: const Icon(Icons.payments_outlined, size: 18),
              label: Text(t('pay_labourers')),
              onPressed: () => VoucherScreen.open(context, VoucherType.payment,
                  partyId: '${app.businessId}:hamali',
                  expense: true,
                  amount: pending > 0 ? pending : null,
                  narration: hamals > 0 ? '$hamals ${t('hamal_count')}' : null),
            ),
          ]),
          if (c.hasTransport) ...[
            const Divider(height: 20, thickness: 1.2),
            // गाडी भाडे, the same way as hamali: taken on bills → drivers' share → ours
            Row(children: [Expanded(child: Text(t('transport_charged'))), money(c.transportCharged)]),
            if (c.driversEarned != 0)
              Row(children: [Expanded(child: Text('− ${t('drivers_share')}')), money(c.driversEarned)]),
            const Divider(height: 12),
            Row(children: [
              Expanded(child: Text(t('transport_ours'), style: const TextStyle(fontWeight: FontWeight.bold))),
              money(c.ownTransport, color: c.ownTransport >= 0 ? Colors.green.shade700 : Colors.red.shade700, bold: true),
            ]),
            if (c.driversPaid != 0) Row(children: [Expanded(child: Text(t('drivers_paid_today'))), money(c.driversPaid)]),
            if (owedTotal > 0)
              Row(children: [
                Expanded(child: Text(t('drivers_owed'), style: const TextStyle(fontWeight: FontWeight.bold))),
                money(owedTotal, color: Colors.red.shade700, bold: true),
              ]),
            if (c.transporters.isNotEmpty) ...[
              const SizedBox(height: 10),
              Row(children: [
                Expanded(flex: 3, child: Text(t('transporter'), style: Theme.of(context).textTheme.bodySmall)),
                Expanded(flex: 2, child: Text(t('earned_today'), textAlign: TextAlign.right, style: Theme.of(context).textTheme.bodySmall)),
                Expanded(flex: 2, child: Text(t('paid_today'), textAlign: TextAlign.right, style: Theme.of(context).textTheme.bodySmall)),
                Expanded(flex: 2, child: Text(t('owed_total'), textAlign: TextAlign.right, style: Theme.of(context).textTheme.bodySmall)),
              ]),
              for (final d in c.transporters)
                InkWell(
                  // tap a driver who is owed to pay him
                  onTap: d.owed > 0
                      ? () => VoucherScreen.open(context, VoucherType.payment, partyId: d.transporter.id, amount: d.owed)
                      : null,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(children: [
                      Expanded(flex: 3, child: Text(d.transporter.display(app.english))),
                      Expanded(flex: 2, child: Align(alignment: Alignment.centerRight, child: money(d.earnedToday))),
                      Expanded(flex: 2, child: Align(alignment: Alignment.centerRight, child: money(d.paidToday))),
                      Expanded(
                          flex: 2,
                          child: Align(
                              alignment: Alignment.centerRight,
                              child: money(d.owed, color: d.owed > 0 ? Colors.red.shade700 : null, bold: true))),
                    ]),
                  ),
                ),
              if (owedTotal > 0)
                Align(
                  alignment: Alignment.centerRight,
                  child: Text(t('tap_driver_to_pay'), style: Theme.of(context).textTheme.bodySmall),
                ),
            ],
            if (c.freightPaid != 0) ...[
              const SizedBox(height: 4),
              // tap: that day's भाडे entries (goods brought in etc.)
              InkWell(
                key: const Key('freight_today'),
                onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => ReportView(
                            load: () => app.reports.ledgerStatement('${app.businessId}:freight', from: c.date, to: c.date)))),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(children: [
                    Expanded(child: Text(t('freight_paid_today'))),
                    Text(Money.fmt(c.freightPaid)),
                    const Icon(Icons.chevron_right, size: 18),
                  ]),
                ),
              ),
            ],
          ],
          const SizedBox(height: 6),
          Align(
            alignment: Alignment.centerLeft, // clear of the + button
            child: FilledButton.icon(
              key: const Key('day_close'),
              icon: const Icon(Icons.nightlight_round, size: 18),
              label: Text(t('day_close')),
              onPressed: () => DayCloseScreen.open(context, date: c.date),
            ),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: const Key('charges_details'),
              icon: const Icon(Icons.list_alt, size: 18),
              label: Text(t('charges_details')),
              onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => ReportView(load: () => app.reports.chargesRegister(c.date, c.date)))),
            ),
          ),
        ],
      ),
    );
  }
}

/// उधारी tab: bills not paid in full today (given / taken) and goods lent.
class _UdhariView extends StatelessWidget {
  final String date;
  const _UdhariView({required this.date});

  @override
  Widget build(BuildContext context) {
    final app = App.of(context);
    final t = app.t;
    final scheme = Theme.of(context).colorScheme;
    return LiveBuilder<UdhariDay>(
      reloadKey: date,
      load: () => app.reports.udhariDay(date),
      builder: (context, d) {
        Widget box(String label, String v, Color c) => Expanded(
              child: Column(children: [
                Text(label, style: Theme.of(context).textTheme.bodySmall),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(v, maxLines: 1, style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: c)),
                ),
              ]),
            );
        Widget section(String title, Color c, List<UdhariRow> rows, {String? total}) => Column(children: [
              Container(
                color: c.withValues(alpha: 0.08),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(children: [
                  Text(title, style: TextStyle(color: c, fontWeight: FontWeight.bold)),
                  const Spacer(),
                  if (total != null) Text(total, style: TextStyle(color: c, fontWeight: FontWeight.bold)),
                ]),
              ),
              for (final r in rows)
                ListTile(
                  dense: true,
                  title: Text('${r.party}${r.pageNo != null ? ' (${r.pageNo})' : ''}'),
                  subtitle: r.items.isEmpty ? null : Text(r.items),
                  trailing: r.type.isGoodsLoan
                      ? Text(t('vt_${r.type.code}'), style: TextStyle(color: c, fontWeight: FontWeight.w600))
                      : Text(Money.fmt(r.amount), style: TextStyle(color: c, fontWeight: FontWeight.bold, fontSize: 15)),
                  onTap: () => VoucherScreen.edit(context, r.voucherId),
                ),
            ]);
        final given = d.rows.where((r) => r.type == VoucherType.sale).toList();
        final taken = d.rows.where((r) => r.type == VoucherType.purchase).toList();
        return ListView(padding: const EdgeInsets.only(bottom: 90), children: [
          Card(
            margin: const EdgeInsets.all(8),
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Row(children: [
                box(t('udhari_given'), Money.fmt(d.given), Colors.orange.shade800),
                box(t('udhari_taken'), Money.fmt(d.taken), scheme.primary),
                box(t('udhari_goods'), '${d.goods.length}', Colors.brown),
              ]),
            ),
          ),
          if (d.rows.isEmpty)
            Padding(padding: const EdgeInsets.all(32), child: Center(child: Text(t('udhari_none')))),
          if (given.isNotEmpty) section(t('udhari_given'), Colors.orange.shade800, given, total: Money.fmt(d.given)),
          if (taken.isNotEmpty) section(t('udhari_taken'), scheme.primary, taken, total: Money.fmt(d.taken)),
          if (d.goods.isNotEmpty) section(t('udhari_goods'), Colors.brown, d.goods),
        ]);
      },
    );
  }
}
