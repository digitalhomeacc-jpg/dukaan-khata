import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';

import '../data/app_data.dart';
import '../logic/summary.dart';
import '../models.dart';
import '../ui/save_button.dart';
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
/// All loans at a glance: what you owe in total and what is due when.
class LoansSummaryCard extends StatelessWidget {
  const LoansSummaryCard({super.key, required this.data});

  final AppData data;

  @override
  Widget build(BuildContext context) {
    final loans = data.loans.where((l) => !l.closed).toList();
    if (loans.isEmpty) return const SizedBox.shrink();
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final owed = loans.fold(0.0, (v, l) => v + loanStatus(l, data.loanEvents).owed);
    final dues = upcomingDues(loans, data.loanEvents);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final in30 = dues.where((d) => d.date.isBefore(today.add(const Duration(days: 31))));
    final due30 = in30.fold(0.0, (v, d) => v + d.amount);
    final overdue = dues.where((d) => d.date.isBefore(today)).fold(0.0, (v, d) => v + d.amount);
    final byMonth = <DateTime, double>{};
    for (final d in dues) {
      final m = DateTime(d.date.year, d.date.month);
      byMonth[m] = (byMonth[m] ?? 0) + d.amount;
    }
    final estimated = dues.any((d) => d.estimate);

    Widget stat(String label, String value, {Color? color}) => Expanded(
      child: Column(
        children: [
          FittedBox(
            child: Text(
              value,
              style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700, color: color),
            ),
          ),
          Text(label, style: text.bodySmall, textAlign: TextAlign.center),
        ],
      ),
    );

