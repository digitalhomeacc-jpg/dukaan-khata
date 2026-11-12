import 'package:flutter/material.dart';

import '../accounting/models.dart';
import '../accounting/recurring.dart';
import '../core/money.dart';
import '../core/theme.dart';
import '../shared/widgets.dart';
import '../state/app_controller.dart';
import 'parties_screen.dart';

const _mr = ['जानेवारी', 'फेब्रुवारी', 'मार्च', 'एप्रिल', 'मे', 'जून', 'जुलै', 'ऑगस्ट', 'सप्टेंबर', 'ऑक्टोबर', 'नोव्हेंबर', 'डिसेंबर'];
const _en = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];

/// "नोव्हेंबर 2026" for "2026-11".
String monthLabel(String ym, bool english) =>
    '${(english ? _en : _mr)[int.parse(ym.substring(5, 7)) - 1]} ${ym.substring(0, 4)}';

class _Row {
  Item? item;
  final qty = TextEditingController(text: '1');
  final rate = TextEditingController();
  _Row([this.item, double q = 1, int r = 0]) {
    qty.text = fmtQty(q);
    if (r != 0) rate.text = Money.fmt(r).replaceAll(',', '');
  }
  double get q => double.tryParse(normalizeDigits(qty.text)) ?? 0;
  int get r => Money.parse(rate.text) ?? 0;
}

/// दरमहा आकार of one party (or all): rent, water … charged every month.
class RecurringListScreen extends StatelessWidget {
  final String? partyId;
  const RecurringListScreen({super.key, this.partyId});
  static Future<void> open(BuildContext context, {String? partyId}) =>
      Navigator.push(context, MaterialPageRoute(builder: (_) => RecurringListScreen(partyId: partyId)));

  @override
  Widget build(BuildContext context) {
    final app = App.of(context);
    final t = app.t;
    final today = todayIso();
    return LiveBuilder<List<Recurring>>(
      reloadKey: partyId,
      load: () => app.recurring.list(partyId: partyId),
      builder: (context, list) {
        final due = list.fold<int>(0, (s, r) => s + r.dueMonths(today).length);
        return Scaffold(
          appBar: AppBar(title: Text(t('recurring'))),
          floatingActionButton: app.actor.isOwner
              ? FloatingActionButton.extended(
                  heroTag: 'rec_add',
                  icon: const Icon(Icons.add),
                  label: Text(t('recurring_new')),
                  onPressed: () async {
                    // money coming in (rent, water) or going out (loan interest, bills)
                    final kind = await showModalBottomSheet<bool>(
                      context: context,
                      showDragHandle: true,
                      builder: (ctx) => SafeArea(
                        child: Column(mainAxisSize: MainAxisSize.min, children: [
                          ListTile(
                            leading: const Icon(Icons.south_west, color: AppColors.paid),
                            title: Text(t('recurring_in')),
                            subtitle: Text(t('recurring_in_sub')),
                            onTap: () => Navigator.pop(ctx, false),
                          ),
                          ListTile(
                            leading: const Icon(Icons.north_east, color: AppColors.due),
                            title: Text(t('recurring_out')),
                            subtitle: Text(t('recurring_out_sub')),
                            onTap: () => Navigator.pop(ctx, true),
                          ),
                        ]),
                      ),
                    );
                    if (kind == null || !context.mounted) return;
                    kind ? await RecurringPayForm.open(context) : await RecurringForm.open(context, partyId: partyId);
                  },
                )
              : null,
          body: ListView(padding: const EdgeInsets.fromLTRB(8, 8, 8, 96), children: [
            if (due > 0)
              Card(
                color: AppColors.haldi.withValues(alpha: 0.14),
                child: ListTile(
                  leading: const Icon(Icons.event_repeat, color: AppColors.haldi),
                  title: Text(t('recurring_due').replaceAll('{n}', '$due'), style: const TextStyle(fontWeight: FontWeight.w700)),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => DueChargesScreen.open(context),
                ),
              ),
            if (list.isEmpty)
              Padding(padding: const EdgeInsets.all(24), child: Text(t('recurring_empty'), textAlign: TextAlign.center)),
            for (final r in list)
              Card(
                child: ListTile(
                  title: Text(r.partyName, style: const TextStyle(fontWeight: FontWeight.w700)),
                  leading: Icon(r.payment ? Icons.north_east : Icons.south_west, color: r.payment ? AppColors.due : AppColors.paid),
                  subtitle: Text([
                    if (r.payment)
                      '${t('recurring_out')} · ${r.amount > 0 ? '₹${Money.fmt(r.amount)}' : t('recurring_ask')}${r.note == null ? '' : ' · ${r.note}'}'
                    else
                      r.lines.map((l) => '${l.item.display(app.english)} ${l.rate > 0 ? '₹${Money.fmt((l.qty * l.rate).round())}' : t('recurring_ask')}').join(' + '),
                    if (r.stopped)
                      t('recurring_stopped')
                    else if (r.lastCharged != null)
                      '${t('recurring_last')}: ${monthLabel(r.lastCharged!, app.english)}'
                    else
                      '${t('recurring_from')}: ${monthLabel(r.startMonth, app.english)}',
                  ].join('\n')),
                  isThreeLine: true,
                  trailing: app.actor.isOwner
                      ? PopupMenuButton<String>(
                          onSelected: (v) async {
                            switch (v) {
                              case 'edit':
                                r.payment ? await RecurringPayForm.open(context, editId: r.id) : await RecurringForm.open(context, editId: r.id);
                              case 'stop':
                                await app.recurring.setStopped(r.id, !r.stopped, lastCharged: r.lastCharged);
                              case 'khata':
                                if (context.mounted) await KhataScreen.open(context, r.partyId);
                            }
                          },
                          itemBuilder: (_) => [
                            PopupMenuItem(value: 'edit', child: Text(t('edit'))),
                            PopupMenuItem(value: 'stop', child: Text(t(r.stopped ? 'recurring_resume' : 'recurring_stop'))),
                            PopupMenuItem(value: 'khata', child: Text(t('khata'))),
                          ],
                        )
                      : null,
                  onTap: () => KhataScreen.open(context, r.partyId),
                ),
              ),
          ]),
        );
      },
    );
  }
}

