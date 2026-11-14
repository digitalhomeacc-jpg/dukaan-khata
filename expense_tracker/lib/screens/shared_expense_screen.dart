import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../data/app_data.dart';
import '../ui/category_style.dart';
import '../ui/format.dart';

Future<void> openSharedExpense(BuildContext context, AppData data) =>
    Navigator.of(context)
        .push(MaterialPageRoute<void>(fullscreenDialog: true, builder: (_) => SharedExpenseScreen(data: data)));

/// "Dinner ₹900, paid by me / by Rahul, split equally with Rahul and Priya."
class SharedExpenseScreen extends StatefulWidget {
  const SharedExpenseScreen({super.key, required this.data});

  final AppData data;

  @override
  State<SharedExpenseScreen> createState() => _SharedExpenseScreenState();
}

class _SharedExpenseScreenState extends State<SharedExpenseScreen> {
  final _desc = TextEditingController();
  final _total = TextEditingController();
  final _newFriend = TextEditingController();
  final _custom = <String, TextEditingController>{};
  final _with = <String>{};
  String? _paidBy; // null = me
  String? _categoryId;
  late String? _accountId = widget.data.cashAccount?.id;
  var _equal = true;
  var _busy = false;
  String? _error;

  late final List<String> _friends = {for (final l in widget.data.friendBalances) l.person}.toList()..sort();

  @override
  void dispose() {
    for (final c in [_desc, _total, _newFriend, ..._custom.values]) {
      c.dispose();
    }
    super.dispose();
  }

  double get _totalValue => double.tryParse(_total.text.replaceAll(',', '')) ?? 0;

  /// Each person's part; "me" is the user.
  Map<String, double> get _parts {
    final people = ['me', ..._with];
    if (_equal) {
      final each = (_totalValue / people.length * 100).floorToDouble() / 100;
      final parts = {for (final p in people) p: each};
      parts['me'] =
          ((_totalValue - each * (people.length - 1)) * 100).roundToDouble() / 100; // you take the paise left over
      return parts;
    }
    return {for (final p in people) p: double.tryParse(_custom[p]?.text.replaceAll(',', '') ?? '') ?? 0};
  }

  TextEditingController _ctl(String p) => _custom.putIfAbsent(p, TextEditingController.new);

  void _addFriend() {
    final n = _newFriend.text.trim();
    if (n.isEmpty) return;
    setState(() {
      if (!_friends.contains(n)) _friends.add(n);
      _with.add(n);
      _newFriend.clear();
    });
  }

  Future<void> _save() async {
    final parts = _parts;
    final total = _totalValue;
    String? err;
    if (_desc.text.trim().isEmpty) err = 'What was it for?';
    if (total <= 0) err ??= 'Enter the total';
    if (_with.isEmpty) err ??= 'Pick who shared it';
    if (_paidBy != null && !_with.contains(_paidBy)) err ??= 'The person who paid must be in the split';
    final sum = parts.values.fold(0.0, (s, v) => s + v);
    if ((sum - total).abs() > 0.5) err ??= 'The parts add up to ${money(sum)}, not ${money(total)}';
    if (err != null) return setState(() => _error = err);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.data.addSharedExpense(
        description: _desc.text.trim(),
        total: total,
        at: DateTime.now(),
        categoryId: _categoryId,
        paidBy: _paidBy,
        accountId: _accountId,
        myShare: parts['me'] ?? 0,
        friendShares: {for (final p in _with) p: parts[p] ?? 0},
      );
      if (mounted) Navigator.pop(context);
    } catch (e) {
      setState(() {
        _busy = false;
        _error = 'Could not save: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final parts = _parts;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Shared expense'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton(onPressed: _busy ? null : _save, child: const Text('Save')),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _desc,
            autofocus: true,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(labelText: 'What for?', hintText: 'e.g. Pizza night'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _total,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))],
            style: text.headlineSmall,
            decoration: const InputDecoration(labelText: 'Total', prefixText: '₹ '),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 20),
          Text('Split with', style: text.titleSmall),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final f in _friends)
                FilterChip(
                  label: Text(f),
                  selected: _with.contains(f),
                  onSelected: (v) => setState(() {
                    v ? _with.add(f) : _with.remove(f);
                    if (!v && _paidBy == f) _paidBy = null;
                  }),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _newFriend,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(labelText: 'Add a person', isDense: true),
                  onSubmitted: (_) => _addFriend(),
                ),
              ),
              IconButton(onPressed: _addFriend, icon: const Icon(Icons.person_add_alt)),
            ],
          ),
          const SizedBox(height: 20),
          Text('Paid by', style: text.titleSmall),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ChoiceChip(
                label: const Text('Me'),
                selected: _paidBy == null,
                onSelected: (_) => setState(() => _paidBy = null),
              ),
              for (final f in _with)
                ChoiceChip(label: Text(f), selected: _paidBy == f, onSelected: (_) => setState(() => _paidBy = f)),
            ],
          ),
          if (_paidBy == null) ...[
            const SizedBox(height: 12),
            Text('Paid from', style: text.titleSmall),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final a in widget.data.activeAccounts)
                  ChoiceChip(
                    avatar: Icon(accountIcon(a), size: 18),
                    label: Text(a.name),
                    selected: _accountId == a.id,
                    onSelected: (_) => setState(() => _accountId = a.id),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Paid by UPI or card? Better: open that payment from its bank email and use “Split with friends” there.',
              style: text.bodySmall,
            ),
          ],
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(child: Text('Parts', style: text.titleSmall)),
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: true, label: Text('Equal')),
                  ButtonSegment(value: false, label: Text('Amounts')),
                ],
                selected: {_equal},
                onSelectionChanged: (s) => setState(() => _equal = s.first),
              ),
            ],
          ),
          for (final p in ['me', ..._with])
            ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: Text(p == 'me' ? 'You' : p),
              trailing: _equal
                  ? Text(money(parts[p] ?? 0), style: const TextStyle(fontWeight: FontWeight.w600))
                  : SizedBox(
                      width: 110,
                      child: TextField(
                        controller: _ctl(p),
                        textAlign: TextAlign.end,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        decoration: const InputDecoration(prefixText: '₹ ', isDense: true),
                        onChanged: (_) => setState(() {}),
                      ),
                    ),
            ),
          const SizedBox(height: 12),
          Text('Category', style: text.titleSmall),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final c in widget.data.categories.where((c) => !c.isLoan))
                ChoiceChip(
                  avatar: Icon(iconFor(c), size: 18, color: colorFor(c)),
                  label: Text(c.name),
                  selected: _categoryId == c.id,
                  onSelected: (sel) => setState(() => _categoryId = sel ? c.id : null),
                ),
            ],
          ),
          const SizedBox(height: 16),
          if (_with.isNotEmpty && _totalValue > 0)
            Card.filled(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  _paidBy == null
                      ? 'You paid ${money(_totalValue)}. Your spending: ${money(parts['me'] ?? 0)}. '
                            '${_with.map((f) => '$f owes you ${money(parts[f] ?? 0)}').join(', ')}.'
                      : '$_paidBy paid ${money(_totalValue)}. Your spending: ${money(parts['me'] ?? 0)}, which you owe $_paidBy.',
                ),
              ),
            ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
          const SizedBox(height: 40),
        ],
      ),
    );
  }
}
