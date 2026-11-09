import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../accounting/bookings.dart';
import '../accounting/interest.dart';
import '../accounting/ledger_repo.dart';
import '../accounting/models.dart';
import '../core/money.dart';
import '../core/theme.dart';
import '../inventory/stock_repo.dart';
import '../shared/export.dart';
import '../shared/widgets.dart';
import '../state/app_controller.dart';
import 'books_screens.dart';
import 'booking_screen.dart';
import 'interest_screen.dart';
import 'staff_screen.dart';
import 'promise_screen.dart';
import 'voucher_screen.dart';

/// Customer / supplier list – the digital INDEX page.
class PartiesScreen extends StatefulWidget {
  final LedgerGroup group;
  const PartiesScreen({super.key, required this.group});
  @override
  State<PartiesScreen> createState() => _PartiesScreenState();
}

enum _Sort { name, page, due }

class _PartiesScreenState extends State<PartiesScreen> {
  final _q = TextEditingController();
  _Sort sort = _Sort.name;

  @override
  Widget build(BuildContext context) {
    final app = App.of(context);
    final t = app.t;
    final isCust = widget.group == LedgerGroup.customer;
    return Scaffold(
      appBar: AppBar(
        title: Text(isCust ? t('customers') : t('suppliers')),
        actions: [
          PopupMenuButton<_Sort>(
            icon: const Icon(Icons.sort),
            onSelected: (s) => setState(() => sort = s),
            itemBuilder: (_) => [
              PopupMenuItem(value: _Sort.name, child: Text(t('name'))),
              PopupMenuItem(value: _Sort.page, child: Text(t('page_no'))),
              PopupMenuItem(value: _Sort.due, child: Text(t('due'))),
            ],
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'add_${widget.group.code}',
        icon: const Icon(Icons.person_add),
        label: Text(isCust ? t('new_customer') : t('new_supplier')),
        onPressed: () => PartyForm.open(context, widget.group),
      ),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: TextField(
            controller: _q,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search),
              hintText: t('search_party'),
              border: const OutlineInputBorder(),
              isDense: true,
            ),
          ),
        ),
        Expanded(
          child: LiveBuilder<(List<Ledger>, Map<String, List<GoodsOwed>>, Map<String, List<Booking>>)>(
            reloadKey: '${_q.text}|$sort',
            load: () async {
              // उसना माल per party, shown under the name
              final goods = <String, List<GoodsOwed>>{};
              for (final g in await app.stock.goodsOwed()) {
                (goods[g.partyId] ??= []).add(g);
              }
              // open बुकिंग per party
              final booked = <String, List<Booking>>{};
              for (final b in await app.bookings.list()) {
                if (b.open) (booked[b.partyId] ??= []).add(b);
              }
              final list = _q.text.trim().isEmpty
                  ? await app.ledgers.parties(widget.group)
                  : await app.ledgers.search(_q.text, groups: const [LedgerGroup.customer, LedgerGroup.supplier], limit: 500);
              switch (sort) {
                case _Sort.name:
                  break;
                case _Sort.page:
                  list.sort((a, b) => (int.tryParse(a.pageNo ?? '') ?? 99999).compareTo(int.tryParse(b.pageNo ?? '') ?? 99999));
                case _Sort.due:
                  list.sort((a, b) => isCust ? b.balance.compareTo(a.balance) : a.balance.compareTo(b.balance));
              }
              return (list, goods, booked);
            },
            builder: (context, data) {
              final (list, goods, booked) = data;
              final total = list.fold<int>(0, (s, l) => s + l.balance);
              return Column(children: [
                Container(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Row(children: [
                    Text('${list.length} ${isCust ? t('customers') : t('suppliers')}'),
                    const Spacer(),
                    Text('${t('total')}: '),
                    BalanceText(total, supplier: !isCust, size: 15),
                  ]),
                ),
                Expanded(
                  child: list.isEmpty
                      ? Center(child: Text(t('no_entries')))
                      : ListView.separated(
                          padding: const EdgeInsets.only(bottom: 90),
                          itemCount: list.length,
                          separatorBuilder: (_, __) => const Divider(height: 1),
                          itemBuilder: (_, i) {
                            final l = list[i];
                            return ListTile(
                              leading: CircleAvatar(child: Text(l.pageNo ?? l.name.characters.first, style: const TextStyle(fontSize: 13))),
                              title: Text(l.name, style: const TextStyle(fontSize: 17)),
                              subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                Text([
                                  if (l.dual || l.group != widget.group) t('dual_party'),
                                  if (l.nameEn != null) l.nameEn!,
                                  if (l.phone != null) l.phone!,
                                ].join(' · ')),
                                if (goods[l.id] case final g?)
                                  Text(
                                    g
                                        .map((x) => '${t(x.qty > 0 ? 'goods_they_owe' : 'goods_we_owe')}: '
                                            '${x.item.display(app.english)} ${fmtQty(x.qty.abs())} ${t('unit_${x.item.unit}')}')
                                        .join(' · '),
                                    style: const TextStyle(color: AppColors.haldi, fontWeight: FontWeight.w600, fontSize: 13),
                                  ),
                                if (booked[l.id] case final bs?)
                                  Text(
                                    '${t('booking')}: ${bookingSummary(bs, app)}',
                                    style: const TextStyle(color: AppColors.ink, fontWeight: FontWeight.w600, fontSize: 13),
                                  ),
                              ]),
                              trailing: BalanceText(l.balance, supplier: !isCust),
                              onTap: () => KhataScreen.open(context, l.id),
                            );
                          },
                        ),
                ),
              ]);
            },
          ),
        ),
      ]),
    );
  }
}

