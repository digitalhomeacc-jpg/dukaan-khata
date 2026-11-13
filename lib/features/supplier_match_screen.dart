import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../accounting/models.dart';
import '../accounting/voucher_service.dart';
import '../core/money.dart';
import '../core/theme.dart';
import '../shared/pdf_text.dart';
import '../shared/statement_parser.dart';
import '../shared/supplier_statement.dart';
import '../shared/widgets.dart';
import '../state/app_controller.dart';
import 'voucher_screen.dart';

/// कंपनी स्टेटमेंट जुळवा: the supplier's own account statement (PDF) set
/// against our khata – what is on theirs but not ours, and the other way.
class SupplierMatchScreen extends StatefulWidget {
  final Ledger supplier;
  const SupplierMatchScreen({super.key, required this.supplier});
  static Future<void> open(BuildContext context, Ledger supplier) =>
      Navigator.push(context, MaterialPageRoute(builder: (_) => SupplierMatchScreen(supplier: supplier)));
  @override
  State<SupplierMatchScreen> createState() => _SupplierMatchScreenState();
}

class _SupplierMatchScreenState extends State<SupplierMatchScreen> {
  List<SupplierLine>? lines; // the whole statement
  SupplierMatch? match; // from the books start on
  int ourBalance = 0, ourOpening = 0;
  int oldImported = 0; // old entries already on the khata from a statement
  /// Our units per statement unit (company: tonnes, us: bags → 20). Kept per supplier.
  double get factor => App.read(context).prefInt('stmt_factor_${widget.supplier.id}', 20).toDouble();
  String? progress;
  bool busy = false;
  String? error;