/// Set up a monthly charge: party, what to charge, from which month.
class RecurringForm extends StatefulWidget {
  final String? partyId;
  final String? editId;
  final bool autoSave; // self-check only (demo)
  const RecurringForm({super.key, this.partyId, this.editId, this.autoSave = false});
  static Future<void> open(BuildContext context, {String? partyId, String? editId}) =>
      Navigator.push(context, MaterialPageRoute(builder: (_) => RecurringForm(partyId: partyId, editId: editId)));
  @override
  State<RecurringForm> createState() => _RecurringFormState();
}

class _RecurringFormState extends State<RecurringForm> {
  Ledger? party;
  List<Item> items = [];
  final rows = <_Row>[];
  final note = TextEditingController();
  late String start = monthOf(todayIso());
  bool loading = true, saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final app = App.read(context);
    items = await app.stock.list();
    // services first – rent, water … are usually services
    items.sort((a, b) => (a.isService ? 0 : 1).compareTo(b.isService ? 0 : 1));
    if (widget.editId != null) {
      final r = (await app.recurring.list()).firstWhere((x) => x.id == widget.editId);
      party = await app.ledgers.byId(r.partyId);
      start = r.startMonth;
      note.text = r.note ?? '';
      for (final l in r.lines) {
        // an item hidden since then must still be in the dropdown
        if (!items.any((i) => i.id == l.item.id)) items.add(l.item);
        rows.add(_Row(l.item, l.qty, l.rate));
      }
    } else {
      if (widget.partyId != null) party = await app.ledgers.byId(widget.partyId!);
      rows.add(_Row());
    }
    if (mounted) setState(() => loading = false);
    if (mounted && widget.autoSave) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        final route = ModalRoute.of(context);
        await _save();
        if (mounted && (route?.isCurrent ?? false)) Navigator.pop(context, 'not saved');
      });
    }
  }

  Future<void> _save() async {
    final app = App.read(context);
    final t = app.t;
    if (party == null) return toast(context, t('err_party'), error: true);
    final lines = [
      for (final r in rows)
        if (r.item != null && r.q > 0) ItemLine(r.item!.id, r.q, r.r),
    ];
    if (lines.isEmpty) return toast(context, t('err_items'), error: true);
    setState(() => saving = true);
    try {
      await app.recurring.save(app.vouchers, app.actor,
          existingId: widget.editId, partyId: party!.id, startMonth: start, lines: lines, note: note.text.trim().isEmpty ? null : note.text.trim());
      if (mounted) {
        toast(context, t('saved'));
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
    final app = App.of(context);
    final t = app.t;
    final now = monthOf(todayIso());
    final months = [for (var m = now, i = 0; i < 3; m = nextMonth(m), i++) m];
    if (!months.contains(start)) months.insert(0, start);
    return Scaffold(
      appBar: AppBar(title: Text(widget.editId == null ? t('recurring_new') : '${t('recurring')} · ${t('edit')}')),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 600),
                child: ListView(padding: const EdgeInsets.fromLTRB(12, 8, 12, 110), children: [
                  Card(
                    child: ListTile(
                      leading: CircleAvatar(child: Text(party?.pageNo ?? (party == null ? '+' : party!.name.characters.first))),
                      title: Text(party?.name ?? t('pick_customer'), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                      trailing: party == null ? const Icon(Icons.search) : BalanceText(party!.balance),
                      onTap: widget.editId != null
                          ? null
                          : () async {
                              final l = await pickLedger(context,
                                  groups: const [LedgerGroup.customer, LedgerGroup.supplier], createAs: LedgerGroup.customer);
                              if (l != null) setState(() => party = l);
                            },
                    ),
                  ),
                  SectionTitle(t('recurring_items')),
                  for (var i = 0; i < rows.length; i++)
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(12, 8, 4, 10),
                        child: Column(children: [
                          Row(children: [
                            Expanded(
                              child: DropdownButtonFormField<String>(
                                initialValue: rows[i].item?.id,
                                isExpanded: true,
                                decoration: InputDecoration(labelText: t('item'), isDense: true),
                                items: [
                                  for (final it in items)
                                    DropdownMenuItem(
                                        value: it.id, child: Text('${it.display(app.english)}${it.isService ? ' · ${t('no_stock')}' : ''}')),
                                ],
                                onChanged: (id) => setState(() {
                                  final it = items.firstWhere((x) => x.id == id);
                                  rows[i].item = it;
                                  if (rows[i].rate.text.isEmpty && it.saleRate > 0) {
                                    rows[i].rate.text = Money.fmt(it.saleRate).replaceAll(',', '');
                                  }
                                }),
                              ),
                            ),
                            IconButton(
                              icon: const Icon(Icons.close, size: 20),
                              onPressed: rows.length == 1 ? null : () => setState(() => rows.removeAt(i)),
                            ),
                          ]),
                          const SizedBox(height: 6),
                          Row(children: [
                            SizedBox(
                              width: 80,
                              child: TextField(
                                controller: rows[i].qty,
                                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                decoration: InputDecoration(labelText: t('qty'), isDense: true),
                              ),
                            ),
                            const Padding(padding: EdgeInsets.symmetric(horizontal: 8), child: Text('×')),
                            Expanded(
                              child: TextField(
                                key: Key('rec_rate_$i'),
                                controller: rows[i].rate,
                                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                decoration: InputDecoration(
                                    labelText: t('rate'), prefixText: '₹ ', isDense: true, helperText: t('recurring_rate_help')),
                              ),
                            ),
                            const SizedBox(width: 8),
                          ]),
                        ]),
                      ),
                    ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      icon: const Icon(Icons.add),
                      label: Text(t('booking_add_item')),
                      onPressed: () => setState(() => rows.add(_Row())),
                    ),
                  ),
                  SectionTitle(t('recurring_from')),
                  Wrap(spacing: 6, children: [
                    for (final m in months)
                      ChoiceChip(label: Text(monthLabel(m, app.english)), selected: m == start, onSelected: (_) => setState(() => start = m)),
                  ]),
                  const SizedBox(height: 4),
                  Text(t('recurring_help'), style: Theme.of(context).textTheme.bodySmall),
                  const SizedBox(height: 12),
                  TextField(controller: note, decoration: InputDecoration(labelText: t('narration'), border: const OutlineInputBorder(), isDense: true)),
                ]),
              ),
            ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
          child: FilledButton.icon(
            key: const Key('rec_save'),
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
            onPressed: saving || loading || !app.actor.isOwner ? null : _save,
            icon: const Icon(Icons.event_repeat),
            label: Text(t('save')),
          ),
        ),
      ),
    );
  }
}