/// Add / edit a customer, supplier or any account.
class PartyForm extends StatefulWidget {
  final LedgerGroup group;
  final Ledger? existing;
  const PartyForm({super.key, required this.group, this.existing});

  static Future<void> open(BuildContext context, LedgerGroup group, {Ledger? existing}) =>
      Navigator.push(context, MaterialPageRoute(builder: (_) => PartyForm(group: group, existing: existing)));

  @override
  State<PartyForm> createState() => _PartyFormState();
}

class _PartyFormState extends State<PartyForm> {
  late final name = TextEditingController(text: widget.existing?.name);
  late final nameEn = TextEditingController(text: widget.existing?.nameEn);
  late final phone = TextEditingController(text: widget.existing?.phone);
  late final address = TextEditingController(text: widget.existing?.address);
  late final page = TextEditingController(text: widget.existing?.pageNo);
  late final code = TextEditingController(text: widget.existing?.shortCode);
  late final gstin = TextEditingController(text: widget.existing?.gstin);
  late final opening = TextEditingController(
      text: widget.existing == null || widget.existing!.openingBalance == 0
          ? ''
          : Money.fmt(widget.existing!.openingBalance.abs()).replaceAll(',', ''));
  late final interestRate = TextEditingController(
      text: (widget.existing?.interestRate ?? 0) == 0 ? '' : fmtRate(widget.existing!.interestRate));
  late final limit = TextEditingController(
      text: (widget.existing?.creditLimit ?? 0) == 0 ? '' : Money.fmt(widget.existing!.creditLimit).replaceAll(',', ''));
  late bool openingTheyOwe = widget.existing == null
      ? widget.group != LedgerGroup.supplier
      : widget.existing!.openingBalance >= 0 && !(widget.existing!.openingBalance == 0 && widget.group == LedgerGroup.supplier);
  late LedgerGroup group = widget.existing?.group ?? widget.group;

  bool get isParty => group.isParty;

  /// Groups offered in the dropdown.
  List<LedgerGroup> get _groups {
    if (widget.existing != null) return widget.existing!.allowedGroups;
    return widget.group.isParty || widget.group == LedgerGroup.transporter
        ? const [LedgerGroup.customer, LedgerGroup.supplier, LedgerGroup.transporter]
        : LedgerGroup.values.where((g) => !g.isParty && g != LedgerGroup.transporter && g != LedgerGroup.staff).toList();
  }

  Future<void> _delete() async {
    final app = App.read(context);
    final t = app.t;
    final l = widget.existing!;
    final used = await app.ledgers.usageCount(l.id);
    if (!mounted) return;
    final msg = used == 0 && !l.system
        ? t('confirm_delete_ledger').replaceAll('{name}', l.name)
        : t('confirm_hide_ledger').replaceAll('{name}', l.name).replaceAll('{n}', '$used');
    if (!await confirm(context, msg)) return;
    try {
      final deleted = await app.ledgers.deleteOrHide(l);
      if (!mounted) return;
      toast(context, deleted ? t('deleted') : t('ledger_hidden'));
      Navigator.of(context).popUntil((r) => r.isFirst);
    } catch (e) {
      if (mounted) toast(context, errText(context, e), error: true);
    }
  }