    return Card.filled(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                stat('You owe in all', money(owed.roundToDouble()), color: scheme.error),
                stat('Due in 30 days', money(due30.roundToDouble())),
                stat('Loans', '${loans.length}'),
              ],
            ),
            if (overdue > 0) ...[
              const SizedBox(height: 8),
              Text(
                'Overdue: ${money(overdue)}',
                style: text.bodyMedium?.copyWith(color: scheme.error, fontWeight: FontWeight.w600),
              ),
            ],
            if (dues.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text('Coming up', style: text.titleSmall),
              for (final d in dues.take(6))
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(
                    children: [
                      SizedBox(width: 64, child: Text(DateFormat('d MMM').format(d.date), style: text.bodyMedium)),
                      Expanded(child: Text(d.loan.name, maxLines: 1, overflow: TextOverflow.ellipsis)),
                      Text(
                        '${d.estimate ? '≈ ' : ''}${money(d.amount)}',
                        style: text.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: d.date.isBefore(today) ? scheme.error : null,
                        ),
                      ),
                    ],
                  ),
                ),
              Theme(
                data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
                child: ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  title: Text('Due by month', style: text.titleSmall),
                  children: [
                    for (final m in (byMonth.entries.toList()..sort((a, b) => a.key.compareTo(b.key))))
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 3),
                        child: Row(
                          children: [
                            Expanded(child: Text(DateFormat('MMMM yyyy').format(m.key))),
                            Text(money(m.value.roundToDouble()), style: const TextStyle(fontWeight: FontWeight.w600)),
                          ],
                        ),
                      ),
                    if (estimated)
                      Padding(
                        padding: const EdgeInsets.only(top: 6, bottom: 8),
                        child: Text(
                          '≈ later EMIs are estimated from each loan\'s EMI. Loans with their own schedule (like Slice) '
                          'show its exact amounts.',
                          style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

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
                          loan.kind == LoanKind.creditLine
                              ? [
                                  'Credit line',
                                  if (creditLeft(loan, data.loanEvents) case final left?) '${money(left)} left to use',
                                ].join(' · ')
                              : 'EMI loan',
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

  Future<void> _setCreditLeft(BuildContext context, Loan loan) async {
    final c = TextEditingController(text: loan.availableCredit?.toStringAsFixed(0) ?? '');
    final v = await showDialog<double>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Credit left to use'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'The spending power the ${loan.name} app shows now (e.g. "Purchase power"). New spends and repayments '
              'move it from today.',
              style: Theme.of(ctx).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: c,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: 'Credit left', prefixText: '₹ '),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, double.tryParse(c.text.replaceAll(',', ''))),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (v != null && v >= 0) await data.setCreditLeft(loan.id, v);
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
          const SizedBox(height: 8),
          Row(
            children: [
              if (loan.kind == LoanKind.creditLine) ...[
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _setCreditLeft(context, loan),
                    icon: const Icon(Icons.credit_score_outlined, size: 18),
                    label: const Text('Credit left'),
                  ),
                ),
                const SizedBox(width: 12),
              ],
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => ListenableBuilder(
                        listenable: data,
                        builder: (_, _) => ScheduleScreen(data: data, loanId: loan.id),
                      ),
                    ),
                  ),
                  icon: const Icon(Icons.event_note_outlined, size: 18),
                  label: const Text('Repayment schedule'),
                ),
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
                  if (creditLeft(loan, data.loanEvents) case final left?)
                    fact('Credit left to use', '${money(left)} (about)'),
                  if (loan.schedule.where((e) => !e.date.isBefore(DateTime.now())).isNotEmpty)
                    fact(
                      'Schedule',
                      '${loan.schedule.where((e) => !e.date.isBefore(DateTime.now())).length} dues left · '
                          '${money(loan.schedule.where((e) => !e.date.isBefore(DateTime.now())).fold(0.0, (v, e) => v + e.amount))}',
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
    if (_busy) return;
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
    if (mounted) {
      Navigator.of(context)
        ..pop()
        ..pop();
    }
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
          SaveButton(onSave: _save),
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

/// The lender's repayment schedule: add, change or remove dues, or paste them from a screenshot's text.
class ScheduleScreen extends StatefulWidget {
  const ScheduleScreen({super.key, required this.data, required this.loanId});

  final AppData data;
  final String loanId;

  @override
  State<ScheduleScreen> createState() => _ScheduleScreenState();
}

class _ScheduleScreenState extends State<ScheduleScreen> {
  late List<({DateTime date, double amount})> _rows = [...?widget.data.loan(widget.loanId)?.schedule];
  var _changed = false;
  var _busy = false;

  void _set(List<({DateTime date, double amount})> rows) => setState(() {
    _rows = rows..sort((a, b) => a.date.compareTo(b.date));
    _changed = true;
  });

  Future<void> _edit([int? i]) async {
    final old = i == null ? null : _rows[i];
    var date = old?.date ?? DateTime(DateTime.now().year, DateTime.now().month + 1, 5);
    final amount = TextEditingController(text: old == null ? '' : old.amount.toStringAsFixed(2));
    final result = await showDialog<({DateTime date, double amount})>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: Text(old == null ? 'Add a due' : 'Change this due'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              OutlinedButton.icon(
                onPressed: () async {
                  final d = await showDatePicker(
                    context: ctx,
                    initialDate: date,
                    firstDate: DateTime(2020),
                    lastDate: DateTime(2040),
                  );
                  if (d != null) setState(() => date = d);
                },
                icon: const Icon(Icons.event),
                label: Text(DateFormat('d MMM yyyy').format(date)),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: amount,
                autofocus: old == null,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'Amount due', prefixText: '₹ '),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(
              onPressed: () {
                final a = double.tryParse(amount.text.replaceAll(',', ''));
                if (a != null && a > 0) Navigator.pop(ctx, (date: date, amount: a));
              },
              child: const Text('OK'),
            ),
          ],
        ),
      ),
    );
    if (result == null) return;
    _set([
      for (final (j, r) in _rows.indexed)
        if (j != i) r,
      result,
    ]);
  }

  Future<void> _paste() async {
    final c = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Paste the schedule'),
        content: SizedBox(
          width: 400,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'On iPhone: open the screenshot in Photos, tap the text icon (bottom right), then Copy All, and paste '
                'it here. Several screenshots? Paste them one after another. Lines like "Due on 05 Dec \'26 '
                '₹4,940.24" or "05/12/2026 4940.24" are read.',
                style: Theme.of(ctx).textTheme.bodySmall,
              ),
              const SizedBox(height: 8),
              TextField(
                controller: c,
                autofocus: true,
                minLines: 4,
                maxLines: 10,
                decoration: const InputDecoration(hintText: 'Paste here'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, c.text), child: const Text('Read it')),
        ],
      ),
    );
    if (text == null || !mounted) return;
    final found = parseSchedule(text);
    if (found.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('No dates with amounts found in that text.')));
      return;
    }
    // Same dates are replaced, new ones added.
    final byDay = {for (final r in _rows) DateTime(r.date.year, r.date.month, r.date.day): r};
    for (final f in found) {
      byDay[DateTime(f.date.year, f.date.month, f.date.day)] = f;
    }
    _set(byDay.values.toList());
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Read ${found.length} due${found.length == 1 ? '' : 's'}. Check them, then Save.')),
    );
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    try {
      await widget.data.saveSchedule(widget.loanId, _rows);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not save: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final loan = widget.data.loan(widget.loanId);
    final text = Theme.of(context).textTheme;
    final today = DateTime.now();
    final left = _rows.where((r) => !r.date.isBefore(DateTime(today.year, today.month, today.day)));
    return Scaffold(
      appBar: AppBar(
        title: Text('${loan?.name ?? 'Loan'}: schedule'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton(onPressed: _changed && !_busy ? _save : null, child: const Text('Save')),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(),
        icon: const Icon(Icons.add),
        label: const Text('Add a due'),
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 96),
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: OutlinedButton.icon(
              onPressed: _paste,
              icon: const Icon(Icons.content_paste),
              label: const Text('Paste from a screenshot'),
              style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            ),
          ),
          if (_rows.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                '${left.length} dues left · ${money(left.fold(0.0, (v, r) => v + r.amount))}',
                style: text.titleSmall,
              ),
            ),
          if (_rows.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'No schedule yet. Paste it from a screenshot, or add each due by hand.',
                textAlign: TextAlign.center,
              ),
            ),
          for (final (i, r) in _rows.indexed)
            ListTile(
              leading: Icon(
                r.date.isBefore(DateTime(today.year, today.month, today.day))
                    ? Icons.check_circle_outline
                    : Icons.event,
              ),
              title: Text(DateFormat('EEE, d MMM yyyy').format(r.date)),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(money(r.amount), style: const TextStyle(fontWeight: FontWeight.w600)),
                  IconButton(
                    tooltip: 'Remove',
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: () => _set([
                      for (final (j, x) in _rows.indexed)
                        if (j != i) x,
                    ]),
                  ),
                ],
              ),
              onTap: () => _edit(i),
            ),
        ],
      ),
    );
  }
}
