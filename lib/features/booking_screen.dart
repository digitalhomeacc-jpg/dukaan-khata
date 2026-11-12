import 'package:flutter/material.dart';

import '../accounting/bookings.dart';
import '../accounting/models.dart';
import '../core/money.dart';
import '../core/theme.dart';
import '../shared/widgets.dart';
import '../state/app_controller.dart';
import 'parties_screen.dart';

class _BookRow {
  Item? item;
  final qty = TextEditingController();
  final rate = TextEditingController();
  _BookRow([this.item, double q = 0, int r = 0]) {
    if (q != 0) qty.text = fmtQty(q);
    if (r != 0) rate.text = Money.fmt(r).replaceAll(',', '');
  }
  double get q => double.tryParse(normalizeDigits(qty.text)) ?? 0;
  int get r => Money.parse(rate.text) ?? 0;
}

/// New / edit बुकिंग: items at a locked rate, plus the advance paid with it.
class BookingScreen extends StatefulWidget {
  final String? partyId;
  final String? editId;
  final bool autoSave; // self-check only (demo)
  final bool supplier; // open as an order placed with a supplier
  const BookingScreen({super.key, this.partyId, this.editId, this.autoSave = false, this.supplier = false});
  static Future<void> open(BuildContext context, {String? partyId, String? editId, bool supplier = false}) => Navigator.push(
      context, MaterialPageRoute(builder: (_) => BookingScreen(partyId: partyId, editId: editId, supplier: supplier)));
  @override
  State<BookingScreen> createState() => _BookingScreenState();
}

class _BookingScreenState extends State<BookingScreen> {
  Ledger? party;
  late bool customer = !widget.supplier;
  String date = todayIso();
  List<Item> items = [];
  List<Ledger> moneyAccounts = [];
  final rows = <_BookRow>[];
  final advance = TextEditingController();
  final note = TextEditingController();
  String? payId;
  bool loading = true, saving = false;
  Booking? editing;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final app = App.read(context);
    items = await app.stock.list();
    moneyAccounts = await app.ledgers.list([LedgerGroup.cash, LedgerGroup.upi, LedgerGroup.bank]);
    payId = app.vouchers.sys('cash');
    if (widget.editId != null) {
      final b = (await app.bookings.list()).firstWhere((x) => x.id == widget.editId);
      editing = b;
      party = await app.ledgers.byId(b.partyId);
      customer = b.customer;
      date = b.date;
      note.text = b.note ?? '';
      for (final l in b.lines) {
        // an item hidden since then must still be in the dropdown
        if (!items.any((i) => i.id == l.item.id)) items.add(l.item);
        rows.add(_BookRow(l.item, l.qty, l.rate));
      }
    } else {
      if (widget.partyId != null) {
        party = await app.ledgers.byId(widget.partyId!);
        customer = party!.group != LedgerGroup.supplier;
      }
      rows.add(_BookRow());
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

  int get total => rows.fold(0, (s, r) => s + (r.q * r.r).round());
  bool get old => Books.isHistory(date);

  Future<void> _pickParty() async {
    final l = await pickLedger(context,
        groups: customer ? const [LedgerGroup.customer, LedgerGroup.supplier] : const [LedgerGroup.supplier, LedgerGroup.customer],
        createAs: customer ? LedgerGroup.customer : LedgerGroup.supplier);
    if (l != null) setState(() => party = l);
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
    if (lines.any((l) => l.rate <= 0)) return toast(context, t('booking_rate_needed'), error: true);
    setState(() => saving = true);
    try {
      await app.bookings.save(
        app.vouchers,
        app.actor,
        existingId: editing?.id,
        date: date,
        partyId: party!.id,
        customer: customer,
        items: lines,
        advance: editing != null ? editing!.advance : (Money.parse(advance.text) ?? 0),
        advanceLedgerId: payId,
        note: note.text.trim().isEmpty ? null : note.text.trim(),
      );
      if (!mounted) return;
      toast(context, t('saved'));
      Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        toast(context, errText(context, e), error: true);
        setState(() => saving = false);
      }
    }
  }

