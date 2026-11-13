import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';

import '../data/app_data.dart';
import '../logic/summary.dart';
import '../models.dart';
import '../ui/category_style.dart';
import '../ui/format.dart';

final _date = DateFormat('d MMM yyyy');
String _short(DateTime d) => DateFormat(d.year == DateTime.now().year ? 'd MMM' : 'd MMM yyyy').format(d);

/// Known lenders: what the card is called and which payee names mean them.
const lenderPresets = <String, ({String name, LoanKind kind, List<String> aliases})>{
  'kreditbee': (
    name: 'KreditBee',
    kind: LoanKind.emi,
    aliases: ['kreditbee', 'krazybee', 'krazybee services', 'kbmas'],
  ),
  'fibe': (name: 'Fibe', kind: LoanKind.emi, aliases: ['fibe', 'earlysalary', 'social worth technologies', 'fibe.cf.']),
  'slice': (
    name: 'Slice borrow',
    kind: LoanKind.creditLine,
    aliases: ['slice', 'slice borrow', 'slice small finance bank'],
  ),
};

/// One lender loan on the Loans tab.
class LenderLoanCard extends StatelessWidget {
  const LenderLoanCard({super.key, required this.data, required this.loan});

  final AppData data;
  final Loan loan;

  @override
  Widget build(BuildContext context) {
    final s = loanStatus(loan, data.loanEvents);
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final due = s.nextDueDate;
    final overdue = due != null && !s.nextDuePaid && due.isBefore(DateTime.now().subtract(const Duration(days: 1)));
    return Card.outlined(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => ListenableBuilder(
              listenable: data,
              builder: (_, _) => LoanDetailScreen(data: data, loanId: loan.id),
            ),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  CircleAvatar(child: Text(loan.name.isEmpty ? '?' : loan.name[0].toUpperCase())),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(loan.name, style: text.titleMedium),
                        Text(
                          loan.kind == LoanKind.creditLine ? 'Credit line' : 'EMI loan',
                          style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(money(s.owed), style: text.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
                      Text(s.owedIsEmiBased ? 'left to pay' : 'owed', style: text.bodySmall),
                    ],
                  ),
                ],
              ),
              if (s.emisPaid != null && loan.tenureMonths != null) ...[
                const SizedBox(height: 12),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(value: s.emisPaid! / loan.tenureMonths!, minHeight: 8),
                ),
                const SizedBox(height: 4),
                Text('${s.emisPaid} of ${loan.tenureMonths} EMIs paid · ${s.emisLeft} left', style: text.bodySmall),
              ],
              if (due != null) ...[
                const SizedBox(height: 10),
                Row(
                  children: [
                    Icon(
                      s.nextDuePaid ? Icons.check_circle : Icons.event,
                      size: 18,
                      color: s.nextDuePaid ? Colors.green.shade700 : (overdue ? scheme.error : scheme.primary),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        s.nextDuePaid
                            ? 'Paid ${money(s.nextDueAmount ?? 0)} due ${_short(due)}'
                            : '${overdue ? 'Overdue' : 'Next due'}: ${money(s.nextDueAmount ?? 0)} on ${_short(due)}',
                        style: TextStyle(color: overdue ? scheme.error : null, fontWeight: FontWeight.w500),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class LoanDetailScreen extends StatelessWidget {
  const LoanDetailScreen({super.key, required this.data, required this.loanId});

  final AppData data;
  final String loanId;

  Future<void> _record(BuildContext context, Loan loan, LoanEventKind kind) async {
    final s = loanStatus(loan, data.loanEvents);
    final amount = TextEditingController(
      text: kind == LoanEventKind.repay
          ? _plain(s.nextDuePaid ? loan.emiAmount : (s.nextDueAmount ?? loan.emiAmount))
          : '',
    );
    var when = DateTime.now();
    final result = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, set) => AlertDialog(
          title: Text(kind == LoanEventKind.repay ? 'Mark a payment' : 'Borrowed more'),
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
              const SizedBox(height: 12),
              OutlinedButton.icon(
                icon: const Icon(Icons.event),
                label: Text(_date.format(when)),
                onPressed: () async {
                  final d = await showDatePicker(
                    context: c,
                    initialDate: when,
                    firstDate: DateTime(2015),
                    lastDate: DateTime.now().add(const Duration(days: 1)),
                  );
                  if (d != null) set(() => when = DateTime(d.year, d.month, d.day, 12));
                },
              ),
              if (kind == LoanEventKind.repay)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    'Payments from your bank to ${loan.name} are added by themselves when the bank email arrives. '
                    'Use this for payments made another way.',
                    style: Theme.of(c).textTheme.bodySmall,
                  ),
                ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Save')),
          ],
        ),
      ),
    );
    final v = double.tryParse(amount.text.replaceAll(',', ''));
    if (result != true || v == null || v <= 0) return;
    await data.addLoanEvent(loan.id, kind, v, when, note: 'Added by hand');
  }

  Future<void> _setOwed(BuildContext context, Loan loan) async {
    final c = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('How much do you owe now?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Check the ${loan.name} app and type the total amount owed. New borrowing and payments are counted from today.',
              style: Theme.of(ctx).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: c,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: 'Amount owed', prefixText: '₹ '),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
        ],
      ),
    );
    final v = double.tryParse(c.text.replaceAll(',', ''));
    if (ok == true && v != null && v >= 0) await data.setOwed(loan.id, v);
  }

  @override
  Widget build(BuildContext context) {
    final loan = data.loan(loanId);
    if (loan == null) return const Scaffold(body: Center(child: Text('This loan was deleted.')));
    final s = loanStatus(loan, data.loanEvents);
    final events = data.loanEvents.where((e) => e.loanId == loan.id).toList()..sort((a, b) => b.at.compareTo(a.at));
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;

    Widget fact(String label, String value) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Text(label, style: TextStyle(color: scheme.onSurfaceVariant)),
          ),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w500)),
        ],
      ),
    );

    return Scaffold(
      appBar: AppBar(
        title: Text(loan.name),
        actions: [
          IconButton(
            tooltip: 'Edit details',
            icon: const Icon(Icons.edit_outlined),
            onPressed: () => openLoanForm(context, data, existing: loan),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          Center(child: Text(s.owedIsEmiBased ? 'Left to pay' : 'You owe', style: text.titleMedium)),
          Center(
            child: Text(money(s.owed), style: text.displaySmall?.copyWith(fontWeight: FontWeight.w600)),
          ),
          if (s.owedIsEmiBased) Center(child: Text('EMIs left × EMI, interest included', style: text.bodySmall)),
          if (s.emisPaid != null && loan.tenureMonths != null) ...[
            const SizedBox(height: 16),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(value: s.emisPaid! / loan.tenureMonths!, minHeight: 10),
            ),
            const SizedBox(height: 4),
            Center(child: Text('${s.emisPaid} of ${loan.tenureMonths} EMIs paid · ${s.emisLeft} left')),
          ],
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: () => _record(context, loan, LoanEventKind.repay),
                  icon: const Icon(Icons.check),
                  label: Text(loan.kind == LoanKind.emi ? 'Mark EMI paid' : 'Mark payment'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton(onPressed: () => _setOwed(context, loan), child: const Text('Set amount owed')),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Card.filled(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Column(
                children: [
                  if (s.nextDueDate != null)
                    fact(
                      s.nextDuePaid ? 'Last due (paid)' : 'Next due',
                      '${money(s.nextDueAmount ?? 0)} · ${_date.format(s.nextDueDate!)}',
                    ),
                  if (loan.emiAmount != null) fact('EMI', money(loan.emiAmount!)),
                  if (loan.dueDay != null) fact('EMI date', '${loan.dueDay} of every month'),
                  if (loan.interestRate != null) fact('Interest', '${_plain(loan.interestRate)}% a year'),
                  if (loan.principal != null) fact('Amount borrowed', money(loan.principal!)),
                  fact(
                    loan.kind == LoanKind.creditLine ? 'Borrowed & spent (tracked)' : 'Borrowed more (tracked)',
                    money(s.borrowed - (loan.principal ?? 0)),
                  ),
                  fact('Paid back (tracked)', money(s.repaid)),
                  if (loan.outstanding != null && loan.outstandingAt != null)
                    fact('Owed set by you', '${money(loan.outstanding!)} on ${_short(loan.outstandingAt!)}'),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(child: Text('History', style: text.titleMedium)),
              TextButton.icon(
                onPressed: () => _record(context, loan, LoanEventKind.borrow),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Borrowed more'),
              ),
            ],
          ),
          if (events.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Text('Nothing yet. Payments and borrowing appear here from emails, or when you add them.'),
            ),
          for (final e in events)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(switch (e.kind) {
                LoanEventKind.borrow => Icons.call_received,
                LoanEventKind.spend => Icons.shopping_bag_outlined,
                LoanEventKind.repay => Icons.call_made,
              }, color: e.kind == LoanEventKind.repay ? Colors.green.shade700 : scheme.error),
              title: Text(switch (e.kind) {
                LoanEventKind.borrow => 'Borrowed',
                LoanEventKind.spend => 'Bought: ${e.note ?? ''}',
                LoanEventKind.repay => 'Paid back',
              }),
              subtitle: Text(
                '${_short(e.at)}${e.fromEmail ? ' · from email' : (e.note != null ? ' · ${e.note}' : '')}',
              ),
              trailing: Text(money(e.amount), style: const TextStyle(fontWeight: FontWeight.w600)),
              onLongPress: e.fromEmail
                  ? null
                  : () async {
                      final yes = await showDialog<bool>(
                        context: context,
                        builder: (c) => AlertDialog(
                          title: const Text('Remove this entry?'),
                          actions: [
                            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
                            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Remove')),
                          ],
                        ),
                      );
                      if (yes == true) await data.deleteLoanEvent(e.id);
                    },
            ),
        ],
      ),
    );
  }
}