  Future<void> _save() async {
    final app = App.read(context);
    if (name.text.trim().isEmpty) return toast(context, app.t('err_required'), error: true);
    final ob = (Money.parse(opening.text) ?? 0) * (openingTheyOwe ? 1 : -1);
    String id;
    if (widget.existing == null) {
      id = await app.ledgers.create(
        name: name.text,
        nameEn: nameEn.text,
        group: group,
        phone: phone.text,
        address: address.text,
        pageNo: page.text,
        shortCode: code.text,
        gstin: gstin.text,
        openingBalance: ob,
        creditLimit: Money.parse(limit.text) ?? 0,
      );
    } else {
      id = widget.existing!.id;
      await app.ledgers.update(widget.existing!.id,
          name: name.text,
          nameEn: nameEn.text,
          phone: phone.text,
          address: address.text,
          pageNo: page.text,
          shortCode: code.text,
          gstin: gstin.text,
          openingBalance: ob,
          creditLimit: Money.parse(limit.text) ?? 0,
          group: group == widget.existing!.group ? null : group);
    }
    // व्याज दर – owner only
    if (app.actor.isOwner && group.isParty) {
      final r = parseRate(interestRate.text);
      if (r != (widget.existing?.interestRate ?? 0)) await app.ledgers.setInterestRate(id, r);
    }
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final app = App.of(context);
    final t = app.t;
    final canEditOpening = app.actor.isOwner;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.existing?.name ??
            (group == LedgerGroup.customer ? t('new_customer') : group == LedgerGroup.supplier ? t('new_supplier') : t('new_ledger'))),
        actions: [
          if (widget.existing != null && app.actor.isOwner && !widget.existing!.isCore)
            IconButton(tooltip: t('delete'), icon: const Icon(Icons.delete_outline), onPressed: _delete),
        ],
      ),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        TextField(controller: name, autofocus: widget.existing == null, decoration: InputDecoration(labelText: t('name'), border: const OutlineInputBorder())),
        const SizedBox(height: 12),
        TextField(controller: nameEn, decoration: InputDecoration(labelText: t('name_en'), border: const OutlineInputBorder())),
        const SizedBox(height: 12),
        if (_groups.length > 1 && (widget.existing == null || app.actor.isOwner)) ...[
          DropdownButtonFormField<LedgerGroup>(
            initialValue: group,
            decoration: InputDecoration(labelText: t('group'), border: const OutlineInputBorder()),
            items: [for (final g in _groups) DropdownMenuItem(value: g, child: Text(t('grp_${g.code}')))],
            onChanged: (g) => setState(() => group = g!),
          ),
          if (widget.existing != null && group != widget.existing!.group)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(t('group_change_note'), style: Theme.of(context).textTheme.bodySmall),
            ),
          const SizedBox(height: 12),
        ],
        if (isParty) ...[
          Row(children: [
            Expanded(
              child: TextField(
                controller: page,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(labelText: t('page_no'), border: const OutlineInputBorder()),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              flex: 2,
              child: TextField(
                controller: phone,
                keyboardType: TextInputType.phone,
                decoration: InputDecoration(labelText: t('phone'), border: const OutlineInputBorder()),
              ),
            ),
          ]),
          const SizedBox(height: 12),
          TextField(controller: address, decoration: InputDecoration(labelText: t('address'), border: const OutlineInputBorder())),
          const SizedBox(height: 12),
          if (App.of(context).actor.isOwner) ...[
            TextField(
              controller: gstin,
              textCapitalization: TextCapitalization.characters,
              decoration: const InputDecoration(labelText: 'GSTIN', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 12),
          ],
        ],
        if (group.isMoney) ...[
          TextField(
            controller: code,
            textCapitalization: TextCapitalization.characters,
            decoration: InputDecoration(labelText: '${t('short_code')} (C / H / D / P / T)', border: const OutlineInputBorder()),
          ),
          const SizedBox(height: 12),
        ],
        SectionTitle(t('opening_balance')),
        if (isParty)
          SegmentedButton<bool>(
            segments: [
              ButtonSegment(value: true, label: Text(t('opening_receivable'))),
              ButtonSegment(value: false, label: Text(t('opening_payable'))),
            ],
            selected: {openingTheyOwe},
            onSelectionChanged: canEditOpening ? (s) => setState(() => openingTheyOwe = s.first) : null,
          ),
        const SizedBox(height: 8),
        TextField(
          controller: opening,
          enabled: canEditOpening,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(labelText: t('amount'), prefixText: '₹ ', border: const OutlineInputBorder()),
        ),
        if (group.isParty && app.actor.isOwner) ...[
          const SizedBox(height: 12),
          TextField(
            key: const Key('party_interest_rate'),
            controller: interestRate,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText: t('interest_rate'),
              suffixText: '% ${t('per_month')}',
              helperText: t('interest_rate_help'),
              border: const OutlineInputBorder(),
            ),
          ),
        ],
        if (group == LedgerGroup.customer) ...[
          const SizedBox(height: 12),
          TextField(
            controller: limit,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(labelText: t('credit_limit'), prefixText: '₹ ', border: const OutlineInputBorder()),
          ),
        ],
        const SizedBox(height: 24),
        FilledButton(
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
          onPressed: _save,
          child: Text(t('save')),
        ),
      ]),
    );
  }
}