/// This month's (and any missed month's) charges: check the amounts, tap लावा.
class DueChargesScreen extends StatefulWidget {
  const DueChargesScreen({super.key});
  static Future<void> open(BuildContext context) =>
      Navigator.push(context, MaterialPageRoute(builder: (_) => const DueChargesScreen()));
  @override
  State<DueChargesScreen> createState() => _DueChargesScreenState();
}

class _DueChargesScreenState extends State<DueChargesScreen> {
  int reload = 0;
  final rates = <String, TextEditingController>{}; // "$recurringId|$month|$i"
  final busy = <String>{};

  TextEditingController _rate(Recurring r, String m, int i) =>
      rates.putIfAbsent('${r.id}|$m|$i', () => TextEditingController(text: r.lines[i].rate == 0 ? '' : Money.fmt(r.lines[i].rate).replaceAll(',', '')));

  List<ItemLine> _lines(Recurring r, String m) => [
        for (var i = 0; i < r.lines.length; i++)
          if ((Money.parse(_rate(r, m, i).text) ?? 0) > 0) ItemLine(r.lines[i].item.id, r.lines[i].qty, Money.parse(_rate(r, m, i).text)!),
      ];

  Future<void> _charge(Recurring r, String m) async {
    final app = App.read(context);
    final t = app.t;
    final lines = _lines(r, m);
    if (lines.isEmpty) return toast(context, t('err_amount'), error: true);
    setState(() => busy.add('${r.id}|$m'));
    try {
      final label = monthLabel(m, app.english);
      await app.recurring.charge(app.vouchers, app.actor, r, m, lines,
          narration: '${r.lines.map((l) => l.item.name).join(' + ')} – $label${r.note == null ? '' : ' · ${r.note}'}');
      if (mounted) toast(context, '${t('saved')} · ${r.partyName} · $label');
    } catch (e) {
      if (mounted) toast(context, errText(context, e), error: true);
    }
    if (mounted) setState(() => (busy.remove('${r.id}|$m'), reload++));
  }

