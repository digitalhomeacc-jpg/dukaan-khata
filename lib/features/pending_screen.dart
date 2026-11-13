import 'package:flutter/material.dart';

import '../accounting/ledger_repo.dart';
import '../accounting/models.dart';
import '../core/money.dart';
import '../shared/widgets.dart';
import '../state/app_controller.dart';
import 'voucher_screen.dart';

/// बिलनिहाय बाकी: the bills that make up a customer's / supplier's balance,
/// oldest first, with how long each has been waiting.
class PendingScreen extends StatelessWidget {
  final String ledgerId;
  const PendingScreen({super.key, required this.ledgerId});

  static Future<void> open(BuildContext context, String ledgerId) =>
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => PendingScreen(ledgerId: ledgerId)));

  @override
  Widget build(BuildContext context) {
    final app = App.of(context);
    final t = app.t;
    final today = parseIso(todayIso());
    return Scaffold(
      appBar: AppBar(title: Text(t('pending_bills'))),
      body: LiveBuilder<(Statement, List<PendingBill>)>(
        reloadKey: ledgerId,
        load: () async {
          final st = await app.ledgers.statement(ledgerId);
          return (st, pendingBills(st, Books.start));
        },
        builder: (context, data) {
          final (st, bills) = data;
          int age(PendingBill b) => today.difference(parseIso(b.date)).inDays;
          Color tone(int d) => d > 90
              ? Colors.red.shade700
              : d > 60
                  ? Colors.deepOrange.shade600
                  : d > 30
                      ? Colors.orange.shade700
                      : Colors.green.shade700;
          final buckets = <(String, int, Color)>[
            ('0–30', 0, Colors.green.shade700),
            ('31–60', 0, Colors.orange.shade700),
            ('61–90', 0, Colors.deepOrange.shade600),
            ('90+', 0, Colors.red.shade700),
          ];
          for (final b in bills) {
            final d = age(b);
            final i = d > 90 ? 3 : d > 60 ? 2 : d > 30 ? 1 : 0;
            buckets[i] = (buckets[i].$1, buckets[i].$2 + b.left, buckets[i].$3);
          }
          String label(PendingBill b) {
            final r = b.row;
            if (r == null) return t('opening_lump');
            if (b.old) return '${t('old_${r.kind ?? 'sale'}')} (${t('old_entry_short')})';
            return '${t('vt_${r.type.code}')} #${r.vno}';
          }

          return ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 32), children: [
            Text(st.ledger.name, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(t('pending_help'), style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 12),
            Row(children: [
              for (final (name, amt, c) in buckets)
                Expanded(
                  child: Card(
                    margin: const EdgeInsets.only(right: 6),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 6),
                      child: Column(children: [
                        Text('$name ${t('days')}', style: TextStyle(fontSize: 11, color: c, fontWeight: FontWeight.w600)),
                        const SizedBox(height: 2),
                        FittedBox(
                          child: Text(Money.fmt(amt), style: TextStyle(fontWeight: FontWeight.w800, color: amt == 0 ? Colors.grey : c)),
                        ),
                      ]),
                    ),
                  ),
                ),
            ]),
            const SizedBox(height: 8),
            if (bills.isEmpty)
              Padding(padding: const EdgeInsets.all(24), child: Center(child: Text(t('pending_none'))))
            else
              for (final b in bills)
                Card(
                  margin: const EdgeInsets.only(bottom: 8),
                  child: ListTile(
                    onTap: b.row == null ? null : () => VoucherScreen.edit(context, b.row!.voucherId),
                    leading: SizedBox(
                      width: 52,
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Column(mainAxisSize: MainAxisSize.min, children: [
                          Text('${age(b)}', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: tone(age(b)))),
                          Text(t('days'), style: TextStyle(fontSize: 10, color: tone(age(b)))),
                        ]),
                      ),
                    ),
                    title: Text(label(b), style: const TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: Text([
                      shortDate(b.date),
                      if (b.row != null && b.row!.details.isNotEmpty) b.row!.details,
                    ].join(' · ')),
                    trailing: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerRight,
                      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.end, children: [
                        Text(Money.fmt(b.left), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                        if (b.left != b.amount)
                          Text('${t('pending_of')} ${Money.fmt(b.amount)}', style: Theme.of(context).textTheme.bodySmall),
                      ]),
                    ),
                  ),
                ),
          ]);
        },
      ),
    );
  }
}
