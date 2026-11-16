import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../data/app_data.dart';
import '../logic/summary.dart' show splitEqually;
import '../models.dart';
import '../ui/format.dart';

/// Money received a little before/after a payment that could be friends paying their part.
List<Txn> _creditsNear(AppData data, Txn payment, {Duration window = const Duration(days: 2)}) {
  final used = {
    for (final s in data.shares)
      if (s.paidTxnId != null) s.paidTxnId!,
  };
  return data.transactions
      .where(
        (t) =>
            !t.isDebit &&
            !t.excluded &&
            !t.isLoanTransfer &&
            !used.contains(t.id) &&
            t.amount < payment.amount &&
            t.txnAt.difference(payment.txnAt).abs() <= window,
      )
      .toList()
    ..sort((a, b) => a.txnAt.difference(payment.txnAt).abs().compareTo(b.txnAt.difference(payment.txnAt).abs()));
}

/// "Split with friends" on a payment you made for a group.
class SplitSection extends StatelessWidget {
  const SplitSection({super.key, required this.data, required this.payment});

  final AppData data;
  final Txn payment;

  /// Pick friends (or type a new name), split equally or set each part; never more than the bill.
  Future<void> _addPerson(BuildContext context) async {
    final existing = data.sharesOf(payment.id);
    final taken = existing.fold(0.0, (v, s) => v + s.amount);
    final left = payment.amount - taken; // what is still yours to share
    final already = {for (final s in existing) AppData.keyOf(s.person)};
    // Connected friends first, then everyone you share money with; by the name they have in the app.
    final names = <String>{
      for (final l in data.links.where((l) => l.active))
        if (data.me != null && l.nameFor(data.me!).isNotEmpty) l.nameFor(data.me!),
      for (final f in data.friendBalances) f.person,
      for (final e in data.personNames.entries)
        if (data.people[e.key] == 'friend') e.value,
    }.where((n) => !already.contains(AppData.keyOf(n)) && !data.aliases.containsKey(AppData.keyOf(n))).toList();
    final picked = <String>[];
    final typed = TextEditingController();
    final exact = <String, TextEditingController>{};
    var equally = true;
    var includeMe = true;
    String? error;
    final messenger = ScaffoldMessenger.of(context);
    final result = await showModalBottomSheet<Map<String, double>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      builder: (c) => StatefulBuilder(
        builder: (c, setState) {
          Map<String, double> parts() {
            if (equally) {
              final split = splitEqually(left, [if (includeMe) 'me', ...picked]);
              return {for (final p in picked) p: split[p] ?? 0};
            }
            return {for (final p in picked) p: double.tryParse((exact[p]?.text ?? '').replaceAll(',', '')) ?? 0};
          }

          final total = parts().values.fold(0.0, (v, x) => v + x);
          void addTyped() {
            final n = typed.text.trim();
            if (n.isEmpty) return;
            // A name you already have (any spelling of it) is that person, not a new one.
            final known =
                names.where((x) => AppData.keyOf(x) == AppData.keyOf(n)).firstOrNull ?? data.aliases[AppData.keyOf(n)];
            setState(() {
              final name = known ?? n;
              if (!picked.contains(name)) picked.add(name);
              typed.clear();
            });
          }

          return Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + MediaQuery.viewInsetsOf(c).bottom),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('Split ${money(left)} with friends', style: Theme.of(c).textTheme.titleLarge),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final n in {...names, ...picked})
                        FilterChip(
                          label: Text(n),
                          avatar: data.linkFor(n) != null ? const Icon(Icons.link, size: 16) : null,
                          selected: picked.contains(n),
                          onSelected: (v) => setState(() => v ? picked.add(n) : picked.remove(n)),
                        ),
                    ],
                  ),
                  TextField(
                    controller: typed,
                    textCapitalization: TextCapitalization.words,
                    decoration: InputDecoration(
                      labelText: 'Someone else',
                      suffixIcon: IconButton(icon: const Icon(Icons.add), onPressed: () => setState(addTyped)),
                    ),
                    onSubmitted: (_) => addTyped(),
                  ),
                  const SizedBox(height: 12),
                  SegmentedButton<bool>(
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(value: true, label: Text('Equally')),
                      ButtonSegment(value: false, label: Text('Exact amounts')),
                    ],
                    selected: {equally},
                    onSelectionChanged: (v) => setState(() => equally = v.first),
                  ),
                  if (equally)
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      value: includeMe,
                      onChanged: (v) => setState(() => includeMe = v ?? true),
                      title: const Text('I had a share too'),
                    ),
                  for (final p in picked)
                    Row(
                      children: [
                        Expanded(child: Text(p)),
                        if (equally)
                          Text(money(parts()[p] ?? 0), style: const TextStyle(fontWeight: FontWeight.w600))
                        else
                          SizedBox(
                            width: 120,
                            child: TextField(
                              controller: exact.putIfAbsent(p, TextEditingController.new),
                              keyboardType: const TextInputType.numberWithOptions(decimal: true),
                              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))],
                              decoration: const InputDecoration(prefixText: '₹ ', isDense: true),
                              onChanged: (_) => setState(() {}),
                            ),
                          ),
                      ],
                    ),
                  if (picked.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        total > left + 0.005
                            ? 'Friends\' parts (${money(total)}) are more than ${money(left)}'
                            : 'Your part stays ${money(payment.amount - taken - total)} · friends owe you ${money(total)}',
                        style: TextStyle(color: total > left + 0.005 ? Theme.of(c).colorScheme.error : null),
                      ),
                    ),
                  if (error != null) Text(error!, style: TextStyle(color: Theme.of(c).colorScheme.error)),
                  const SizedBox(height: 12),
                  FilledButton(
                    onPressed: () {
                      final ps = {
                        for (final e in parts().entries)
                          if (e.value > 0) e.key: e.value,
                      };
                      if (ps.isEmpty) return setState(() => error = 'Pick a friend and their part');
                      if (total > left + 0.005) return setState(() => error = 'More than the bill');
                      Navigator.pop(c, ps);
                    },
                    child: const Text('Add'),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
    if (result == null) return;
    for (final e in result.entries) {
      try {
        await data.addShare(payment.id, e.key, e.value);
      } catch (err) {
        messenger.showSnackBar(SnackBar(content: Text('${e.key}\'s part was not added: $err')));
      }
    }
  }

  Future<void> _shareActions(BuildContext context, TxnShare s) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text('${s.person} · ${money(s.amount)}'),
              subtitle: Text(s.paid ? 'Paid you back' : 'Owes you'),
            ),
            if (!s.paid) ...[
              ListTile(
                leading: const Icon(Icons.account_balance),
                title: const Text('Paid me back to my bank'),
                onTap: () => Navigator.pop(c, 'bank'),
              ),
              ListTile(
                leading: const Icon(Icons.payments_outlined),
                title: const Text('Paid me back in cash'),
                onTap: () => Navigator.pop(c, 'cash'),
              ),
            ],
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('Remove'),
              onTap: () => Navigator.pop(c, 'delete'),
            ),
          ],
        ),
      ),
    );
    if (!context.mounted || action == null) return;
    switch (action) {
      case 'cash':
        await data.markSharePaid(s.id);
      case 'delete':
        await data.deleteShare(s.id);
      case 'bank':
        final credits = _creditsNear(
          data,
          payment,
          window: const Duration(days: 45),
        ).where((t) => !t.txnAt.isBefore(payment.txnAt.subtract(const Duration(days: 2)))).toList();
        final picked = await showModalBottomSheet<Txn>(
          context: context,
          showDragHandle: true,
          builder: (c) => SafeArea(
            child: credits.isEmpty
                ? const Padding(
                    padding: EdgeInsets.all(24),
                    child: Text('No money received after this payment that is not already linked.'),
                  )
                : ListView(
                    shrinkWrap: true,
                    children: [
                      const ListTile(title: Text('Which money was it?')),
                      for (final t in credits.take(30))
                        ListTile(
                          title: Text(t.title),
                          subtitle: Text('${dayLabel(t.txnAt)}, ${timeLabel(t.txnAt)}'),
                          trailing: Text(money(t.amount)),
                          onTap: () => Navigator.pop(c, t),
                        ),
                    ],
                  ),
          ),
        );
        if (picked != null) await data.markSharePaid(s.id, paidTxnId: picked.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final shares = data.sharesOf(payment.id);
    final own = data.shareTotalsNow.own(payment);
    final near = _creditsNear(data, payment).take(4).toList();
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Split with friends', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 4),
        Text(
          shares.isEmpty
              ? 'Paid for a group? Add friends\' parts so only your share counts as spending.'
              : 'Your share: ${money(own)} of ${money(payment.amount)}',
          style: TextStyle(color: scheme.onSurfaceVariant),
        ),
        for (final s in shares)
          ListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            leading: CircleAvatar(
              radius: 14,
              child: Text(s.person[0].toUpperCase(), style: const TextStyle(fontSize: 12)),
            ),
            title: Text(s.person),
            subtitle: Text(s.paid ? 'Paid you back' : 'Owes you'),
            trailing: Text(money(s.amount), style: const TextStyle(fontWeight: FontWeight.w600)),
            onTap: () => _shareActions(context, s),
          ),
        if (near.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(
            'Money received around then. Tap if it was a friend paying their part:',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final t in near)
                ActionChip(
                  avatar: const Icon(Icons.add, size: 16),
                  label: Text('${t.title} · ${money(t.amount)}'),
                  onPressed: () => data.addShare(payment.id, t.title, t.amount, paidTxnId: t.id),
                ),
            ],
          ),
        ],
        const SizedBox(height: 6),
        TextButton.icon(
          onPressed: () => _addPerson(context),
          icon: const Icon(Icons.person_add_alt, size: 18),
          label: const Text('Add a friend\'s part'),
        ),
      ],
    );
  }
}