  final payFrom = <String, String>{}; // recurring id → money account chosen
  List<Ledger> moneyAccounts = [];

  @override
  void initState() {
    super.initState();
    App.read(context).ledgers.list([LedgerGroup.cash, LedgerGroup.upi, LedgerGroup.bank]).then((l) {
      if (mounted) setState(() => moneyAccounts = l);
    });
  }

  Future<void> _pay(Recurring r, String m) async {
    final app = App.read(context);
    final t = app.t;
    final amt = Money.parse(_rate(r, m, 0).text) ?? 0;
    if (amt <= 0) return toast(context, t('err_amount'), error: true);
    setState(() => busy.add('${r.id}|$m'));
    try {
      final label = monthLabel(m, app.english);
      final today = todayIso();
      await app.recurring.pay(app.vouchers, app.actor, r, m,
          amount: amt,
          payFromId: payFrom[r.id] ?? r.payFromId ?? app.vouchers.sys('cash'),
          // this month's payment is made today; an older month's on its 1st
          date: m == monthOf(today) ? today : null,
          narration: '${r.note ?? r.partyName} – $label');
      if (mounted) toast(context, '${t('saved')} · ${r.note ?? r.partyName} · ₹${Money.fmt(amt)}');
    } catch (e) {
      if (mounted) toast(context, errText(context, e), error: true);
    }
    if (mounted) setState(() => (busy.remove('${r.id}|$m'), reload++));
  }