/// The digital khata page – looks like the paper page: date, items, amount, जमा, running balance.
class KhataScreen extends StatefulWidget {
  final String ledgerId;
  const KhataScreen({super.key, required this.ledgerId});

  static Future<void> open(BuildContext context, String id) =>
      Navigator.push(context, MaterialPageRoute(builder: (_) => KhataScreen(ledgerId: id)));

  @override
  State<KhataScreen> createState() => _KhataScreenState();
}

class _KhataScreenState extends State<KhataScreen> {
  final _shotKey = GlobalKey();
  String? from;
  String? to;

  Future<void> _shareImage(Statement st) async {
    final app = App.read(context);
    final boundary = _shotKey.currentContext!.findRenderObject() as RenderRepaintBoundary;
    final img = await boundary.toImage(pixelRatio: 2.5);
    final bytes = (await img.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
    final msg = app.t('reminder_msg')
        .replaceAll('{name}', st.ledger.name)
        .replaceAll('{shop}', app.businessName)
        .replaceAll('{amount}', Money.fmt(st.closing, abs: true));
    await Exporter.shareImage(bytes, st.ledger.name, text: msg);
  }

  @override
  Widget build(BuildContext context) {
    final app = App.of(context);
    final t = app.t;
    return LiveBuilder<Statement>(
      reloadKey: '$from|$to',
      load: () => app.ledgers.statement(widget.ledgerId, from: from, to: to),
      builder: (context, st) {
        final l = st.ledger;
        final isCust = l.group == LedgerGroup.customer;
        final isSup = l.group == LedgerGroup.supplier;
        return Scaffold(
          appBar: AppBar(
            title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(l.name),
              Text([if (l.pageNo != null) '${t('page_no')} ${l.pageNo}', if (l.phone != null) l.phone!].join(' · '),
                  style: Theme.of(context).textTheme.bodySmall),
            ]),
            actions: [
              if (l.group.isParty)
                IconButton(
                  tooltip: t('promise_new'),
                  icon: const Icon(Icons.event_available_outlined),
                  onPressed: () => addPromise(context, l),
                ),
              IconButton(
                icon: const Icon(Icons.edit),
                onPressed: () => l.group == LedgerGroup.staff
                    ? StaffForm.open(context, existing: l)
                    : PartyForm.open(context, l.group, existing: l),
              ),
              PopupMenuButton<String>(
                onSelected: (v) async {
                  final rep = app.reports;
                  switch (v) {
                    case 'pdf':
                      await Exporter.sharePdf(await app.pdfTable(() => app.reports.ledgerStatement(l.id, from: from, to: to)), shop: app.pdfShopName);
                    case 'xls':
                      await Exporter.shareExcel([await rep.ledgerStatement(l.id, from: from, to: to)], l.name);
                    case 'print':
                      await Exporter.printPdf(await app.pdfTable(() => app.reports.ledgerStatement(l.id, from: from, to: to)), shop: app.pdfShopName);
                    case 'v_sale':
                      if (context.mounted) await VoucherScreen.open(context, VoucherType.sale, partyId: l.id);
                    case 'v_receipt':
                      if (context.mounted) await VoucherScreen.open(context, VoucherType.receipt, partyId: l.id);
                    case 'v_purchase':
                      if (context.mounted) await VoucherScreen.open(context, VoucherType.purchase, partyId: l.id);
                    case 'v_payment':
                      if (context.mounted) await VoucherScreen.open(context, VoucherType.payment, partyId: l.id);
                    case 'old':
                      if (context.mounted) await VoucherScreen.open(context, VoucherType.history, partyId: l.id);
                    case 'advance_back':
                      if (context.mounted) await VoucherScreen.open(context, VoucherType.receipt, partyId: l.id, narration: t('advance_back'));
                    case 'booking':
                      if (context.mounted) await BookingScreen.open(context, partyId: l.id);
                    case 'interest':
                      if (context.mounted) await InterestScreen.open(context, l.id);
                    case 'goods_out':
                      if (context.mounted) await VoucherScreen.open(context, VoucherType.goodsOut, partyId: l.id);
                    case 'goods_in':
                      if (context.mounted) await VoucherScreen.open(context, VoucherType.goodsIn, partyId: l.id);
                    case 'range':
                      if (!context.mounted) return;
                      final r = await showDateRangePicker(
                        context: context,
                        firstDate: DateTime(2015),
                        lastDate: DateTime.now().add(const Duration(days: 1)),
                      );
                      setState(() {
                        from = r == null ? null : isoDate(r.start);
                        to = r == null ? null : isoDate(r.end);
                      });
                  }
                },
                itemBuilder: (_) => [
                  // the "other side" for someone who is both customer and supplier
                  if (l.group == LedgerGroup.customer) ...[
                    PopupMenuItem(value: 'v_purchase', child: Text(t('purchase'))),
                    PopupMenuItem(value: 'v_payment', child: Text(t('payment'))),
                  ],
                  if (l.group == LedgerGroup.supplier) ...[
                    PopupMenuItem(value: 'v_sale', child: Text(t('sale'))),
                    PopupMenuItem(value: 'v_receipt', child: Text(t('receipt'))),
                  ],
                  if (l.group == LedgerGroup.staff) PopupMenuItem(value: 'advance_back', child: Text(t('advance_back'))),
                  if (l.group.isParty) PopupMenuItem(value: 'booking', child: Text(t('booking_new'))),
                  if (app.actor.isOwner && l.group.isParty)
                    PopupMenuItem(value: 'interest', child: Text(t('interest_add'))),
                  if (l.group.isParty || l.group == LedgerGroup.transporter) ...[
                    PopupMenuItem(value: 'goods_out', child: Text(t('goods_out'))),
                    PopupMenuItem(value: 'goods_in', child: Text(t('goods_in'))),
                  ],
                  if (app.actor.isOwner && l.group.isParty) PopupMenuItem(value: 'old', child: Text(t('old_entry_add'))),
                  PopupMenuItem(value: 'range', child: Text('${t('from')} – ${t('to')}')),
                  PopupMenuItem(value: 'pdf', child: Text('${t('statement')} PDF')),
                  PopupMenuItem(value: 'xls', child: Text('${t('statement')} Excel')),
                  const PopupMenuItem(value: 'print', child: Text('Print')),
                ],
              ),
            ],
          ),
          body: Column(children: [
            Container(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              padding: const EdgeInsets.all(12),
              child: Row(children: [
                if (l.phone != null) ...[
                  IconButton.filledTonal(icon: const Icon(Icons.call), onPressed: () => WhatsApp.call(l.phone!)),
                  const SizedBox(width: 8),
                ],
                if (l.group.isParty)
                  FilledButton.tonalIcon(
                    icon: const Icon(Icons.chat),
                    label: Text(t('remind')),
                    onPressed: () => WhatsApp.send(
                      l.phone,
                      t('reminder_msg')
                          .replaceAll('{name}', l.name)
                          .replaceAll('{shop}', app.businessName)
                          .replaceAll('{amount}', Money.fmt(st.closing, abs: true)),
                    ),
                  ),
                const SizedBox(width: 8),
                IconButton.filledTonal(icon: const Icon(Icons.share), tooltip: t('statement'), onPressed: () => _shareImage(st)),
                const Spacer(),
                BalanceText(st.closing, supplier: isSup, size: 22),
              ]),
            ),
            _OpenPromises(partyId: l.id),
            _GoodsOwedCard(party: l),
            _BookingsBanner(party: l),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.only(bottom: 90),
                child: RepaintBoundary(
                  key: _shotKey,
                  child: Container(
                    color: Theme.of(context).colorScheme.surface,
                    child: _KhataTable(st: st, shop: app.pdfShopName),
                  ),
                ),
              ),
            ),
          ]),
          bottomNavigationBar: SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: l.group == LedgerGroup.staff ? StaffKhataActions(staff: l) : Row(children: [
                Expanded(
                  child: FilledButton(
                    style: FilledButton.styleFrom(backgroundColor: Colors.red.shade700, minimumSize: const Size.fromHeight(52)),
                    onPressed: () => VoucherScreen.open(context, isSup ? VoucherType.purchase : isCust ? VoucherType.sale : VoucherType.payment, partyId: l.id),
                    child: Text(isSup ? t('purchase') : isCust ? t('sale') : t('payment'), style: const TextStyle(fontSize: 17)),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton(
                    style: FilledButton.styleFrom(backgroundColor: Colors.green.shade700, minimumSize: const Size.fromHeight(52)),
                    onPressed: () => VoucherScreen.open(context, isSup ? VoucherType.payment : VoucherType.receipt, partyId: l.id),
                    child: Text(isSup ? t('payment') : t('receipt'), style: const TextStyle(fontSize: 17)),
                  ),
                ),
              ]),
            ),
          ),
        );
      },
    );
  }
}

