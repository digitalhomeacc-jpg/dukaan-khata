import 'package:material_ui/material_ui.dart';

import '../data/app_data.dart';
import '../logic/summary.dart';
import '../models.dart';
import '../ui/category_style.dart';
import '../ui/format.dart';
import 'budgets_screen.dart';
import 'import_statement_screen.dart';
import 'month_bar.dart';
import 'txn_editor.dart';

enum _Filter { all, spent, received, uncategorised }

class TransactionsScreen extends StatefulWidget {
  const TransactionsScreen({super.key, required this.data, this.accountId});

  final AppData data;

  /// Opened from the Accounts tab: only this account's transactions.
  final String? accountId;

  @override
  State<TransactionsScreen> createState() => _TransactionsScreenState();
}

class _TransactionsScreenState extends State<TransactionsScreen> {
  var _month = monthStart(DateTime.now());
  var _filter = _Filter.all;
  var _query = '';
  late String? _accountId = widget.accountId;

  bool _keep(Txn t) {
    if (!inMonth(t.txnAt, _month)) return false;
    if (_accountId != null && t.accountId != _accountId && t.counterAccountId != _accountId) return false;
    final ok = switch (_filter) {
      _Filter.all => true,
      _Filter.spent => t.isDebit,
      _Filter.received => !t.isDebit,
      _Filter.uncategorised => t.categoryId == null && !t.excluded,
    };
    if (!ok) return false;
    if (_query.isEmpty) return true;
    final q = _query.toLowerCase();
    return t.title.toLowerCase().contains(q) ||
        (t.note ?? '').toLowerCase().contains(q) ||
        (widget.data.category(t.categoryId)?.name.toLowerCase().contains(q) ?? false);
  }