  Widget _payCard(Recurring r, String m, List<(Recurring, String)> due, AppController app) {
    final t = app.t;
    final scheme = Theme.of(context).colorScheme;
    final first = due.firstWhere((d) => d.$1.id == r.id).$2 == m;
    final ctl = rates.putIfAbsent('${r.id}|$m|0', () => TextEditingController(text: r.amount == 0 ? '' : Money.fmt(r.amount).replaceAll(',', '')));
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 10, 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.north_east, size: 18, color: AppColors.due),
            const SizedBox(width: 6),
            Expanded(
              child: Text.rich(TextSpan(children: [
                TextSpan(text: r.note ?? r.partyName, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                TextSpan(text: '  ${monthLabel(m, app.english)}', style: TextStyle(color: scheme.onSurfaceVariant)),
              ])),
            ),
            SizedBox(
              width: 120,
              child: TextField(
                key: Key('due_pay_${r.id}_$m'),
                controller: ctl,
                enabled: first,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                textAlign: TextAlign.right,
                decoration: InputDecoration(prefixText: '₹ ', isDense: true, hintText: r.amount == 0 ? t('recurring_enter') : null),
                onChanged: (_) => setState(() {}),
              ),
            ),
          ]),
          if (r.note != null) Text(r.partyName, style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
          if (first) ...[
            const SizedBox(height: 8),
            PayModeChips(
              accounts: moneyAccounts,
              selected: payFrom[r.id] ?? r.payFromId,
              allowCredit: false,
              onSelected: (id) => setState(() => payFrom[r.id] = id!),
            ),
          ],
          if (first && app.actor.isOwner)
            Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              TextButton(
                onPressed: () async {
                  if (!await confirm(context, t('recurring_skip_q').replaceAll('{m}', monthLabel(m, app.english)))) return;
                  await app.recurring.skip(r, m);
                  if (mounted) setState(() => reload++);
                },
                child: Text(t('recurring_skip')),
              ),
              const SizedBox(width: 6),
              FilledButton.icon(
                key: Key('due_paybtn_${r.id}_$m'),
                style: FilledButton.styleFrom(backgroundColor: AppColors.due),
                onPressed: busy.contains('${r.id}|$m') || (Money.parse(ctl.text) ?? 0) <= 0 ? null : () => _pay(r, m),
                icon: const Icon(Icons.check, size: 18),
                label: Text(t('recurring_pay_btn')),
              ),
            ])
          else if (!first)
            Text(t('recurring_after_prev'), style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final app = App.of(context);
    final t = app.t;
    final scheme = Theme.of(context).colorScheme;
    return LiveBuilder<List<(Recurring, String)>>(
      reloadKey: reload,
      load: () => app.recurring.due(todayIso()),
      builder: (context, due) => Scaffold(
        appBar: AppBar(title: Text(t('recurring_due_title'))),
        body: due.isEmpty
            ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(t('recurring_none_due'), textAlign: TextAlign.center)))
            : ListView(padding: const EdgeInsets.fromLTRB(8, 8, 8, 40), children: [
                for (final (r, m) in due)
                  if (r.payment) _payCard(r, m, due, app) else () {
                    // months of one charge are done oldest first
                    final first = due.firstWhere((d) => d.$1.id == r.id).$2 == m;
                    final total = _lines(r, m).fold<int>(0, (s, l) => s + l.amount);
                    return Card(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(14, 10, 10, 8),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Row(children: [
                            Expanded(
                              child: Text.rich(TextSpan(children: [
                                TextSpan(text: r.partyName, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                                TextSpan(text: '  ${monthLabel(m, app.english)}', style: TextStyle(color: scheme.onSurfaceVariant)),
                              ])),
                            ),
                            Text('₹${Money.fmt(total)}', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 17)),
                          ]),
                          const SizedBox(height: 6),
                          for (var i = 0; i < r.lines.length; i++)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 6),
                              child: Row(children: [
                                Expanded(
                                    child: Text(
                                        '${r.lines[i].item.display(app.english)}${r.lines[i].qty != 1 ? ' × ${fmtQty(r.lines[i].qty)}' : ''}')),
                                SizedBox(
                                  width: 120,
                                  child: TextField(
                                    key: Key('due_rate_${r.id}_${m}_$i'),
                                    controller: _rate(r, m, i),
                                    enabled: first,
                                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                    textAlign: TextAlign.right,
                                    decoration: InputDecoration(
                                      prefixText: '₹ ',
                                      isDense: true,
                                      hintText: r.lines[i].rate == 0 ? t('recurring_enter') : null,
                                    ),
                                    onChanged: (_) => setState(() {}),
                                  ),
                                ),
                              ]),
                            ),
                          if (first && app.actor.isOwner)
                            Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                              TextButton(
                                onPressed: () async {
                                  if (!await confirm(context, t('recurring_skip_q').replaceAll('{m}', monthLabel(m, app.english)))) return;
                                  await app.recurring.skip(r, m);
                                  if (mounted) setState(() => reload++);
                                },
                                child: Text(t('recurring_skip')),
                              ),
                              const SizedBox(width: 6),
                              FilledButton.icon(
                                key: Key('due_charge_${r.id}_$m'),
                                onPressed: busy.contains('${r.id}|$m') || total <= 0 ? null : () => _charge(r, m),
                                icon: const Icon(Icons.check, size: 18),
                                label: Text(t('recurring_charge')),
                              ),
                            ])
                          else if (!first)
                            Text(t('recurring_after_prev'), style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
                        ]),
                      ),
                    );
                  }(),
              ]),
      ),
    );
  }
}

/// दरमहा देणे: a payment made every month – loan interest, light bill, internet …
class RecurringPayForm extends StatefulWidget {
  final String? editId;
  final bool autoSave; // self-check only (demo)
  const RecurringPayForm({super.key, this.editId, this.autoSave = false});
  static Future<void> open(BuildContext context, {String? editId}) =>
      Navigator.push(context, MaterialPageRoute(builder: (_) => RecurringPayForm(editId: editId)));
  @override
  State<RecurringPayForm> createState() => _RecurringPayFormState();
}