class _KhataTable extends StatelessWidget {
  final Statement st;
  final String shop;
  const _KhataTable({required this.st, required this.shop});

  @override
  Widget build(BuildContext context) {
    final app = App.of(context);
    final t = app.t;
    final small = Theme.of(context).textTheme.bodySmall;
    const pad = EdgeInsets.symmetric(horizontal: 6, vertical: 8);
    Widget cell(String s, {TextAlign a = TextAlign.left, TextStyle? style, int flex = 2}) =>
        Expanded(flex: flex, child: Padding(padding: pad, child: Text(s, textAlign: a, style: style)));
    Widget dateCell(String s, {TextStyle? style}) => SizedBox(
        width: 64,
        child: Padding(
          padding: pad,
          child: FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: Text(s, style: style)),
        ));
    String bal(int b) => b == 0 ? '0' : '${Money.fmt(b, abs: true)} ${b > 0 ? t('dr_short') : t('cr_short')}';
    final red = TextStyle(color: Colors.red.shade700, fontWeight: FontWeight.w600);
    final green = TextStyle(color: Colors.green.shade700, fontWeight: FontWeight.w600);
    return Column(children: [
      Padding(
        padding: const EdgeInsets.all(8),
        child: Text('$shop · ${st.ledger.name}', style: Theme.of(context).textTheme.titleSmall),
      ),
      Container(
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
        child: Row(children: [
          dateCell(t('date'), style: const TextStyle(fontWeight: FontWeight.bold)),
          cell(t('details'), flex: 4, style: const TextStyle(fontWeight: FontWeight.bold)),
          cell(t('debit_given'), a: TextAlign.right, style: const TextStyle(fontWeight: FontWeight.bold)),
          cell(t('credit_got'), a: TextAlign.right, style: const TextStyle(fontWeight: FontWeight.bold)),
          cell(t('balance'), a: TextAlign.right, flex: 3, style: const TextStyle(fontWeight: FontWeight.bold)),
        ]),
      ),
      // Old entries copied from the paper khata: shown so a customer can see
      // what made up their balance, but never counted (the opening balance
      // below already includes them).
      if (st.references.isNotEmpty) ...[
        Container(
          width: double.infinity,
          color: Theme.of(context).colorScheme.secondaryContainer.withValues(alpha: 0.5),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Text(t('old_entries_ref'), style: small?.copyWith(fontWeight: FontWeight.w600)),
        ),
        for (final r in st.references)
          InkWell(
            onTap: () => VoucherScreen.edit(context, r.voucherId),
            child: Container(
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: Theme.of(context).colorScheme.outlineVariant.withValues(alpha: 0.5))),
              ),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                dateCell(shortDate(r.date), style: small),
                Expanded(
                  flex: 4,
                  child: Padding(
                    padding: pad,
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(t('old_${r.kind ?? 'sale'}'), style: small),
                      if (r.details.isNotEmpty) Text(r.details, style: small),
                      if (r.hamali != 0 || r.transport != 0) Text(chargesText(t, r.hamali, r.transport, null), style: small),
                      if (r.haste != null) Text('${t('haste')}: ${r.haste}', style: small),
                    ]),
                  ),
                ),
                cell(r.debit == 0 ? '' : Money.fmt(r.debit), a: TextAlign.right, style: small),
                cell(r.credit == 0 ? '' : Money.fmt(r.credit), a: TextAlign.right, style: small),
                cell('—', a: TextAlign.right, flex: 3, style: small),
              ]),
            ),
          ),
      ],
      Row(children: [
        dateCell(st.from == null ? shortDate(Books.start) : shortDate(st.from!)),
        cell(t('opening_balance'), flex: 4, style: small),
        cell(''),
        cell(''),
        cell(bal(st.opening), a: TextAlign.right, flex: 3, style: const TextStyle(fontWeight: FontWeight.bold)),
      ]),
      const Divider(height: 1),
      for (final r in st.rows)
        InkWell(
          onTap: () => VoucherScreen.edit(context, r.voucherId),
          child: Container(
            decoration: BoxDecoration(border: Border(bottom: BorderSide(color: Theme.of(context).colorScheme.outlineVariant.withValues(alpha: 0.5)))),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              dateCell(shortDate(r.date)),
              Expanded(
                flex: 4,
                child: Padding(
                  padding: pad,
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('${t('vt_${r.type.code}')}${r.payCode != null && r.credit > 0 ? ' (${r.payCode})' : ''}', style: small),
                    if (r.details.isNotEmpty) Text(r.details),
                    if (r.hamali != 0 || r.transport != 0)
                      Text(chargesText(t, r.hamali, r.transport, r.transporterName), style: small),
                    if (r.haste != null) Text('${t('haste')}: ${r.haste}', style: small),
                  ]),
                ),
              ),
              cell(r.debit == 0 ? '' : Money.fmt(r.debit), a: TextAlign.right, style: red),
              cell(r.credit == 0 ? '' : Money.fmt(r.credit), a: TextAlign.right, style: green),
              cell(bal(r.balance), a: TextAlign.right, flex: 3),
            ]),
          ),
        ),
      Container(
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
        child: Row(children: [
          dateCell(''),
          cell(t('total'), flex: 4, style: const TextStyle(fontWeight: FontWeight.bold)),
          cell(Money.fmt(st.totalDebit), a: TextAlign.right, style: red),
          cell(Money.fmt(st.totalCredit), a: TextAlign.right, style: green),
          cell(bal(st.closing), a: TextAlign.right, flex: 3, style: const TextStyle(fontWeight: FontWeight.bold)),
        ]),
      ),
    ]);
  }
}

