import 'package:material_ui/material_ui.dart';

import '../data/app_data.dart';
import '../logic/summary.dart';
import '../models.dart';
import '../ui/format.dart';
import 'lender_loans.dart';
import 'txn_editor.dart';

/// Money borrowed from and lent to friends, with each friend's balance.
class LoansScreen extends StatelessWidget {
  const LoansScreen({super.key, required this.data});

  final AppData data;

  @override
  Widget build(BuildContext context) {
    final loans = loanBalances(data.transactions, data.loanCategoryIds);
    final lenderLoans = data.loans.where((l) => !l.closed).toList();
    final lenderOwed = lenderLoans.fold(0.0, (s, l) => s + loanStatus(l, data.loanEvents).owed);
    final iOwe = loans.where((l) => l.balance > 0).fold(0.0, (s, l) => s + l.balance) + lenderOwed;
    final owedToMe = loans.where((l) => l.balance < 0).fold(0.0, (s, l) => s - l.balance);
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Loans')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 96),
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Card(
              color: scheme.primaryContainer,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 8),
                child: Row(
                  children: [
                    _total(context, 'You owe', iOwe),
                    _total(context, 'Owed to you', owedToMe),
                  ],
                ),
              ),
            ),
          ),
          _SectionHeader(
            title: 'Loans & credit',
            action: TextButton.icon(
              onPressed: () => openLoanForm(context, data),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Add a loan'),
            ),
          ),
          if (lenderLoans.isEmpty)
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text('Slice borrow appears here by itself from its emails. Add KreditBee, Fibe or any other loan with “Add a loan”.'),
            ),
          for (final l in lenderLoans) LenderLoanCard(data: data, loan: l),
          const SizedBox(height: 8),
          const _SectionHeader(title: 'Friends'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Expanded(
                  child: FilledButton.tonalIcon(
                    onPressed: () => newLoanEntry(context, data, borrowed: true),
                    icon: const Icon(Icons.call_received),
                    label: const Text('I borrowed'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.tonalIcon(
                    onPressed: () => newLoanEntry(context, data, borrowed: false),
                    icon: const Icon(Icons.call_made),
                    label: const Text('I lent'),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          if (loans.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'Record money you borrowed from or lent to a friend. '
                'You can also put a bank payment under the "Personal loans" category, with the friend\'s name.',
                textAlign: TextAlign.center,
              ),
            ),
          for (final l in loans)
            ListTile(
              leading: CircleAvatar(child: Text(l.person.isEmpty ? '?' : l.person[0].toUpperCase())),
              title: Text(l.person),
              subtitle: Text(l.settled
                  ? 'Settled'
                  : l.balance > 0
                      ? 'You owe'
                      : 'Owes you'),
              trailing: Text(
                l.settled ? '' : money(l.balance.abs()),
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: l.balance > 0 ? scheme.error : Colors.green.shade700,
                ),
              ),
              onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                builder: (_) => ListenableBuilder(
                  listenable: data,
                  builder: (context, _) => _PersonLoans(data: data, person: l.person),
                ),
              )),
            ),
        ],
      ),
    );
  }

  Widget _total(BuildContext context, String label, double v) {
    final color = Theme.of(context).colorScheme.onPrimaryContainer;
    return Expanded(
      child: Column(
        children: [
          Text(label, style: TextStyle(color: color.withValues(alpha: 0.8))),
          const SizedBox(height: 4),
          FittedBox(
            child: Text(money(v),
                style: Theme.of(context).textTheme.titleLarge?.copyWith(color: color, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }
}

/// Opens the editor for a loan entry. Received money = borrowed / repaid to you.
Future<void> newLoanEntry(BuildContext context, AppData data, {required bool borrowed, String? person}) async {
  final Category cat;
  try {
    cat = await data.ensureLoanCategory();
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not make the loan category: $e')));
    }
    return;
  }
  if (!context.mounted) return;
  await openTxnEditor(
    context,
    data,
    prefill: Txn(
      id: '',
      amount: 0,
      isDebit: !borrowed,
      txnAt: DateTime.now(),
      merchant: person,
      categoryId: cat.id,
      accountId: data.cashAccount?.id,
      method: 'cash',
    ),
  );
}

class _PersonLoans extends StatelessWidget {
  const _PersonLoans({required this.data, required this.person});

  final AppData data;
  final String person;

  @override
  Widget build(BuildContext context) {
    final l = loanBalances(data.transactions, data.loanCategoryIds)
        .where((x) => x.person.toLowerCase() == person.toLowerCase())
        .firstOrNull;
    final balance = l?.balance ?? 0;
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(person)),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              children: [
                Text(
                  balance.abs() < 0.005
                      ? 'All settled'
                      : balance > 0
                          ? 'You owe $person'
                          : '$person owes you',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 4),
                Text(money(balance.abs()), style: Theme.of(context).textTheme.headlineMedium),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => newLoanEntry(context, data, borrowed: true, person: person),
                    child: Text(balance < 0 ? 'They paid back' : 'Borrowed more'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => newLoanEntry(context, data, borrowed: false, person: person),
                    child: Text(balance > 0 ? 'I paid back' : 'Lent more'),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          for (final t in l?.txns ?? const <Txn>[])
            ListTile(
              leading: Icon(t.isDebit ? Icons.call_made : Icons.call_received,
                  color: t.isDebit ? Colors.green.shade700 : scheme.error),
              title: Text(t.isDebit ? 'You gave' : 'You got'),
              subtitle: Text([
                dayLabel(t.txnAt),
                if (data.account(t.accountId) != null) data.account(t.accountId)!.name,
                if ((t.note ?? '').isNotEmpty) t.note!,
              ].join(' · ')),
              trailing: Text(money(t.amount), style: const TextStyle(fontWeight: FontWeight.w600)),
              onTap: () => openTxnEditor(context, data, existing: t),
            ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, this.action});

  final String title;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 4),
        child: Row(
          children: [
            Expanded(
              child: Text(title,
                  style: TextStyle(color: Theme.of(context).colorScheme.primary, fontWeight: FontWeight.w600)),
            ),
            ?action,
          ],
        ),
      );
}
