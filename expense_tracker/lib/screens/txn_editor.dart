import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../data/app_data.dart';
import '../logic/summary.dart';
import '../models.dart';
import '../ui/category_picker.dart';
import '../ui/category_style.dart';
import '../ui/format.dart';
import 'split_section.dart';

Future<void> openTxnEditor(BuildContext context, AppData data, {Txn? existing, Txn? prefill}) {
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => TxnEditor(data: data, existing: existing, prefill: prefill),
    ),
  );
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
  late final _amount = TextEditingController(text: _start == null || _start.amount <= 0 ? '' : _plain(_start.amount));
  late final _merchant = TextEditingController(text: _start?.merchant ?? '');
  late final _note = TextEditingController(text: _start?.note ?? '');
  late bool _isDebit = _start?.isDebit ?? true;
  late DateTime _when = _start?.txnAt ?? DateTime.now();
  late String? _categoryId = _start?.categoryId;
  late String _method = _start?.method ?? (widget.existing == null ? 'cash' : 'other');
  late bool _excluded = _start?.excluded ?? false;
  late String? _accountId = _start?.accountId ?? (widget.existing == null ? widget.data.cashAccount?.id : null);
  late String? _counterId = _start?.counterAccountId;
  var _remember = true;
  var _busy = false;

  bool get _isNew => widget.existing == null;
  bool get _isLoan => widget.data.loanCategoryIds.contains(_categoryId);

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
      accountId: _accountId,
      counterAccountId: _counterId == _accountId ? null : _counterId,
      excluded: _excluded,
    );
    final categoryChanged = _categoryId != widget.existing?.categoryId;
    try {
      final remember = !_isNew && categoryChanged && _remember && _merchant.text.trim().isNotEmpty;
      final vpa = widget.existing?.payeeVpa;
      await widget.data.saveTxn(txn, isNew: _isNew, rememberCategory: remember && vpa == null);
      if (remember && vpa != null) {
        await widget.data.categorizeGroup(
          widget.data.transactions.where((t) => t.payeeVpa == vpa && t.id != txn.id),
          _categoryId,
          vpas: {vpa},
        );
      }
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
        content: Text(
          widget.existing!.fromEmail
              ? 'It came from a bank email. It will not be added again unless you re-sync.'
              : 'This cannot be undone.',
        ),
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
        title: Text(_isNew ? 'Add transaction' : 'Payment details'),
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
            if (existing != null) ...[BankRecordCard(data: widget.data, txn: existing), const SizedBox(height: 16)],
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
              autofocus: _isNew && (widget.prefill?.amount ?? 0) <= 0,
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
              decoration: InputDecoration(
                labelText: _isLoan ? "Friend's name" : (_isDebit ? 'Paid to' : 'Received from'),
                helperText: _isLoan
                    ? (_isDebit
                          ? 'Spent = you lent money or paid them back'
                          : 'Received = you borrowed or they paid you back')
                    : null,
              ),
              validator: (v) => _isLoan && (v ?? '').trim().isEmpty ? 'Whose loan is it?' : null,
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
            Text(_isDebit ? 'Paid from' : 'Received in', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            _AccountChips(
              data: widget.data,
              selected: _accountId,
              onSelected: (id) => setState(() {
                _accountId = id;
                if (_isNew && widget.data.account(id)?.kind == AccountKind.cash) _method = 'cash';
              }),
            ),
            const SizedBox(height: 20),
            Text('Category', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            CategoryField(
              data: widget.data,
              categoryId: _categoryId,
              onTap: () async {
                final pick = await pickCategory(context, widget.data, selected: _categoryId, allowFriends: true);
                if (pick != null && mounted) setState(() => _categoryId = pick.id);
              },
            ),
            if (_isLoan)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  'Goes to your balance with this friend. If they bought something for you, pick what it was instead (e.g. Food).',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            if (categoryChanged && _merchant.text.trim().isNotEmpty)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: _remember,
                onChanged: (v) => setState(() => _remember = v ?? true),
                title: Text(
                  existing?.payeeVpa != null
                      ? 'Use it for every payment to UPI ••${existing!.payeeVpa}'
                      : 'Always use this category for “${_merchant.text.trim()}”',
                ),
                subtitle: Text(
                  existing?.payeeVpa != null
                      ? 'Past and new payments to this UPI ID (not other UPI IDs with the same name)'
                      : 'Also fills in its other payments that have no category',
                ),
              ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _note,
              maxLines: 2,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Your note',
                hintText: 'What was it for? Who was with you? Bill no.…',
              ),
            ),
            if (existing != null && !existing.isLoanTransfer && !_isLoan) ...[
              const SizedBox(height: 16),
              ListenableBuilder(
                listenable: widget.data,
                builder: (context, _) {
                  final live = widget.data.txn(existing.id) ?? existing;
                  return live.isDebit
                      ? SplitSection(data: widget.data, payment: live)
                      : PaidBackSection(data: widget.data, credit: live);
                },
              ),
            ],
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _excluded,
              onChanged: (v) => setState(() => _excluded = v),
              title: const Text('Move between my own accounts'),
              subtitle: const Text('ATM cash, card bill payments, savings. Not counted as spending or income'),
            ),
            if (_excluded) ...[
              Text(
                _isDebit ? 'Moved to (optional)' : 'Moved from (optional)',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 8),
              _AccountChips(
                data: widget.data,
                selected: _counterId,
                hide: _accountId,
                onSelected: (id) => setState(() => _counterId = id),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// What the bank said about a payment: the voucher's printed part, read-only.
class BankRecordCard extends StatefulWidget {
  const BankRecordCard({super.key, required this.data, required this.txn});

  final AppData data;
  final Txn txn;

  @override
  State<BankRecordCard> createState() => _BankRecordCardState();
}

class _BankRecordCardState extends State<BankRecordCard> {
  var _showEmail = false;

  /// The readable part of a bank email: its body without links and the long footer.
  static String _emailText(String body) {
    var t = body.replaceAll(RegExp(r'https?://\S+'), '').replaceAll(RegExp(r'[ \t]+'), ' ');
    final end = RegExp(r'(?i)(warm regards|regards,|this is a system.generated|do not reply|please do not|disclaimer)')
        .firstMatch(t);
    if (end != null) t = t.substring(0, end.start);
    return t.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).join('\n').trim();
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.data.txn(widget.txn.id) ?? widget.txn;
    final data = widget.data;
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final account = data.account(t.accountId);
    final balance = account == null ? null : runningBalances(data.transactions, account)[t.id];
    final raw = [t.details, t.emailBody].whereType<String>().join(' ');
    final ref = RegExp(r'(?<![\d])(\d{12})(?![\d])').firstMatch(raw)?.group(1);
    final email = t.emailBody == null ? null : _emailText(t.emailBody!);
    final (IconData icon, String from) = switch (t.source) {
      'statement' => (Icons.description_outlined, 'Bank statement'),
      'email' => (Icons.mail_outline, 'Bank email'),
      _ => (Icons.edit_note, 'Added by you'),
    };

    Widget row(String label, String value, {bool copy = false}) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 92,
            child: Text(label, style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
          ),
          Expanded(child: SelectableText(value, style: text.bodyMedium)),
          if (copy)
            InkWell(
              onTap: () {
                Clipboard.setData(ClipboardData(text: value));
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Copied $label')));
              },
              child: Padding(
                padding: const EdgeInsets.only(left: 6),
                child: Icon(Icons.copy, size: 16, color: scheme.primary),
              ),
            ),
        ],
      ),
    );

    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: scheme.outlineVariant),
      ),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 18, color: scheme.primary),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  from,
                  style: text.labelLarge?.copyWith(color: scheme.primary),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text(
                '${t.isDebit ? '−' : '+'}${money(t.amount)}',
                style: text.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: t.isDebit ? null : Colors.green.shade700,
                ),
              ),
            ],
          ),
          const Divider(height: 18),
          row('Date', '${dayLabel(t.txnAt)}${t.source == 'statement' ? '' : ', ${timeLabel(t.txnAt)}'}'),
          if (account != null) row('Account', account.name),
          if ((t.details ?? '').isNotEmpty) row('Bank wrote', t.details!, copy: true),
          if (t.payeeVpa != null) row('UPI ID', '••${t.payeeVpa}'),
          if (ref != null) row('Reference', ref, copy: true),
          if (balance != null) row('Balance after', '${balance < 0 ? '−' : ''}${money(balance.abs())}'),
          if (t.emailSubject != null) row('Email', t.emailSubject!),
          if (email != null && email.isNotEmpty) ...[
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                style: TextButton.styleFrom(padding: EdgeInsets.zero, visualDensity: VisualDensity.compact),
                onPressed: () => setState(() => _showEmail = !_showEmail),
                icon: Icon(_showEmail ? Icons.expand_less : Icons.expand_more, size: 18),
                label: Text(_showEmail ? 'Hide the email' : 'Show the bank email'),
              ),
            ),
            if (_showEmail)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(color: scheme.surface, borderRadius: BorderRadius.circular(10)),
                child: SelectableText(email, style: text.bodySmall),
              ),
          ],
        ],
      ),
    );
  }
}

class _AccountChips extends StatelessWidget {
  const _AccountChips({required this.data, required this.selected, required this.onSelected, this.hide});

  final AppData data;
  final String? selected;
  final String? hide;
  final ValueChanged<String?> onSelected;

  @override
  Widget build(BuildContext context) {
    final list = [
      for (final a in data.accounts)
        if (a.id != hide && (!a.archived || a.id == selected)) a,
    ];
    if (list.isEmpty) {
      return Text('Add accounts in the Accounts tab', style: TextStyle(color: Theme.of(context).colorScheme.outline));
    }
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final a in list)
          ChoiceChip(
            avatar: Icon(accountIcon(a), size: 18),
            label: Text(a.name),
            selected: selected == a.id,
            onSelected: (sel) => onSelected(sel ? a.id : null),
          ),
      ],
    );
  }
}