/// "हमाली 300 · गाडी भाडे 500 (आपली गाडी)"
String chargesText(String Function(String) t, int hamali, int transport, String? transporter) => [
      if (hamali != 0) '${t('hamali')} ${Money.fmt(hamali)}',
      if (transport != 0) '${t('transport')} ${Money.fmt(transport)} (${transporter ?? t('own_vehicle')})',
    ].join(' · ');

/// Banner on the khata: the promise(s) this customer has given.
class _OpenPromises extends StatelessWidget {
  final String partyId;
  const _OpenPromises({required this.partyId});
  @override
  Widget build(BuildContext context) {
    final app = App.of(context);
    final t = app.t;
    return LiveBuilder<List<(Voucher, Ledger)>>(
      reloadKey: partyId,
      load: () => app.ledgers.promises(partyId: partyId),
      builder: (context, list) => list.isEmpty
          ? const SizedBox.shrink()
          : Material(
              color: Theme.of(context).colorScheme.tertiaryContainer.withValues(alpha: 0.6),
              child: InkWell(
                onTap: () => PromisesScreen.open(context),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: Row(children: [
                    const Icon(Icons.event_available, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        list
                            .map((p) => '${t('promise_short')}: ${shortDate(p.$1.date)}'
                                '${p.$1.amount > 0 ? ' · ₹${Money.fmt(p.$1.amount)}' : ''}'
                                '${p.$1.date.compareTo(todayIso()) < 0 ? ' (${t('promise_overdue')})' : ''}')
                            .join('\n'),
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                    const Icon(Icons.chevron_right, size: 18),
                  ]),
                ),
              ),
            ),
    );
  }
}

