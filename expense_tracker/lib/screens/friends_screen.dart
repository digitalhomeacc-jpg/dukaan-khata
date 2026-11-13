import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/app_data.dart';
import '../logic/summary.dart';
import '../models.dart';
import '../ui/format.dart';
import 'people_review_screen.dart';
import 'shared_expense_screen.dart';
import 'txn_editor.dart';

/// Splitwise-style: who owes whom, shared expenses, settle up.
class FriendsScreen extends StatelessWidget {
  const FriendsScreen({super.key, required this.data});

  final AppData data;

  @override
  Widget build(BuildContext context) {
    final balances = loanBalances(data.transactions, data.loanCategoryIds, shares: data.shares);
    final owedToYou = balances.where((l) => l.balance < 0).fold(0.0, (s, l) => s - l.balance);
    final youOwe = balances.where((l) => l.balance > 0).fold(0.0, (s, l) => s + l.balance);
    final toReview = peopleToReview(data.transactions, decided: data.decidedPeople).length;
    final scheme = Theme.of(context).colorScheme;

    Widget total(String label, double v, Color color) => Expanded(
          child: Column(
            children: [
              Text(label, style: TextStyle(color: scheme.onPrimaryContainer.withValues(alpha: 0.8))),
              const SizedBox(height: 4),
              FittedBox(
                child: Text(money(v),
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(color: color, fontWeight: FontWeight.w600)),
              ),
            ],
          ),
        );

    return Scaffold(
      appBar: AppBar(title: const Text('Friends')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => openSharedExpense(context, data),
        icon: const Icon(Icons.call_split),
        label: const Text('Shared expense'),
      ),
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
                    total('Owed to you', owedToYou, Colors.green.shade800),
                    total('You owe', youOwe, scheme.error),
                  ],
                ),
              ),
            ),
          ),
          if (toReview > 0)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Card.filled(
                child: ListTile(
                  leading: const Icon(Icons.person_search),
                  title: Text('$toReview ${toReview == 1 ? 'person' : 'people'} you paid or got money from'),
                  subtitle: const Text('Tick your friends: their money is not spending or income'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                    builder: (_) => ListenableBuilder(listenable: data, builder: (_, _) => PeopleReviewScreen(data: data)),
                  )),
                ),
              ),
            ),
          if (balances.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'No friends yet.\n\nMark people you pay or get money from as friends, add a shared expense, '
                'or split a payment from its details. Money between friends is kept here, not in your spending.',
                textAlign: TextAlign.center,
              ),
            ),
          for (final l in balances)
            ListTile(
              leading: CircleAvatar(child: Text(l.person.isEmpty ? '?' : l.person[0].toUpperCase())),
              title: Text(l.person),
              subtitle: Text(l.settled ? 'Settled up' : (l.balance > 0 ? 'You owe' : 'Owes you')),
              trailing: Text(
                l.settled ? '' : money(l.balance.abs()),
                style: TextStyle(fontWeight: FontWeight.w600, color: l.balance > 0 ? scheme.error : Colors.green.shade700),
              ),
              onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                builder: (_) => ListenableBuilder(listenable: data, builder: (_, _) => FriendDetailScreen(data: data, person: l.person)),
              )),
            ),
        ],
      ),
    );
  }
}

class FriendDetailScreen extends StatelessWidget {
  const FriendDetailScreen({super.key, required this.data, required this.person});

  final AppData data;
  final String person;