class _RecurringPayFormState extends State<RecurringPayForm> {
  Ledger? account;
  String? payFrom;
  List<Ledger> moneyAccounts = [];
  final amount = TextEditingController();
  final note = TextEditingController();
  late String start = monthOf(todayIso());
  bool loading = true, saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final app = App.read(context);
    moneyAccounts = await app.ledgers.list([LedgerGroup.cash, LedgerGroup.upi, LedgerGroup.bank]);
    payFrom = app.vouchers.sys('cash');
    if (widget.editId != null) {
      final r = (await app.recurring.list()).firstWhere((x) => x.id == widget.editId);
      account = await app.ledgers.byId(r.partyId);
      payFrom = r.payFromId ?? payFrom;
      start = r.startMonth;
      if (r.amount > 0) amount.text = Money.fmt(r.amount).replaceAll(',', '');
      note.text = r.note ?? '';
    }
    if (mounted) setState(() => loading = false);
    if (mounted && widget.autoSave) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        final route = ModalRoute.of(context);
        await _save();
        if (mounted && (route?.isCurrent ?? false)) Navigator.pop(context, 'not saved');
      });
    }
  }

  Future<void> _save() async {
    final app = App.read(context);
    final t = app.t;
    if (account == null) return toast(context, t('err_party'), error: true);
    setState(() => saving = true);
    try {
      await app.recurring.savePayment(app.vouchers, app.actor,
          existingId: widget.editId,
          ledgerId: account!.id,
          payFromId: payFrom!,
          startMonth: start,
          amount: Money.parse(amount.text) ?? 0,
          note: note.text.trim().isEmpty ? null : note.text.trim());
      if (mounted) {
        toast(context, t('saved'));
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
    final app = App.of(context);
    final t = app.t;
    final now = monthOf(todayIso());
    final months = [for (var m = now, i = 0; i < 3; m = nextMonth(m), i++) m];
    if (!months.contains(start)) months.insert(0, start);
    return Scaffold(
      appBar: AppBar(title: Text(t('recurring_out'))),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 600),
                child: ListView(padding: const EdgeInsets.fromLTRB(12, 8, 12, 110), children: [
                  TextField(
                    key: const Key('recpay_note'),
                    controller: note,
                    autofocus: widget.editId == null,
                    decoration: InputDecoration(labelText: t('recurring_pay_name'), hintText: t('recurring_pay_name_hint'), border: const OutlineInputBorder()),
                  ),
                  const SizedBox(height: 12),
                  Card(
                    child: ListTile(
                      leading: const Icon(Icons.account_balance_wallet_outlined),
                      title: Text(account?.name ?? t('recurring_pay_account'), style: const TextStyle(fontWeight: FontWeight.w600)),
                      subtitle: Text(account == null ? t('recurring_pay_account_help') : t('grp_${account!.group.code}')),
                      trailing: const Icon(Icons.search),
                      onTap: () async {
                        final l = await pickLedger(context, groups: const [
                          LedgerGroup.expense,
                          LedgerGroup.directExpense,
                          LedgerGroup.loan,
                          LedgerGroup.capital,
                          LedgerGroup.supplier,
                          LedgerGroup.otherLiability,
                        ], createAs: LedgerGroup.expense);
                        if (l != null) setState(() => account = l);
                      },
                    ),
                  ),
                  const SizedBox(height: 12),
                  AmountField(controller: amount, label: t('recurring_pay_amount')),
                  const SizedBox(height: 4),
                  Text(t('recurring_rate_help'), style: Theme.of(context).textTheme.bodySmall),
                  SectionTitle(t('pay_mode')),
                  PayModeChips(accounts: moneyAccounts, selected: payFrom, allowCredit: false, onSelected: (id) => setState(() => payFrom = id)),
                  SectionTitle(t('recurring_from')),
                  Wrap(spacing: 6, children: [
                    for (final m in months)
                      ChoiceChip(label: Text(monthLabel(m, app.english)), selected: m == start, onSelected: (_) => setState(() => start = m)),
                  ]),
                  const SizedBox(height: 6),
                  Text(t('recurring_pay_help'), style: Theme.of(context).textTheme.bodySmall),
                ]),
              ),
            ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
          child: FilledButton.icon(
            key: const Key('recpay_save'),
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
            onPressed: saving || loading || !app.actor.isOwner ? null : _save,
            icon: const Icon(Icons.event_repeat),
            label: Text(t('save')),
          ),
        ),
      ),
    );
  }
}