/// उसना माल: bags lent to (or borrowed from) this party, counted in bags,
/// apart from the money balance. Tap for the full list of entries.
class _GoodsOwedCard extends StatelessWidget {
  final Ledger party;
  const _GoodsOwedCard({required this.party});

  @override
  Widget build(BuildContext context) {
    final app = App.of(context);
    final t = app.t;
    return LiveBuilder<List<GoodsOwed>>(
      reloadKey: party.id,
      load: () => app.stock.goodsOwed(partyId: party.id),
      builder: (context, list) {
        if (list.isEmpty) return const SizedBox.shrink();
        final they = list.where((g) => g.qty > 0).toList();
        final we = list.where((g) => g.qty < 0).toList();
        String fmt(List<GoodsOwed> l) =>
            l.map((g) => '${g.item.display(app.english)} ${fmtQty(g.qty.abs())} ${t('unit_${g.item.unit}')}').join(', ');
        return Material(
          color: AppColors.haldi.withValues(alpha: 0.12),
          child: InkWell(
            onTap: () => _history(context),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 4, 4),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  const Icon(Icons.inventory_2_outlined, size: 18, color: AppColors.haldi),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      if (they.isNotEmpty)
                        Text('${t('goods_they_owe')}: ${fmt(they)}', style: const TextStyle(fontWeight: FontWeight.w700)),
                      if (we.isNotEmpty)
                        Text('${t('goods_we_owe')}: ${fmt(we)}', style: const TextStyle(fontWeight: FontWeight.w700)),
                    ]),
                  ),
                  const Icon(Icons.chevron_right, size: 18),
                ]),
                Wrap(spacing: 4, children: [
                  TextButton.icon(
                    icon: const Icon(Icons.south_west, size: 16),
                    label: Text(t('goods_in_short')),
                    onPressed: () => VoucherScreen.open(context, VoucherType.goodsIn, partyId: party.id),
                  ),
                  TextButton.icon(
                    icon: const Icon(Icons.north_east, size: 16),
                    label: Text(t('goods_out_short')),
                    onPressed: () => VoucherScreen.open(context, VoucherType.goodsOut, partyId: party.id),
                  ),
                ]),
              ]),
            ),
          ),
        );
      },
    );
  }

  Future<void> _history(BuildContext context) async {
    final app = App.read(context);
    final t = app.t;
    final moves = await app.stock.goodsMoves(party.id);
    if (!context.mounted) return;
    await showModalBottomSheet(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.7),
          child: ListView(shrinkWrap: true, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text('${t('r_goods_owed')} · ${party.name}', style: Theme.of(ctx).textTheme.titleMedium),
            ),
            for (final (id, date, type, what, opening) in moves)
              ListTile(
                leading: Icon(type == VoucherType.goodsOut ? Icons.north_east : Icons.south_west,
                    color: type == VoucherType.goodsOut ? AppColors.due : AppColors.paid),
                title: Text(what),
                subtitle: Text('${opening ? t('goods_opening_short') : shortDate(date)} · ${t('vt_${type.code}')}'),
                onTap: () {
                  Navigator.pop(ctx);
                  VoucherScreen.edit(context, id);
                },
              ),
          ]),
        ),
      ),
    );
  }
}

