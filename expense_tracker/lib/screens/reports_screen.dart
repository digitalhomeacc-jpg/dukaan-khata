import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';

import '../data/app_data.dart';
import '../logic/reports.dart';
import '../ui/category_style.dart';
import '../ui/format.dart';
import '../ui/range.dart';
import 'transactions_screen.dart';

Future<void> openReports(BuildContext context, AppData data) => Navigator.of(context).push(
  MaterialPageRoute<void>(
    builder: (_) => ListenableBuilder(
      listenable: data,
      builder: (_, _) => ReportsScreen(data: data),
    ),
  ),
);

/// Books for any period, like Tally: each account's statement, income and expenses, and Excel downloads.
class ReportsScreen extends StatefulWidget {
  const ReportsScreen({super.key, required this.data});

  final AppData data;

  @override
  State<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends State<ReportsScreen> {
  var _range = rangePresets().first.range;

  AppData get data => widget.data;

  Future<void> _save(String name, String csv) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final where = await FilePicker.saveFile(
        fileName: name,
        bytes: Uint8List.fromList(utf8.encode(csv)),
        mimeType: 'text/csv',
      );
      if (where != null || mounted) {
        messenger.showSnackBar(SnackBar(content: Text('Saved $name: open it in Excel or Google Sheets')));
      }
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Could not save: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final accounts = data.accounts.where((a) => !a.archived).toList();
    final statements = [for (final a in accounts) accountStatement(data.transactions, a, _range.start, _range.end)];
    final ie = incomeExpense(
      data.transactions,
      _range.start,
      _range.end,
      notSpendingIds: data.notSpendingCategoryIds,
      shares: data.shareTotalsNow,
    );
    final period = rangeLabel(_range);
    final stamp =
        '${DateFormat('yyyy-MM-dd').format(_range.start)}_to_'
        '${DateFormat('yyyy-MM-dd').format(_range.end.subtract(const Duration(days: 1)))}';
    String? categoryName(String? id) => data.category(id)?.name;
    String? groupName(String? id) {
      final c = data.category(id);
      return c?.parentId == null ? null : data.category(c!.parentId)?.name;
    }

    Widget cell(String v, {bool bold = false, Color? color, double width = 78}) => SizedBox(
      width: width,
      child: Text(
        v,
        textAlign: TextAlign.end,
        style: TextStyle(fontWeight: bold ? FontWeight.w700 : FontWeight.w500, color: color, fontSize: 13),
      ),
    );
    String m(double v) => '${v < 0 ? '−' : ''}${money(v.abs())}';

    Widget section(String title, List<Widget> children, {Widget? action}) => Card.outlined(
      margin: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(title, style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                ),
                ?action,
              ],
            ),
            const SizedBox(height: 8),
            ...children,
          ],
        ),
      ),
    );

    return Scaffold(
      appBar: AppBar(title: const Text('Reports')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          Center(
            child: RangeBar(range: _range, onChanged: (r) => setState(() => _range = r)),
          ),
          RangeChips(range: _range, onChanged: (r) => setState(() => _range = r)),
          const SizedBox(height: 6),

          // Account statements
          section(
            'Account statements',
            [
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const SizedBox(width: 120, child: Text('Account', style: TextStyle(fontSize: 12))),
                        for (final h in ['Opening', 'In', 'Out', 'Closing']) cell(h, width: 86),
                      ],
                    ),
                    const Divider(),
                    for (final s in statements)
                      InkWell(
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => ListenableBuilder(
                              listenable: data,
                              builder: (_, _) => TransactionsScreen(data: data, accountId: s.account.id),
                            ),
                          ),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          child: Row(
                            children: [
                              SizedBox(
                                width: 120,
                                child: Text(s.account.name, maxLines: 2, overflow: TextOverflow.ellipsis),
                              ),
                              cell(m(s.opening), width: 86),
                              cell(money(s.moneyIn), color: Colors.green.shade700, width: 86),
                              cell(money(s.moneyOut), color: scheme.error, width: 86),
                              cell(m(s.closing), bold: true, width: 86),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              Text(
                'Opening + in − out = closing, for every account. Tap one for its ledger.',
                style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
            action: IconButton(
              tooltip: 'Download account statements',
              icon: const Icon(Icons.download),
              onPressed: () => _save('account-statements_$stamp.csv', statementsCsv(statements, period)),
            ),
          ),

          // Income and expenses
          section(
            'Income and expenses',
            [
              Text('Income', style: text.titleSmall?.copyWith(color: Colors.green.shade700)),
              for (final e in ie.income)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: CategoryAvatar(data.category(e.key), size: 26),
                  title: Text(categoryName(e.key) ?? 'No category'),
                  trailing: Text(money(e.value)),
                ),
              _total('Total income', ie.totalIncome, Colors.green.shade700),
              const SizedBox(height: 10),
              Text('Expenses', style: text.titleSmall?.copyWith(color: scheme.error)),
              for (final e in ie.expenses)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: CategoryAvatar(data.category(e.key), size: 26),
                  title: Text([?groupName(e.key), categoryName(e.key) ?? 'No category'].join(' › ')),
                  trailing: Text(money(e.value)),
                ),
              _total('Total expenses', ie.totalExpenses, scheme.error),
              const Divider(height: 20),
              _total(
                ie.totalIncome >= ie.totalExpenses ? 'Kept' : 'Spent more than came in',
                ie.totalIncome - ie.totalExpenses,
                ie.totalIncome >= ie.totalExpenses ? Colors.green.shade700 : scheme.error,
              ),
            ],
            action: IconButton(
              tooltip: 'Download income and expenses',
              icon: const Icon(Icons.download),
              onPressed: () => _save('income-expenses_$stamp.csv', incomeExpenseCsv(ie, period, categoryName)),
            ),
          ),

          // Downloads
          section('Download for Excel', [
            Text(
              'Files open in Excel, Google Sheets or Numbers. Everything for $period.',
              style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(44)),
              onPressed: () => _save(
                'transactions_$stamp.csv',
                transactionsCsv(
                  data.transactions,
                  _range.start,
                  _range.end,
                  categoryName: categoryName,
                  groupName: groupName,
                  accountName: (id) => data.account(id)?.name,
                  shares: data.shareTotalsNow,
                ),
              ),
              icon: const Icon(Icons.table_view_outlined),
              label: const Text('All transactions'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(44)),
              onPressed: () => _save('account-statements_$stamp.csv', statementsCsv(statements, period)),
              icon: const Icon(Icons.account_balance_outlined),
              label: const Text('Account statements'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(44)),
              onPressed: () => _save('income-expenses_$stamp.csv', incomeExpenseCsv(ie, period, categoryName)),
              icon: const Icon(Icons.summarize_outlined),
              label: const Text('Income and expenses'),
            ),
          ]),
        ],
      ),
    );
  }

  Widget _total(String label, double v, Color color) => Row(
    children: [
      Expanded(
        child: Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
      ),
      Text(
        '${v < 0 ? '−' : ''}${money(v.abs())}',
        style: TextStyle(fontWeight: FontWeight.w700, color: color),
      ),
    ],
  );
}