/// On money received: "was this a friend paying their part of something you paid?"
class PaidBackSection extends StatelessWidget {
  const PaidBackSection({super.key, required this.data, required this.credit});

  final AppData data;
  final Txn credit;

  @override
  Widget build(BuildContext context) {
    final linked = data.sharesPaidBy(credit.id);
    if (linked.isNotEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Friend paying you back', style: Theme.of(context).textTheme.titleSmall),
          for (final s in linked)
            ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: Text('${s.person}\'s part (${money(s.amount)})'),
              subtitle: Text(
                'of ${data.txn(s.txnId)?.title ?? 'a payment'}'
                '${data.txn(s.txnId) != null ? ' · ${dayLabel(data.txn(s.txnId)!.txnAt)}' : ''}. Not counted as income.',
              ),
              trailing: TextButton(onPressed: () => data.deleteShare(s.id), child: const Text('Unlink')),
            ),
        ],
      );
    }
    // Unpaid parts by someone with this name, or payments made around then.
    final name = credit.title.toLowerCase();
    final owed = data.shares
        .where((s) => !s.paid && (name.contains(s.person.toLowerCase()) || s.person.toLowerCase().contains(name)))
        .toList();
    final payments = data.transactions
        .where(
          (t) =>
              t.isDebit &&
              !t.excluded &&
              !t.isLoanTransfer &&
              t.amount > credit.amount &&
              t.txnAt.difference(credit.txnAt).abs() <= const Duration(days: 2),
        )
        .take(4)
        .toList();
    if (owed.isEmpty && payments.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Was this a friend paying their part?', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 4),
        Text(
          'Then it is not counted as income, and your spending is only your share.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final s in owed)
              ActionChip(
                avatar: const Icon(Icons.check, size: 16),
                label: Text('${s.person}\'s ${money(s.amount)} of ${data.txn(s.txnId)?.title ?? 'a payment'}'),
                onPressed: () => data.markSharePaid(s.id, paidTxnId: credit.id),
              ),
            for (final t in payments)
              ActionChip(
                avatar: const Icon(Icons.call_split, size: 16),
                label: Text('Part of ${t.title} · ${money(t.amount)}'),
                onPressed: () => data.addShare(t.id, credit.title, credit.amount, paidTxnId: credit.id),
              ),
          ],
        ),
      ],
    );
  }
}