  Future<void> _delete() async {
    final app = App.read(context);
    if (!await confirm(context, app.t('confirm_delete'))) return;
    try {
      await app.vouchers.delete(editing!.id, app.actor);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) toast(context, errText(context, e), error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = App.of(context);
    final t = app.t;
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(editing == null ? t('booking_new') : '${t('booking')} · ${t('edit')}'),
        actions: [
          if (editing != null && app.actor.isOwner) IconButton(icon: const Icon(Icons.delete_outline), onPressed: _delete),
        ],
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 640),
                child: ListView(padding: const EdgeInsets.fromLTRB(12, 8, 12, 110), children: [
                  SegmentedButton<bool>(
                    segments: [
                      ButtonSegment(value: true, label: Text(t('booking_customer')), icon: const Icon(Icons.person_outline)),
                      ButtonSegment(value: false, label: Text(t('booking_supplier')), icon: const Icon(Icons.storefront_outlined)),
                    ],
                    selected: {customer},
                    onSelectionChanged: editing != null ? null : (s) => setState(() => customer = s.first),
                  ),
                  const SizedBox(height: 10),
                  Card(
                    child: ListTile(
                      leading: CircleAvatar(child: Text(party?.pageNo ?? (party == null ? '+' : party!.name.characters.first))),
                      title: Text(party?.name ?? t(customer ? 'pick_customer' : 'pick_supplier'),
                          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                      trailing: party == null
                          ? const Icon(Icons.search)
                          : BalanceText(party!.balance, supplier: party!.group == LedgerGroup.supplier),
                      onTap: editing != null ? null : _pickParty,
                    ),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: 220,
                    child: DateField(
                      date: date,
                      label: t('date'),
                      // the owner may note a booking taken before the books start
                      first: app.actor.isOwner ? null : Books.start,
                      onChanged: (d) => setState(() => date = d),
                    ),
                  ),
                  if (old)
                    Container(
                      margin: const EdgeInsets.only(top: 8),
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(color: AppColors.haldi.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(10)),
                      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        const Icon(Icons.history_edu, size: 20, color: AppColors.haldi),
                        const SizedBox(width: 8),
                        Expanded(child: Text(t('booking_old_help').replaceAll('{date}', shortDate(Books.start)))),
                      ]),
                    ),
                  SectionTitle(t('booking_items')),
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
                                  for (final it in items) DropdownMenuItem(value: it.id, child: Text(it.display(app.english))),
                                ],
                                onChanged: (id) => setState(() {
                                  final it = items.firstWhere((x) => x.id == id);
                                  rows[i].item = it;
                                  if (rows[i].rate.text.isEmpty) {
                                    final r = customer ? it.saleRate : it.purchaseRate;
                                    if (r > 0) rows[i].rate.text = Money.fmt(r).replaceAll(',', '');
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
                            Expanded(
                              child: TextField(
                                key: Key('book_qty_$i'),
                                controller: rows[i].qty,
                                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                decoration: InputDecoration(
                                    labelText: '${t(old ? 'booking_qty_left' : 'qty')}${rows[i].item == null ? '' : ' (${t('unit_${rows[i].item!.unit}')})'}', isDense: true),
                                onChanged: (_) => setState(() {}),
                              ),
                            ),
                            const Padding(padding: EdgeInsets.symmetric(horizontal: 8), child: Text('×')),
                            Expanded(
                              child: TextField(
                                key: Key('book_rate_$i'),
                                controller: rows[i].rate,
                                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                decoration: InputDecoration(labelText: t('booking_rate'), prefixText: '₹ ', isDense: true),
                                onChanged: (_) => setState(() {}),
                              ),
                            ),
                            const SizedBox(width: 8),
                            SizedBox(
                              width: 90,
                              child: Text('₹${Money.fmt((rows[i].q * rows[i].r).round())}',
                                  textAlign: TextAlign.right, style: const TextStyle(fontWeight: FontWeight.w700)),
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
                      onPressed: () => setState(() => rows.add(_BookRow())),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                    child: Row(children: [
                      Text(t('booking_value'), style: Theme.of(context).textTheme.titleMedium),
                      const Spacer(),
                      Text('₹${Money.fmt(total)}', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
                    ]),
                  ),
                  if (editing == null) ...[
                    SectionTitle(t(customer ? 'booking_advance_in' : 'booking_advance_out')),
                    AmountField(controller: advance, label: t(old ? 'booking_advance_old' : 'booking_advance'), onChanged: (_) => setState(() {})),
                    if ((Money.parse(advance.text) ?? 0) > 0 && !old) ...[
                      const SizedBox(height: 8),
                      PayModeChips(accounts: moneyAccounts, selected: payId, allowCredit: false, onSelected: (id) => setState(() => payId = id)),
                    ],
                    const SizedBox(height: 6),
                    Text(t(old ? 'booking_advance_help_old' : customer ? 'booking_advance_help_in' : 'booking_advance_help_out'),
                        style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
                  ] else if (editing!.advance > 0)
                    Padding(
                      padding: const EdgeInsets.all(4),
                      child: Text('${t('booking_advance')}: ₹${Money.fmt(editing!.advance)} – ${t('booking_advance_edit_help')}',
                          style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
                    ),
                  const SizedBox(height: 12),
                  TextField(controller: note, decoration: InputDecoration(labelText: t('narration'), border: const OutlineInputBorder(), isDense: true)),
                ]),
              ),
            ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
          child: FilledButton.icon(
            key: const Key('booking_save'),
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
            onPressed: saving || loading ? null : _save,
            icon: const Icon(Icons.bookmark_added_outlined),
            label: Text(t('save')),
          ),
        ),
      ),
    );
  }
}