String _plain(double? v) {
  if (v == null) return '';
  return v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2);
}

Future<void> openLoanForm(BuildContext context, AppData data, {Loan? existing}) => Navigator.of(context).push(
  MaterialPageRoute<void>(
    fullscreenDialog: true,
    builder: (_) => _LoanForm(data: data, existing: existing),
  ),
);

class _LoanForm extends StatefulWidget {
  const _LoanForm({required this.data, this.existing});

  final AppData data;
  final Loan? existing;

  @override
  State<_LoanForm> createState() => _LoanFormState();
}

class _LoanFormState extends State<_LoanForm> {
  final _form = GlobalKey<FormState>();
  late String _lender = widget.existing?.lender ?? 'kreditbee';
  late LoanKind _kind = widget.existing?.kind ?? LoanKind.emi;
  late final _name = TextEditingController(text: widget.existing?.name ?? lenderPresets['kreditbee']!.name);
  late final _principal = TextEditingController(text: _plain(widget.existing?.principal));
  late final _emi = TextEditingController(text: _plain(widget.existing?.emiAmount));
  late final _tenure = TextEditingController(text: widget.existing?.tenureMonths?.toString() ?? '');
  late final _paid = TextEditingController(text: widget.existing == null ? '' : '${widget.existing!.emisPaidBefore}');
  late final _rate = TextEditingController(text: _plain(widget.existing?.interestRate));
  late final _dueDay = TextEditingController(text: widget.existing?.dueDay?.toString() ?? '');
  late final _owed = TextEditingController();
  var _busy = false;

