import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/app_data.dart';
import '../logic/summary.dart';
import '../models.dart';
import '../ui/format.dart';
import '../ui/same_person_card.dart';
import 'people_review_screen.dart';
import 'places_screen.dart';
import 'shared_expense_screen.dart';
import 'txn_editor.dart';

const _appLink = 'https://digitalhomeacc-jpg.github.io/expense-tracker/';

class FriendRow {
  FriendRow(this.person, this.balance, this.link, {this.spendsOnly = false});

  final String person;

  /// Positive: you owe them. Negative: they owe you.
  final double balance;
  final FriendLink? link;

  bool get settled => balance.abs() < 0.005;

  /// Marked a friend, but their payments count as your spends: nothing owed either way.
  final bool spendsOnly;
}

/// Everyone in your Friends list: from your own payments, and connected friends' shared record.
List<FriendRow> friendRows(AppData data) {
  final rows = <String, FriendRow>{};
  for (final l in data.friendBalances) {
    final link = data.linkFor(l.person);
    rows[AppData.keyOf(l.person)] = FriendRow(
      l.person,
      link == null || data.me == null ? l.balance : sharedBalance(data.sharedEntries, link.id, data.me!),
      link,
    );
  }
  for (final link in data.links.where((l) => l.active)) {
    final name = data.me == null ? '' : link.nameFor(data.me!);
    if (name.isEmpty) continue;
    rows.putIfAbsent(
      AppData.keyOf(name),
      () => FriendRow(name, sharedBalance(data.sharedEntries, link.id, data.me!), link),
    );
  }
  // Friends whose payments are your spends: listed too, with nothing owed.
  for (final MapEntry(:key, :value) in data.people.entries) {
    if (value != 'friend') continue;
    rows.putIfAbsent(
      key,
      () => FriendRow(data.personNames[key] ?? key, 0, data.linkFor(data.personNames[key] ?? key), spendsOnly: true),
    );
  }
  final out = rows.values.toList()
    ..sort((a, b) {
      if (a.settled != b.settled) return a.settled ? 1 : -1;
      return b.balance.abs().compareTo(a.balance.abs());
    });
  return out;
}

/// Splitwise-style: who owes whom, shared expenses, settle up, connected friends.
class FriendsScreen extends StatelessWidget {
  const FriendsScreen({super.key, required this.data});

  final AppData data;