/// बुकिंग report: customer and supplier bookings – booked, delivered, left.
class BookingsScreen extends StatefulWidget {
  const BookingsScreen({super.key});
  static Future<void> open(BuildContext context) =>
      Navigator.push(context, MaterialPageRoute(builder: (_) => const BookingsScreen()));
  @override
  State<BookingsScreen> createState() => _BookingsScreenState();
}

class _BookingsScreenState extends State<BookingsScreen> {
  bool showAll = false;

  @override
  Widget build(BuildContext context) {
    final app = App.of(context);
    final t = app.t;
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: Text(t('bookings')),
          actions: [
            FilterChip(
              label: Text(t('booking_show_done')),
              selected: showAll,
              onSelected: (v) => setState(() => showAll = v),
            ),
            const SizedBox(width: 8),
          ],
          bottom: TabBar(tabs: [Tab(text: t('booking_customer')), Tab(text: t('booking_supplier'))]),
        ),
        floatingActionButton: Builder(
          builder: (context) => FloatingActionButton.extended(
            heroTag: 'booking_add',
            icon: const Icon(Icons.add),
            label: Text(t('booking_new')),
            onPressed: () => BookingScreen.open(context),
          ),
        ),
        body: TabBarView(children: [
          _BookingList(customer: true, showAll: showAll),
          _BookingList(customer: false, showAll: showAll),
        ]),
      ),
    );
  }
}

class _BookingList extends StatelessWidget {
  final bool customer;
  final bool showAll;
  const _BookingList({required this.customer, required this.showAll});

  @override
  Widget build(BuildContext context) {
    final app = App.of(context);
    final t = app.t;
    return LiveBuilder<List<Booking>>(
      reloadKey: '$customer|$showAll',
      load: () async => (await app.bookings.list(customer: customer)).where((b) => showAll || b.open).toList().reversed.toList(),
      builder: (context, list) => list.isEmpty
          ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(t('booking_empty'), textAlign: TextAlign.center)))
          : ListView(padding: const EdgeInsets.fromLTRB(8, 8, 8, 96), children: [for (final b in list) BookingCard(b)]),
    );
  }
}