  Future<void> _pick() async {
    final app = App.read(context);
    final files = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['pdf']);
    if (files.isEmpty) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final Uint8List bytes = await files.single.readAsBytes();
      final parsed = SupplierStatement.parsePdfJson(await extractPdfText(bytes));
      if (parsed.isEmpty) throw StatementFormatException('pdf_unreadable');
      lines = parsed;
      await _rematch();
    } on StatementFormatException catch (e) {
      error = app.t('bank_err_${e.message}');
    } catch (e) {
      error = '$e';
    }
    if (mounted) setState(() => busy = false);
  }

  /// Statement lines from the books start on, against our entries of the same days.
  Future<void> _rematch() async {
    final app = App.read(context);
    final all = lines!;
    final inBooks = all.where((l) => !Books.isHistory(l.date)).toList();
    // invoices of the last week before the books start may be goods that came after it
    final weekBefore = isoDate(parseIso(Books.start).subtract(const Duration(days: 7)));
    final early = all.where((l) => Books.isHistory(l.date) && l.date.compareTo(weekBefore) >= 0).toList();
    final st = await app.ledgers.statement(widget.supplier.id, from: Books.start, to: all.last.date.compareTo(todayIso()) > 0 ? all.last.date : todayIso());
    // goods on each bill, in our unit (bags) – to match the company's tonnes
    final qty = {
      for (final q in await app.db.getAll(
          'SELECT il.voucher_id, SUM(il.qty) AS q FROM inventory_lines il JOIN vouchers v ON v.id = il.voucher_id '
          "WHERE v.party_id = ? AND v.deleted = 0 AND il.deleted = 0 AND v.vtype = 'purchase' GROUP BY il.voucher_id",
          [widget.supplier.id]))
        q['voucher_id'] as String: (q['q'] as num).toDouble()
    };
    final ours = [
      for (final r in st.rows)
        KhataEntry(r.voucherId, r.date, '${app.t('vt_${r.type.code}')}${r.details.isEmpty ? '' : ' · ${r.details}'}', r.credit, r.debit,
            qty: qty[r.voucherId] ?? 0)
    ];
    final fresh = await app.ledgers.byId(widget.supplier.id);
    final imported = await app.db.get(
        "SELECT COUNT(*) AS n FROM vouchers WHERE party_id = ? AND vtype = 'history' AND deleted = 0", [widget.supplier.id]);
    if (!mounted) return;
    setState(() {
      oldImported = imported['n'] as int;
      match = SupplierMatch.match(inBooks, ours, early: early, factor: factor);
      ourBalance = fresh?.balance ?? 0;
      ourOpening = fresh?.openingBalance ?? 0;
    });
  }

  /// Their balance just before our books start (+ = we owed them), less the
  /// invoices whose goods we entered after the start (counted there).
  int? get _theirOpening {
    final before = lines!.where((l) => Books.isHistory(l.date)).toList();
    if (before.isEmpty) return null;
    return before.last.balance - (match?.transit.fold<int>(0, (s, l) => s + l.debit) ?? 0);
  }

  /// Statement lines before the books start that become old entries.
  List<SupplierLine> get _oldLines {
    final transit = match?.transit.toSet() ?? {};
    return lines!.where((l) => Books.isHistory(l.date) && !transit.contains(l)).toList();
  }

  Future<void> _importOld() async {
    final app = App.read(context);
    final t = app.t;
    final old = _oldLines;
    // which of our items each statement product is (PPC → Wonder PPC …)
    final products = {for (final l in old) if (l.kind == 'invoice') StatementImport.productOf(l.text)}..remove('');
    final all = await app.stock.list();
    final map = <String, String?>{for (final p in products) p: StatementImport.guessItem(p, all)?.id};
    if (!mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: Text(t('sm_map_title')),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(t('sm_map_help').replaceAll('{n}', fmtQty(factor)), style: Theme.of(ctx).textTheme.bodySmall),
              const SizedBox(height: 10),
              for (final p in products) ...[
                Text(p, style: const TextStyle(fontWeight: FontWeight.w700)),
                DropdownButton<String?>(
                  isExpanded: true,
                  value: map[p],
                  items: [
                    DropdownMenuItem(value: null, child: Text(t('sm_map_none'))),
                    for (final i in all) DropdownMenuItem(value: i.id, child: Text(i.display(app.english))),
                  ],
                  onChanged: (v) => setD(() => map[p] = v),
                ),
                const SizedBox(height: 6),
              ],
              const SizedBox(height: 4),
              Text(t('sm_import_q').replaceAll('{n}', '${old.length}').replaceAll('{date}', shortDate(Books.start))),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t('cancel'))),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(t('sm_import_go'))),
          ],
        ),
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => busy = true);
    try {
      final added = await app.vouchers.importOldEntries(
        widget.supplier.id,
        [
          for (final l in old)
            OldLine(
              l.date,
              StatementImport.kindOf(l),
              l.amount,
              [if (l.qty > 0) '${fmtQty(l.qty)} ${t('sm_unit_them')}', l.text].join(' · '),
              stmtKind: l.kind,
              items: [
                if (map[StatementImport.productOf(l.text)] case final String id when l.kind == 'invoice' && l.qty > 0)
                  ItemLine.fromTotal(id, l.qty * factor, l.debit),
              ],
            ),
        ],
        app.actor,
        onProgress: (d, n) {
          if (mounted) setState(() => progress = '$d / $n');
        },
      );
      if (mounted) toast(context, t('sm_imported').replaceAll('{n}', '$added').replaceAll('{s}', '${old.length - added}'));
    } catch (e) {
      if (mounted) toast(context, errText(context, e), error: true);
    }
    progress = null;
    await _rematch();
    if (mounted) setState(() => busy = false);
  }

  /// मागील बाकी = the company's balance before the books start (owner, asks first).
  Future<void> _setOpening(int theirs) async {
    final app = App.read(context);
    final t = app.t;
    final l = await app.ledgers.byId(widget.supplier.id);
    if (l == null || !mounted) return;
    final ours = -theirs; // + = they owe us
    if (!await confirm(
        context,
        t('sm_set_opening_q')
            .replaceAll('{old}', '₹${Money.fmt(l.openingBalance.abs())}')
            .replaceAll('{new}', '₹${Money.fmt(ours.abs())} ${ours <= 0 ? t('we_owe') : t('they_owe')}'))) {
      return;
    }
    await app.ledgers.update(l.id,
        name: l.name,
        nameEn: l.nameEn,
        phone: l.phone,
        address: l.address,
        pageNo: l.pageNo,
        shortCode: l.shortCode,
        gstin: l.gstin,
        openingBalance: ours,
        creditLimit: l.creditLimit);
    await _rematch();
  }

  Future<void> _addDiscount(SupplierLine l) async {
    final app = App.read(context);
    await app.vouchers.save(
        VoucherInput(type: VoucherType.payment, date: l.date, partyId: widget.supplier.id, discount: l.credit, narration: '${app.t('co_discount_short')} – ${l.text}'),
        app.actor);
  }

  Future<void> _addAllDiscounts() async {
    final t = App.read(context).t;
    final list = match!.missing.where((l) => l.kind == 'discount').toList();
    if (!await confirm(context, t('sm_all_discounts_q').replaceAll('{n}', '${list.length}').replaceAll('{amt}', Money.fmt(list.fold(0, (s, l) => s + l.credit))))) return;
    setState(() => busy = true);
    try {
      for (final l in list) {
        await _addDiscount(l);
      }
    } catch (e) {
      if (mounted) toast(context, errText(context, e), error: true);
    }
    await _rematch();
    if (mounted) setState(() => busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final app = App.of(context);
    final t = app.t;
    final m = match;
    String bal(int theirs) => '₹${Money.fmt(theirs.abs())} ${theirs >= 0 ? t('we_owe') : t('sm_advance')}';
    return Scaffold(
      appBar: AppBar(title: Text('${t('sm_title')} · ${widget.supplier.name}')),
      body: ListView(padding: const EdgeInsets.fromLTRB(12, 8, 12, 24), children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(t('sm_help'), style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 10),
              FilledButton.icon(
                key: const Key('sm_pick'),
                onPressed: busy ? null : _pick,
                icon: busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.picture_as_pdf),
                label: Text(t(lines == null ? 'sm_pick' : 'sm_pick_again')),
              ),
              if (error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(error!, style: const TextStyle(color: AppColors.due))),
            ]),
          ),
        ),
        if (m != null && lines != null) ...[
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${shortDate(lines!.first.date)} – ${shortDate(lines!.last.date)} · ${lines!.length} ${t('sm_lines')}',
                    style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(height: 8),
                _cmp(t('sm_closing'), bal(lines!.last.balance), bal(-ourBalance), lines!.last.balance == -ourBalance),
                if (_theirOpening case final o?) ...[
                  _cmp(t('sm_opening').replaceAll('{date}', shortDate(Books.start)), bal(o), bal(-ourOpening), o == -ourOpening),
                  if (o != -ourOpening && app.actor.isOwner)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        key: const Key('sm_set_opening'),
                        icon: const Icon(Icons.sync_alt, size: 18),
                        label: Text(t('sm_set_opening')),
                        onPressed: busy ? null : () => _setOpening(o),
                      ),
                    ),
                ],
                for (final x in m.transit)
                  Padding(
                    padding: const EdgeInsets.only(left: 26, bottom: 4),
                    child: Text(t('sm_transit').replaceAll('{date}', shortDate(x.date)).replaceAll('{amt}', Money.fmt(x.debit)),
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppColors.ink)),
                  ),
                _cmp(t('sm_billed'), '₹${Money.fmt(m.stBilled)}', '₹${Money.fmt(m.ourBought)}', m.stBilled == m.ourBought),
                _cmp(t('sm_credited'), '₹${Money.fmt(m.stCredited)}', '₹${Money.fmt(m.ourPaid)}', m.stCredited == m.ourPaid),
                const SizedBox(height: 6),
                Text(
                    m.missing.isEmpty && m.extra.isEmpty
                        ? '✓ ${t('sm_all_match').replaceAll('{n}', '${m.matched}')}'
                        : t('sm_result').replaceAll('{ok}', '${m.matched}').replaceAll('{a}', '${m.missing.length}').replaceAll('{b}', '${m.extra.length}'),
                    style: TextStyle(fontWeight: FontWeight.w700, color: m.missing.isEmpty && m.extra.isEmpty ? AppColors.paid : AppColors.haldi)),
                const SizedBox(height: 8),
                // 1 टन = 20 बॅग (tap to change for this supplier)
                ActionChip(
                  key: const Key('sm_factor'),
                  avatar: const Icon(Icons.scale_outlined, size: 18),
                  label: Text(t('sm_factor').replaceAll('{n}', fmtQty(factor))),
                  onPressed: () async {
                    final ctl = TextEditingController(text: fmtQty(factor));
                    final v = await showDialog<String>(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        title: Text(t('sm_factor_q')),
                        content: TextField(controller: ctl, autofocus: true, keyboardType: TextInputType.number),
                        actions: [FilledButton(onPressed: () => Navigator.pop(ctx, ctl.text), child: Text(t('save')))],
                      ),
                    );
                    final n = int.tryParse(normalizeDigits(v ?? '').trim());
                    if (n != null && n > 0) {
                      await app.setPrefInt('stmt_factor_${widget.supplier.id}', n);
                      await _rematch();
                    }
                  },
                ),
              ]),
            ),
          ),
          // everything before the books start → old entries (change no number)
          if (_oldLines.isNotEmpty && app.actor.isOwner)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(t('sm_old_title').replaceAll('{date}', shortDate(Books.start)), style: const TextStyle(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 4),
                  Text(t('sm_old_help').replaceAll('{n}', '${_oldLines.length}').replaceAll('{have}', '$oldImported'),
                      style: Theme.of(context).textTheme.bodySmall),
                  const SizedBox(height: 8),
                  FilledButton.tonalIcon(
                    key: const Key('sm_import_old'),
                    onPressed: busy ? null : _importOld,
                    icon: busy && progress != null
                        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.history_edu),
                    label: Text(progress ?? t('sm_import_btn').replaceAll('{n}', '${_oldLines.length}')),
                  ),
                ]),
              ),
            ),
          if (m.rateDiff.isNotEmpty) ...[
            SectionTitle('${t('sm_rate_diff')} (${m.rateDiff.length})'),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
              child: Text(t('sm_rate_diff_help'), style: Theme.of(context).textTheme.bodySmall),
            ),
            for (final (l, e, diff) in m.rateDiff)
              Card(
                child: ListTile(
                  dense: true,
                  title: Text('${shortDate(l.date)} · ${fmtQty(l.qty)} ${t('sm_unit_them')} = ${fmtQty(e.qty)} ${t('sm_unit_us')}'),
                  subtitle: Text('${t('sm_theirs')} ₹${Money.fmt(l.debit)} · ${t('sm_ours')} ₹${Money.fmt(e.bought)}'),
                  trailing: Text('${diff > 0 ? '+' : '−'}₹${Money.fmt(diff.abs())}',
                      style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15, color: AppColors.haldi)),
                  onTap: () async {
                    await VoucherScreen.edit(context, e.voucherId);
                    await _rematch();
                  },
                ),
              ),
          ],
          if (m.missing.isNotEmpty) ...[
            SectionTitle('${t('sm_missing')} (${m.missing.length})'),
            if (m.missing.where((l) => l.kind == 'discount').length > 1)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                    key: const Key('sm_all_discounts'),
                    onPressed: busy ? null : _addAllDiscounts,
                    icon: const Icon(Icons.done_all),
                    label: Text(t('sm_all_discounts'))),
              ),
            for (final l in m.missing)
              Card(
                child: ListTile(
                  dense: true,
                  title: Text('${shortDate(l.date)} · ${t('sm_kind_${l.kind}')}'
                      '${l.qty > 0 ? ' · ${fmtQty(l.qty)} ${t('sm_unit_them')} = ${fmtQty(l.qty * factor)} ${t('sm_unit_us')}' : ''}'),
                  subtitle: Text(l.text, maxLines: 2, overflow: TextOverflow.ellipsis),
                  trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                    Text(Money.fmt(l.amount),
                        style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15, color: l.debit > 0 ? AppColors.due : AppColors.paid)),
                    if (l.kind != 'charge')
                      IconButton(
                        tooltip: t('sm_add'),
                        icon: const Icon(Icons.add_circle_outline),
                        onPressed: busy
                            ? null
                            : () async {
                                switch (l.kind) {
                                  case 'discount':
                                    await _addDiscount(l);
                                  case 'payment':
                                    await VoucherScreen.open(context, VoucherType.payment,
                                        partyId: widget.supplier.id, amount: l.credit, narration: l.text, date: l.date);
                                  default:
                                    // the invoice as a purchase: our item, MT → bags, the exact total
                                    final item = StatementImport.guessItem(StatementImport.productOf(l.text), await app.stock.list());
                                    if (!context.mounted) return;
                                    await VoucherScreen.open(context, VoucherType.purchase,
                                        partyId: widget.supplier.id,
                                        date: l.date,
                                        narration: l.text,
                                        lines: [if (item != null && l.qty > 0) ItemLine.fromTotal(item.id, l.qty * factor, l.debit)]);
                                }
                                await _rematch();
                              },
                      ),
                  ]),
                ),
              ),
          ],
          if (m.extra.isNotEmpty) ...[
            SectionTitle('${t('sm_extra')} (${m.extra.length})'),
            for (final e in m.extra)
              Card(
                child: ListTile(
                  dense: true,
                  title: Text('${shortDate(e.date)} · ${e.text}', maxLines: 2, overflow: TextOverflow.ellipsis),
                  trailing: Text(Money.fmt(e.bought > 0 ? e.bought : e.paid),
                      style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15, color: e.bought > 0 ? AppColors.due : AppColors.paid)),
                  onTap: () async {
                    await VoucherScreen.edit(context, e.voucherId);
                    await _rematch();
                  },
                ),
              ),
          ],
        ],
      ]),
    );
  }

  Widget _cmp(String label, String theirs, String ours, bool same) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(children: [
          Icon(same ? Icons.check_circle : Icons.error_outline, size: 18, color: same ? AppColors.paid : AppColors.haldi),
          const SizedBox(width: 8),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
              Text('${App.of(context).t('sm_theirs')}: $theirs   ·   ${App.of(context).t('sm_ours')}: $ours', style: Theme.of(context).textTheme.bodySmall),
            ]),
          ),
        ]),
      );
}
