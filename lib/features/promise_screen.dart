import 'package:flutter/material.dart';

import '../accounting/models.dart';
import '../accounting/voucher_service.dart';
import '../core/money.dart';
import '../core/theme.dart';
import '../shared/export.dart';
import '../shared/widgets.dart';
import '../state/app_controller.dart';
import 'parties_screen.dart';
import 'voucher_screen.dart';

/// Record a customer's promise after a call: "will pay ₹5,000 on 15th".
Future<void> addPromise(BuildContext context, Ledger party, {Voucher? replacing}) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => _PromiseSheet(party: party, replacing: replacing),
  );
}

class _PromiseSheet extends StatefulWidget {
  final Ledger party;
  final Voucher? replacing; // "put off" – the old promise is marked missed
  const _PromiseSheet({required this.party, this.replacing});
  @override
  State<_PromiseSheet> createState() => _PromiseSheetState();
}

class _PromiseSheetState extends State<_PromiseSheet> {
  late String date = isoDate(DateTime.now().add(const Duration(days: 7)));
  late final amount = TextEditingController(
      text: widget.replacing != null && widget.replacing!.amount > 0
          ? Money.fmt(widget.replacing!.amount).replaceAll(',', '')
          : (widget.party.balance > 0 ? Money.fmt(widget.party.balance).replaceAll(',', '') : ''));
  late final note = TextEditingController(text: widget.replacing?.narration ?? '');
  bool saving = false;

  Future<void> _save() async {
    final app = App.read(context);
    setState(() => saving = true);
    try {
      await app.vouchers.save(
        VoucherInput(
          type: VoucherType.promise,
          date: date,
          partyId: widget.party.id,
          amount: Money.parse(amount.text) ?? 0,
          narration: note.text.trim().isEmpty ? null : note.text.trim(),
        ),
        app.actor,
      );
      if (widget.replacing != null) await app.vouchers.setPromiseStatus(widget.replacing!.id, 'missed');
      if (mounted) {
        toast(context, app.t('promise_saved').replaceAll('{date}', shortDate(date)));
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) {
        toast(context, errText(context, e), error: true);
        setState(() => saving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = App.of(context).t;
    final p = widget.party;
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + MediaQuery.of(context).viewInsets.bottom),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(widget.replacing == null ? t('promise_new') : t('promise_put_off'),
            style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 4),
        Row(children: [
          Expanded(child: Text(p.name, style: Theme.of(context).textTheme.bodyMedium)),
          BalanceText(p.balance, size: 14),
        ]),
        const SizedBox(height: 14),
        DateField(
          date: date,
          label: t('promise_date'),
          first: todayIso(),
          last: isoDate(DateTime.now().add(const Duration(days: 730))),
          autofocus: true,
          onChanged: (d) => setState(() => date = d),
        ),
        const SizedBox(height: 6),
        Wrap(spacing: 6, children: [
          for (final (label, days) in [(t('tomorrow'), 1), (t('in_3_days'), 3), (t('in_a_week'), 7), (t('in_15_days'), 15), (t('in_a_month'), 30)])
            ActionChip(
              label: Text(label),
              onPressed: () => setState(() => date = isoDate(DateTime.now().add(Duration(days: days)))),
            ),
        ]),
        const SizedBox(height: 12),
        AmountField(controller: amount, label: t('promise_amount')),
        const SizedBox(height: 12),
        TextField(
          controller: note,
          decoration: InputDecoration(labelText: t('promise_note'), hintText: t('promise_note_hint'), isDense: true),
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: saving ? null : _save,
          icon: const Icon(Icons.event_available),
          label: Text(t('save')),
        ),
      ]),
    );
  }
}

/// वसुली वायदे: every open promise – overdue, today, coming – with call,
/// WhatsApp reminder, "money came", "put off" and "cancel".
class PromisesScreen extends StatefulWidget {
  const PromisesScreen({super.key});
  static Future<void> open(BuildContext context) =>
      Navigator.push(context, MaterialPageRoute(builder: (_) => const PromisesScreen()));
  @override
  State<PromisesScreen> createState() => _PromisesScreenState();
}

class _PromisesScreenState extends State<PromisesScreen> {
  bool showOpen = true;