  bool get _isNew => widget.existing == null;

  @override
  void dispose() {
    for (final c in [_name, _principal, _emi, _tenure, _paid, _rate, _dueDay, _owed]) {
      c.dispose();
    }
    super.dispose();
  }

  void _pickLender(String key) => setState(() {
    _lender = key;
    final p = lenderPresets[key];
    if (p != null) {
      _name.text = p.name;
      _kind = p.kind;
    } else {
      _name.text = '';
    }
  });

  double? _d(TextEditingController c) => c.text.trim().isEmpty ? null : double.tryParse(c.text.replaceAll(',', ''));
  int? _i(TextEditingController c) => c.text.trim().isEmpty ? null : int.tryParse(c.text.trim());

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _busy = true);
    final name = _name.text.trim();
    final preset = lenderPresets[_lender];
    final row = <String, dynamic>{
      'lender': _lender,
      'name': name,
      'kind': _kind == LoanKind.creditLine ? 'credit_line' : 'emi',
      'principal': _d(_principal),
      'emi_amount': _d(_emi),
      'tenure_months': _i(_tenure),
      'emis_paid_before': _i(_paid) ?? 0,
      'interest_rate': _d(_rate),
      'due_day': _i(_dueDay),
      'aliases': preset?.aliases ?? [name.toLowerCase()],
    };
    final owed = _d(_owed);
    if (owed != null) {
      row['outstanding'] = owed;
      row['outstanding_at'] = DateTime.now().toUtc().toIso8601String();
    }
    try {
      await widget.data.saveLoan(row, id: widget.existing?.id);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            e.toString().contains('duplicate') ? 'You already have a loan called “$name”' : 'Could not save: $e',
          ),
        ),
      );
    }
  }

  Future<void> _delete() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Delete ${widget.existing!.name}?'),
        content: const Text('Its history goes too. Bank transactions stay, but count as normal spending again.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Delete')),
        ],
      ),
    );
    if (yes != true) return;
    await widget.data.deleteLoan(widget.existing!.id);
    if (mounted)
      Navigator.of(context)
        ..pop()
        ..pop();
  }

  Widget _number(
    TextEditingController c,
    String label, {
    String? prefix,
    String? helper,
    bool decimal = true,
    String? Function(String?)? validator,
  }) => TextFormField(
    controller: c,
    keyboardType: TextInputType.numberWithOptions(decimal: decimal),
    inputFormatters: [FilteringTextInputFormatter.allow(RegExp(decimal ? r'[0-9.,]' : r'[0-9]'))],
    decoration: InputDecoration(labelText: label, prefixText: prefix, helperText: helper),
    validator: validator,
  );

  @override
  Widget build(BuildContext context) {
    final emi = _kind == LoanKind.emi;
    return Scaffold(
      appBar: AppBar(
        title: Text(_isNew ? 'Add a loan' : 'Edit loan'),
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
            Text('Lender', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final e in lenderPresets.entries)
                  ChoiceChip(
                    label: Text(e.value.name),
                    selected: _lender == e.key,
                    onSelected: (_) => _pickLender(e.key),
                  ),
                ChoiceChip(
                  label: const Text('Other'),
                  selected: !lenderPresets.containsKey(_lender),
                  onSelected: (_) => _pickLender('other'),
                ),
              ],
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _name,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                labelText: 'Name on the card',
                helperText: 'Also how bank payments to them are recognised',
              ),
              validator: (v) => (v ?? '').trim().isEmpty ? 'Enter a name' : null,
            ),
            const SizedBox(height: 16),
            SegmentedButton<LoanKind>(
              segments: const [
                ButtonSegment(value: LoanKind.emi, label: Text('EMI loan')),
                ButtonSegment(value: LoanKind.creditLine, label: Text('Credit line')),
              ],
              selected: {_kind},
              onSelectionChanged: (s) => setState(() => _kind = s.first),
            ),
            const SizedBox(height: 16),
            _number(_principal, 'Amount borrowed', prefix: '₹ '),
            const SizedBox(height: 12),
            if (emi) ...[
              Row(
                children: [
                  Expanded(child: _number(_emi, 'EMI amount', prefix: '₹ ')),
                  const SizedBox(width: 12),
                  Expanded(child: _number(_tenure, 'Number of EMIs', decimal: false)),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: _number(
                      _paid,
                      'EMIs already paid',
                      decimal: false,
                      validator: (v) {
                        final p = int.tryParse(v ?? ''), t = _i(_tenure);
                        return p != null && t != null && p > t ? 'More than the number of EMIs' : null;
                      },
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _number(
                      _dueDay,
                      'EMI date (day)',
                      decimal: false,
                      validator: (v) {
                        final d = int.tryParse(v ?? '');
                        return v != null && v.isNotEmpty && (d == null || d < 1 || d > 31) ? '1 to 31' : null;
                      },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
            ],
            _number(_rate, 'Interest rate (optional)', helper: '% a year, as shown in the lender app'),
            const SizedBox(height: 12),
            _number(
              _owed,
              _isNew ? 'Amount owed now (optional)' : 'Update amount owed (optional)',
              prefix: '₹ ',
              helper: emi
                  ? 'Leave empty to work it out from EMIs left'
                  : 'From the lender app; payments and borrowing are counted from today',
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Icon(Icons.info_outline, size: 18, color: Theme.of(context).colorScheme.outline),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Money you borrow is not counted as income, and paying it back is not counted as spending.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
            ),
            if (_kind == LoanKind.creditLine) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  Icon(
                    accountIcon(const Account(id: '', name: '', kind: AccountKind.card)),
                    size: 18,
                    color: Theme.of(context).colorScheme.outline,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Things you buy with a credit line are counted as spending when you buy them.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