/// One booking: party, date, each item booked / delivered / left at the locked rate.
class BookingCard extends StatelessWidget {
  final Booking b;
  final bool compact;
  const BookingCard(this.b, {super.key, this.compact = false});

  @override
  Widget build(BuildContext context) {
    final app = App.of(context);
    final t = app.t;
    final scheme = Theme.of(context).colorScheme;
    final muted = TextStyle(fontSize: 12, color: scheme.onSurfaceVariant);
    const num = [FontFeature.tabularFigures()];
    final status = b.closed ? t('booking_closed') : b.done ? t('booking_done') : t('booking_open');
    final statusColor = b.closed ? AppColors.neutral : b.done ? AppColors.paid : AppColors.haldi;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        onTap: () => BookingScreen.open(context, editId: b.id),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(
                child: Text.rich(TextSpan(children: [
                  TextSpan(text: b.partyName, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                  if (b.pageNo != null) TextSpan(text: '  ${t('page_no')} ${b.pageNo}', style: muted),
                ])),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(color: statusColor.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(20)),
                child: Text(status, style: TextStyle(color: statusColor, fontSize: 12, fontWeight: FontWeight.w700)),
              ),
            ]),
            Text(
              [
                shortDate(b.date),
                if (b.old) t('booking_old_tag'),
                '${t('booking_value')} ₹${Money.fmt(b.value)}',
                if (b.advance > 0) '${t('booking_advance')} ₹${Money.fmt(b.advance)}',
                if (b.note != null) b.note!,
              ].join(' · '),
              style: muted,
            ),
            const SizedBox(height: 8),
            Table(
              columnWidths: const {0: FlexColumnWidth(3), 1: FlexColumnWidth(2), 2: FlexColumnWidth(2), 3: FlexColumnWidth(2), 4: FlexColumnWidth(2)},
              children: [
                TableRow(children: [
                  for (final h in ['item', 'booking_booked', 'booking_delivered', 'booking_left', 'rate'])
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text(t(h), style: muted, textAlign: h == 'item' ? TextAlign.left : TextAlign.right),
                    ),
                ]),
                for (final l in b.lines)
                  TableRow(children: [
                    Text(l.item.display(app.english), style: const TextStyle(fontWeight: FontWeight.w600)),
                    Text(fmtQty(l.qty), textAlign: TextAlign.right, style: const TextStyle(fontFeatures: num)),
                    Text(b.closed ? '' : fmtQty(l.delivered), textAlign: TextAlign.right, style: const TextStyle(fontFeatures: num)),
                    Text(b.closed ? '–' : '${fmtQty(l.remaining)} ${t('unit_${l.item.unit}')}',
                        textAlign: TextAlign.right,
                        style: TextStyle(
                            fontWeight: FontWeight.w800, fontFeatures: num, color: l.remaining > 0 && !b.closed ? AppColors.due : AppColors.paid)),
                    Text('₹${Money.fmt(l.rate)}', textAlign: TextAlign.right, style: const TextStyle(fontFeatures: num)),
                  ]),
              ],
            ),
            if (!compact)
              Align(
                alignment: Alignment.centerRight,
                child: Wrap(children: [
                  TextButton(onPressed: () => KhataScreen.open(context, b.partyId), child: Text(t('khata'))),
                  if (app.actor.isOwner && !b.done)
                    TextButton(
                      onPressed: () async {
                        if (b.closed || await confirm(context, t('booking_close_q'))) await app.bookings.setClosed(b.id, !b.closed);
                      },
                      child: Text(b.closed ? t('booking_reopen') : t('booking_close')),
                    ),
                ]),
              ),
          ]),
        ),
      ),
    );
  }
}
