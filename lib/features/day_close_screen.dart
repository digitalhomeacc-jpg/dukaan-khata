import 'package:flutter/material.dart';

import '../accounting/ledger_repo.dart';
import '../accounting/models.dart';
import '../accounting/reports.dart';
import '../core/money.dart';
import '../core/theme.dart';
import '../shared/export.dart';
import '../shared/widgets.dart';
import '../state/app_controller.dart';
import 'cash_count_screen.dart';
import 'voucher_screen.dart';

/// दिवस बंद करा: the evening routine on one page – count the cash, pay the
/// labourers and drivers, then send the day's summary on WhatsApp.
class DayCloseScreen extends StatefulWidget {
  final String date;
  const DayCloseScreen({super.key, required this.date});
  static Future<void> open(BuildContext context, {String? date}) =>
      Navigator.push(context, MaterialPageRoute(builder: (_) => DayCloseScreen(date: date ?? todayIso())));
  @override
  State<DayCloseScreen> createState() => _DayCloseScreenState();
}

class _DayData {
  final DayCharges charges;
  final Map<String, int> dash;
  final UdhariDay udhari;
  final int expenses;
  final int cashDiff; // + extra, − short (from today's cash count), 0 = none / matched
  final bool counted;
  final List<Item> low;
  _DayData(this.charges, this.dash, this.udhari, this.expenses, this.cashDiff, this.counted, this.low);
}

class _DayCloseScreenState extends State<DayCloseScreen> {
  String get date => widget.date;

  Future<_DayData> _load(AppController app) async {
    final b = app.businessId;
    final exp = await app.db.get(
        'SELECT COALESCE(SUM(vl.debit - vl.credit), 0) AS s FROM voucher_lines vl JOIN ledgers l ON l.id = vl.ledger_id '
        "JOIN vouchers v ON v.id = vl.voucher_id WHERE vl.business_id = ? AND vl.vdate = ? AND vl.deleted = 0 AND v.vtype = 'payment' "
        "AND l.grp IN ('expense', 'direct_expense') AND l.id <> ?",
        [b, date, '$b:cash_diff']);
    final diff = await app.db.get(
        'SELECT COALESCE(SUM(credit - debit), 0) AS s, COUNT(*) AS n FROM voucher_lines WHERE ledger_id = ? AND vdate = ? AND deleted = 0',
        ['$b:cash_diff', date]);
    return _DayData(
      await app.ledgers.dayCharges(date),
      await app.ledgers.dashboard(date),
      await app.reports.udhariDay(date),
      (exp['s'] as num).toInt(),
      (diff['s'] as num).toInt(),
      (diff['n'] as int) > 0 || app.prefInt('counted_$date', 0) == 1,
      (await app.stock.list()).where((i) => i.lowStock > 0 && i.stock <= i.lowStock).toList(),
    );
  }

  /// The message for WhatsApp (plain text, *bold* headings).
  String _summary(AppController app, _DayData d) {
    final t = app.t;
    String m(int v) => '₹${Money.fmt(v)}';
    final c = d.charges;
    return [
      '*${app.businessName}* – ${shortDate(date)}',
      '${t('today_sales')}: ${m(d.dash['sales']!)}',
      '${t('today_collection')}: ${m(d.dash['collections']!)}',
      if (d.udhari.given > 0) '${t('udhari_given')}: ${m(d.udhari.given)}',
      if (d.udhari.taken > 0) '${t('udhari_taken')}: ${m(d.udhari.taken)}',
      if (d.expenses > 0) '${t('expense')}: ${m(d.expenses)}',
      if (c.hamaliToPay != 0 || c.hamaliPaid != 0) '${t('hamali')}: ${Money.fmt(c.hamaliToPay)} / ${Money.fmt(c.hamaliPaid)}',
      if (c.transportCharged != 0) '${t('transport')}: ${Money.fmt(c.transportCharged)}${c.driversOwed > 0 ? ' · ${t('drivers_owed')} ${m(c.driversOwed)}' : ''}',
      if (app.actor.isOwner) ...[
        '',
        '${t('cash_in_hand')}: ${m(d.dash['cash']!)}',
        '${t('upi_balance')}: ${m(d.dash['upi']!)}',
        '${t('bank_balance')}: ${m(d.dash['bank']!)}',
      ],
      if (d.cashDiff != 0) '${t(d.cashDiff < 0 ? 'cash_short' : 'cash_extra')}: ${m(d.cashDiff.abs())}',
      if (d.low.isNotEmpty) ...[
        '',
        '*${t('low_stock_items')}*: ${d.low.map((i) => '${i.display(app.english)} ${fmtQty(i.stock)}').join(', ')}',
      ],
    ].join('\n');
  }

