import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:speech_to_text/speech_to_text.dart';

import '../accounting/models.dart';
import '../accounting/voucher_service.dart';
import '../core/money.dart';
import '../core/theme.dart';
import '../shared/export.dart';
import '../shared/shortcode_parser.dart';
import '../shared/widgets.dart';
import '../state/app_controller.dart';
import 'audit_screen.dart';
import 'books_screens.dart';
import 'parties_screen.dart';

/// One screen for every kind of entry. Shows only the fields the type needs.
class VoucherScreen extends StatefulWidget {
  final VoucherType type;
  final String? partyId;
  final String? editId;
  final bool expenseMode; // payment screen opened as "खर्च"
  final int? presetAmount; // e.g. day-end payment to a transporter
  final String? presetNarration;
  final String? historyKind; // old entry: sale | purchase | received | paid
  const VoucherScreen({
    super.key,
    required this.type,
    this.partyId,
    this.editId,
    this.expenseMode = false,
    this.presetAmount,
    this.presetNarration,
    this.historyKind,
  });

  static Future<void> open(
    BuildContext context,
    VoucherType type, {
    String? partyId,
    bool expense = false,
    int? amount,
    String? narration,
  }) => Navigator.push(
    context,
    MaterialPageRoute(
      builder: (_) =>
          VoucherScreen(type: type, partyId: partyId, expenseMode: expense, presetAmount: amount, presetNarration: narration),
    ),
  );

  static Future<void> edit(BuildContext context, String voucherId) async {
    final app = App.read(context);
    final (v, _) = await app.vouchers.load(voucherId);
    if (!context.mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => VoucherScreen(type: v.type, editId: voucherId),
      ),
    );
  }

  @override
  State<VoucherScreen> createState() => _VoucherScreenState();
}

/// One item row: qty × rate = amount. Type any two – typing the amount works
/// out the rate (7 bags for ₹2,000 → ₹285.71), and the total stays exact.
class _LineCtl {
  Item item;
  final TextEditingController qty;
  final TextEditingController rate;
  final TextEditingController amt;
  bool amountTyped; // the user typed the total; rate follows from it
  _LineCtl(this.item, double q, int ratePaise, {int? amount})
    : qty = TextEditingController(text: fmtQty(q)),
      rate = TextEditingController(text: ratePaise == 0 ? '' : _plainMoney(ratePaise)),
      amt = TextEditingController(),
      amountTyped = amount != null && amount != (q * ratePaise).round() {
    _showAmount(amount ?? (q * ratePaise).round());
  }
  double get q => double.tryParse(normalizeDigits(qty.text)) ?? 0;
  int get r => Money.parse(rate.text) ?? 0;
  int get amount => amountTyped ? (Money.parse(amt.text) ?? 0) : (q * r).round();

  static String _plainMoney(int p) => Money.fmt(p).replaceAll(',', '');
  void _showAmount(int a) => amt.text = a == 0 ? '' : _plainMoney(a);

  /// qty or rate changed → amount follows (unless the total was typed:
  /// then a new qty recalculates the rate and keeps the total).
  void qtyChanged() {
    if (amountTyped) {
      final a = Money.parse(amt.text) ?? 0;
      rate.text = q == 0 ? '' : _plainMoney((a / q).round());
    } else {
      _showAmount((q * r).round());
    }
  }

  void rateChanged() {
    amountTyped = false;
    _showAmount((q * r).round());
  }

  void amountChanged() {
    amountTyped = amt.text.trim().isNotEmpty;
    final a = Money.parse(amt.text) ?? 0;
    if (amountTyped && q != 0) rate.text = _plainMoney((a / q).round());
  }

  ItemLine toLine() => amountTyped ? ItemLine.fromTotal(item.id, q, amount) : ItemLine(item.id, q, r);
}

class _VoucherScreenState extends State<VoucherScreen> {
  late VoucherType type = widget.type;
  String date = todayIso();
  Ledger? party;
  String? payId; // null = udhar
  List<Ledger> moneyAccounts = [];
  List<Item> items = [];
  final lines = <_LineCtl>[];
  final quick = TextEditingController();
  final quickFocus = FocusNode();
  final amount = TextEditingController();
  final paid = TextEditingController();
  final discount = TextEditingController();
  final narration = TextEditingController();
  final ref = TextEditingController();
  bool gstBill = false;
  // bill charges (sale only)
  final hamaliCtl = TextEditingController();
  final varhaiCtl = TextEditingController(); // वराई with a purchase
  final transportCtl = TextEditingController();
  final fareCtl = TextEditingController();
  String? transporterId; // null = own vehicle
  bool fareTouched = false;
  List<Ledger> transporters = [];
  int gstRate = 0; // percent × 100; owner-only genuine GST bill
  final roundCtl = TextEditingController(); // signed rupees, e.g. -7 or 3
  final hasteCtl = TextEditingController(); // हस्ते – who brought / took it
  List<String> hasteSuggestions = [];
  bool paidTouched = false;
  bool loading = true;
  bool saving = false;
  Voucher? editing;
  final _speech = SpeechToText();
  bool _listening = false;