  @override
  Widget build(BuildContext context) {
    final data = widget.data;
    final loans = data.notSpendingCategoryIds;
    final summary = summarize(
      _accountId == null ? data.transactions : data.transactions.where((t) => t.accountId == _accountId),
      _month,
      loanCategoryIds: loans,
      shares: data.shareTotalsNow,
    );
    final account = data.account(_accountId);
    final running = account == null ? const <String, double>{} : runningBalances(data.transactions, account);
    final check = account == null ? null : checkBalance(data.transactions, account, data.balanceReadings);
    final shown = data.transactions.where(_keep).toList();
    final days = groupByDay(shown);
    final uncategorised =
        data.transactions.where((t) => inMonth(t.txnAt, _month) && t.categoryId == null && !t.excluded && t.isDebit).length;

    return Scaffold(
      appBar: AppBar(
        title: MonthBar(month: _month, onChanged: (m) => setState(() => _month = m)),
        centerTitle: true,
        actions: [
          if (widget.accountId != null && account != null && account.kind == AccountKind.bank)
            IconButton(
              tooltip: 'Import bank statement',
              icon: const Icon(Icons.upload_file),
              onPressed: () => openImportStatement(context, data, account: account),
            ),
          if (widget.accountId == null)
            PopupMenuButton<String?>(
              tooltip: 'Show one account',
              icon: Icon(_accountId == null ? Icons.filter_list : Icons.filter_list_alt),
              initialValue: _accountId,
              onSelected: (id) => setState(() => _accountId = id == '' ? null : id),
              itemBuilder: (_) => [
                const PopupMenuItem(value: '', child: Text('All accounts')),
                for (final a in data.accounts)
                  PopupMenuItem(
                    value: a.id,
                    child: ListTile(dense: true, leading: Icon(accountIcon(a)), title: Text(a.name)),
                  ),
              ],
            ),
        ],
      ),
      body: !data.loaded
          ? Center(
              child: data.error == null
                  ? const CircularProgressIndicator()
                  : Padding(padding: const EdgeInsets.all(24), child: Text('Could not load: ${data.error}')),
            )
          : CustomScrollView(
              slivers: [
                if (account != null)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                      child: InputChip(
                        avatar: Icon(accountIcon(account), size: 18),
                        label: Text(account.name),
                        onDeleted: widget.accountId == null ? () => setState(() => _accountId = null) : null,
                      ),
                    ),
                  ),
                if (account != null && check != null)
                  SliverToBoxAdapter(child: BalanceCheckCard(data: data, account: account, check: check)),
                SliverToBoxAdapter(child: _SummaryCard(summary: summary)),
                if (_accountId == null)
                  for (final p in budgetProgress(data.budgets.where((b) => b.categoryId == null), summary))
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                        child: BudgetBar(progress: p),
                      ),
                    ),
                if (uncategorised > 0 && _filter != _Filter.uncategorised)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                      child: Card.filled(
                        child: ListTile(
                          leading: const Icon(Icons.label_off_outlined),
                          title: Text('$uncategorised ${uncategorised == 1 ? 'payment needs' : 'payments need'} a category'),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => setState(() => _filter = _Filter.uncategorised),
                        ),
                      ),
                    ),
                  ),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                    child: TextField(
                      decoration: const InputDecoration(
                        prefixIcon: Icon(Icons.search),
                        hintText: 'Search merchant, note or category',
                        isDense: true,
                      ),
                      onChanged: (v) => setState(() => _query = v.trim()),
                    ),
                  ),
                ),
                SliverToBoxAdapter(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                    child: Row(
                      children: [
                        for (final f in _Filter.values)
                          Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: ChoiceChip(
                              label: Text(switch (f) {
                                _Filter.all => 'All',
                                _Filter.spent => 'Spent',
                                _Filter.received => 'Received',
                                _Filter.uncategorised => 'No category',
                              }),
                              selected: _filter == f,
                              onSelected: (_) => setState(() => _filter = f),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                if (days.isEmpty)
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: _EmptyState(hasAny: data.transactions.isNotEmpty),
                  ),
                for (final day in days) ...[
                  SliverToBoxAdapter(child: _DayHeader(day: day.key, txns: day.value, loanCategoryIds: loans, shares: data.shareTotalsNow)),
                  SliverList.builder(
                    itemCount: day.value.length,
                    itemBuilder: (context, i) => TxnTile(txn: day.value[i], data: data, balanceAfter: running[day.value[i].id]),
                  ),
                ],
                const SliverToBoxAdapter(child: SizedBox(height: 96)),
              ],
            ),
    );
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.summary});

  final MonthSummary summary;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget cell(String label, String value, Color color) => Expanded(
          child: Column(
            children: [
              Text(label, style: TextStyle(color: scheme.onPrimaryContainer.withValues(alpha: 0.8))),
              const SizedBox(height: 4),
              FittedBox(
                child: Text(value, style: Theme.of(context).textTheme.titleLarge?.copyWith(color: color, fontWeight: FontWeight.w600)),
              ),
            ],
          ),
        );
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Card(
        color: scheme.primaryContainer,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 8),
          child: Row(
            children: [
              cell('Spent', money(summary.spent), scheme.onPrimaryContainer),
              cell('Received', money(summary.received), scheme.onPrimaryContainer),
              cell('Net', '${summary.net < 0 ? '−' : ''}${money(summary.net.abs())}', scheme.onPrimaryContainer),
            ],
          ),
        ),
      ),
    );
  }
}

class _DayHeader extends StatelessWidget {
  const _DayHeader({required this.day, required this.txns, required this.loanCategoryIds, required this.shares});

  final DateTime day;
  final List<Txn> txns;
  final Set<String> loanCategoryIds;
  final ShareTotals shares;

  @override
  Widget build(BuildContext context) {
    final spent = txns.where((t) => t.isDebit && counts(t, loanCategoryIds)).fold(0.0, (s, t) => s + shares.own(t));
    final style = Theme.of(context).textTheme.labelLarge?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Row(
        children: [
          Expanded(child: Text(dayLabel(day), style: style)),
          if (spent > 0) Text('Spent ${money(spent)}', style: style),
        ],
      ),
    );
  }
}

class TxnTile extends StatelessWidget {
  const TxnTile({super.key, required this.txn, required this.data, this.balanceAfter});

  final Txn txn;
  final AppData data;

  /// Account balance after this transaction (shown when looking at one account).
  final double? balanceAfter;

