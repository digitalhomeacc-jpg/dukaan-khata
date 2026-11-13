import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../data/app_data.dart';
import '../models.dart';
import '../ui/category_style.dart';
import '../ui/format.dart';

Future<void> openTxnEditor(BuildContext context, AppData data, {Txn? existing, Txn? prefill}) {
  return Navigator.of(context).push(MaterialPageRoute<void>(
    fullscreenDialog: true,
    builder: (_) => TxnEditor(data: data, existing: existing, prefill: prefill),
  ));
}

const _methods = {
  'upi': 'UPI',
  'card': 'Card',
  'netbanking': 'Bank transfer',
  'atm': 'ATM',
  'cash': 'Cash',
  'other': 'Other',
};

class TxnEditor extends StatefulWidget {
  const TxnEditor({super.key, required this.data, this.existing, this.prefill});

  final AppData data;
  final Txn? existing;
  final Txn? prefill;

  @override
  State<TxnEditor> createState() => _TxnEditorState();
}

class _TxnEditorState extends State<TxnEditor> {
  final _form = GlobalKey<FormState>();
  late final Txn? _start = widget.existing ?? widget.prefill;
  late final _amount = TextEditingController(text: _start == null ? '' : _plain(_start.amount));
  late final _merchant = TextEditingController(text: _start?.merchant ?? '');
  late final _note = TextEditingController(text: _start?.note ?? '');
  late bool _isDebit = _start?.isDebit ?? true;
  late DateTime _when = _start?.txnAt ?? DateTime.now();
  late String? _categoryId = _start?.categoryId;
  late String _method = _start?.method ?? (widget.existing == null ? 'cash' : 'other');
  late bool _excluded = _start?.excluded ?? false;
  var _remember = true;
  var _busy = false;

  bool get _isNew => widget.existing == null;

  static String _plain(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2);

  @override
  void dispose() {
    _amount.dispose();
    _merchant.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _when,
      firstDate: DateTime(2015),
      lastDate: DateTime.now().add(const Duration(days: 1)),
    );
    if (d == null || !mounted) return;
    final t = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(_when));
    setState(() => _when = DateTime(d.year, d.month, d.day, t?.hour ?? _when.hour, t?.minute ?? _when.minute));
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _busy = true);
    final txn = Txn(
      id: widget.existing?.id ?? '',
      amount: double.parse(_amount.text.replaceAll(',', '')),
      isDebit: _isDebit,
      txnAt: _when,
      merchant: _merchant.text,
      note: _note.text,
      method: _method,
      categoryId: _categoryId,
      excluded: _excluded,
    );
    final categoryChanged = _categoryId != widget.existing?.categoryId;
    try {
      await widget.data.saveTxn(
        txn,
        isNew: _isNew,
        rememberCategory: !_isNew && categoryChanged && _remember && _merchant.text.trim().isNotEmpty,
      );
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not save: $e')));
    }
  }

  Future<void> _delete() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Delete this transaction?'),
        content: Text(widget.existing!.fromEmail
            ? 'It came from a bank email. It will not be added again unless you re-sync.'
            : 'This cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Delete')),
        ],
      ),
    );
    if (yes != true) return;
    await widget.data.deleteTxn(widget.existing!.id);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final existing = widget.existing;
    final categoryChanged = !_isNew && _categoryId != existing?.categoryId && _categoryId != null;
    return Scaffold(
      appBar: AppBar(
        title: Text(_isNew ? 'Add transaction' : 'Edit transaction'),
        actions: [
          if (!_isNew) IconButton(tooltip: 'Delete', icon: const Icon(Icons.delete_outline), onPressed: _delete),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton(onPressed: _busy ? null : _save, child: const Text('Save')),
          ),
        ],
      ),
      body: Form(
        key: _form,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: true, label: Text('Spent'), icon: Icon(Icons.arrow_upward)),
                ButtonSegment(value: false, label: Text('Received'), icon: Icon(Icons.arrow_downward)),
              ],
              selected: {_isDebit},
              onSelectionChanged: (s) => setState(() => _isDebit = s.first),
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _amount,
              autofocus: _isNew && widget.prefill == null,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))],
              style: Theme.of(context).textTheme.headlineSmall,
              decoration: const InputDecoration(labelText: 'Amount', prefixText: '₹ '),
              validator: (v) {
                final n = double.tryParse((v ?? '').replaceAll(',', ''));
                return n == null || n <= 0 ? 'Enter an amount' : null;
              },
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _merchant,
              textCapitalization: TextCapitalization.words,
              decoration: InputDecoration(labelText: _isDebit ? 'Paid to' : 'Received from'),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _pickDate,
              icon: const Icon(Icons.event),
              label: Text('${dayLabel(_when)}, ${timeLabel(_when)}'),
              style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48), alignment: Alignment.centerLeft),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final e in _methods.entries)
                  ChoiceChip(
                    label: Text(e.value),
                    selected: _method == e.key,
                    onSelected: (_) => setState(() => _method = e.key),
                  ),
              ],
            ),
            const SizedBox(height: 20),
            Text('Category', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final c in widget.data.categories)
                  ChoiceChip(
                    avatar: Icon(iconFor(c), size: 18, color: colorFor(c)),
                    label: Text(c.name),
                    selected: _categoryId == c.id,
                    onSelected: (sel) => setState(() => _categoryId = sel ? c.id : null),
                  ),
              ],
            ),
            if (categoryChanged && _merchant.text.trim().isNotEmpty)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: _remember,
                onChanged: (v) => setState(() => _remember = v ?? true),
                title: Text('Always use this category for “${_merchant.text.trim()}”'),
                subtitle: const Text('Also fills in its other payments that have no category'),
              ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _note,
              maxLines: 2,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(labelText: 'Note (optional)'),
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _excluded,
              onChanged: (v) => setState(() => _excluded = v),
              title: const Text("Don't count in totals"),
              subtitle: const Text('For card bill payments and moving money between your own accounts'),
            ),
            if (existing != null && existing.fromEmail) ...[
              const Divider(height: 32),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.mail_outline),
                title: const Text('Added from a bank email'),
                subtitle: Text([
                  if (existing.bank != null) '${existing.bank}${existing.accountLast4 != null ? ' ••${existing.accountLast4}' : ''}',
                  if (existing.emailSubject != null) '“${existing.emailSubject}”',
                ].join('\n')),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