  // Old entry (before the books start): a full bill or a money entry that
  // only changes the party's khata – no stock, cash, hamali or profit.
  bool get isHistory => type == VoucherType.history;
  late String hKind = widget.historyKind ?? 'sale'; // sale | purchase | received | paid
  bool get historyBill => isHistory && (hKind == 'sale' || hKind == 'purchase');

  bool get hasItems =>
      historyBill ||
      const {
        VoucherType.sale,
        VoucherType.purchase,
        VoucherType.salesReturn,
        VoucherType.purchaseReturn,
        VoucherType.stockAdjust,
      }.contains(type);
  bool get hasPay => type != VoucherType.stockAdjust && type != VoucherType.journal && !isHistory;
  bool get creditAllowed =>
      const {VoucherType.sale, VoucherType.purchase, VoucherType.salesReturn, VoucherType.purchaseReturn}.contains(type);
  bool get stockOnly => type == VoucherType.stockAdjust;

  int get itemsTotal => lines.fold(0, (s, l) => s + l.amount);
  bool get isSale => type == VoucherType.sale;
  bool get chargesOn => isSale || historyBill;
  int get hamali => chargesOn ? (Money.parse(hamaliCtl.text) ?? 0) : 0;
  int get transport => chargesOn ? (Money.parse(transportCtl.text) ?? 0) : 0;
  int get fare => Money.parse(fareCtl.text) ?? transport;
  bool get gstAllowed => type == VoucherType.sale || type == VoucherType.purchase;
  int get gst => gstAllowed && gstRate > 0 ? ((itemsTotal * gstRate / 10000) / 100).round() * 100 : 0;
  bool get roundAllowed => type == VoucherType.sale || type == VoucherType.purchase || historyBill;
  int get roundOff => roundAllowed ? (Money.parse(roundCtl.text) ?? 0) : 0;
  int get totalBeforeRound =>
      (hasItems && !(historyBill && lines.isEmpty) ? itemsTotal : (Money.parse(amount.text) ?? 0)) + hamali + transport + gst;
  int get total => totalBeforeRound + roundOff;

  List<LedgerGroup> get partyGroups => switch (type) {
    // one person can be both customer and supplier
    VoucherType.sale || VoucherType.salesReturn => [LedgerGroup.customer, LedgerGroup.supplier],
    VoucherType.purchase || VoucherType.purchaseReturn => [LedgerGroup.supplier, LedgerGroup.customer],
    VoucherType.receipt => [
      LedgerGroup.customer,
      LedgerGroup.supplier,
      LedgerGroup.income,
      LedgerGroup.capital,
      LedgerGroup.loan,
      LedgerGroup.gst,
      LedgerGroup.otherLiability,
      LedgerGroup.otherAsset,
    ],
    VoucherType.payment =>
      widget.expenseMode
          ? [LedgerGroup.expense, LedgerGroup.directExpense]
          : [
              LedgerGroup.supplier,
              LedgerGroup.transporter,
              LedgerGroup.customer,
              LedgerGroup.expense,
              LedgerGroup.directExpense,
              LedgerGroup.capital,
              LedgerGroup.loan,
              LedgerGroup.gst,
              LedgerGroup.otherAsset,
              LedgerGroup.otherLiability,
            ],
    VoucherType.contra => [LedgerGroup.cash, LedgerGroup.upi, LedgerGroup.bank],
    VoucherType.history => [LedgerGroup.customer, LedgerGroup.supplier, LedgerGroup.transporter],
    _ => [],
  };