  Future<void> _settle(BuildContext context, double balance) async {
    final iPaid = balance > 0;
    final amount = TextEditingController(text: balance.abs() < 0.005 ? '' : balance.abs().toStringAsFixed(balance.abs() == balance.abs().roundToDouble() ? 0 : 2));
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(iPaid ? 'You paid $person' : '$person paid you'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: amount,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))],
              decoration: const InputDecoration(labelText: 'Amount', prefixText: '₹ '),
            ),
            const SizedBox(height: 8),
            Text('Paid by UPI? It is added by itself when the bank email arrives. Use this for cash.',
                style: Theme.of(c).textTheme.bodySmall),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Save')),
        ],
      ),
    );
    final v = double.tryParse(amount.text.replaceAll(',', ''));
    if (ok == true && v != null && v > 0) await data.settleUp(person, v, iPaid: iPaid);
  }

  Future<void> _remind(double owed, List<TxnShare> open) async {
    final first = person.split(' ').first;
    final items = open.take(3).map((s) => '${data.txn(s.txnId)?.title ?? 'a shared expense'} (${money(s.amount)})').join(', ');
    final text = 'Hi $first, a gentle reminder: you owe me ${money(owed)}${items.isEmpty ? '' : ' for $items'}. Thanks!';
    await launchUrl(Uri.parse('https://wa.me/?text=${Uri.encodeComponent(text)}'), mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    final key = person.toLowerCase().trim();
    final l = loanBalances(data.transactions, data.loanCategoryIds, shares: data.shares)
        .where((x) => x.person.toLowerCase().trim() == key)
        .firstOrNull;
    final balance = l?.balance ?? 0;
    final open = data.shares.where((s) => !s.paid && s.person.toLowerCase().trim() == key).toList();
    final paidForMe = data.transactions.where((t) => t.paidBy?.toLowerCase().trim() == key).toList();
    final scheme = Theme.of(context).colorScheme;
    final settled = balance.abs() < 0.005;

    return Scaffold(
      appBar: AppBar(
        title: Text(person),
        actions: [
          PopupMenuButton<String>(
            onSelected: (v) async {
              if (v == 'unfriend') {
                await data.markFriend(person, friend: false);
                if (context.mounted) Navigator.pop(context);
              }
            },
            itemBuilder: (_) => const [PopupMenuItem(value: 'unfriend', child: Text('Not a friend (count as spending)'))],
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              children: [
                Text(settled ? 'All settled' : (balance > 0 ? 'You owe $person' : '$person owes you'),
                    style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 4),
                Text(money(balance.abs()),
                    style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                        color: settled ? null : (balance > 0 ? scheme.error : Colors.green.shade700))),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: settled ? null : () => _settle(context, balance),
                    icon: const Icon(Icons.handshake_outlined),
                    label: const Text('Settle up'),
                  ),
                ),
                if (balance < 0) ...[
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => _remind(-balance, open),
                      icon: const Icon(Icons.chat_outlined),
                      label: const Text('Remind'),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 16),
          for (final s in open)
            ListTile(
              leading: Icon(Icons.call_split, color: Colors.green.shade700),
              title: Text('Their part of ${data.txn(s.txnId)?.title ?? 'a shared expense'}'),
              subtitle: Text(data.txn(s.txnId) == null ? 'Owes you' : '${dayLabel(data.txn(s.txnId)!.txnAt)} · owes you'),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(money(s.amount), style: const TextStyle(fontWeight: FontWeight.w600)),
                  IconButton(tooltip: 'Paid back in cash', icon: const Icon(Icons.check_circle_outline), onPressed: () => data.markSharePaid(s.id)),
                ],
              ),
              onTap: data.txn(s.txnId) == null ? null : () => openTxnEditor(context, data, existing: data.txn(s.txnId)),
            ),
          for (final t in paidForMe)
            ListTile(
              leading: Icon(Icons.call_split, color: scheme.error),
              title: Text('$person paid: ${t.title}'),
              subtitle: Text('${dayLabel(t.txnAt)} · your share, you owe'),
              trailing: Text(money(t.amount), style: const TextStyle(fontWeight: FontWeight.w600)),
              onTap: () => openTxnEditor(context, data, existing: t),
            ),
          for (final t in l?.txns ?? const <Txn>[])
            if (t.paidBy == null)
              ListTile(
                leading: Icon(t.isDebit ? Icons.call_made : Icons.call_received,
                    color: t.isDebit ? Colors.green.shade700 : scheme.error),
                title: Text(t.isDebit ? 'You sent' : 'You got'),
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
