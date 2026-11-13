import 'package:flutter/material.dart';

import '../accounting/models.dart';
import '../core/money.dart';
import '../shared/widgets.dart';
import '../state/app_controller.dart';
import 'parties_screen.dart';

/// हिशोब पुन्हा तपासायचे: customers / suppliers marked for a manual re-check.
class RecheckScreen extends StatelessWidget {
  const RecheckScreen({super.key});

  static Future<void> open(BuildContext context) =>
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => const RecheckScreen()));

  @override
  Widget build(BuildContext context) {
    final app = App.of(context);
    final t = app.t;
    return Scaffold(
      appBar: AppBar(title: Text(t('recheck_list'))),
      body: LiveBuilder<List<(Ledger, String)>>(
        tables: const ['ledgers', 'voucher_lines', 'audit_log'],
        load: () async {
          final marks = await app.ledgers.recheckMarks();
          final all = await app.ledgers.list([LedgerGroup.customer, LedgerGroup.supplier]);
          return [
            for (final l in all)
              if (marks.containsKey(l.id)) (l, marks[l.id]!)
          ];
        },
        builder: (context, list) => ListView(padding: const EdgeInsets.fromLTRB(12, 8, 12, 32), children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 10),
            child: Text(t('recheck_help'), style: Theme.of(context).textTheme.bodySmall),
          ),
          if (list.isEmpty) Padding(padding: const EdgeInsets.all(24), child: Center(child: Text(t('recheck_none')))),
          for (final (l, note) in list)
            Card(
              margin: const EdgeInsets.only(bottom: 8),
              child: ListTile(
                onTap: () => KhataScreen.open(context, l.id),
                leading: const Icon(Icons.flag, color: Colors.deepOrange),
                title: Text(l.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                subtitle: Text([if (l.pageNo != null) '${t('page_no')} ${l.pageNo}', if (note.isNotEmpty) note].join(' · ')),
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  BalanceText(l.balance, supplier: l.group == LedgerGroup.supplier),
                  IconButton(
                    tooltip: t('recheck_done'),
                    icon: const Icon(Icons.check_circle_outline),
                    onPressed: () => app.ledgers.setRecheck(l.id, l.name, false),
                  ),
                ]),
              ),
            ),
        ]),
      ),
    );
  }
}

/// Customers / suppliers whose old entries don't add up to the opening
/// balance yet (or who have an opening balance but no old entries at all).
class OldMismatchScreen extends StatelessWidget {
  const OldMismatchScreen({super.key});

  static Future<void> open(BuildContext context) =>
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => const OldMismatchScreen()));

  @override
  Widget build(BuildContext context) {
    final app = App.of(context);
    final t = app.t;
    String bal(int b) => b == 0 ? '0' : '${Money.fmt(b, abs: true)} ${b > 0 ? t('dr_short') : t('cr_short')}';
    return Scaffold(
      appBar: AppBar(title: Text(t('old_mismatch_list'))),
      body: LiveBuilder<(List<(Ledger, int, int)>, int)>(
        load: () async {
          final olds = await app.ledgers.oldSummaries();
          final all = await app.ledgers.list([LedgerGroup.customer, LedgerGroup.supplier]);
          var done = 0;
          final out = <(Ledger, int, int)>[];
          for (final l in all) {
            if (l.openingBalance == 0 && !olds.containsKey(l.id)) continue;
            final o = olds[l.id];
            final total = o?.total ?? 0;
            if (total == l.openingBalance) {
              done++;
            } else {
              out.add((l, total, o?.count ?? 0));
            }
          }
          return (out, done);
        },
        builder: (context, data) {
          final (list, done) = data;
          return ListView(padding: const EdgeInsets.fromLTRB(12, 8, 12, 32), children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 0, 4, 10),
              child: Text(
                '${t('old_mismatch_help')}\n${t('old_mismatch_count').replaceAll('{n}', '${list.length}').replaceAll('{d}', '$done')}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            if (list.isEmpty) Padding(padding: const EdgeInsets.all(24), child: Center(child: Text(t('old_mismatch_none')))),
            for (final (l, total, n) in list)
              Card(
                margin: const EdgeInsets.only(bottom: 8),
                child: ListTile(
                  onTap: () => KhataScreen.open(context, l.id),
                  title: Text(l.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: Text([
                    if (l.pageNo != null) '${t('page_no')} ${l.pageNo}',
                    '${t('opening_balance')} ${bal(l.openingBalance)}',
                    n == 0 ? t('old_mismatch_no_entries') : '${t('old_total')} ${bal(total)} ($n)',
                  ].join(' · ')),
                  trailing: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
                    Text(t('old_diff_short'), style: Theme.of(context).textTheme.bodySmall),
                    Text(bal(l.openingBalance - total),
                        style: const TextStyle(fontWeight: FontWeight.w800, color: Colors.deepOrange)),
                  ]),
                ),
              ),
          ]);
        },
      ),
    );
  }
}