  @override
  Widget build(BuildContext context) {
    final app = App.of(context);
    final t = app.t;
    final today = todayIso();
    return Scaffold(
      appBar: AppBar(title: Text(t('promises'))),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'promise_add',
        icon: const Icon(Icons.add_call),
        label: Text(t('promise_new')),
        onPressed: () async {
          final l = await pickLedger(context, groups: const [LedgerGroup.customer, LedgerGroup.supplier]);
          if (l != null && context.mounted) await addPromise(context, l);
        },
      ),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: SegmentedButton<bool>(
            segments: [
              ButtonSegment(value: true, label: Text(t('promise_waiting'))),
              ButtonSegment(value: false, label: Text(t('promise_history'))),
            ],
            selected: {showOpen},
            onSelectionChanged: (s) => setState(() => showOpen = s.first),
          ),
        ),
        Expanded(
          child: LiveBuilder<List<(Voucher, Ledger)>>(
            reloadKey: showOpen,
            load: () => app.ledgers.promises(open: showOpen),
            builder: (context, list) {
              if (list.isEmpty) {
                return Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(showOpen ? t('promise_empty') : t('no_entries'), textAlign: TextAlign.center),
                  ),
                );
              }
              final children = <Widget>[];
              String? lastGroup;
              for (final (v, l) in list) {
                final group = !showOpen
                    ? null
                    : v.date.compareTo(today) < 0
                    ? 'promise_overdue'
                    : v.date == today
                    ? 'promise_today'
                    : 'promise_coming';
                if (group != null && group != lastGroup) {
                  children.add(SectionTitle(t(group)));
                  lastGroup = group;
                }
                children.add(_PromiseCard(v: v, party: l, today: today));
              }
              return ListView(padding: const EdgeInsets.only(bottom: 90), children: children);
            },
          ),
        ),
      ]),
    );
  }
}

class _PromiseCard extends StatelessWidget {
  final Voucher v;
  final Ledger party;
  final String today;
  const _PromiseCard({required this.v, required this.party, required this.today});

  @override
  Widget build(BuildContext context) {
    final app = App.of(context);
    final t = app.t;
    final overdue = v.status == null || v.status == 'open' ? v.date.compareTo(today) < 0 : false;
    final days = parseIso(today).difference(parseIso(v.date)).inDays;
    final color = overdue ? AppColors.due : (v.date == today ? AppColors.haldi : AppColors.ink);
    final done = v.status == 'done';
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 8, 4),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          InkWell(
            onTap: () => KhataScreen.open(context, party.id),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Container(
                width: 52,
                padding: const EdgeInsets.symmetric(vertical: 6),
                decoration: BoxDecoration(color: color.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(10)),
                child: Column(children: [
                  Text('${parseIso(v.date).day}', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: color)),
                  Text(shortDate(v.date).split('/').skip(1).join('/'), style: TextStyle(fontSize: 11, color: color)),
                ]),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(party.name, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                  Text(
                    [
                      if (party.pageNo != null) '${t('page_no')} ${party.pageNo}',
                      if (v.amount > 0) '${t('promise_amount_short')} ₹${Money.fmt(v.amount)}',
                      if (overdue) t('days_late').replaceAll('{n}', '$days'),
                      if (!overdue && v.status != null && v.status != 'open') t(done ? 'promise_kept' : 'promise_missed'),
                    ].join(' · '),
                    style: TextStyle(color: overdue ? AppColors.due : null, fontSize: 13),
                  ),
                  if (v.narration != null) Text(v.narration!, style: Theme.of(context).textTheme.bodySmall),
                ]),
              ),
              BalanceText(party.balance, size: 14),
            ]),
          ),
          if (v.status == null || v.status == 'open')
            Wrap(spacing: 0, children: [
              if (party.phone != null)
                IconButton(tooltip: t('call'), icon: const Icon(Icons.call_outlined), onPressed: () => WhatsApp.call(party.phone!)),
              IconButton(
                tooltip: t('remind'),
                icon: const Icon(Icons.chat_outlined),
                onPressed: () => WhatsApp.send(
                  party.phone,
                  t('promise_reminder_msg')
                      .replaceAll('{name}', party.name)
                      .replaceAll('{shop}', app.businessName)
                      .replaceAll('{date}', shortDate(v.date))
                      .replaceAll('{amount}', Money.fmt(v.amount > 0 ? v.amount : party.balance)),
                ),
              ),
              TextButton.icon(
                icon: const Icon(Icons.payments_outlined, size: 18),
                label: Text(t('promise_paid')),
                onPressed: () async {
                  await app.vouchers.setPromiseStatus(v.id, 'done');
                  if (context.mounted) {
                    await VoucherScreen.open(context, VoucherType.receipt, partyId: party.id, amount: v.amount > 0 ? v.amount : null);
                  }
                },
              ),
              TextButton.icon(
                icon: const Icon(Icons.update, size: 18),
                label: Text(t('promise_put_off_short')),
                onPressed: () => addPromise(context, party, replacing: v),
              ),
              TextButton(
                onPressed: () async {
                  if (await confirm(context, t('promise_cancel_q'))) await app.vouchers.setPromiseStatus(v.id, 'missed');
                },
                child: Text(t('promise_cancel')),
              ),
            ])
          else
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(onPressed: () => app.vouchers.setPromiseStatus(v.id, 'open'), child: Text(t('bank_undo'))),
            ),
        ]),
      ),
    );
  }
}