  String? _accountText() {
    final a = data.account(txn.accountId);
    final from = a?.name ??
        (txn.bank == null ? null : '${txn.bank}${txn.accountLast4 != null ? ' ••${txn.accountLast4}' : ''}');
    final other = data.account(txn.counterAccountId);
    if (txn.excluded && other != null) return txn.isDebit ? '${from ?? '?'} → ${other.name}' : '${other.name} → ${from ?? '?'}';
    return from;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final cat = data.category(txn.categoryId);
    var details = [
      cat?.name ?? (txn.isDebit ? 'No category' : null),
      _accountText(),
      timeLabel(txn.txnAt),
    ].whereType<String>().join(' · ');
    final lenderLoan = data.loan(txn.loanId);
    final isLoan = (cat?.isLoan ?? false) || txn.isLoanTransfer;
    if (txn.isLoanTransfer) {
      details = '${txn.loanRole == 'borrow' ? 'Borrowed' : 'Loan payment'}${lenderLoan != null ? ' · ${lenderLoan.name}' : ''} · $details';
    } else if (txn.loanRole == 'spend' && lenderLoan != null) {
      details = 'Paid with ${lenderLoan.name} · $details';
    } else if (isLoan) {
      details = '${txn.isDebit ? 'Lent / repaid' : 'Borrowed / got back'} · $details';
    }
    final mySplit = data.sharesOf(txn.id);
    final paidBack = data.sharesPaidBy(txn.id);
    if (mySplit.isNotEmpty) {
      final own = data.shareTotalsNow.own(txn);
      final open = mySplit.where((s) => !s.paid).length;
      details = 'Your share ${money(own)}${open > 0 ? ' · $open to pay you' : ''} · $details';
    } else if (paidBack.isNotEmpty) {
      details = 'Paid back: ${paidBack.map((s) => s.person).toSet().join(', ')}\'s share · $details';
    }
    final notMine = paidBack.isNotEmpty && data.shareTotalsNow.own(txn) == 0;
    final amountColor = txn.excluded || isLoan || notMine ? scheme.outline : (txn.isDebit ? scheme.onSurface : Colors.green.shade700);
    return ListTile(
      leading: CategoryAvatar(cat),
      title: Text(txn.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        txn.excluded ? 'Not counted · $details' : details,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (txn.fromEmail) Icon(Icons.mail_outline, size: 14, color: scheme.outline),
          const SizedBox(width: 4),
          Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                signedMoney(txn.amount, isDebit: txn.isDebit),
                style: TextStyle(
                  color: amountColor,
                  fontWeight: FontWeight.w600,
                  decoration: txn.excluded ? TextDecoration.lineThrough : null,
                ),
              ),
              if (balanceAfter != null)
                Text('Bal ${balanceAfter! < 0 ? '−' : ''}${money(balanceAfter!.abs())}',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.outline)),
            ],
          ),
        ],
      ),
      onTap: () => openTxnEditor(context, data, existing: txn),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.hasAny});

  final bool hasAny;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.inbox_outlined, size: 56, color: Theme.of(context).colorScheme.outline),
            const SizedBox(height: 12),
            Text(
              hasAny
                  ? 'Nothing here for this month.'
                  : 'No transactions yet.\nTap Add, or connect Gmail in Settings so bank alerts arrive here automatically.',
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
}

/// Bank's balance (from its email) next to the app's, with the difference.
class BalanceCheckCard extends StatelessWidget {
  const BalanceCheckCard({super.key, required this.data, required this.account, required this.check});

  final AppData data;
  final Account account;
  final BalanceCheck check;

  Future<void> _match(BuildContext context) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Use the bank\'s balance?'),
        content: Text(
          'The opening balance of ${account.name} changes by ${check.difference < 0 ? '−' : '+'}${money(check.difference.abs())} '
          'so the app shows ${money(check.bank)} on ${dayLabel(check.asOf)}, like the bank. '
          'Better first: add any missing transaction (cash deposit, card charge, bank fee) if you know it.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Use bank balance')),
        ],
      ),
    );
    if (yes == true) await data.matchBankBalance(account, check.difference);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final ok = check.matches;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Card.outlined(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(ok ? Icons.verified_outlined : Icons.warning_amber_rounded,
                      color: ok ? Colors.green.shade700 : scheme.error, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(ok ? 'Matches the bank' : 'Differs from the bank by ${money(check.difference.abs())}',
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text('Bank: ${money(check.bank)} · App: ${check.app < 0 ? '−' : ''}${money(check.app.abs())} · ${dayLabel(check.asOf)}, ${timeLabel(check.asOf)}',
                  style: Theme.of(context).textTheme.bodySmall),
              if (!ok) ...[
                const SizedBox(height: 6),
                Text(
                  check.difference > 0
                      ? 'The bank has more: money came in that the app has not seen (e.g. a cash deposit or a refund).'
                      : 'The bank has less: money went out that the app has not seen (e.g. a card charge, ATM or bank fee).',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(onPressed: () => _match(context), child: const Text('Use bank balance')),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