/// "अल्ट्राटेक 175 बॅग बाकी @ ₹275" for every open booking line.
String bookingSummary(List<Booking> bs, AppController app) => [
      for (final b in bs)
        for (final l in b.lines)
          if (l.remaining > 0)
            '${l.item.display(app.english)} ${fmtQty(l.remaining)} ${app.t('unit_${l.item.unit}')} @ ₹${Money.fmt(l.rate)}',
    ].join(' · ');

/// Open bookings on the khata page – tap for the bookings report.
class _BookingsBanner extends StatelessWidget {
  final Ledger party;
  const _BookingsBanner({required this.party});
  @override
  Widget build(BuildContext context) {
    final app = App.of(context);
    final t = app.t;
    return LiveBuilder<List<Booking>>(
      reloadKey: party.id,
      load: () async => (await app.bookings.list(partyId: party.id)).where((b) => b.open).toList(),
      builder: (context, list) => list.isEmpty
          ? const SizedBox.shrink()
          : Material(
              color: AppColors.ink.withValues(alpha: 0.08),
              child: InkWell(
                onTap: () => BookingsScreen.open(context),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: Row(children: [
                    const Icon(Icons.bookmark_added_outlined, size: 18, color: AppColors.ink),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text('${t('booking')} ${t('booking_left')}: ${bookingSummary(list, app)}',
                          style: const TextStyle(fontWeight: FontWeight.w700)),
                    ),
                    const Icon(Icons.chevron_right, size: 18),
                  ]),
                ),
              ),
            ),
    );
  }
}