  @override
  Widget build(BuildContext context) {
    final rows = friendRows(data);
    final owedToYou = rows.where((r) => r.balance < 0).fold(0.0, (s, r) => s - r.balance);
    final youOwe = rows.where((r) => r.balance > 0).fold(0.0, (s, r) => s + r.balance);
    final toReview = peopleToReview(data.transactions, decided: {...data.decidedPeople, ...data.aliases.keys}).length;
    final scheme = Theme.of(context).colorScheme;
    final groups = rows.any((r) => r.spendsOnly)
        ? payeeGroups(data.transactions, shares: data.shareTotalsNow, aliases: data.aliases, withMoneyInOnly: true)
        : const <PayeeGroup>[];
    PayeeGroup? groupOf(String person) {
      final key = AppData.keyOf(person);
      return groups.where((g) => g.keys.contains(key)).firstOrNull ??
          groups.where((g) => g.keys.any((k) => sameName(k, key))).firstOrNull;
    }

    Widget total(String label, double v, Color color) => Expanded(
      child: Column(
        children: [
          Text(label, style: TextStyle(color: scheme.onPrimaryContainer.withValues(alpha: 0.8))),
          const SizedBox(height: 4),
          FittedBox(
            child: Text(
              money(v),
              style: Theme.of(context).textTheme.titleLarge?.copyWith(color: color, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('Friends'),
        actions: [
          IconButton(
            tooltip: 'Start everyone fresh',
            icon: const Icon(Icons.restart_alt),
            onPressed: () async {
              final yes = await showDialog<bool>(
                context: context,
                builder: (c) => AlertDialog(
                  title: const Text('Start everyone fresh from today?'),
                  content: const Text(
                    'Everything with friends before today counts as settled. Older entries stay as history. '
                    'Then open a friend and set their opening balance if something is still owed.',
                  ),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
                    FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Start fresh')),
                  ],
                ),
              );
              if (yes == true) {
                await data.startFresh({for (final r in rows) AppData.keyOf(r.person): r.person}, DateTime.now());
              }
            },
          ),
          IconButton(
            tooltip: 'Enter an invite code',
            icon: const Icon(Icons.person_add_alt_1),
            onPressed: () => showAcceptInvite(context, data),
          ),
        ],
      ),
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
          for (final q in data.questions) _QuestionCard(data: data, question: q),
          if (toReview > 0)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Card.filled(
                child: ListTile(
                  leading: const Icon(Icons.person_search),
                  title: Text('$toReview ${toReview == 1 ? 'person' : 'people'} you paid or got money from'),
                  subtitle: const Text('Tick your friends: their money is not spending or income'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => ListenableBuilder(
                        listenable: data,
                        builder: (_, _) => PeopleReviewScreen(data: data),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          if (rows.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'No friends yet.\n\nMark people you pay or get money from as friends, add a shared expense, '
                'or split a payment from its details. Money between friends is kept here, not in your spending.',
                textAlign: TextAlign.center,
              ),
            ),
          for (final r in rows)
            ListTile(
              leading: Badge(
                isLabelVisible: r.link != null,
                backgroundColor: Colors.green.shade700,
                label: const Icon(Icons.link, size: 10, color: Colors.white),
                child: CircleAvatar(child: Text(r.person.isEmpty ? '?' : r.person[0].toUpperCase())),
              ),
              title: Text(r.person),
              subtitle: Text(
                [
                  if (r.spendsOnly && r.settled)
                    switch (groupOf(r.person)) {
                      final g? => [
                        'Not owed',
                        if (g.total > 0) 'paid ${money(g.total)}',
                        if (g.received > 0) 'got ${money(g.received)}',
                      ].join(' · '),
                      null => 'No payments yet',
                    }
                  else
                    r.settled ? 'Settled up' : (r.balance > 0 ? 'You owe' : 'Owes you'),
                  if (r.link != null) 'connected',
                ].join(' · '),
              ),
              trailing: Text(
                r.settled ? '' : money(r.balance.abs()),
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: r.balance > 0 ? scheme.error : Colors.green.shade700,
                ),
              ),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => ListenableBuilder(
                    listenable: data,
                    builder: (_, _) => r.spendsOnly && r.settled && r.link == null && groupOf(r.person) != null
                        ? PlaceDetailScreen(data: data, keys: groupOf(r.person)!.keys)
                        : FriendDetailScreen(data: data, person: r.person),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// "Was this ₹500 from Vijay Sharma the ₹500 Rahul says he paid you?"
class _QuestionCard extends StatelessWidget {
  const _QuestionCard({required this.data, required this.question});

  final AppData data;
  final MatchQuestion question;

  @override
  Widget build(BuildContext context) {
    final e = data.sharedEntries.where((x) => x.id == question.entryId).firstOrNull;
    final t = data.txn(question.txnId);
    if (e == null || t == null || data.me == null) return const SizedBox.shrink();
    final link = data.links.where((l) => l.id == e.linkId).firstOrNull;
    final friend = link?.nameFor(data.me!) ?? 'Your friend';
    final theyPaid = e.creditor != data.me;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Card.outlined(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.help_outline, color: Theme.of(context).colorScheme.primary),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text('Same payment?', style: TextStyle(fontWeight: FontWeight.w600)),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                theyPaid
                    ? 'Was ${money(t.amount)} ${t.isDebit ? 'to' : 'from'} ${t.title} (${dayLabel(t.txnAt)}) the ${money(e.amount)} $friend says they paid you?'
                    : 'Was ${money(t.amount)} to ${t.title} (${dayLabel(t.txnAt)}) the ${money(e.amount)} $friend says you paid them?',
              ),
              const SizedBox(height: 4),
              Text('Yes also remembers ${t.title} as $friend.', style: Theme.of(context).textTheme.bodySmall),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(onPressed: () => data.answerMatch(question.id, false), child: const Text('No')),
                  FilledButton(onPressed: () => data.answerMatch(question.id, true), child: const Text('Yes, same')),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Enter a friend's invite code (or open their invite link).
Future<void> showAcceptInvite(BuildContext context, AppData data, {String? code}) async {
  final codeCtl = TextEditingController(text: code ?? '');
  final nameCtl = TextEditingController();
  String? error;
  await showDialog<void>(
    context: context,
    builder: (c) => StatefulBuilder(
      builder: (c, set) => AlertDialog(
        title: const Text('Connect with a friend'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: codeCtl,
              decoration: const InputDecoration(labelText: 'Invite code'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: nameCtl,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                labelText: 'Your friend\'s name',
                helperText: 'As it shows in your bank, e.g. Rahul Kumar',
              ),
            ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(error!, style: TextStyle(color: Theme.of(c).colorScheme.error)),
              ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
          FilledButton(
            onPressed: () async {
              if (codeCtl.text.trim().isEmpty || nameCtl.text.trim().isEmpty)
                return set(() => error = 'Enter the code and the name');
              try {
                await data.acceptInvite(codeCtl.text, nameCtl.text);
                if (c.mounted) Navigator.pop(c);
              } catch (e) {
                final msg = e.toString();
                final m = RegExp(r'message: ([^,]+)').firstMatch(msg);
                set(() => error = m?.group(1) ?? msg);
              }
            },
            child: const Text('Connect'),
          ),
        ],
      ),
    ),
  );
}

class FriendDetailScreen extends StatelessWidget {
  const FriendDetailScreen({super.key, required this.data, required this.person});

  final AppData data;
  final String person;

  Future<void> _settle(BuildContext context, double balance) async {
    final iPaid = balance > 0;
    final amount = TextEditingController(
      text: balance.abs() < 0.005
          ? ''
          : balance.abs().toStringAsFixed(balance.abs() == balance.abs().roundToDouble() ? 0 : 2),
    );
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
            Text(
              'Paid by UPI? It is added by itself when the bank email arrives. Use this for cash.',
              style: Theme.of(c).textTheme.bodySmall,
            ),
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

  /// "Not all of it is a loan": set what is really owed; the rest is kept as a note, e.g. his spends through you.
  Future<void> _correct(BuildContext context, double balance) async {
    final result = await showDialog<({double owed, String reason, bool fresh})>(
      context: context,
      builder: (c) => _CorrectBalanceDialog(person: person, balance: balance),
    );
    if (result == null) return;
    if (result.fresh) {
      await data.startFresh(
        {AppData.keyOf(person): person},
        DateTime.now(),
        opening: {AppData.keyOf(person): result.owed},
      );
      return;
    }
    final change = result.owed - balance; // positive: you owe more
    if (change.abs() < 0.005) return;
    await data.correctFriendBalance(person, change, result.reason);
  }

  Future<void> _remind(double owed, List<TxnShare> open) async {
    final first = person.split(' ').first;
    final items = open
        .take(3)
        .map((s) => '${data.txn(s.txnId)?.title ?? 'a shared expense'} (${money(s.amount)})')
        .join(', ');
    final text =
        'Hi $first, a gentle reminder: you owe me ${money(owed)}${items.isEmpty ? '' : ' for $items'}. Thanks!';
    await launchUrl(
      Uri.parse('https://wa.me/?text=${Uri.encodeComponent(text)}'),
      mode: LaunchMode.externalApplication,
    );
  }

  Future<void> _invite(BuildContext context) async {
    try {
      final code = await data.inviteFriend(person);
      final text =
          'Hi ${person.split(' ').first}, I track our payments in Expense Tracker. Join so what we send each other '
          'and share shows up in both our apps: $_appLink#invite-$code\n'
          'Or in the app: Friends → Enter invite code: $code';
      await launchUrl(
        Uri.parse('https://wa.me/?text=${Uri.encodeComponent(text)}'),
        mode: LaunchMode.externalApplication,
      );
    } catch (e) {
      if (context.mounted)
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not make an invite: $e')));
    }
  }

  Future<void> _alias(BuildContext context) => showAlsoKnownAs(context, data, person);

  String _entryText(SharedEntry e, String me) {
    final mine = e.creditor == me;
    final what = e.description == null || e.description!.isEmpty ? '' : ' · ${e.description}';
    return switch (e.kind) {
      'expense' => mine ? '$person\'s share$what' : 'Your share$what ($person paid)',
      _ => mine ? 'You paid $person$what' : '$person paid you$what',
    };
  }

  @override
  Widget build(BuildContext context) {
    final key = AppData.keyOf(person);
    final link = data.linkFor(person);
    final pending = data.pendingInviteFor(person);
    final me = data.me;
    final l = data.friendBalances.where((x) => AppData.keyOf(x.person) == key).firstOrNull;
    final start = data.ledgerStarts[key];
    String canonKey(String name) => AppData.keyOf(data.aliases[AppData.keyOf(name)] ?? name);
    final history = start == null
        ? const <Txn>[]
        : (data.transactions
              .where(
                (t) =>
                    t.txnAt.isBefore(start.from) &&
                    data.loanCategoryIds.contains(t.categoryId) &&
                    canonKey(t.title) == key,
              )
              .toList()
            ..sort((a, b) => b.txnAt.compareTo(a.txnAt)));
    final balance = link != null && me != null ? sharedBalance(data.sharedEntries, link.id, me) : (l?.balance ?? 0);
    final open = data.shares.where((s) => !s.paid && AppData.keyOf(s.person) == key).toList();
    final paidForMe = data.transactions.where((t) => t.paidBy != null && AppData.keyOf(t.paidBy!) == key).toList();
    final otherNames = data.aliases.entries.where((e) => AppData.keyOf(e.value) == key).map((e) => e.key).toList();
    final scheme = Theme.of(context).colorScheme;
    final settled = balance.abs() < 0.005;
    final entries = link == null
        ? const <SharedEntry>[]
        : (data.sharedEntries.where((e) => e.linkId == link.id).toList()..sort((a, b) => b.at.compareTo(a.at)));

    return Scaffold(
      appBar: AppBar(
        title: Text(person),
        actions: [
          PopupMenuButton<String>(
            onSelected: (v) async {
              switch (v) {
                case 'alias':
                  await _alias(context);
                case 'family' || 'me':
                  await data.setPersonRole(person, v);
                  if (context.mounted) Navigator.pop(context);
                case 'disconnect':
                  if (link != null) await data.disconnect(link.id);
                case 'unfriend':
                  await data.markFriend(person, friend: false);
                  if (context.mounted) Navigator.pop(context);
              }
            },
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'alias', child: Text('Also known as… (another account)')),
              const PopupMenuItem(value: 'family', child: Text('Family (money from them is income)')),
              const PopupMenuItem(value: 'me', child: Text('This is me (my own account)')),
              if (link != null) const PopupMenuItem(value: 'disconnect', child: Text('Disconnect')),
              const PopupMenuItem(value: 'unfriend', child: Text('Not a friend (count as spending)')),
            ],
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
                Text(
                  settled ? 'All settled' : (balance > 0 ? 'You owe $person' : '$person owes you'),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 4),
                Text(
                  money(balance.abs()),
                  style: Theme.of(context).textTheme.headlineMedium
                      ?.copyWith(color: settled ? null : (balance > 0 ? scheme.error : Colors.green.shade700)),
                ),
                if (otherNames.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text('Also: ${otherNames.join(', ')}', style: Theme.of(context).textTheme.bodySmall),
                ],
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: SamePersonCard(data: data, person: person),
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
                if (link == null) ...[
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => _correct(context, balance),
                      icon: const Icon(Icons.tune),
                      label: const Text('Opening balance'),
                    ),
                  ),
                ],
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
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: link != null
                ? Card.filled(
                    child: ListTile(
                      leading: Icon(Icons.link, color: Colors.green.shade700),
                      title: const Text('Connected'),
                      subtitle: Text('$person sees the same entries and balance in their app.'),
                    ),
                  )
                : Card.outlined(
                    child: ListTile(
                      leading: const Icon(Icons.share),
                      title: Text(pending == null ? 'Connect with $person' : 'Invite sent · code ${pending.code}'),
                      subtitle: Text(
                        pending == null
                            ? 'If they use the app too, what you send each other and share shows up in both apps.'
                            : 'Waiting for $person to accept. Tap to send it again.',
                      ),
                      onTap: () => _invite(context),
                    ),
                  ),
          ),
          const SizedBox(height: 8),
          if (link != null && me != null)
            for (final e in entries)
              ListTile(
                leading: Icon(
                  e.kind == 'expense' ? Icons.call_split : (e.creditor == me ? Icons.call_made : Icons.call_received),
                  color: e.deleted ? scheme.outline : (e.creditor == me ? Colors.green.shade700 : scheme.error),
                ),
                title: Text(
                  _entryText(e, me),
                  style: TextStyle(decoration: e.deleted ? TextDecoration.lineThrough : null),
                ),
                subtitle: Text(
                  [
                    dayLabel(e.at),
                    if (e.deleted)
                      'removed by ${e.deletedBy == me ? 'you' : person}'
                    else
                      'added by ${e.createdBy == me ? 'you' : person}',
                    if (!e.deleted && (e.creditor == me ? e.creditorTxn : e.debtorTxn) != null) 'in your bank',
                  ].join(' · '),
                ),
                trailing: Text(
                  money(e.amount),
                  style: TextStyle(fontWeight: FontWeight.w600, color: e.deleted ? scheme.outline : null),
                ),
                onLongPress: e.deleted
                    ? null
                    : () async {
                        final yes = await showDialog<bool>(
                          context: context,
                          builder: (c) => AlertDialog(
                            title: const Text('Remove this entry?'),
                            content: Text('It is removed for $person too; they see that you removed it.'),
                            actions: [
                              TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
                              FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Remove')),
                            ],
                          ),
                        );
                        if (yes == true) await data.deleteSharedEntry(e.id);
                      },
              )
          else ...[
            for (final s in open)
              ListTile(
                leading: Icon(Icons.call_split, color: Colors.green.shade700),
                title: Text('Their part of ${data.txn(s.txnId)?.title ?? 'a shared expense'}'),
                subtitle: Text(
                  data.txn(s.txnId) == null ? 'Owes you' : '${dayLabel(data.txn(s.txnId)!.txnAt)} · owes you',
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(money(s.amount), style: const TextStyle(fontWeight: FontWeight.w600)),
                    IconButton(
                      tooltip: 'Paid back in cash',
                      icon: const Icon(Icons.check_circle_outline),
                      onPressed: () => data.markSharePaid(s.id),
                    ),
                  ],
                ),
                onTap: data.txn(s.txnId) == null
                    ? null
                    : () => openTxnEditor(context, data, existing: data.txn(s.txnId)),
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
                  leading: Icon(
                    t.isDebit ? Icons.call_made : Icons.call_received,
                    color: t.isDebit ? Colors.green.shade700 : scheme.error,
                  ),
                  title: Text(
                    t.accountId == null && (t.note ?? '').isNotEmpty && t.note != 'Settle up'
                        ? t.note!
                        : (t.isDebit ? 'You sent' : 'You got'),
                  ),
                  subtitle: Text(
                    [
                      dayLabel(t.txnAt),
                      if (AppData.keyOf(t.title) != key) 'as ${t.title}',
                      if (data.account(t.accountId) != null) data.account(t.accountId)!.name,
                      if (t.accountId == null && t.note != 'Settle up')
                        'balance correction'
                      else if ((t.note ?? '').isNotEmpty)
                        t.note!,
                    ].join(' · '),
                  ),
                  trailing: Text(money(t.amount), style: const TextStyle(fontWeight: FontWeight.w600)),
                  onTap: () => openTxnEditor(context, data, existing: t),
                ),
          ],
          if (start != null) ...[
            const Divider(),
            ListTile(
              leading: const Icon(Icons.flag_outlined),
              title: Text('Opening balance · ${dayLabel(start.from)}'),
              subtitle: Text(
                start.opening.abs() < 0.005
                    ? 'Everything before was settled'
                    : (start.opening > 0 ? 'You owed $person' : '$person owed you'),
              ),
              trailing: Text(
                start.opening.abs() < 0.005 ? '₹0' : money(start.opening.abs()),
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            if (history.isNotEmpty)
              ExpansionTile(
                leading: const Icon(Icons.history),
                title: Text('History before ${dayLabel(start.from)}'),
                subtitle: Text('${history.length} entries · not counted'),
                children: [
                  for (final t in history)
                    ListTile(
                      dense: true,
                      enabled: false,
                      title: Text('${t.isDebit ? 'You sent' : 'You got'} ${money(t.amount)}'),
                      subtitle: Text(
                        [dayLabel(t.txnAt), if (AppData.keyOf(t.title) != key) 'as ${t.title}'].join(' · '),
                      ),
                      onTap: () => openTxnEditor(context, data, existing: t),
                    ),
                ],
              ),
          ],
        ],
      ),
    );
  }
}

class _CorrectBalanceDialog extends StatefulWidget {
  const _CorrectBalanceDialog({required this.person, required this.balance});

  final String person;

  /// Positive: you owe them.
  final double balance;

  @override
  State<_CorrectBalanceDialog> createState() => _CorrectBalanceDialogState();
}

class _CorrectBalanceDialogState extends State<_CorrectBalanceDialog> {
  static const _reasons = ['His/her spends through me', 'Gift / let go', 'Old balance', 'Other'];
  late var _youOwe = widget.balance >= 0;
  late final _amount = TextEditingController(text: _plain(widget.balance.abs()));
  var _reason = _reasons.first;
  var _fresh = true;

  static String _plain(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2);

  double? get _owed {
    final v = double.tryParse(_amount.text.replaceAll(',', ''));
    return v == null ? null : (_youOwe ? v : -v);
  }

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final first = widget.person.split(' ').first;
    final owed = _owed;
    final diff = owed == null ? null : (widget.balance - owed).abs();
    return AlertDialog(
      title: const Text('What is really owed?'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SegmentedButton<bool>(
              showSelectedIcon: false,
              segments: [
                const ButtonSegment(value: true, label: Text('I owe')),
                ButtonSegment(value: false, label: Text('$first owes')),
              ],
              selected: {_youOwe},
              onSelectionChanged: (v) => setState(() => _youOwe = v.first),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _amount,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))],
              decoration: const InputDecoration(labelText: 'Amount', prefixText: '₹ '),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _fresh,
              onChanged: (v) => setState(() => _fresh = v),
              title: const Text('Start fresh from today'),
              subtitle: const Text(
                'Older entries stay as history but stop counting; this amount is the opening balance',
              ),
            ),
            if (!_fresh && diff != null && diff >= 0.005) ...[
              const SizedBox(height: 12),
              Text('The other ${money(diff)} was:', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final r in _reasons)
                    ChoiceChip(
                      label: Text(r == _reasons.first ? '$first\'s spends through me' : r),
                      selected: _reason == r,
                      onSelected: (_) => setState(() => _reason = r),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                'Not your spending or income, and not owed. Your bank balances do not change.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: owed == null
              ? null
              : () => Navigator.pop(context, (
                  owed: owed,
                  reason: _reason == _reasons.first ? '$first\'s spends through me' : _reason,
                  fresh: _fresh,
                )),
          child: const Text('Save'),
        ),
      ],
    );
  }
}