  LedgerGroup? get createAs => switch (type) {
    VoucherType.sale || VoucherType.salesReturn || VoucherType.receipt => LedgerGroup.customer,
    VoucherType.purchase || VoucherType.purchaseReturn => LedgerGroup.supplier,
    VoucherType.payment => widget.expenseMode ? LedgerGroup.expense : LedgerGroup.supplier,
    VoucherType.history => hKind == 'purchase' ? LedgerGroup.supplier : LedgerGroup.customer,
    _ => null,
  };

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final app = App.read(context);
    moneyAccounts = await app.ledgers.list([LedgerGroup.cash, LedgerGroup.upi, LedgerGroup.bank]);
    items = await app.stock.list();
    transporters = await app.ledgers.list([LedgerGroup.transporter]);
    if (widget.editId != null) {
      final (v, ls) = await app.vouchers.load(widget.editId!);
      editing = v;
      type = v.type;
      date = v.date;
      if (v.partyId != null) party = await app.ledgers.byId(v.partyId!);
      payId = v.payLedgerId;
      if (v.type == VoucherType.history) {
        final k = v.payLedgerId ?? '';
        hKind = k.startsWith(historyKindPrefix)
            ? k.substring(historyKindPrefix.length)
            : (ls.isEmpty && v.amount == 0 && v.paid > 0 ? 'received' : 'sale'); // entries made before bills existed
        payId = null;
      }
      for (final l in ls) {
        final it = items.firstWhere(
          (i) => i.id == l.itemId,
          orElse: () => Item(id: l.itemId, name: '?'),
        );
        lines.add(_LineCtl(it, l.qty, l.rate, amount: l.amount));
      }
      if (!hasItems || (historyBill && ls.isEmpty)) {
        final a = v.type == VoucherType.history && hKind == 'received' && v.amount == 0 ? v.paid : v.amount;
        amount.text = a == 0 ? '' : Money.fmt(a).replaceAll(',', '');
      }
      paid.text = v.paid == 0 ? '' : Money.fmt(v.paid).replaceAll(',', '');
      paidTouched = true;
      narration.text = v.narration ?? '';
      hasteCtl.text = v.haste ?? '';
      ref.text = v.refNo ?? '';
      gstBill = v.gstBillNeeded;
      if (v.hamali != 0) hamaliCtl.text = _plain(v.hamali);
      if (v.transport != 0) transportCtl.text = _plain(v.transport);
      transporterId = v.transporterId;
      gstRate = v.gstRate;
      final ro = await app.vouchers.roundOffOf(v);
      if (ro != 0) roundCtl.text = Money.fmt(ro).replaceAll(',', '');
      final vr = await app.vouchers.varhaiOf(v);
      if (vr != 0) varhaiCtl.text = _plain(vr);
      if (v.transporterFare != null && v.transporterFare != v.transport) {
        fareCtl.text = _plain(v.transporterFare!);
        fareTouched = true;
      }
      if (party == null && creditAllowed) payId = v.payLedgerId ?? app.vouchers.sys('cash');
    } else {
      if (widget.partyId != null) party = await app.ledgers.byId(widget.partyId!);
      if (widget.presetAmount != null && widget.presetAmount! > 0) amount.text = _plain(widget.presetAmount!);
      if (widget.presetNarration != null) narration.text = widget.presetNarration!;
      // sensible default payment account
      if (creditAllowed) {
        // purchases are usually on credit; a sale without a name is a cash sale
        payId = party == null && !_isBuying ? app.vouchers.sys('cash') : null;
      } else if (type == VoucherType.contra) {
        payId = app.vouchers.sys('cash');
      } else {
        payId = app.vouchers.sys('cash');
      }
    }
    setState(() => loading = false);
    _loadHaste();
  }

  String _title(AppController app) {
    if (isHistory) return '${app.t('old_entry')}${editing != null ? ' · ${app.t('edit')}' : ''}';
    if (editing != null) return '${app.t('edit')} · ${app.t('vt_${type.code}')} #${editing!.vno}';
    if (widget.expenseMode) return app.t('expense');
    return app.t(type.code);
  }

  void _addParsed(String text) {
    final parser = ShortcodeParser(items);
    final defaultItem = lines.isNotEmpty ? lines.last.item : null;
    final parsed = parser.parseAll(text, defaultItem: defaultItem);
    if (parsed.isEmpty || parsed.any((p) => p.item == null)) {
      toast(context, '${App.read(context).t('err_quick')}: "$text"', error: true);
      return;
    }
    setState(() {
      for (final p in parsed) {
        final buying = type == VoucherType.purchase || (isHistory && hKind == 'purchase');
        final rate = p.ratePaise ?? (buying ? p.item!.purchaseRate : p.item!.saleRate);
        lines.add(_LineCtl(p.item!, p.qty, rate, amount: p.total));
      }
      quick.clear();
      _syncPaid();
    });
    quickFocus.requestFocus();
  }

  void _addItem(Item it) {
    setState(() {
      lines.add(
        _LineCtl(it, 1, type == VoucherType.purchase || type == VoucherType.purchaseReturn ? it.purchaseRate : it.saleRate),
      );
      _syncPaid();
    });
  }

  void _syncPaid() {
    if (!paidTouched && payId != null && creditAllowed) {
      paid.text = total == 0 ? '' : Money.fmt(total).replaceAll(',', '');
    }
  }

  Future<void> _voice() async {
    final app = App.read(context);
    if (_listening) {
      await _speech.stop();
      setState(() => _listening = false);
      return;
    }
    final ok = await _speech.initialize();
    if (!ok) {
      if (mounted) toast(context, App.read(context).t('err_mic'), error: true);
      return;
    }
    setState(() => _listening = true);
    await _speech.listen(
      localeId: app.english ? 'en_IN' : 'mr_IN',
      onResult: (r) {
        quick.text = r.recognizedWords
            .replaceAll(RegExp(r'\s+(into|इंटू|गुणिले|x)\s+', caseSensitive: false), '×')
            .replaceAll(RegExp(r'\s+(rupaye|rupees|रुपये)', caseSensitive: false), '');
        if (r.finalResult) {
          setState(() => _listening = false);
          if (quick.text.trim().isNotEmpty) _addParsed(quick.text);
        }
      },
    );
  }

  Future<void> _save({bool andNew = false}) async {
    final app = App.read(context);
    final t = app.t;
    // an old bill may be typed as just an amount when the items aren't known
    final amountOnly = historyBill && lines.isEmpty;
    if (hasItems && lines.isEmpty && !amountOnly) return toast(context, t('err_items'), error: true);
    if (amountOnly && (Money.parse(amount.text) ?? 0) <= 0) return toast(context, t('err_amount'), error: true);
    if (!hasItems && total <= 0) return toast(context, t('err_amount'), error: true);
    final needsParty = const {VoucherType.receipt, VoucherType.payment, VoucherType.contra, VoucherType.history}.contains(type);
    if (needsParty && party == null) return toast(context, t('err_party'), error: true);
    if (creditAllowed && party == null && payId == null) {
      return toast(context, t('err_party'), error: true);
    }
    final input = VoucherInput(
      type: type,
      date: date,
      partyId: party?.id,
      payLedgerId: isHistory ? '$historyKindPrefix$hKind' : payId,
      items: [
        for (final l in lines)
          if (l.q != 0) l.toLine(),
      ],
      amount: hasItems && lines.isNotEmpty ? 0 : (Money.parse(amount.text) ?? 0),
      paid: historyBill
          ? (Money.parse(paid.text) ?? 0)
          : creditAllowed && payId != null
          ? (Money.parse(paid.text) ?? total)
          : 0,
      discount: Money.parse(discount.text) ?? 0,
      narration: narration.text.trim().isEmpty ? null : narration.text.trim(),
      refNo: ref.text.trim().isEmpty ? null : ref.text.trim(),
      gstBillNeeded: gstBill,
      hamali: hamali,
      transport: transport,
      transporterId: isSale && transport != 0 ? transporterId : null,
      transporterFare: isSale && transporterId != null && transport != 0 ? fare : null,
      gstRate: gstAllowed ? gstRate : 0,
      roundOff: roundOff,
      haste: hasteCtl.text,
      varhai: type == VoucherType.purchase ? (Money.parse(varhaiCtl.text) ?? 0) : 0,
    );
    // credit limit warning
    if (party != null && party!.creditLimit > 0 && type == VoucherType.sale) {
      final newBal = party!.balance + total - input.paid;
      if (newBal > party!.creditLimit && !await confirm(context, '${t('over_limit')}\n₹${Money.fmt(newBal)}')) return;
      if (!mounted) return;
    }
    setState(() => saving = true);
    try {
      await app.vouchers.save(input, app.actor, existingId: editing?.id);
      if (!mounted) return;
      var msg = t('saved');
      if (party != null && party!.group.isParty) {
        final bal = await app.ledgers.balanceAt(party!.id);
        msg += ' · ${party!.name}: ${t('new_balance')} ₹${Money.fmt(bal, abs: true)} ${bal >= 0 ? t('they_owe') : t('we_owe')}';
      }
      if (!mounted) return;
      toast(context, msg);
      if (andNew) {
        setState(() {
          lines.clear();
          amount.clear();
          paid.clear();
          discount.clear();
          narration.clear();
          ref.clear();
          paidTouched = false;
          gstBill = false;
          hamaliCtl.clear();
          transportCtl.clear();
          fareCtl.clear();
          fareTouched = false;
          transporterId = null;
          gstRate = 0;
          roundCtl.clear();
          hasteCtl.clear();
          hasteSuggestions = [];
          party = null;
          payId = creditAllowed ? (_isBuying ? null : app.vouchers.sys('cash')) : payId;
          saving = false;
        });
      } else {
        Navigator.pop(context);
      }
    } on PermissionDenied catch (e) {
      toast(context, errText(context, e), error: true);
      setState(() => saving = false);
    } catch (e) {
      toast(context, errText(context, e), error: true);
      setState(() => saving = false);
    }
  }

  Future<void> _delete() async {
    final app = App.read(context);
    if (!await confirm(context, app.t('confirm_delete'))) return;
    try {
      await app.vouchers.delete(editing!.id, app.actor);
      if (mounted) {
        toast(context, app.t('deleted'));
        Navigator.pop(context);
      }
    } on PermissionDenied catch (e) {
      if (mounted) toast(context, errText(context, e), error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = App.of(context);
    final t = app.t;
    if (loading) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    final canEdit = editing == null || VoucherService.canEdit(app.actor, editing!.date);
    return Scaffold(
      appBar: AppBar(
        title: Text(_title(app)),
        actions: [
          if (editing != null)
            IconButton(
              icon: const Icon(Icons.history),
              tooltip: t('history'),
              onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => AuditScreen(voucherId: editing!.id))),
            ),
          if (editing != null && (type == VoucherType.sale || type == VoucherType.purchase))
            IconButton(
              icon: const Icon(Icons.receipt_long),
              tooltip: t('bill_pdf'),
              onPressed: () async {
                final (v, ls) = await app.vouchers.load(editing!.id);
                if (!context.mounted) return;
                await Exporter.shareBill(app, v, ls, items, party, transporters);
              },
            ),
          if (editing != null && app.actor.isOwner) IconButton(icon: const Icon(Icons.delete_outline), onPressed: _delete),
        ],
      ),
      body: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.keyS, control: true): () => _save(),
          const SingleActivator(LogicalKeyboardKey.enter, control: true): () => _save(andNew: true),
        },
        child: ListView(
          padding: const EdgeInsets.all(12),
          children: [
            if (isHistory) _historyHeader(app),
            Row(
              children: [
                SizedBox(
                  width: 210,
                  child: DateField(
                    date: date,
                    enabled: app.actor.isOwner,
                    autofocus: isHistory && editing == null,
                    // old entries: any date before the books start; others: from the books start
                    first: isHistory ? null : Books.start,
                    last: isHistory ? isoDate(parseIso(Books.start).subtract(const Duration(days: 1))) : null,
                    onChanged: (d) => setState(() => date = d),
                  ),
                ),
                const Spacer(),
                if (editing?.createdBy != null)
                  Flexible(
                    child: Text('${t('created_by')}: ${editing!.createdBy}', style: Theme.of(context).textTheme.bodySmall),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            if (partyGroups.isNotEmpty) _partyCard(app),
            if (hasItems) ...[
              const SizedBox(height: 12),
              _quickEntry(app),
              const SizedBox(height: 8),
              _itemChips(app),
              const SizedBox(height: 8),
              ..._lineRows(app),
              if (historyBill && lines.isEmpty) ...[
                const SizedBox(height: 4),
                AmountField(controller: amount, label: t('amount_no_items'), onChanged: (_) => setState(() {})),
              ],
              if (chargesOn) _chargesCard(app),
              if (type == VoucherType.purchase) _varhaiCard(app),
              if (gstAllowed && app.actor.isOwner) _gstCard(app),
              if (roundAllowed) _roundCard(app),
              if (!stockOnly)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Row(
                    children: [
                      Text(
                        chargesOn && hamali + transport != 0 ? t('bill_total') : t('total'),
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const Spacer(),
                      Text(
                        '₹${Money.fmt(total)}',
                        style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                ),
            ] else if (!stockOnly) ...[
              const SizedBox(height: 12),
              AmountField(
                controller: amount,
                label: t('amount'),
                autofocus: editing == null && party != null,
                onChanged: (_) => setState(() {}),
              ),
            ],
            if (hasPay) ...[
              SectionTitle(type == VoucherType.contra ? t('from_account') : t('pay_mode')),
              PayModeChips(
                accounts: moneyAccounts.where((a) => type != VoucherType.contra || a.id != party?.id).toList(),
                selected: payId,
                allowCredit: creditAllowed,
                creditLabel: _isBuying ? t('udhar_buy') : t('udhar'),
                onSelected: (id) async {
                  if (id == null && party == null) {
                    // credit needs a name: ask for the supplier / customer first
                    final l = await pickLedger(context, groups: partyGroups, createAs: createAs);
                    if (l == null) return;
                    party = l;
                  }
                  setState(() {
                    payId = id;
                    paidTouched = false;
                    if (id == null) paid.clear();
                    _syncPaid();
                  });
                },
              ),
              if (creditAllowed && payId != null && party != null) ...[
                const SizedBox(height: 12),
                AmountField(controller: paid, label: t('paid_now'), onChanged: (_) => setState(() => paidTouched = true)),
                if ((Money.parse(paid.text) ?? 0) < total)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      '${t('due')}: ₹${Money.fmt(total - (Money.parse(paid.text) ?? 0))}',
                      style: TextStyle(color: Colors.red.shade700, fontWeight: FontWeight.bold),
                    ),
                  ),
              ],
            ],
            if (historyBill) ...[
              const SizedBox(height: 12),
              AmountField(
                controller: paid,
                label: hKind == 'purchase' ? t('old_paid_then') : t('old_received_then'),
                onChanged: (_) => setState(() {}),
              ),
            ],
            if (type == VoucherType.receipt || (type == VoucherType.payment && !widget.expenseMode)) ...[
              const SizedBox(height: 12),
              TextField(
                controller: discount,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: t('discount'),
                  prefixText: '₹ ',
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ],
            const SizedBox(height: 12),
            TextField(
              controller: narration,
              decoration: InputDecoration(labelText: t('narration'), border: const OutlineInputBorder(), isDense: true),
            ),
            const SizedBox(height: 8),
            TextField(
              key: const Key('haste'),
              controller: hasteCtl,
              textCapitalization: TextCapitalization.words,
              decoration: InputDecoration(
                labelText: t('haste_label'),
                hintText: t('haste_hint'),
                prefixIcon: const Icon(Icons.badge_outlined, size: 20),
                border: const OutlineInputBorder(),
                isDense: true,
              ),
            ),
            if (hasteSuggestions.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Wrap(spacing: 6, children: [
                  for (final h in hasteSuggestions)
                    ActionChip(label: Text(h), onPressed: () => setState(() => hasteCtl.text = h)),
                ]),
              ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: ref,
                    decoration: InputDecoration(labelText: t('ref'), border: const OutlineInputBorder(), isDense: true),
                  ),
                ),
                const SizedBox(width: 8),
                FilterChip(label: Text(t('gst_bill_needed')), selected: gstBill, onSelected: (v) => setState(() => gstBill = v)),
              ],
            ),
            const SizedBox(height: 80),
          ],
        ),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // the bill total stays in view while scrolling a long bill
              if (!stockOnly && total != 0)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(
                    children: [
                      Text(t('total'), style: Theme.of(context).textTheme.titleMedium),
                      if (creditAllowed &&
                          party != null &&
                          total - (payId == null ? 0 : (Money.parse(paid.text) ?? total)) > 0) ...[
                        const SizedBox(width: 10),
                        Text(
                          '${t('due')} ₹${Money.fmt(total - (payId == null ? 0 : (Money.parse(paid.text) ?? total)))}',
                          style: TextStyle(color: AppColors.due, fontWeight: FontWeight.w600),
                        ),
                      ],
                      const Spacer(),
                      Text(
                        '₹${Money.fmt(total)}',
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
                      ),
                    ],
                  ),
                ),
              Row(
                children: [
                  if (editing == null)
                    Expanded(
                      child: OutlinedButton(
                        style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                        onPressed: saving ? null : () => _save(andNew: true),
                        child: Text(t('save_new')),
                      ),
                    ),
                  if (editing == null) const SizedBox(width: 12),
                  Expanded(
                    flex: 2,
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(52),
                        textStyle: const TextStyle(fontSize: 18),
                      ),
                      onPressed: saving || !canEdit ? null : () => _save(),
                      icon: const Icon(Icons.check),
                      label: Text(t('save')),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Names that brought / took things for this party before (one tap to reuse).
  Future<void> _loadHaste() async {
    if (party == null) return;
    final rows = await App.read(context).db.getAll(
      "SELECT haste, MAX(created_at) AS t FROM vouchers WHERE party_id = ? AND haste IS NOT NULL AND haste <> '' "
      'GROUP BY haste ORDER BY t DESC LIMIT 4',
      [party!.id],
    );
    if (mounted) setState(() => hasteSuggestions = [for (final r in rows) r['haste'] as String]);
  }

  bool get _isBuying => type == VoucherType.purchase || type == VoucherType.purchaseReturn || (isHistory && hKind == 'purchase');

  /// Old entry: what kind, and a reminder that it only changes the khata.
  Widget _historyHeader(AppController app) {
    final t = app.t;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Card(
          color: Theme.of(context).colorScheme.secondaryContainer.withValues(alpha: 0.6),
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Text(t('old_entry_help').replaceAll('{date}', shortDate(Books.start)), style: Theme.of(context).textTheme.bodySmall),
          ),
        ),
        const SizedBox(height: 8),
        SegmentedButton<String>(
          showSelectedIcon: false,
          segments: [
            ButtonSegment(value: 'sale', label: Text(t('old_sale'))),
            ButtonSegment(value: 'purchase', label: Text(t('old_purchase'))),
            ButtonSegment(value: 'received', label: Text(t('old_received'))),
            ButtonSegment(value: 'paid', label: Text(t('old_paid'))),
          ],
          selected: {hKind},
          onSelectionChanged: (s) => setState(() => hKind = s.first),
        ),
      ]),
    );
  }

  Widget _partyCard(AppController app) {
    final t = app.t;
    final label = type == VoucherType.contra
        ? t('to_account')
        : widget.expenseMode
        ? t('expense')
        : t(partyGroups.first == LedgerGroup.supplier ? 'supplier' : 'party');
    return Card(
      child: ListTile(
        leading: CircleAvatar(child: Text(party?.pageNo ?? (party == null ? '+' : party!.name.characters.first))),
        title: Text(
          party?.name ??
              (_isBuying
                  ? t('pick_supplier')
                  : creditAllowed
                  ? '${t('walk_in')} / ${t('cash_sale')}'
                  : '$label – ${t('select')}'),
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          party == null
              ? label
              : [
                  if (party!.pageNo != null) '${t('page_no')} ${party!.pageNo}',
                  if (party!.phone != null) party!.phone!,
                ].join(' · '),
        ),
        trailing: party != null && (party!.group.isParty || party!.group == LedgerGroup.transporter)
            ? Row(mainAxisSize: MainAxisSize.min, children: [
                if (party!.group.isParty) BalanceText(party!.balance, supplier: party!.group == LedgerGroup.supplier),
                // edit phone, page no., opening balance … without leaving the bill
                IconButton(
                  key: const Key('voucher_party_edit'),
                  tooltip: t('edit_party'),
                  icon: const Icon(Icons.edit_outlined, size: 20),
                  onPressed: () async {
                    final before = party!;
                    await PartyForm.open(context, before.group, existing: before);
                    final fresh = await app.ledgers.byId(before.id);
                    if (mounted && party?.id == before.id) setState(() => party = fresh);
                  },
                ),
              ])
            : party != null
            ? null
            : const Icon(Icons.search),
        onTap: () async {
          final l = await pickLedger(context, groups: partyGroups, createAs: createAs);
          if (l != null) {
            setState(() {
              party = l;
              if (creditAllowed && editing == null) {
                payId = null; // default credit for named party
                paid.clear();
                paidTouched = false;
              }
            });
            _loadHaste();
          }
        },
        onLongPress: creditAllowed
            ? () => setState(() {
                party = null;
                payId ??= App.read(context).vouchers.sys('cash');
              })
            : null,
      ),
    );
  }

  String _plain(int paise) => Money.fmt(paise).replaceAll(',', '');

  /// Compact underline field for qty / rate inside an item row.
  InputDecoration _lineField(String label) => InputDecoration(
    labelText: label,
    isDense: true,
    filled: false,
    contentPadding: const EdgeInsets.symmetric(vertical: 6),
    border: const UnderlineInputBorder(),
    enabledBorder: const UnderlineInputBorder(),
    focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: Theme.of(context).colorScheme.primary, width: 1.6)),
  );

  /// Round off: tap ₹1 / ₹10 to round the bill to the nearest rupee / ten
  /// rupees, or type the difference yourself (−7, +3).
  Widget _roundCard(AppController app) {
    final t = app.t;
    void roundTo(int stepPaise) => setState(() {
      final base = totalBeforeRound;
      final r = (base / stepPaise).round() * stepPaise - base;
      roundCtl.text = r == 0 ? '' : Money.fmt(r).replaceAll(',', '');
      _syncPaid();
    });
    return Card(
      margin: const EdgeInsets.only(top: 8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: Row(
          children: [
            Text(t('round_off'), style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(width: 8),
            ActionChip(label: const Text('₹1'), onPressed: () => roundTo(100)),
            const SizedBox(width: 6),
            ActionChip(label: const Text('₹10'), onPressed: () => roundTo(1000)),
            const SizedBox(width: 10),
            Expanded(
              child: TextField(
                key: const Key('round_off'),
                controller: roundCtl,
                keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                textAlign: TextAlign.right,
                decoration: const InputDecoration(isDense: true, prefixText: '+/− ₹ ', hintText: '0'),
                onChanged: (_) => setState(_syncPaid),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Genuine GST bill (owner only): rate on the goods value, posted to the GST ledger.
  Widget _gstCard(AppController app) {
    final t = app.t;
    return Card(
      margin: const EdgeInsets.only(top: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.lock_outline, size: 16),
                const SizedBox(width: 6),
                Text(t('gst_bill'), style: Theme.of(context).textTheme.titleSmall),
                const Spacer(),
                if (gst > 0) Text('GST ₹${Money.fmt(gst)}', style: const TextStyle(fontWeight: FontWeight.bold)),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                for (final r in const [0, 500, 1200, 1800, 2800])
                  ChoiceChip(
                    label: Text(r == 0 ? t('no') : '${r ~/ 100}%'),
                    selected: gstRate == r,
                    onSelected: (_) => setState(() {
                      gstRate = r;
                      _syncPaid();
                    }),
                  ),
              ],
            ),
            if (gstRate > 0 && (party?.gstin == null))
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(t('gstin_missing'), style: TextStyle(color: Colors.orange.shade800, fontSize: 12)),
              ),
          ],
        ),
      ),
    );
  }

  /// Hamali + transport on the bill. Own vehicle = our income; outside
  /// transporter = we owe him (paid at day end), any extra = our margin.
  /// वराई: the company's driver hands over hamali money for the labourers.
  /// Kept out of the supplier's bill – it goes to cash and the day-end hamali.
  Widget _varhaiCard(AppController app) {
    final t = app.t;
    return Card(
      margin: const EdgeInsets.only(top: 8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          TextField(
            key: const Key('varhai'),
            controller: varhaiCtl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText: t('varhai_received'),
              border: const OutlineInputBorder(),
              isDense: true,
              prefixText: '₹ ',
              prefixIcon: const Icon(Icons.engineering, size: 20),
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 6),
          Text(t('varhai_help'), style: Theme.of(context).textTheme.bodySmall),
        ]),
      ),
    );
  }

  Widget _chargesCard(AppController app) {
    final t = app.t;
    final dense = InputDecoration(border: const OutlineInputBorder(), isDense: true, prefixText: '₹ ');
    final margin = transport - fare;
    return Card(
      margin: const EdgeInsets.only(top: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(t('charges'), style: Theme.of(context).textTheme.titleSmall),
                const Spacer(),
                if (lines.isNotEmpty)
                  Text('${t('goods_total')}: ₹${Money.fmt(itemsTotal)}', style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const Key('hamali'),
                    controller: hamaliCtl,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: dense.copyWith(labelText: t('hamali'), prefixIcon: const Icon(Icons.engineering, size: 20)),
                    onChanged: (_) => setState(_syncPaid),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    key: const Key('transport'),
                    controller: transportCtl,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: dense.copyWith(labelText: t('transport'), prefixIcon: const Icon(Icons.local_shipping, size: 20)),
                    onChanged: (_) => setState(() {
                      if (!fareTouched) fareCtl.clear();
                      _syncPaid();
                    }),
                  ),
                ),
              ],
            ),
            if (transport != 0 && isSale) ...[
              const SizedBox(height: 10),
              DropdownButtonFormField<String>(
                initialValue: transporterId ?? '_own',
                isExpanded: true,
                decoration: InputDecoration(labelText: t('vehicle'), border: const OutlineInputBorder(), isDense: true),
                items: [
                  DropdownMenuItem(value: '_own', child: Text(t('own_vehicle'))),
                  for (final tr in transporters) DropdownMenuItem(value: tr.id, child: Text(tr.display(app.english))),
                  DropdownMenuItem(value: '_new', child: Text('+ ${t('new_transporter')}')),
                ],
                onChanged: (v) async {
                  if (v == '_new') {
                    final id = await _addTransporter(app);
                    setState(() => transporterId = id ?? transporterId);
                  } else {
                    setState(() => transporterId = v == '_own' ? null : v);
                  }
                },
              ),
              if (transporterId != null) ...[
                const SizedBox(height: 10),
                TextField(
                  controller: fareCtl,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: dense.copyWith(labelText: t('transporter_fare'), hintText: _plain(transport)),
                  onChanged: (_) => setState(() => fareTouched = fareCtl.text.isNotEmpty),
                ),
                if (margin != 0)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      '${t('transport_margin')}: ₹${Money.fmt(margin)}',
                      style: TextStyle(color: margin > 0 ? Colors.green.shade700 : Colors.red.shade700),
                    ),
                  ),
              ],
            ],
          ],
        ),
      ),
    );
  }

  Future<String?> _addTransporter(AppController app) async {
    final t = app.t;
    final name = TextEditingController();
    final phone = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t('new_transporter')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: name,
              autofocus: true,
              decoration: InputDecoration(labelText: t('name')),
            ),
            TextField(
              controller: phone,
              keyboardType: TextInputType.phone,
              decoration: InputDecoration(labelText: t('phone')),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t('cancel'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(t('save'))),
        ],
      ),
    );
    if (ok != true || name.text.trim().isEmpty) return null;
    final id = await app.ledgers.create(name: name.text, group: LedgerGroup.transporter, phone: phone.text);
    transporters = await app.ledgers.list([LedgerGroup.transporter]);
    return id;
  }

  Widget _quickEntry(AppController app) {
    return TextField(
      controller: quick,
      focusNode: quickFocus,
      autofocus: editing == null && party != null,
      textInputAction: TextInputAction.done,
      onSubmitted: (s) {
        if (s.trim().isNotEmpty) _addParsed(s);
      },
      decoration: InputDecoration(
        labelText: app.t('quick_entry'),
        border: const OutlineInputBorder(),
        prefixIcon: const Icon(Icons.bolt),
        suffixIcon: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: Icon(_listening ? Icons.mic : Icons.mic_none, color: _listening ? Colors.red : null),
              tooltip: app.t('voice'),
              onPressed: _voice,
            ),
            IconButton(
              icon: const Icon(Icons.add_circle),
              onPressed: () => quick.text.trim().isEmpty ? null : _addParsed(quick.text),
            ),
          ],
        ),
      ),
    );
  }

  Widget _itemChips(AppController app) => SizedBox(
    height: 40,
    child: ListView(
      scrollDirection: Axis.horizontal,
      children: [
        for (final it in items)
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: ActionChip(
              avatar: it.shortCode == null
                  ? null
                  : CircleAvatar(child: Text(it.shortCode!, style: const TextStyle(fontSize: 10))),
              label: Text('${it.display(app.english)} (${fmtQty(it.stock)})'),
              onPressed: () => _addItem(it),
            ),
          ),
      ],
    ),
  );

  List<Widget> _lineRows(AppController app) => [
    for (var i = 0; i < lines.length; i++)
      Card(
        margin: const EdgeInsets.symmetric(vertical: 3),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 4, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(
                            text: lines[i].item.display(app.english),
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          TextSpan(
                            text:
                                '   ${app.t('stock_qty')}: ${fmtQty(lines[i].item.stock)} ${app.t('unit_${lines[i].item.unit}')}',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.close, size: 20),
                    onPressed: () => setState(() {
                      lines.removeAt(i);
                      _syncPaid();
                    }),
                  ),
                ],
              ),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    flex: 2,
                    child: TextField(
                      controller: lines[i].qty,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                      decoration: _lineField('${app.t('qty')} (${app.t('unit_${lines[i].item.unit}')})'),
                      onChanged: (_) => setState(() {
                        lines[i].qtyChanged();
                        _syncPaid();
                      }),
                    ),
                  ),
                  if (!stockOnly) ...[
                    const Padding(padding: EdgeInsets.symmetric(horizontal: 6, vertical: 8), child: Text('×')),
                    Expanded(
                      flex: 2,
                      child: TextField(
                        controller: lines[i].rate,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        decoration: _lineField(app.t('rate')),
                        onChanged: (_) => setState(() {
                          lines[i].rateChanged();
                          _syncPaid();
                        }),
                      ),
                    ),
                    const Padding(padding: EdgeInsets.symmetric(horizontal: 6, vertical: 8), child: Text('=')),
                    Expanded(
                      flex: 3,
                      child: TextField(
                        controller: lines[i].amt,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        textAlign: TextAlign.right,
                        style: const TextStyle(fontWeight: FontWeight.bold),
                        decoration: _lineField(app.t('amount')).copyWith(prefixText: '₹ '),
                        onChanged: (_) => setState(() {
                          lines[i].amountChanged();
                          _syncPaid();
                        }),
                      ),
                    ),
                  ],
                  const SizedBox(width: 8),
                ],
              ),
            ],
          ),
        ),
      ),
  ];
}
