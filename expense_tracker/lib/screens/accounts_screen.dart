import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../data/app_data.dart';
import '../logic/summary.dart';
import '../models.dart';
import '../ui/category_style.dart';
import '../ui/format.dart';
import 'transactions_screen.dart';

/// Cash, bank accounts, cards and wallets with their balances.
class AccountsScreen extends StatelessWidget {
  const AccountsScreen({super.key, required this.data});

  final AppData data;

  @override
  Widget build(BuildContext context) {
    final balances = accountBalances(data.transactions, data.accounts);
    final month = monthStart(DateTime.now());
    final active = data.accounts.where((a) => !a.archived).toList();
    final archived = data.accounts.where((a) => a.archived).toList();
    // Money you have: cash, bank and wallets. Card dues are shown separately.
    final have = active.where((a) => a.kind != AccountKind.card).fold(0.0, (s, a) => s + (balances[a.id] ?? 0));
    final owed = active.where((a) => a.kind == AccountKind.card).fold(0.0, (s, a) => s + (balances[a.id] ?? 0));
    final scheme = Theme.of(context).colorScheme;

    Widget tile(Account a) {
      final bal = balances[a.id] ?? 0;
      final flow = accountFlow(data.transactions, a.id, month);
      final isCard = a.kind == AccountKind.card;
      return ListTile(
        leading: CircleAvatar(child: Icon(accountIcon(a))),
        title: Text(a.name),
        subtitle: Text('This month: in ${money(flow.moneyIn)} · out ${money(flow.moneyOut)}'),
        trailing: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              isCard ? money(-bal < 0 ? 0 : -bal) : '${bal < 0 ? '−' : ''}${money(bal.abs())}',
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: bal < 0 && !isCard ? scheme.error : null,
              ),
            ),
            if (isCard) Text('due', style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
        onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
          builder: (_) => ListenableBuilder(
            listenable: data,
            builder: (_, _) => TransactionsScreen(data: data, accountId: a.id),
          ),
        )),
        onLongPress: () => editAccount(context, data, a),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Accounts'),
        actions: [
          IconButton(tooltip: 'Add account', icon: const Icon(Icons.add), onPressed: () => editAccount(context, data)),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 96),
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Card(
              color: scheme.primaryContainer,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
                child: Row(
                  children: [
                    Expanded(child: _Stat(label: 'You have', value: '${have < 0 ? '−' : ''}${money(have.abs())}')),
                    if (active.any((a) => a.kind == AccountKind.card))
                      Expanded(child: _Stat(label: 'Card dues', value: money(owed < 0 ? -owed : 0))),
                  ],
                ),
              ),
            ),
          ),
          for (final a in active) tile(a),
          if (archived.isNotEmpty)
            ExpansionTile(
              title: Text('Hidden accounts (${archived.length})'),
              children: [for (final a in archived) tile(a)],
            ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              'Tap an account to see its transactions, long-press to edit it. '
              'Bank accounts and cards from your emails are added automatically. '
              'Set an opening balance so the balance matches your bank.',
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.onPrimaryContainer;
    return Column(
      children: [
        Text(label, style: TextStyle(color: color.withValues(alpha: 0.8))),
        const SizedBox(height: 4),
        FittedBox(
          child: Text(value,
              style: Theme.of(context).textTheme.titleLarge?.copyWith(color: color, fontWeight: FontWeight.w600)),
        ),
      ],
    );
  }
}

Future<void> editAccount(BuildContext context, AppData data, [Account? a]) => showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _AccountForm(data: data, existing: a),
    );

class _AccountForm extends StatefulWidget {
  const _AccountForm({required this.data, this.existing});

  final AppData data;
  final Account? existing;

  @override
  State<_AccountForm> createState() => _AccountFormState();
}

class _AccountFormState extends State<_AccountForm> {
  late final _name = TextEditingController(text: widget.existing?.name ?? '');
  late AccountKind _kind = widget.existing?.kind ?? AccountKind.bank;
  late final _opening = TextEditingController(text: _openingText());
  late bool _archived = widget.existing?.archived ?? false;
  String? _error;

  String _openingText() {
    final e = widget.existing;
    if (e == null || e.openingBalance == 0) return '';
    final v = e.kind == AccountKind.card ? -e.openingBalance : e.openingBalance;
    return v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2);
  }

  @override
  void dispose() {
    _name.dispose();
    _opening.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) return setState(() => _error = 'Enter a name');
    final raw = _opening.text.trim().replaceAll(',', '');
    final entered = raw.isEmpty ? 0.0 : double.tryParse(raw);
    if (entered == null) return setState(() => _error = 'Opening balance is not a number');
    try {
      await widget.data.saveAccount(
        id: widget.existing?.id,
        name: name,
        kind: _kind,
        // A card's opening figure is what you owed, stored as a negative balance.
        openingBalance: _kind == AccountKind.card ? -entered : entered,
        archived: _archived,
      );
      if (mounted) Navigator.pop(context);
    } catch (e) {
      setState(() => _error = e.toString().contains('duplicate') ? 'You already have “$name”' : 'Could not save: $e');
    }
  }

  Future<void> _delete() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Delete “${widget.existing!.name}”?'),
        content: const Text('Its transactions stay, without an account. To keep its history linked, hide it instead.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Delete')),
        ],
      ),
    );
    if (yes != true) return;
    await widget.data.deleteAccount(widget.existing!.id);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(widget.existing == null ? 'New account' : 'Edit account', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final k in AccountKind.values)
                ChoiceChip(
                  avatar: Icon(accountIcon(Account(id: '', name: '', kind: k)), size: 18),
                  label: Text(accountKindLabel(k)),
                  selected: _kind == k,
                  onSelected: (_) => setState(() => _kind = k),
                ),
            ],
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _name,
            autofocus: widget.existing == null,
            textCapitalization: TextCapitalization.words,
            decoration: InputDecoration(labelText: 'Name', hintText: 'e.g. HDFC Savings, Paytm', errorText: _error),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _opening,
            keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,\-]'))],
            decoration: InputDecoration(
              labelText: _kind == AccountKind.card ? 'Amount owed before using the app' : 'Opening balance',
              prefixText: '₹ ',
              helperText: 'Before your first transaction in the app',
            ),
          ),
          if (widget.existing != null)
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _archived,
              onChanged: (v) => setState(() => _archived = v),
              title: const Text('Hide this account'),
              subtitle: const Text('For closed accounts; history stays'),
            ),
          const SizedBox(height: 16),
          Row(
            children: [
              if (widget.existing != null && widget.existing!.kind != AccountKind.cash)
                TextButton(onPressed: _delete, child: const Text('Delete')),
              const Spacer(),
              FilledButton(onPressed: _save, child: const Text('Save')),
            ],
          ),
        ],
      ),
    );
  }
}