  @override
  Widget build(BuildContext context) {
    final app = App.of(context);
    final t = app.t;
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text('${t('day_close')} · ${shortDate(date)}')),
      body: LiveBuilder<_DayData>(
        reloadKey: '$date|${app.prefInt('hamals_$date', 0)}|${app.prefInt('counted_$date', 0)}',
        load: () => _load(app),
        builder: (context, d) {
          final c = d.charges;
          final hamals = app.prefInt('hamals_$date', 0);
          final minTotal = hamals * app.prefInt('hamal_min', 300) * 100;
          final toPay = c.hamaliToPay > minTotal ? c.hamaliToPay : minTotal;
          final hamaliPending = toPay - c.hamaliPaid;
          final owed = c.transporters.where((x) => x.owed > 0).toList();

          Widget step(int n, String title, String sub, bool done, {Widget? action, List<Widget> more = const []}) => Card(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      CircleAvatar(
                        radius: 15,
                        backgroundColor: done ? AppColors.paid : scheme.surfaceContainerHighest,
                        child: done
                            ? const Icon(Icons.check, size: 18, color: Colors.white)
                            : Text('$n', style: TextStyle(fontWeight: FontWeight.w800, color: scheme.onSurface)),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
                          Text(sub, style: Theme.of(context).textTheme.bodySmall),
                        ]),
                      ),
                      ?action,
                    ]),
                    ...more,
                  ]),
                ),
              );

          final text = _summary(app, d);
          return ListView(padding: const EdgeInsets.fromLTRB(12, 8, 12, 24), children: [
            // 1 · cash
            step(
              1,
              t('cash_count'),
              d.cashDiff != 0
                  ? '${t(d.cashDiff < 0 ? 'cash_short' : 'cash_extra')} ₹${Money.fmt(d.cashDiff.abs())}'
                  : app.actor.isOwner
                      ? '${t('cash_in_hand')}: ₹${Money.fmt(d.dash['cash']!)}'
                      : t('cash_count_sub'),
              d.counted,
              action: FilledButton.tonal(
                key: const Key('close_count'),
                onPressed: () async {
                  await CashCountScreen.open(context, date: date);
                  await app.setPrefInt('counted_$date', 1);
                },
                child: Text(t('close_count_btn')),
              ),
            ),
            // 2 · labourers
            step(
              2,
              t('hamali'),
              '${t('hamali_to_pay')}: ₹${Money.fmt(toPay)} · ${t('hamali_paid')}: ₹${Money.fmt(c.hamaliPaid)}',
              hamaliPending <= 0 && (toPay > 0 || c.hamaliPaid > 0),
              action: hamaliPending > 0
                  ? FilledButton.tonal(
                      key: const Key('close_hamali'),
                      onPressed: () => VoucherScreen.open(context, VoucherType.payment,
                          partyId: '${app.businessId}:hamali',
                          expense: true,
                          amount: hamaliPending,
                          narration: hamals > 0 ? '$hamals ${t('hamal_count')}' : null),
                      child: Text('${t('pay_now')} ₹${Money.fmt(hamaliPending)}'),
                    )
                  : null,
              more: [
                Padding(
                  padding: const EdgeInsets.only(top: 6, left: 42),
                  child: Row(children: [
                    Expanded(child: Text(t('hamal_count'))),
                    IconButton.filledTonal(
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(Icons.remove, size: 18),
                        onPressed: hamals > 0 ? () => app.setPrefInt('hamals_$date', hamals - 1) : null),
                    SizedBox(width: 36, child: Text('$hamals', textAlign: TextAlign.center, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800))),
                    IconButton.filledTonal(
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(Icons.add, size: 18),
                        onPressed: () => app.setPrefInt('hamals_$date', hamals + 1)),
                  ]),
                ),
                if (minTotal > c.hamaliToPay)
                  Padding(
                    padding: const EdgeInsets.only(left: 42),
                    child: Text('${t('hamal_pocket')}: ₹${Money.fmt(minTotal - c.hamaliToPay)}',
                        style: TextStyle(color: Colors.red.shade700, fontWeight: FontWeight.w600)),
                  ),
              ],
            ),
            // 3 · drivers
            step(
              3,
              t('transporters'),
              owed.isEmpty ? t('close_none_owed') : '${t('drivers_owed')}: ₹${Money.fmt(c.driversOwed)}',
              owed.isEmpty,
              more: [
                for (final x in owed)
                  Padding(
                    padding: const EdgeInsets.only(left: 42, top: 4),
                    child: Row(children: [
                      Expanded(child: Text(x.transporter.display(app.english))),
                      FilledButton.tonal(
                        onPressed: () => VoucherScreen.open(context, VoucherType.payment, partyId: x.transporter.id, amount: x.owed),
                        child: Text('${t('pay_now')} ₹${Money.fmt(x.owed)}'),
                      ),
                    ]),
                  ),
              ],
            ),
            // 4 · the day in one message
            const SizedBox(height: 6),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(t('close_summary'), style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 8),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(color: scheme.surfaceContainerHighest.withValues(alpha: 0.6), borderRadius: BorderRadius.circular(12)),
                    child: Text(text.replaceAll('*', ''), style: const TextStyle(height: 1.5)),
                  ),
                  const SizedBox(height: 10),
                  Row(children: [
                    Expanded(
                      child: FilledButton.icon(
                        key: const Key('close_send'),
                        style: FilledButton.styleFrom(backgroundColor: const Color(0xFF25A35A)),
                        icon: const Icon(Icons.send),
                        label: Text(t('close_send')),
                        onPressed: () => WhatsApp.send(app.prefStr('summary_phone'), text),
                      ),
                    ),
                    const SizedBox(width: 8),
                    // whose WhatsApp it goes to (empty = choose each time)
                    IconButton.filledTonal(
                      tooltip: t('close_phone'),
                      icon: const Icon(Icons.person_outline),
                      onPressed: () async {
                        final ctl = TextEditingController(text: app.prefStr('summary_phone'));
                        final v = await showDialog<String>(
                          context: context,
                          builder: (ctx) => AlertDialog(
                            title: Text(t('close_phone')),
                            content: TextField(
                                controller: ctl,
                                autofocus: true,
                                keyboardType: TextInputType.phone,
                                decoration: InputDecoration(hintText: '98xxxxxxxx', helperText: t('close_phone_help'))),
                            actions: [FilledButton(onPressed: () => Navigator.pop(ctx, ctl.text.trim()), child: Text(t('save')))],
                          ),
                        );
                        if (v != null) await app.setPrefStr('summary_phone', v);
                      },
                    ),
                  ]),
                  if (app.prefStr('summary_phone').isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text('→ ${app.prefStr('summary_phone')}', style: Theme.of(context).textTheme.bodySmall),
                    ),
                ]),
              ),
            ),
          ]);
        },
      ),
    );
  }
}
